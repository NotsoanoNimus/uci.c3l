module uci;

import std::io, std::thread, std::os::process, std::collections;


faultdef
	IMPOSSIBLE_STATE,   // the engine has transitioned, or attempted to transition to, an impossible state
	TIMEOUT,   // initializing the engine consumed too many `readline` calls
	INVALID_OPTION,   // the engine sent an option that couldn't be parsed
	INVALID_RESPONSE,   // the engine sent a response that couldn't be understood
	MALFORMED_RESPONSE,   // the engine's response doesn't follow the UCI protocol, or doesn't make sense otherwise
	MISSING_ID,   // the engine didn't identify itself
	NONEXISTENT_OPTION,   // the (case-INsensitive) option name to be set wasn't one given by the engine's start-up list
	UNEXPECTED_RESPONSE,   // an unexpected response was received from the engine based on its state
;

<* Only allow a certain amount of lines to be provided from an engine during init before the expected "uciok". *>
const usz INIT_LINE_LIMIT = 3_000;

<*
 The default delay to use when allowing the engine to initialize.
 This isn't a very important attribute; it mostly exists for engines which really need initial banners explicitly drained.
*>
const usz INIT_DEFAULT_DELAY = 1_000;


enum OptionType : char
{
	CHECK,
	SPIN,
	COMBO,
	BUTTON,
	STRING,
}

constdef EngineState : inline char
{
	STARTING,
	INITIALIZED,
	AWAIT_READY,
	READY,
	FINALIZED,
}

typedef EngineStateMachine @structlike = inline EngineState;

struct EngineOption (Printable)
{
	OptionType type;
	any value;
	any def;
	any min;   // only used with SPIN types
	any max;   // only used with SPIN types
	List{String} combo;   // only used with COMBO types
}

fn usz? EngineOption.to_format(&self, Formatter* f) @dynamic => @pool()
{
	usz n = f.printf("type %s", self.type.nameof.to_lower_tcopy())!;
	return n;
}

fn void EngineOption.set_default(&self)
{
	self.value = self.def;//.set ? self.def : {};
}

struct ChessEngine
{
	String command;
	SubProcess process;
	HashMap {String, EngineOption} options;
	EngineStateMachine state;
	String name;
	String author;
}

struct Uci
{
	Allocator allocator;
	ChessEngine engine;
	bool initialized;
	bool debug;
	OutStream debug_stream;
}


macro Uci*? start(Allocator allocator, String engine_command, String[] args = {}, bool debug = false, OutStream debug_stream = io::stdout(), usz init_delay_ms = INIT_DEFAULT_DELAY)
{
	Uci* new_uci = create(allocator, engine_command, args, debug, debug_stream)!;
	return new_uci.init(init_delay_ms);
}

fn Uci*? create(Allocator allocator, String engine_command, String[] args = {}, bool debug = false, OutStream debug_stream = io::stdout())
{
	if (allocator == tmem)
	{
		// There are many places where we need to use @pool and lift copied return values from the scope.
		//   In the case of using the temp allocator, these would be implicitly destroyed. Therefore, accommodating
		//   the temp allocator would actually require about double the code, or some really hacky ways to make
		//   sure we can lift copied values safely from the @pools with another allocator or another trick anyway.
		abort("UCI is not intended to use the temp allocator since it is arbitrating a runtime process.");
	}

	DString cmd;
	cmd.init(allocator);
	defer cmd.free();
	cmd.appendf(engine_command);

	@pool()
	{
		foreach (arg : args) cmd.appendf(` '%s'`, arg.treplace(`'`, `'\''`));
	};

	SubProcessOptions proc_opts = {
		.combined_stdout_stderr = true,
		.inherit_environment = true,
		.read_async = true,
		.no_window = true,
		.search_user_path = true,
		.inherit_stdio = false,
	};

	Uci* new_uci = allocator::new(allocator, Uci);
	defer catch allocator::free(allocator, new_uci);

	*new_uci = {
		.allocator = allocator,
		.debug = debug,
		.debug_stream = debug_stream,
		.engine = {
			.command = cmd.copy_str(allocator),
			.process = process::create({ engine_command }, options: proc_opts)!,
			.options = {},
			.state = (EngineStateMachine)EngineState.STARTING,
		},
	};
	new_uci.engine.options.init(allocator);

	return new_uci;
}

fn Uci*? Uci.init(&self, usz init_delay_ms = INIT_DEFAULT_DELAY)
{
	if (self.initialized) return self;

	// Before writing anything to the engine, make sure to drain whatever banner information
	//   or other garbage it might have displayed before it's interacted with at all. This
	//   aims to prevent any weird hangups or other potential bugs.
	thread::sleep_ms(init_delay_ms);
	self.drain()!;

	self.send("uci")!;

	// Typically, an engine will return its "id" fields first, followed by its options.
	@pool()
	{
		while (self.engine.state != EngineState.INITIALIZED)
		{
			String line = self.scan_line(tmem)!;
			self.parse_response(line.trim())!;
		}
	};

	self.initialized = true;
	self.dlog("\nInitialized UCI engine '%s'%s%s.", self.engine.name, self.engine.author.len ? ", authored by " : "", self.engine.author);
	foreach (key : self.engine.options.key_iter()) self.dlog("> %s = %s (%s)", key, self.engine.options[key]!.value, self.engine.options[key]!.type);

	self.await()!;

	return self;
}

fn void? Uci.set_option(&self, String name, any value) => @pool()
{
	String found_key;
	foreach (key : self.engine.options.key_iter())
	{
		if (key.to_lower_tcopy() != name.to_lower_tcopy()) continue;
		found_key = key;
		break;
	}
	if (!found_key.len) return NONEXISTENT_OPTION~;
	if (self.engine.options[found_key]!.type == BUTTON)
	{
		self.send("setoption name %s", found_key)!;
	}
	else
	{
		self.send("setoption name %s value %s", found_key, value)!;
		self.engine.options[found_key].value = value;
	}
	self.await()!;
}

fn void? Uci.drain(&self)
{
	char[1024] tmp;
	while (tmp[..] = 0, self.engine.process.read_stdout(&tmp, 1023)! > 0) self.dlog("DRAIN> %s", (ZString)&tmp);
}

fn void? Uci.await(&self)
{
	// Now ensure we wait to enter a ready state. This is recommended acording to the spec, as some engines might need time to finish init.
	self.send("isready")!;
	self.to_state(AWAIT_READY)!;
	@pool()
	{
		while (self.engine.state != EngineState.READY) self.parse_response(self.scan_line(tmem).trim())!;
	};
}

fn void? Uci.new_game(&self, String[] moves = {}, String fen = "") => @pool()
{
	self.send("ucinewgame")!;
	self.drain()!;

	DString position_str;
	position_str.tinit();
	position_str.append("position");
	if (fen.len > 0)
	{
		position_str.appendf(" fen %s", fen);
	}
	else if (moves.len > 0)
	{
		String joined_moves = string::tjoin(moves, " ");
		position_str.appendf(" startpos moves %s", joined_moves);
	}
	self.send(position_str.str_view())!;
	self.await()!;
}

fn void Uci.free(&self)
{
	self.engine.process.destroy();
	allocator::free(self.allocator, self.engine.command);
	allocator::free(self.allocator, self.engine.name);
	allocator::free(self.allocator, self.engine.author);
	self.engine.options.free();
	mem::zero_volatile(@as_char_view(*self));
}

fn void? Uci.stop(&self)
{
	usz counter;
	self.send("quit")!;
	// let the engine shut itself down, but limit that time to ~2 seconds
	while (thread::sleep_ms(50), counter++ < 40 && self.engine.process.is_running()!);
	self.engine.process.join()!;
}

fn void? Uci.send(&self, String format, args...) => @pool()
{
	// if (!@in(self.engine.state, EngineState.INITIALIZED, EngineState.RUNNING, EngineState.AWAIT_READY)) return
	String written = string::tformat(format, ...args);
	self.engine.process.write_to_stdin(string::tformat("%s\n", written))!;
	self.dlog("U> %s", written);
}


// ==============================================================
// ==============================================================
// ==============================================================
module uci @private;

import std::io, std::thread;


macro bool in(needle, ...) @private
{
    $for var $x = 0; $x < $vacount; $x++:
        assert($defined(needle == $vaarg[$x]), "Index %s: types '%s' (needle) and '%s' are not equatable", $x, $typeof(needle), $typeof($vaarg[$x]));
        if (needle == $vaarg[$x]) return true;
    $endfor
    return false;
}

macro any any_copy(Allocator allocator, #expr) @private @safemacro
{
	var v = #expr;
	$if types::implements_copy($typeof(v)):
		void* new_copy = v.copy(allocator);
	$else
		void* new_copy = allocator::new(allocator, $typeof(v));
		*($typeof(v)*)new_copy = v;
	$endif
	return any_make(new_copy, $typeof(v));
}


fn void? Uci.parse_response(&self, String response)
{
	if (!response.len) return;
	self.dlog("E> %s", response);

	String[] tokens = response.split(mem, " ", skip_empty: true);
	defer allocator::free(mem, tokens);
	foreach (&t : tokens) *t = t.trim();

	if (!tokens.len) return;

	switch (tokens[0])
	{
		case "uciok": self.to_state(INITIALIZED)!;
		case "readyok": self.to_state(READY)!;
		case "id": @pool()
		{
			if (self.engine.state != EngineState.STARTING) return UNEXPECTED_RESPONSE~;   // engine "id" values can only be sent on startup
			if (tokens.len < 3) return MALFORMED_RESPONSE~;
			String[] tokens_globbed = response.tsplit(" ", max: 3, skip_empty: true);
			foreach (&t : tokens) *t = t.trim();
			switch (tokens[1])
			{
				case "name":
					self.engine.name = tokens_globbed[2].copy(mem);
					self.dlog(">>>> Engine name: %s", self.engine.name);
				case "author":
					self.engine.author = tokens_globbed[2].copy(mem);
					self.dlog(">>>> Engine author(s): %s", self.engine.author);
				default: self.dlog("Unknown `id` token '%s' in response. Skipping...", tokens[1]);
			}
		};
		case "option": @pool()
		{
			if (self.engine.state != EngineState.STARTING) return UNEXPECTED_RESPONSE~;   // options can only be sent on startup
			if (tokens.len < 5) return MALFORMED_RESPONSE~;   // at least 5 tokens MUST be present per option line
			if (tokens[1] != "name") return INVALID_OPTION~;

			DString log_entry;
			log_entry.tinit();

			DString option_name;
			option_name.tinit();
			option_name.append(tokens[2]);

			usz idx = 2;
			while (idx++, idx < tokens.len && tokens[idx] != "type") option_name.appendf(" %s", tokens[idx]);
			if (idx >= tokens.len) return INVALID_OPTION~;   // missing required "type"

			OptionType of_type = enum_by_name(OptionType, tokens[++idx].to_upper_tcopy()) ?? INVALID_OPTION~!;
			log_entry.appendf(">>>> Option '%s' of type '%s'", option_name.str_view(), of_type);

			String[] the_rest = tokens[idx..];
			EngineOption eo = {
				.type = of_type,
				.min = any_copy(mem, isz.min),
				.max = any_copy(mem, isz.max),
			};
			for (idx = 1; the_rest.len >= 2; idx = 1)
			{
				switch (the_rest[0])
				{
					case "min":
					case "max":   // should only be seen with SPIN types, always 'min ####' (2 tokens)
						if (of_type != SPIN) return INVALID_OPTION~;
						isz num = the_rest[1].to_integer(isz)!;
						if (the_rest[0] == "min") eo.min = any_copy(mem, num);
						if (the_rest[0] == "max") eo.max = any_copy(mem, num);
						idx = 2;
					case "default":   // valid for all types except button
						switch (of_type)
						{
							case BUTTON: return INVALID_OPTION~;
							case CHECK: eo.def = any_copy(mem, the_rest[1] == "true");
							case SPIN: eo.def = any_copy(mem, the_rest[1].to_integer(isz)!);
							case COMBO:
							case STRING:
								DString collected_default;
								collected_default.tinit();
								collected_default.append(the_rest[1]);
								for (idx = 2; idx < the_rest.len; idx++)
								{
									if (in(the_rest[idx], "type", "default", "min", "max", "var")) break;
									collected_default.appendf(" %s", the_rest[idx]);
								}
								eo.def = any_copy(mem, collected_default.copy_zstr(mem));
						}
						;
					case "var":   // should only be seen with COMBO types
						if (of_type != COMBO) return INVALID_OPTION~;
						if (!eo.combo.is_initialized()) eo.combo.init(mem);
						DString collected_var;
						collected_var.tinit();
						collected_var.append(the_rest[1]);
						for (idx = 2; idx < the_rest.len; idx++)
						{
							if (the_rest[idx] == "var") break;
							collected_var.appendf(" %s", the_rest[idx]);
						}
						eo.combo.push(collected_var.copy_str(mem));
				}
				the_rest = the_rest[idx..];
			}
			eo.set_default();
			self.engine.options[option_name.str_view()] = eo;
		};
	}
}

fn void Uci.dlog(&self, String format, args...)
{
	if (self.debug && self.debug_stream != null) @pool()
	{
		io::fprintfn(self.debug_stream, string::tformat(format, ...args));
	};
}

macro Uci.to_state(&self, EngineState new_state) => self.engine.state.transition(new_state);

fn String? Uci.scan_line(&self, Allocator allocator, usz timeout = 0) => @pool()
{
	DString line;
	line.tinit();
	char b;
	usz subctr;
	while (true)
	{
		if (self.engine.process.read_stdout(&b, 1)! == 0)   // awaiting input, but nonblocking
		{
			thread::sleep_ms(1);
			subctr++;
			if (subctr >= timeout && timeout > 0) return TIMEOUT~;
			continue;
		}
		if (b == '\r' || !b) continue;
		if (b == '\n') break;
		line.append_char(b);
	}
	return line.copy_str(allocator);
}


fn void? EngineStateMachine.transition(&self, EngineState to_state)
{
	EngineState from_state = *self;
	switch (to_state)
	{
		case INITIALIZED:
			if (from_state != STARTING) return IMPOSSIBLE_STATE~;
		default: ;
	}
	*self = (EngineStateMachine)to_state;
}

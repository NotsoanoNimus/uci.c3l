module uci;

import std::io, std::thread, std::os::process, std::collections;


faultdef
	ALREADY_CALCULATING,   // the engine is already in the middle of calculating the best moves for a position
	IMPOSSIBLE_STATE,   // the engine has transitioned, or attempted to transition to, an impossible state
	TIMEOUT,   // initializing the engine consumed too many `readline` calls
	INFINITE_SEARCH,   // the search was going to block infinitely; not permitted
	INVALID_OPTION,   // the engine sent an option that couldn't be parsed
	INVALID_RESPONSE,   // the engine sent a response that couldn't be understood
	MALFORMED_RESPONSE,   // the engine's response doesn't follow the UCI protocol, or doesn't make sense otherwise
	MISSING_ID,   // the engine didn't identify itself
	NO_MOVES_FOUND,   // the engine couldn't find a valid move for the given position
	NONEXISTENT_OPTION,   // the (case-INsensitive) option name to be set wasn't one given by the engine's start-up list
	POSITION_REQUIRED,   // the `position` keyword has not yet been provided to the engine
	SEARCH_INCOMPLETE,   // the async engine is still searching - you should use "join" first before attempting to get the best move result
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

enum EngineState : char
{
	STARTING,
	INITIALIZED,
	AWAIT_READY,
	READY,
	NEW_GAME,
	HAS_POSITION,
	CALCULATING,
	FINALIZED,
}

alias EngineStateMachine = EngineState;

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
	Mutex out_mutex;
	Mutex in_mutex;
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
			.state = STARTING,
		},
	};
	new_uci.engine.options.init(allocator);

	return new_uci;
}

fn Uci*? Uci.init(&self, usz init_delay_ms = INIT_DEFAULT_DELAY)
{
	if (self.initialized) return self;
	self.out_mutex.init()!;
	self.in_mutex.init()!;

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

fn void Uci.free(&self)
{
	self.engine.process.destroy();
	self.out_mutex.destroy();
	self.in_mutex.destroy();
	allocator::free(self.allocator, self.engine.command);
	allocator::free(self.allocator, self.engine.name);
	allocator::free(self.allocator, self.engine.author);
	self.engine.options.free();
	mem::zero_volatile(@as_char_view(*self));
}

fn void? Uci.exit(&self)
{
	defer (void)self.to_state(FINALIZED);
	usz counter;
	self.send("quit")!;
	// let the engine shut itself down, but limit that time to ~2 seconds
	while (thread::sleep_ms(50), counter++ < 40 && self.engine.process.is_running()!);
	self.engine.process.join()!;
}

fn void? Uci.stop(&self)
{
	if (self.engine.state != CALCULATING) return;
	self.send("stop")!;
	// self.await()!;
	// self.drain()!;
	// self.to_state(HAS_POSITION)!;
}

fn void? Uci.send(&self, String format, args...) => @pool()
{
	// NOTE: no need to worry about the engine state here -- UCI is designed so that STDIN is always available to the child
	String written = string::tformat(format, ...args);
	self.engine.process.write_to_stdin(string::tformat("%s\n", written))!;
	self.dlog("U> %s", written);
}

<* A simple options structure used when setting multiple options with `set_options`. *>
struct UciOption
{
	String name;
	any value;
}

fn void? Uci.set_options(&self, UciOption... options) @inline
{
	foreach (option : options) self.set_option(option.name, option.value)!;
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

<* Return how many lines are calculated each time the engine is asked. Defaults to 1 when the key isn't present, per the spec. *>
fn usz Uci.pvs(&self) => types::any_to_int(self.engine.options["MultiPV"].value, usz) ?? 1;

fn void? Uci.drain(&self, char[]* into = null)
{
	char* store;
	usz total_bytes;
	if (into != null) store = allocator::new_array(self.allocator, char, 1023);
	defer catch allocator::free(self.allocator, store);
	char[1024] tmp;
	while (tmp[..] = 0, self.engine.process.read_stdout(&tmp, 1023)! > 0)
	{
		self.dlog("DRAIN> %s", (ZString)&tmp);
		if (into != null) store[total_bytes:1023] = tmp[:1023];
		total_bytes += ((ZString)&tmp).len();
	}
	if (into != null) *into = store[:total_bytes];
}

fn void? Uci.await(&self)
{
	// Now ensure we wait to enter a ready state. This is recommended acording to the spec, as some engines might need time to finish init.
	EngineStateMachine push_state = self.engine.state; // push state
	self.send("isready")!;
	self.to_state(AWAIT_READY)!;
	@pool()
	{
		while (self.engine.state != EngineState.READY) self.parse_response(self.scan_line(tmem).trim())!;
	};
	self.engine.state = push_state; // pop state
}

fn void? Uci.new_game(&self, String[] moves = {}, String fen = "") => @pool()
{
	self.send("ucinewgame")!;
	self.drain()!;
	self.to_state(NEW_GAME)!;

	DString position_str;
	position_str.tinit();
	position_str.append("position ");
	if (fen.len > 0)
	{
		position_str.appendf("fen %s", fen);
	}
	else if (moves.len > 0)
	{
		foreach (&move : moves) *move = move.trim();
		String joined_moves = string::tjoin(moves, " ");
		position_str.appendf("startpos moves %s", joined_moves);
	}
	else
	{
		position_str.append("startpos");
	}
	self.send(position_str.str_view())!;
	self.to_state(HAS_POSITION)!;
	self.await()!;
}

<* Search parameters to constrain the UCI engine's search for a next move. *>
struct UciSearchParams
{
	usz depth;
	usz nodes;
	usz move_time;
	usz moves_to_go;
	usz wtime;
	usz btime;
	usz winc;
	usz binc;
}

<* Contains a single evaluation emitted by the chess engine. *>
struct UciEvaluation
{
	bool dirty;
	usz multipv;
	usz depth;
	usz seldepth;
	usz time;
	usz nodes;
	usz nps;
	String move;
	String[] continuation;
	isz evaluation;
	isz mate;
}

fn void UciEvaluation.free(&self, Allocator allocator)
{
	if (!self.dirty) return;
	self.move.free(allocator);
	foreach (c : self.continuation) c.free(allocator);
}

<* Contains a flat array of evaluation results, sliced based on the current MultiPV setting. *>
struct UciResult
{
	Allocator allocator;
	UciEvaluation[] results;
	usz total_evals;
	String best_move;
}

fn void UciResult.free(&self)
{
	allocator::free(self.allocator, self.results);
	if (self.best_move.len) allocator::free(self.allocator, self.best_move);
}

<* Return the best move from the set of engine results. *>
fn UciEvaluation? UciResult.best(&self)
{
	foreach (&result : self.results) if (result.move == self.best_move) return *result;
	return NO_MOVES_FOUND~!;
}

struct UciResultAsync @if (env::POSIX || env::WIN32)
{
	inline UciResult r;
	Uci* uci;
	Thread worker;
	Mutex mutex;
	bool searching;
	bool* stop_flag;
}

fn void UciResultAsync.free(&self) @if (env::POSIX || env::WIN32)
{
	self.r.free();
	self.mutex.destroy();
}

<* Return the best move from the set of engine results. *>
fn UciEvaluation? UciResultAsync.best(&self) @if (env::POSIX || env::WIN32)
{
	self.mutex.@in_lock()
	{
		if (self.searching) return SEARCH_INCOMPLETE~;
		return self.r.best();
	};
}

<*
 Stop the child thread and return any immediate results.
 This intentionally pauses for 0.5s to give the engine time to report at least one set of PVs.
*>
fn void? UciResultAsync.join(&self, bool no_sleep = false) @if (env::POSIX || env::WIN32)
{
	if (!no_sleep) thread::sleep_ms(500);
	self.stop_flag = &&true;
	self.worker.join()!;
	self.uci.stop()!;
}

<*
 While the engine/adapter itself cannot use the temp allocator, individual results from a BLOCKING CALL can be temporarily allocated.
*>
fn UciResult? Uci.go(&self, Allocator allocator, UciSearchParams params, bool* stop = null)
{
	if (params.depth == 0 && params.move_time == 0 && stop == null) return INFINITE_SEARCH~;
	_dispatch_go(self, &params)!;
	UciResult r = {
		.allocator = allocator,
		.results = allocator::new_array(allocator, UciEvaluation, self.pvs())[:self.pvs()],
	};
	UciEvaluation eval;
	bool stopped;
	while (true)
	{
		if (!stopped && stop != null && @volatile_load(*stop))
		{
			self.stop()!;
			stopped = true; // send the 'stop' command when signaled, then keep consuming until `bestnove`
		}
		if (r.best_move = self.read_info(&eval, stop), r.best_move != {}) break;
		self.update_results(r.results, &eval);
	}
	return r;
}

<*
 NOTE: Use of the temp allocator here is forbidden, since tmem is NOT thread-safe.
*>
fn UciResultAsync*? Uci.go_async(&self, Allocator allocator, UciSearchParams params, bool* stop = null) @if (env::POSIX || env::WIN32)
{
	// Note that an infinite search is ok in async mode, since there's a way to cancel it with `join`
	if (allocator == tmem) abort("Cannot return async engine results with the temp allocator because it isn't thread-safe. Use a different allocator.");
	_dispatch_go(self, &params)!;
	UciResultAsync* r = allocator::new(allocator, UciResultAsync);
	*r = {
		.allocator = allocator,
		.uci = self,
		.results = allocator::new_array(allocator, UciEvaluation, self.pvs())[:self.pvs()],
		.stop_flag = stop,
		.searching = true,
	};
	r.mutex.init()!;
	r.worker.create(&_go_async_thread, r)!;
	return r;
}

fn int _go_async_thread(void* _ctx) @local @if (env::POSIX || env::WIN32) => @pool_init(mem, 1024 * 1024)
{
	bool stopped;
	UciResultAsync* self = _ctx;
	UciEvaluation eval;
	while (true)
	{
		if (!stopped && self.stop_flag != null && @volatile_load(*self.stop_flag))
		{
			self.uci.stop()!!;
			stopped = true; // send the 'stop' command when signaled, then keep consuming until `bestnove`
		}
		if (self.best_move = self.uci.read_info(&eval, self.stop_flag), self.best_move != {}) break;
		self.mutex.@in_lock()
		{
			self.uci.update_results(self.results, &eval);
		};
	}
	self.searching = false;
	return 0;
}

<*
 @param [&inout] uci : "Reference to the current UCI instance."
 @param [&inout] params : "Reference to the params to use when kicking off."
*>
fn void? _dispatch_go(Uci* uci, UciSearchParams* params) @local
{
	if (uci.engine.state == CALCULATING) return ALREADY_CALCULATING~;
	if (uci.engine.state != HAS_POSITION) return POSITION_REQUIRED~;
	uci.to_state(CALCULATING)!;
	@pool()
	{
		DString go_cmd;
		go_cmd.tinit();
		go_cmd.append("go");
		// ordered based on spec definition
		if (params.wtime > 0) go_cmd.appendf(" wtime %d", params.wtime);
		if (params.btime > 0) go_cmd.appendf(" btime %d", params.btime);
		if (params.winc > 0) go_cmd.appendf(" winc %d", params.winc);
		if (params.binc > 0) go_cmd.appendf(" binc %d", params.binc);
		if (params.moves_to_go > 0) go_cmd.appendf(" movestogo %d", params.moves_to_go);
		if (params.depth > 0) go_cmd.appendf(" depth %d", params.depth);
		if (params.nodes > 0) go_cmd.appendf(" nodes %d", params.nodes);
		if (params.move_time > 0) go_cmd.appendf(" movetime %d", params.move_time);
		if (!params.move_time && !params.depth) go_cmd.appendf(" infinite");
		uci.send(go_cmd.str_view())!;
	};
}


// ==============================================================
// ==============================================================
// ==============================================================
module uci @private;

import std::io, std::thread;


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
									if (array::contains((String[]){"type", "default", "min", "max", "var"}, the_rest[idx])) break;
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
		self.out_mutex.@in_lock()
		{
			io::fprintfn(self.debug_stream, string::tformat(format, ...args));
		};
	};
}

macro Uci.to_state(&self, EngineState new_state) => self.engine.state.transition(new_state);

fn String? Uci.scan_line(&self, Allocator allocator, usz timeout = 0) => @pool()
{
	DString line;
	line.tinit();
	char b;
	usz subctr;
	self.in_mutex.@in_lock()
	{
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
	};
	self.dlog("E> %s", line.str_view());
	return line.copy_str(allocator);
}

<*
 @param [&inout] with_eval : "The evaluation to update in the results array."
*>
fn void Uci.update_results(&self, UciEvaluation[] results, UciEvaluation* with_eval)
{
	with_eval.multipv = max(1, with_eval.multipv);
	if (with_eval.multipv > results.len) return;   // don't do anything if the PV is out-of-range
	results[with_eval.multipv - 1].free(self.allocator);
	results[with_eval.multipv - 1] = *with_eval;
}

<*
 @param [&inout] into : "The `UciEvaluation` struct to populate."
*>
fn String Uci.read_info(&self, UciEvaluation* into, bool* stop) => @pool()
{
	String line;
	if (catch @try(line, self.scan_line(tmem))) return "<ERR>";

	if (line.len > 9 && line[:9] == "bestmove ")
	{
		String[] tokens = line.tsplit(" ", max: 3, skip_empty: true);
		return tokens[1].copy(self.allocator);
	}

	if (line.len < 5 || line[:5] != "info ") return "";

	String[] tokens = line.tsplit(" ", skip_empty: true);
	foreach (&t : tokens) *t = t.trim();

	*into = { .dirty = true };
	while (tokens.len > 0)
	{
		tokens = tokens[1..];   // always discards the "info" item right away
		if (tokens.len < 2) break;
		String id = tokens[0].to_lower_tcopy();
		$foreach $field : { "depth", "multipv", "seldepth", "time", "nodes", "nps" } :
			if (id == $field)
			{
				if (catch @try(into.$field, tokens[1].to_integer(usz))) self.dlog("ERROR reading response field %s", $field);
				tokens = tokens[1..];
				continue;
			}
		$endforeach
		switch (id)
		{
			case "info": continue;
			case "score":
				if (tokens.len < 3) { self.dlog("ERROR getting 'score' info: not enough tokens."); continue; }
				if (tokens[1] == "cp")   // centipawns
				{
					if (catch @try(into.evaluation, tokens[2].to_integer(usz))) self.dlog("ERROR reading evaluation score: not a valid unsigned integer.");
				}
				else if (tokens[1] == "mate")   // forced checkmate
				{
					if (catch @try(into.mate, tokens[2].to_integer(isz))) self.dlog("ERROR reading mate score: not a valid integer.");
				}
				else
				{
					self.dlog("ERROR getting 'score' info: unknown type '%s'.", tokens[1]);
				}
				tokens = tokens[1..]; // extra shift to save one loop iteration
			case "pv":
				if (tokens.len < 2) { self.dlog("ERROR getting 'pv' info: not enough tokens."); continue; }
				tokens = tokens[1..]; // shift
				if (!_is_pure_coordinate(tokens[0])) { self.dlog("ERROR getting 'pv' move token: '%s' is not a valid coordinate.", tokens[0]); continue; }
				into.move = tokens[0].copy(self.allocator);
				tokens = tokens[1..]; // shift
				usz cont_count;
				for (; cont_count < tokens.len && _is_pure_coordinate(tokens[cont_count]); cont_count++);
				if (cont_count)
				{
					into.continuation = allocator::new_array(self.allocator, String, cont_count);
					foreach (i, token : tokens[:cont_count]) into.continuation[i] = token.copy(self.allocator);
					tokens = tokens[cont_count..];
				}
		}
	}

	return "";
}

<*
 Moves in UCI are expected to be in a pure coordinate notation, per https://www.chessprogramming.org/Algebraic_Chess_Notation

 <move descriptor> ::= <from square><to square>[<promoted to>]
 <square>        ::= <file letter><rank number>
 <file letter>   ::= 'a'|'b'|'c'|'d'|'e'|'f'|'g'|'h'
 <rank number>   ::= '1'|'2'|'3'|'4'|'5'|'6'|'7'|'8'
 <promoted to>   ::= 'q'|'r'|'b'|'n'
*>
fn bool _is_pure_coordinate(String token) @local => @pool()
{
	const AsciiCharset FILE_LETTER = ascii::@create_set("abcdefgh");
	const AsciiCharset RANK_NUMBER = ascii::@create_set("12345678");
	const AsciiCharset PROMOTION_TYPE = ascii::@create_set("qrbn");

	if (token.len < 4 || token.len > 5) return false;
	token = token.to_lower_tcopy();

	bool squares_ok = FILE_LETTER.contains(token[0]) && RANK_NUMBER.contains(token[1]) && FILE_LETTER.contains(token[2]) && RANK_NUMBER.contains(token[3]);
	return squares_ok && (token.len == 4 || PROMOTION_TYPE.contains(token[4]));
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

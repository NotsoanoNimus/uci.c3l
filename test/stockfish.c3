module test_stockfish;

import std::io, std::thread;
import uci;


fn void? Uci.show_board(&self)
{
	char[] board;
	self.drain()!;   // empty any pending output contents
	self.send("d")!;   // stockfish has the custom "d" command to display an ASCII board
	thread::sleep_ms(200);
	self.drain(into: &board)!;
	io::printfn("BOARD STATE:\n%s", (String)board);
	allocator::free(self.allocator, board);
}


fn void main(String[] args)
{
	if (args.len != 2)
	{
		io::eprintfn("USAGE:  %s {path-to-stockfish}", args[0]);
		return;
	}
	String stockfish_path = args[1];
	io::printfn("Using Stockfish at: |%s|", stockfish_path);

	Uci* fish = uci::start(mem, stockfish_path, debug: false)!!;
	defer
	{
		fish.free();
		allocator::free(mem, fish);
	}
	fish.set_options({"Skill Level", &&3}, {"MultiPV", &&5})!!;
	fish.new_game(fen: "8/2k2p2/2b3p1/P1p1Np2/1p3b2/1P1K4/5r2/R3R3 b - - 0 1")!!;
	fish.show_board()!!;

	UciResultAsync* results_pool = fish.go_async(mem, { .depth = 30, .move_time = 10_000 })!!;
	io::printfn("waiting");
	thread::sleep_ms(2_000);   // non-blocking 'go' means you can do w/e you want here

	io::printfn("join early");
	results_pool.join()!!;
	io::printfn("ASYNC: %s", results_pool.best()!!.move);
	foreach (r : results_pool.results) if (r.dirty) io::printfn("%d - %s %d - %s %s", r.multipv, r.mate ? "mate" : "eval", r.mate ?: r.evaluation, r.move, r.continuation);
	results_pool.free();

	io::printfn("Black plays Bb5...");
	fish.move("c6b5")!!;
	fish.show_board()!!;

	UciResult result = fish.go(mem, { .depth = 15, .move_time = 5_000 })!!;
	io::printfn("SYNCHRONOUS: %s", result.best()!!.move);
	foreach (r : result.results) if (r.dirty) io::printfn("%d - %s %d - %s %s", r.multipv, r.mate ? "mate" : "eval", r.mate ?: r.evaluation, r.move, r.continuation);

	fish.exit()!!;
}

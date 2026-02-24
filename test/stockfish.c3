module test_stockfish;

import std::io, std::thread;
import uci;


fn void main(String[] args)
{
	if (args.len != 2)
	{
		io::eprintfn("USAGE:  %s [path-to-stockfish]", args[0]);
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
	UciResultAsync* results_pool = fish.go_async(mem, { .depth = 30, .move_time = 10_000 })!!;
	io::printfn("waiting");
	thread::sleep_ms(2_000);
	io::printfn("now join");
	results_pool.join()!!;
	io::printfn("async: %s", results_pool.best()!!.move);
	results_pool.free();
	fish.new_game(fen: "8/2k2p2/2b3p1/P1p1Np2/1p3b2/1P1K4/5r2/R3R3 b - - 0 1")!!;
	UciResult result = fish.go(mem, { .depth = 15, .move_time = 5_000 })!!;
	io::printfn("SYNCHRONOUS: %s", result.best()!!.move);
	foreach (r : result.results) io::printfn("%d - %s %d - %s %s", r.multipv, r.mate ? "mate" : "eval", r.mate ?: r.evaluation, r.move, r.continuation);
	fish.exit()!!;
}

module test_leela;

import std::io, std::thread;
import uci;


fn void main(String[] args)
{
	if (args.len != 2)
	{
		io::eprintfn("USAGE:  %s [path-to-lc0]", args[0]);
		return;
	}
	String leela_path = args[1];
	io::printfn("Using Leela (lc0) at: |%s|", leela_path);

	Uci* leela = uci::start(mem, leela_path, debug: false)!!;
	defer
	{
		leela.free();
		allocator::free(mem, leela);
	}
	leela.set_options({"Backend", &&"trivial"}, {"MultiPV", &&5})!!;
	leela.new_game(fen: "8/2k2p2/2b3p1/P1p1Np2/1p3b2/1P1K4/5r2/R3R3 b - - 0 1")!!;
	UciResultAsync* results_pool = leela.go_async(mem, { .depth = 30, .move_time = 10_000 })!!;
	io::printfn("waiting");
	thread::sleep_ms(2_000);
	io::printfn("now join");
	results_pool.join()!!;
	io::printfn("async: %s", results_pool.best()!!.move);
	results_pool.free();
	leela.new_game(fen: "8/2k2p2/2b3p1/P1p1Np2/1p3b2/1P1K4/5r2/R3R3 b - - 0 1")!!;
	UciResult result = leela.go(mem, { .depth = 15, .move_time = 5_000 })!!;
	io::printfn("SYNCHRONOUS: %s", result.best()!!.move);
	foreach (r : result.results) io::printfn("%d - %s %d - %s %s", r.multipv, r.mate ? "mate" : "eval", r.mate ?: r.evaluation, r.move, r.continuation);
	leela.exit()!!;
}

module test_stockfish;

import std::io;
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

	Uci* fish = uci::start(mem, stockfish_path, debug: true)!!;
	defer
	{
		fish.free();
		allocator::free(mem, fish);
	}
	fish.set_option("Skill Level", &&3)!!;
	fish.new_game(fen: "8/2k2p2/2b3p1/P1p1Np2/1p3b2/1P1K4/5r2/R3R3 b - - 0 1")!!;
	fish.stop()!!;
}

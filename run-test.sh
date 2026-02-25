#!/bin/bash
#
# Tests run with Stockfish by default. The submodule should always remain pinned to a stable release.
#
#
TEST_OPTS="-O${2:-0} --libdir .. --lib uci"

echo -e "\n===== Running unit tests..."
c3c compile-test ${TEST_OPTS} ./test/unit/ || { echo "Unit tests failed. Aborting." && exit 1; }

if [[ $# -eq 0 || "${1,,}" == "stockfish" ]]; then
	STOCKFISH="${STOCKFISH:-./test/stockfish/src/stockfish}"
	echo -e "\n\n===== Attempting to test with Stockfish..."
	if [[ ! -x ${STOCKFISH} ]]; then
		echo "ERROR: Please install/update and compile Stockfish in order to run tests."
		echo
		exit 1
	fi

	c3c compile-run ${TEST_OPTS} ./test/stockfish.c3 -- "${STOCKFISH}" \
		|| { echo "Stockfish test failed. Aborting." && exit 1; }
fi


if [[ $# -eq 0 || "${1,,}" == "leela" ]]; then
	LC0="${LC0:-./test/lc0/build/release/lc0}"
	echo -e "\n\n===== Attempting to test with Leela (lc0)..."
	if [[ ! -x ${LC0} ]]; then
		echo "ERROR: Please install/update and compile Leela (lc0) in order to run tests."
		echo
		exit 1
	fi

	c3c compile-run ${TEST_OPTS} ./test/leela.c3 -- "${LC0}" \
		|| { echo "Leela (lc0) test failed. Aborting." && exit 1; }
fi

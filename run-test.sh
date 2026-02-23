#!/bin/bash
#
# Tests run with Stockfish by default. The submodule should always remain pinned to a stable release.
#
#
TEST_OPTS="-O${1:-0} --libdir .. --lib uci"

echo -e "\n===== Running unit tests..."
c3c compile-test ${TEST_OPTS} ./test/unit/ || { echo "Unit tests failed. Aborting." && exit 1; }

STOCKFISH="${STOCKFISH:-./test/stockfish/src/stockfish}"
echo -e "\n\n===== Attempting to test with Stockfish..."
if [[ ! -x ${STOCKFISH} ]]; then
	echo "ERROR: Please install/update and compile Stockfish in order to run tests."
	echo
	exit 1
fi

c3c compile-run ${TEST_OPTS} ./test/stockfish.c3 -- "${STOCKFISH}" \
	|| { echo "Stockfish test failed. Aborting." && exit 1; }

#!/bin/sh
# Compose timings on the host (-O2, no sanitizers).
set -e
cd "$(dirname "$0")/.."
mkdir -p build-bench
${CC:-cc} -std=c11 -O2 -Iinclude src/*.c tests/bench_engine.c -o build-bench/bench_engine
build-bench/bench_engine

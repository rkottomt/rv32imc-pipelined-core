#!/usr/bin/env bash
# Fetch external dependencies (not vendored in this repo).
set -e
cd "$(dirname "$0")/../third_party" 2>/dev/null || { mkdir -p "$(dirname "$0")/../third_party"; cd "$(dirname "$0")/../third_party"; }
[ -d riscv-tests ]  || { git clone --depth 1 https://github.com/riscv-software-src/riscv-tests && (cd riscv-tests && git submodule update --init --depth 1 env); }
[ -d riscv-formal ] || git clone --depth 1 https://github.com/YosysHQ/riscv-formal
[ -d coremark ]     || git clone --depth 1 https://github.com/eembc/coremark

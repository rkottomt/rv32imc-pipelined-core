# Source this file: `source env.sh`
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
export PROJ_ROOT="$ROOT"
export PATH="$ROOT/tools/oss-cad-suite/bin:$(echo $ROOT/tools/xpack-riscv-none-elf-gcc-*/bin):$ROOT/.venv/bin:$PATH"

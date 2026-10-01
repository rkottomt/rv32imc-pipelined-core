#!/usr/bin/env bash
# Generate and run the riscv-formal checks for rv_core.
#   formal/run.sh            run all checks (parallel)
#   formal/run.sh insn_add   run checks whose name matches a pattern
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RF="$ROOT/third_party/riscv-formal"
CORE="$RF/cores/rvcore"
rm -rf "$CORE"; mkdir -p "$CORE/rtl"
cp "$ROOT/formal/checks.cfg" "$ROOT/formal/wrapper.sv" "$CORE/"
cp "$ROOT"/rtl/core/*.v "$ROOT"/rtl/core/*.vh "$CORE/rtl/"
cd "$CORE"
python3 ../../checks/genchecks.py > /dev/null
# the RTL `include`s rv_defs.vh: add the RTL dir to the include path
for f in checks/*.sby; do
  sed -i.bak "s|^read -sv|read -sv -I$CORE/rtl|" "$f"
done
rm -f checks/*.bak
PATTERN="${1:-}"
if [ -n "$PATTERN" ]; then
  targets=$(cd checks && ls -d *.sby | sed 's/\.sby$//' | grep -E "$PATTERN" | sed 's|$|/status|' | tr '\n' ' ')
  make -C checks -j"${JOBS:-8}" -k $targets || true
else
  make -C checks -j"${JOBS:-8}" -k || true
fi
cd checks
pass=$(grep -l PASS */status 2>/dev/null | wc -l | tr -d ' ')
fail=$(grep -L PASS */status 2>/dev/null | wc -l | tr -d ' ')
echo "riscv-formal: $pass PASS, $fail FAIL"
grep -L PASS */status 2>/dev/null | sed 's|/status||' | sed 's/^/  FAIL: /' || true

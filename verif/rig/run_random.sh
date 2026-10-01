#!/usr/bin/env bash
# Run N constrained-random programs through RTL + ISS co-simulation.
#   run_random.sh <first_seed> <count> [length]
# Each seed also randomizes the bus latency/back-pressure and enables random
# external interrupts on every other seed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/build/random}"; mkdir -p "$OUT"
SIM="${SIM:-$ROOT/build/sim_core/Vrv_core}"
first=$1; count=$2; len=${3:-3000}
pass=0; fail=0
for ((s=first; s<first+count; s++)); do
  irq=""; irqarg=""
  if (( s % 2 )); then irq="--irq"; irqarg="+irq_rand=2"; fi
  python3 "$ROOT/verif/rig/rig.py" --seed $s --length $len $irq -o "$OUT/r$s.S"
  riscv-none-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
      -Wl,--no-warn-rwx-segments -T "$ROOT/sw/link.ld" "$OUT/r$s.S" -o "$OUT/r$s.elf" || { echo "seed $s: assemble error"; fail=$((fail+1)); continue; }
  ilat=$(( (s % 3) + 1 )); dlat=$(( (s % 4) + 1 )); stall=$(( (s * 7) % 50 ))
  if "$SIM" +elf="$OUT/r$s.elf" +trace="$OUT/r$s.trace" +seed=$s \
        +ilat=$ilat +dlat=$dlat +stall=$stall $irqarg +max_cycles=500000 > "$OUT/r$s.log" 2>&1 \
     && python3 "$ROOT/verif/iss/compare.py" "$OUT/r$s.elf" "$OUT/r$s.trace" --quiet >> "$OUT/r$s.log" 2>&1; then
    pass=$((pass+1)); [ -n "${KEEP_TRACES:-}" ] || rm -f "$OUT/r$s.trace"
  else
    fail=$((fail+1)); echo "seed $s FAILED (see $OUT/r$s.log)"
  fi
done
echo "random: $pass passed, $fail failed"
[ $fail -eq 0 ]

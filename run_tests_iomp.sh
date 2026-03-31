#!/bin/bash
# =============================================================================
# test-parallel-speedup.sh — 4-case speedup test for PolyBench/OMP (iomp/x86)
#
# Usage:
#   ./test-parallel-speedup.sh                          # all 29 kernels
#   ./test-parallel-speedup.sh <source.c> [DATASET] [PAR_THREADS]
#
#   DATASET     — dataset size (default: LARGE_DATASET)
#   PAR_THREADS — thread count for parallel cases (default: 16)
#
# Four cases (mirrors run_tests_gvsoc.sh but on x86 with iomp):
#   ref_seq — clang -O3,          no -fopenmp  (sequential baseline)
#   ref_par — clang -O3 -fopenmp, native iomp  (reference parallel)
#   opt_seq — CIR/MLIR pipeline,  no -fopenmp  (opt sequential)
#   opt_par — CIR/MLIR pipeline, -fopenmp      (opt parallel)
#
# Each case is run 5 times; min and max are dropped and the mean of the 3
# middle runs is reported (same logic as utilities/time_benchmark.sh).
# Uses the cycle-accurate TSC timer (-DPOLYBENCH_CYCLE_ACCURATE_TIMER).
#
# Speedups reported:
#   ref_seq/ref_par  native parallelisation speedup  (ref  seq→par)
#   opt_seq/opt_par  opt   parallelisation speedup   (opt  seq→par)
#
# CSV output:
#   single kernel → results_<name>/performance_iomp/results.csv
#   all kernels   → results_iomp.csv
# =============================================================================

set -uo pipefail   # no -e: we handle per-kernel errors with NA

# ── LLVM/MLIR toolchain ─────────────────────────────────────────────────────
export PATH=/home/tagliavini/MLIR/INSTALL-LLVM/bin/:$PATH

# ── Colours (disabled when stdout is not a terminal) ─────────────────────────
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
    YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; CYAN=''; YELLOW=''; BOLD=''; RESET=''
fi

# ── Global config ─────────────────────────────────────────────────────────────
DATASET="${2:-LARGE_DATASET}"
PAR_THREADS="${3:-16}"

INC="$HOME/PolyBenchC-4.2.1-OpenMP/utilities"
RULES="$HOME/rules.dsl"
INC_OMP="/usr/lib/gcc/x86_64-linux-gnu/12/include"

export OMP_PLACES=cores
export OMP_PROC_BIND=true

POLYBENCH_CFLAGS="-DPOLYBENCH_TIME -DPOLYBENCH_CYCLE_ACCURATE_TIMER"
if [ "$(id -u)" -eq 0 ]; then
    POLYBENCH_CFLAGS="$POLYBENCH_CFLAGS -DPOLYBENCH_LINUX_FIFO_SCHEDULER"
    POLYBENCH_LFLAGS="-lc"
else
    POLYBENCH_LFLAGS=""
fi

VARIANCE_ACCEPTED=5

# ── All kernels (same list as run_tests_gvsoc.sh) ────────────────────────────
ALL_KERNELS=(
    "./datamining/covariance/covariance-omp.c"
    "./datamining/correlation/correlation-omp.c"
    "./stencils/jacobi-1d/jacobi-1d-omp.c"
    "./stencils/heat-3d/heat-3d-omp.c"
    "./stencils/fdtd-2d/fdtd-2d-omp.c"
    "./stencils/jacobi-2d/jacobi-2d-omp.c"
    "./stencils/adi/adi-omp.c"
    "./linear-algebra/blas/gemm/gemm-omp.c"
    "./linear-algebra/blas/gesummv/gesummv-omp.c"
    "./linear-algebra/blas/trmm/trmm-omp.c"
    "./linear-algebra/blas/gemver/gemver-omp.c"
    "./linear-algebra/blas/syrk/syrk-omp.c"
    "./linear-algebra/blas/syr2k/syr2k-omp.c"
    "./linear-algebra/blas/symm/symm-omp.c"
    "./linear-algebra/solvers/gramschmidt/gramschmidt-omp.c"
    "./linear-algebra/solvers/lu/lu-omp.c"
    "./linear-algebra/solvers/cholesky/cholesky-omp.c"
    "./linear-algebra/solvers/ludcmp/ludcmp-omp.c"
    "./linear-algebra/solvers/trisolv/trisolv-omp.c"
    "./linear-algebra/solvers/durbin/durbin-omp.c"
    "./linear-algebra/kernels/mvt/mvt-omp.c"
    "./linear-algebra/kernels/atax/atax-omp.c"
    "./linear-algebra/kernels/doitgen/doitgen-omp.c"
    "./linear-algebra/kernels/bicg/bicg-omp.c"
    "./linear-algebra/kernels/2mm/2mm-omp.c"
    "./linear-algebra/kernels/3mm/3mm-omp.c"
    "./medley/floyd-warshall/floyd-warshall-omp.c"
    "./medley/deriche/deriche-omp.c"
    "./medley/nussinov/nussinov-omp.c"
)

# ═════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

compile_ref() {
    local src="$1" dataset="$2" outdir="$3" binname="$4" omp_flag="$5"
    clang -O3 "$src" "${INC}/polybench.c" \
        -I"$INC" -I"$(dirname "$src")" -I"$INC_OMP" \
        -D${dataset} ${POLYBENCH_CFLAGS} \
        ${omp_flag} -lm ${POLYBENCH_LFLAGS} \
        -o "$outdir/${binname}"
    clang -O3 -S -emit-llvm "$src" \
        -I"$INC" -I"$(dirname "$src")" -I"$INC_OMP" \
        -D${dataset} ${POLYBENCH_CFLAGS} \
        ${omp_flag} \
        -o "$outdir/${binname}.ll"
}

compile_opt() {
    local src="$1" dataset="$2" outdir="$3" binname="$4" omp_flag="$5"
    local name="${src%.c}"
    name="$(basename "$name")"
    local tmpdir
    tmpdir=$(mktemp -d)

    clang -S -Xclang -fclangir -Xclang -emit-cir ${omp_flag} \
        -I"$INC" -I"$(dirname "$src")" -I"$INC_OMP" \
        -D${dataset} ${POLYBENCH_CFLAGS} \
        "$src" -o "$tmpdir/${name}.cir"

    cir-opt "$tmpdir/${name}.cir" --cir-to-llvm --reconcile-unrealized-casts \
        -o "$tmpdir/${name}-s1.mlir"
    sed -i -E 's/cir\.[^,}]+,? ?//g' "$tmpdir/${name}-s1.mlir"

    mlir-opt-omp \
        --allow-unregistered-dialect \
        --omp-lower-dsl="$RULES" \
        --omp-lower-runtime=iomp \
        --omp-to-omp-lower --omp-outline --omp-lower-plan \
        "$tmpdir/${name}-s1.mlir" > "$tmpdir/${name}-s2.mlir"

    mlir-opt "$tmpdir/${name}-s2.mlir" \
        --convert-arith-to-llvm --convert-func-to-llvm \
        --reconcile-unrealized-casts -o "$tmpdir/${name}-s3.mlir"
    mlir-translate "$tmpdir/${name}-s3.mlir" --mlir-to-llvmir > "$tmpdir/${name}-s4.ll"
    opt -O3 -S "$tmpdir/${name}-s4.ll" > "$tmpdir/${name}-s4.opt.ll"

    llc -relocation-model=pic -filetype=obj "$tmpdir/${name}-s4.opt.ll" \
        -o "$tmpdir/${name}.o"

    clang -O3 -c "${INC}/polybench.c" -I"$INC" \
        -D${dataset} ${POLYBENCH_CFLAGS} -o "$tmpdir/polybench.o"
    clang -O3 ${omp_flag} \
        "$tmpdir/${name}.o" "$tmpdir/polybench.o" -lm ${POLYBENCH_LFLAGS} \
        -o "$outdir/${binname}"

    cp "$tmpdir/${name}-s4.opt.ll" "$outdir/${binname}.ll"

    rm -rf "$tmpdir"
}

run_benchmark() {
    local binary="$1" nthreads="$2" label="$3" timesfile="$4"

    echo -e "  ${CYAN}Running ${label} (${nthreads} thread(s)) 5 times...${RESET}" >&2
    : > "$timesfile"
    for i in 1 2 3 4 5; do
        OMP_NUM_THREADS="$nthreads" "$binary" >> "$timesfile"
    done

    local sorted_3
    sorted_3=$(sort -n "$timesfile" | head -n 4 | tail -n 3)

    local sum=0 count=0
    while IFS= read -r val; do
        sum=$(echo "scale=8; $sum + $val" | bc)
        count=$((count + 1))
    done <<< "$sorted_3"

    if [ "$count" -ne 3 ]; then
        echo -e "  ${RED}[ERROR]${RESET} Not enough numeric lines — is -DPOLYBENCH_TIME set?" >&2
        return 1
    fi

    local mean
    mean=$(echo "scale=8; $sum / 3" | bc)
    [[ "$mean" == .* ]] && mean="0${mean}"

    local max_dev=0
    while IFS= read -r val; do
        local dev
        dev=$(echo "a = $val - $mean; if (0 > a) a *= -1; a" | bc)
        max_dev=$(echo "$dev $max_dev" | awk '{ print ($1 > $2) ? $1 : $2 }')
    done <<< "$sorted_3"

    local variance
    variance=$(echo "scale=5; ($max_dev / $mean) * 100" | bc)
    [[ "$variance" == .* ]] && variance="0${variance}"

    local compvar
    compvar=$(echo "$variance $VARIANCE_ACCEPTED" | awk '{ print ($1 < $2) ? "ok" : "warn" }')

    if [ "$compvar" = "warn" ]; then
        echo -e "  ${YELLOW}[WARNING]${RESET} ${label}: variance above threshold — max deviation=${variance}%, tolerance=${VARIANCE_ACCEPTED}%" >&2
    else
        echo -e "  ${GREEN}[INFO]${RESET}    ${label}: max deviation from mean of 3 runs: ${variance}%" >&2
    fi
    echo -e "  ${BOLD}${label} normalised cycles: ${mean}${RESET}" >&2

    printf "%s" "$mean"
}

ratio() {
    local result
    result=$(echo "scale=4; $1 / $2" | bc 2>/dev/null || echo "N/A")
    [[ "$result" == .* ]] && result="0${result}"
    printf "%s" "$result"
}

# ── Per-kernel entry point ────────────────────────────────────────────────────
# Returns a semicolon-separated data row:
#   name;ref_seq;ref_par;opt_seq;opt_par;sz_ref_seq;sz_ref_par;sz_opt_seq;sz_opt_par;sp_native;sp_opt
# On failure of any step, returns name followed by 10 NA fields.
run_kernel() {
    local src="$1"
    local name
    name="$(basename "${src%-omp.c}")-omp"   # e.g. gemm-omp
    local outdir="results_${name}/performance_iomp"
    local d_ref_seq="$outdir/ref_seq" d_ref_par="$outdir/ref_par"
    local d_opt_seq="$outdir/opt_seq" d_opt_par="$outdir/opt_par"
    mkdir -p "$d_ref_seq" "$d_ref_par" "$d_opt_seq" "$d_opt_par"

    echo -e "${BOLD}── ${name} ──────────────────────────────────────────${RESET}" >&2

    # compile
    echo -e "${CYAN}[1/8]${RESET} Compiling ref_seq — clang, no OpenMP..." >&2
    if ! compile_ref "$src" "$DATASET" "$d_ref_seq" "${name}_ref_seq" "" ; then
        echo -e "${RED}FAILED ref_seq compile — skipping ${name}${RESET}" >&2; printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return
    fi
    local SZ_REF_SEQ; SZ_REF_SEQ=$(stat -c%s "$d_ref_seq/${name}_ref_seq" 2>/dev/null || echo "NA")
    echo -e "${CYAN}[2/8]${RESET} Compiling ref_par — clang -fopenmp..." >&2
    if ! compile_ref "$src" "$DATASET" "$d_ref_par" "${name}_ref_par" "-fopenmp" ; then
        echo -e "${RED}FAILED ref_par compile — skipping ${name}${RESET}" >&2; printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return
    fi
    local SZ_REF_PAR; SZ_REF_PAR=$(stat -c%s "$d_ref_par/${name}_ref_par" 2>/dev/null || echo "NA")
    echo -e "${CYAN}[3/8]${RESET} Compiling opt_seq — CIR/MLIR, no -fopenmp..." >&2
    if ! compile_opt "$src" "$DATASET" "$d_opt_seq" "${name}_opt_seq" "" ; then
        echo -e "${RED}FAILED opt_seq compile — skipping ${name}${RESET}" >&2; printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return
    fi
    local SZ_OPT_SEQ; SZ_OPT_SEQ=$(stat -c%s "$d_opt_seq/${name}_opt_seq" 2>/dev/null || echo "NA")
    echo -e "${CYAN}[4/8]${RESET} Compiling opt_par — CIR/MLIR -fopenmp..." >&2
    if ! compile_opt "$src" "$DATASET" "$d_opt_par" "${name}_opt_par" "-fopenmp" ; then
        echo -e "${RED}FAILED opt_par compile — skipping ${name}${RESET}" >&2; printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return
    fi
    local SZ_OPT_PAR; SZ_OPT_PAR=$(stat -c%s "$d_opt_par/${name}_opt_par" 2>/dev/null || echo "NA")

    # benchmark
    echo -e "${CYAN}[5/8]${RESET} Benchmarking ref_seq — seq (1 thread)..." >&2
    local C_REF_SEQ; C_REF_SEQ=$(run_benchmark "./$d_ref_seq/${name}_ref_seq" 1             "ref_seq" "$d_ref_seq/times.txt") || { printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return; }
    echo -e "${CYAN}[6/8]${RESET} Benchmarking ref_par — par (${PAR_THREADS} threads)..." >&2
    local C_REF_PAR; C_REF_PAR=$(run_benchmark "./$d_ref_par/${name}_ref_par" "$PAR_THREADS" "ref_par" "$d_ref_par/times.txt") || { printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return; }
    echo -e "${CYAN}[7/8]${RESET} Benchmarking opt_seq — opt seq (1 thread)..." >&2
    local C_OPT_SEQ; C_OPT_SEQ=$(run_benchmark "./$d_opt_seq/${name}_opt_seq" 1             "opt_seq" "$d_opt_seq/times.txt") || { printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return; }
    echo -e "${CYAN}[8/8]${RESET} Benchmarking opt_par — opt par (${PAR_THREADS} threads)..." >&2
    local C_OPT_PAR; C_OPT_PAR=$(run_benchmark "./$d_opt_par/${name}_opt_par" "$PAR_THREADS" "opt_par" "$d_opt_par/times.txt") || { printf "%s" "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA"; return; }

    local SP_NATIVE SP_OPT
    SP_NATIVE=$(ratio "$C_REF_SEQ" "$C_REF_PAR")   # ref_seq/ref_par
    SP_OPT=$(ratio    "$C_OPT_SEQ" "$C_OPT_PAR")   # opt_seq/opt_par

    # per-kernel summary
    echo "" >&2
    printf "  %-38s %16s %16s\n" "" "ref (clang -O3)" "opt (CIR/MLIR)" >&2
    printf "  %-38s %16s %16s\n" "──────────────────────────────────────" "────────────────" "────────────────" >&2
    printf "  %-38s %16s %16s\n" "seq  (1T) cycles"    "$C_REF_SEQ" "$C_OPT_SEQ" >&2
    printf "  %-38s %16s %16s\n" "par  (${PAR_THREADS}T) cycles" "$C_REF_PAR" "$C_OPT_PAR" >&2
    printf "  %-38s %16s %16s\n" "speedup seq→par"     "${SP_NATIVE}x" "${SP_OPT}x" >&2
    printf "  %-38s %16s %16s\n" "binary size (bytes)" "$SZ_REF_SEQ / $SZ_REF_PAR" "$SZ_OPT_SEQ / $SZ_OPT_PAR" >&2
    echo "" >&2

    # write per-kernel CSV
    local kcsv="$outdir/results.csv"
    echo "kernel;ref_seq_cycles;ref_par_cycles;opt_seq_cycles;opt_par_cycles;size_ref_seq_bytes;size_ref_par_bytes;size_opt_seq_bytes;size_opt_par_bytes;speedup_native;speedup_opt" > "$kcsv"
    echo "${name};${C_REF_SEQ};${C_REF_PAR};${C_OPT_SEQ};${C_OPT_PAR};${SZ_REF_SEQ};${SZ_REF_PAR};${SZ_OPT_SEQ};${SZ_OPT_PAR};${SP_NATIVE};${SP_OPT}" >> "$kcsv"

    # only the data row goes to stdout — captured by the caller
    printf "%s" "${name};${C_REF_SEQ};${C_REF_PAR};${C_OPT_SEQ};${C_OPT_PAR};${SZ_REF_SEQ};${SZ_REF_PAR};${SZ_OPT_SEQ};${SZ_OPT_PAR};${SP_NATIVE};${SP_OPT}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  PARALLEL SPEEDUP TEST  (${DATASET})${RESET}"
echo -e "${BOLD}  par = ${PAR_THREADS} threads  |  timer: cycle-accurate TSC${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo ""

CSV_HEADER="kernel;ref_seq_cycles;ref_par_cycles;opt_seq_cycles;opt_par_cycles;size_ref_seq_bytes;size_ref_par_bytes;size_opt_seq_bytes;size_opt_par_bytes;speedup_native;speedup_opt"

if [ $# -ge 1 ]; then
    # ── Single kernel mode ───────────────────────────────────────────────────
    SRC="$1"
    if [ ! -f "$SRC" ]; then
        echo "Error: file not found: $SRC"; exit 1
    fi
    row=$(run_kernel "$SRC")
    name="$(basename "${SRC%-omp.c}")-omp"
    CSV="results_${name}/performance_iomp/results.csv"
    # already written inside run_kernel; just report location
    echo -e "  CSV: ${BOLD}${CSV}${RESET}"
else
    # ── Batch mode: all kernels ──────────────────────────────────────────────
    GLOBAL_CSV="results_iomp.csv"
    echo "$CSV_HEADER" > "$GLOBAL_CSV"

    total=${#ALL_KERNELS[@]}
    idx=0
    for src in "${ALL_KERNELS[@]}"; do
        idx=$((idx + 1))
        echo -e "${BOLD}[${idx}/${total}]${RESET} ${src}"
        if [ ! -f "$src" ]; then
            name="$(basename "${src%-omp.c}")-omp"
            echo -e "  ${RED}WARNING: file not found — skipping${RESET}"
            echo "${name};NA;NA;NA;NA;NA;NA;NA;NA;NA;NA" >> "$GLOBAL_CSV"
            continue
        fi
        row=$(run_kernel "$src")
        echo "$row" >> "$GLOBAL_CSV"
        echo ""
    done

    echo -e "${BOLD}Done. Results written to ${GLOBAL_CSV}${RESET}"
fi

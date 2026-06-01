#!/bin/bash
# =============================================================================
# run_tests_opt_par_only.sh — MLIR OpenMP correctness check (PARALLEL ONLY)
# + saves final LLVM IR (.ll)
#
# Compiles each kernel two ways and diffs the array dumps:
#   ref — gcc  -O3 -fopenmp        (with strict FP flags)
#   opt — CIR/MLIR pipeline        (with strict FP flags)
#
# Strict FP flags (-ffp-contract=off + no auto-vectorisation) are required for
# bit-identical results between gcc and the CIR/MLIR pipeline. Without them,
# FMA contraction and reordered reductions cause iterative kernels (e.g.
# fdtd-2d, jacobi-2d) to diverge after a few timesteps even though both
# binaries are IEEE-correct.
# =============================================================================

set -uo pipefail

export PATH=$HOME/eeeslab/llvm-project/build/bin:$PATH
export PATH=$HOME/eeeslab/mlir-opt-omp/build:$PATH

INC="$HOME/eeeslab/PolyBenchC-4.2.1-OpenMP/utilities"
INC_OMP="/usr/lib/gcc/x86_64-linux-gnu/13/include"
RULES="$HOME/eeeslab/mlir-opt-omp/rules.dsl"

DATASET="${2:-MINI_DATASET}"
THREADS="${3:-16}"

export OMP_NUM_THREADS=$THREADS
export OMP_PLACES=cores
export OMP_PROC_BIND=true

POLYBENCH_CFLAGS="-DPOLYBENCH_DUMP_ARRAYS"

# Strict FP flags — keep these in sync between ref and opt.
GCC_STRICT_FP="-ffp-contract=off -fno-tree-vectorize -fno-tree-loop-vectorize -fno-tree-slp-vectorize"
CLANG_STRICT_FP="-ffp-contract=off -fno-vectorize -fno-slp-vectorize"

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
    "./stencils/seidel-2d/seidel-2d-omp.c"
)

compile_opt_par() {
    local src="$1"
    local outdir="$2"
    local binname="$3"

    local name
    name="$(basename "${src%.c}")"

    local tmpdir
    tmpdir=$(mktemp -d)

    echo "  compiling $name ..."

    # Step 1: Clang → CIR (strict FP)
    clang -S ${CLANG_STRICT_FP} \
        -Xclang -fclangir -Xclang -emit-cir -fopenmp \
        -I"$INC" -I"$(dirname "$src")" -I"$INC_OMP" \
        -D${DATASET} ${POLYBENCH_CFLAGS} \
        "$src" -o "$tmpdir/${name}.cir"

    # Step 2: CIR → LLVM dialect MLIR
    cir-opt "$tmpdir/${name}.cir" --cir-to-llvm --reconcile-unrealized-casts \
        -o "$tmpdir/${name}-s1.mlir"

    sed -i -E 's/cir\.[^,}]+,? ?//g' "$tmpdir/${name}-s1.mlir"

    # Step 3: Custom OMP lowering (runtime = libgomp)
    mlir-opt-omp \
        --allow-unregistered-dialect \
        --omp-lower-dsl="$RULES" \
        --omp-lower-runtime=libgomp \
        --omp-to-omp-lower --omp-outline --omp-lower-plan \
        "$tmpdir/${name}-s1.mlir" > "$tmpdir/${name}-s2.mlir"

    # Step 4: MLIR optimisations + lowering to LLVM dialect
    mlir-opt "$tmpdir/${name}-s2.mlir" \
        --canonicalize \
        --cse \
        --sccp \
        --symbol-dce \
        --loop-invariant-code-motion \
        --canonicalize \
        --cse \
        --convert-arith-to-llvm \
        --convert-func-to-llvm \
        --reconcile-unrealized-casts \
        -o "$tmpdir/${name}-s3.mlir"

    # Step 5: MLIR → LLVM IR
    mlir-translate "$tmpdir/${name}-s3.mlir" --mlir-to-llvmir > "$tmpdir/${name}.ll"

    # Step 6: LLVM opt -O3
    opt -S -O3 "$tmpdir/${name}.ll" > "$tmpdir/${name}.opt.ll"

    # Step 7: LLC → object file
    llc -O3 -relocation-model=pic -filetype=obj "$tmpdir/${name}.opt.ll" \
        -o "$tmpdir/${name}.o"

    # Step 8: Compile polybench utility (strict FP)
    clang -O3 ${CLANG_STRICT_FP} \
        -c "$INC/polybench.c" -I"$INC" \
        -D${DATASET} ${POLYBENCH_CFLAGS} \
        -o "$tmpdir/polybench.o"

    # Step 9: Link (strict FP)
    clang -O3 ${CLANG_STRICT_FP} \
        -fopenmp=libgomp -no-pie \
        "$tmpdir/${name}.o" "$tmpdir/polybench.o" \
        -lm -lgomp -o "$outdir/${binname}"

    # ✅ SAVE FINAL LLVM IR
    cp "$tmpdir/${name}.opt.ll" "$outdir/${binname}.ll"

    if [ ! -f "$outdir/${binname}" ]; then
        echo "  ❌ compilation failed"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
}

compile_ref() {
    local src="$1"
    local outdir="$2"
    local binname="$3"

    local name
    name="$(basename "${src%.c}")"

    mkdir -p "$outdir"

    gcc -O3 ${GCC_STRICT_FP} -fopenmp \
        -I"$INC" -I"$(dirname "$src")" \
        -D${DATASET} ${POLYBENCH_CFLAGS} \
        "$src" "$INC/polybench.c" \
        -lm -o "$outdir/${binname}"

    if [ ! -f "$outdir/${binname}" ]; then
        echo "  ❌ ref compilation failed"
        return 1
    fi
}

run_benchmark() {
    local binary="$1"
    local timesfile="$2"

    : > "$timesfile"
    for i in 1 2 3 4 5; do
        "$binary" >> "$timesfile"
    done

    sort -n "$timesfile" | head -n 4 | tail -n 3 | \
        awk '{s+=$1} END {printf "%.6f", s/3}'
}

run_kernel() {
    local src="$1"
    local name
    name="$(basename "${src%-omp.c}")-omp"

    local outdir="results_${name}/correctness"
    local ref_dir="$outdir/ref"
    local opt_dir="$outdir/opt"

    mkdir -p "$ref_dir" "$opt_dir"

    echo "── $name"

    # ── Compile ─────────────────────────────
    echo "  [1/4] compiling ref (gcc, strict FP)..."
    if ! compile_ref "$src" "$ref_dir" "${name}_ref"; then
        echo "  ERROR: ref compile failed"
        echo "${name};ERROR" >> results_correctness.csv
        return
    fi

    echo "  [2/4] compiling opt (MLIR, strict FP)..."
    if ! compile_opt_par "$src" "$opt_dir" "${name}_opt"; then
        echo "  ERROR: opt compile failed"
        echo "${name};ERROR" >> results_correctness.csv
        return
    fi

    # ── Run ────────────────────────────────
    echo "  [3/4] running..."
    "./$ref_dir/${name}_ref" 2> "$ref_dir/dump.txt" > /dev/null || true
    "./$opt_dir/${name}_opt" 2> "$opt_dir/dump.txt" > /dev/null || true

    # ── Compare ────────────────────────────
    echo "  [4/4] comparing..."

    if diff -q "$ref_dir/dump.txt" "$opt_dir/dump.txt" > /dev/null; then
        echo "  ✔ PASS"
        echo "${name};PASS" >> results_correctness.csv
    else
        echo "  ✘ FAIL"
        echo "  first differences:"
        diff --unified=3 "$ref_dir/dump.txt" "$opt_dir/dump.txt" | head -20
        echo ""
        echo "${name};FAIL" >> results_correctness.csv
    fi

    echo ""
}



echo "=== MLIR OpenMP CORRECTNESS CHECK (${DATASET}) ==="
echo "threads: $THREADS"
echo "FP mode: strict (-ffp-contract=off, no auto-vectorisation)"
echo ""

echo "kernel;result" > results_correctness.csv

if [ $# -ge 1 ]; then
    run_kernel "$1"
else
    for src in "${ALL_KERNELS[@]}"; do
        if [ -f "$src" ]; then
            run_kernel "$src"
        fi
    done
fi

# ── Summary ────────────────────────────
passed=$(grep -c ';PASS$' results_correctness.csv || true)
failed=$(grep -c ';FAIL$' results_correctness.csv || true)
errors=$(grep -c ';ERROR$' results_correctness.csv || true)
total=$((passed + failed + errors))

echo ""
echo "=== SUMMARY ==="
echo "passed: $passed / $total"
[ "$failed" -gt 0 ] && echo "failed: $failed"
[ "$errors" -gt 0 ] && echo "errors: $errors"
echo ""
echo "Done → results_correctness.csv"
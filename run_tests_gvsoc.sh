#!/usr/bin/env bash

set -u
set -o pipefail

OUTPUT_CSV="results.csv"

KERNELS=(
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

kernel_name() {
  local path="$1"
  local name
  name="$(basename "$path")"
  name="${name%-omp.c}"
  echo "$name"
}

extract_cycles() {
  local logfile="$1"
  grep -Eo 'Cycles[[:space:]]*=[[:space:]]*[0-9]+' "$logfile" \
    | tail -n 1 \
    | grep -Eo '[0-9]+'
}

run_case() {
  local kernel="$1"
  local case_id="$2"
  local logfile
  local cycles
  local bytes

  logfile="$(mktemp)"

  echo "Running ${kernel} - case${case_id}..." >&2

  case "$case_id" in
    1)
      make clean all run platform=gvsoc KERNEL_SRC="$kernel" 2>&1 | tee "$logfile" >&2
      ;;
    2)
      make clean all run OMP_NATIVE=1 platform=gvsoc KERNEL_SRC="$kernel" 2>&1 | tee "$logfile" >&2
      ;;
    3)
      ./compile-pulp.sh "$kernel" 0 2>&1 | tee "$logfile" >&2
      make clean all run OMP_OPT=1 platform=gvsoc KERNEL_SRC="$kernel" 2>&1 | tee -a "$logfile" >&2
      ;;
    4)
      ./compile-pulp.sh "$kernel" 1 2>&1 | tee "$logfile" >&2
      make clean all run OMP_OPT=1 platform=gvsoc KERNEL_SRC="$kernel" 2>&1 | tee -a "$logfile" >&2
      ;;
    *)
      echo "Invalid case: $case_id" >&2
      rm -f "$logfile"
      return 1
      ;;
  esac

  cycles="$(extract_cycles "$logfile")"
  rm -f "$logfile"

  if [[ -z "${cycles:-}" ]]; then
    echo "WARNING: could not extract cycles for ${kernel} case${case_id}" >&2
    cycles="NA"
  fi

  bytes="$(stat -c%s "BUILD/GAP8_V3/GCC_RISCV_PULPOS/test" 2>/dev/null)" || bytes="NA"
  [[ -n "${bytes:-}" ]] || bytes="NA"

  # Return both values on one line, separated by ;
  printf '%s;%s\n' "$cycles" "$bytes"
}

echo "kernel;ref_seq_cycles;ref_par_cycles;opt_seq_cycles;opt_par_cycles;b1;b2;b3;b4" > "$OUTPUT_CSV"

for kernel in "${KERNELS[@]}"; do
  name="$(kernel_name "$kernel")"

  IFS=';' read -r c1 b1 <<< "$(run_case "$kernel" 1)"
  IFS=';' read -r c2 b2 <<< "$(run_case "$kernel" 2)"
  IFS=';' read -r c3 b3 <<< "$(run_case "$kernel" 3)"
  IFS=';' read -r c4 b4 <<< "$(run_case "$kernel" 4)"

  echo "${name};${c1};${c2};${c3};${c4};${b1};${b2};${b3};${b4}" >> "$OUTPUT_CSV"
done

echo "Done. Results written to ${OUTPUT_CSV}" >&2

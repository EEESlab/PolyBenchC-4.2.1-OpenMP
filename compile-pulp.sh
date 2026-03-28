#!/bin/bash

KERNEL_SRC=$1
USE_OMP=$2

CLANG_FLAGS=""

if [ "$USE_OMP" = "1" ]; then
    CLANG_FLAGS="$CLANG_FLAGS -fopenmp"
fi

KERNEL_DIR="${SRC%/*}"

rm -f *.o  *.ll *.cir *.mlir

clang -O0  $CLANG_FLAGS -Xclang -disable-llvm-optzns -S -Xclang -fclangir -Xclang -emit-cir -I/usr/lib/gcc/x86_64-linux-gnu/12/include -Iutilities -DPULP_TARGET -DMINI_DATASET -DPOLYBENCH_DUMP_ARRAYS -DPOLYBENCH_TIME $KERNEL_SRC -o test.cir
cir-opt test.cir  -cir-unroll-by-two --cir-to-llvm --reconcile-unrealized-casts -o test-s1.mlir
sed -i -E 's/cir\.[^,}]+,? ?//g' test-s1.mlir
../../grammar/mlir-transform/BUILD/mlir-opt-omp  --allow-unregistered-dialect   --omp-lower-dsl=../../grammar/mlir-transform/rules.dsl   --omp-lower-runtime=pmsis   --omp-to-omp-lower --omp-outline --omp-lower-plan  test-s1.mlir > test-s2.mlir
mlir-opt test-s2.mlir --convert-arith-to-llvm --convert-func-to-llvm --reconcile-unrealized-casts -o test-s3.mlir
#mlir-opt test-s2.mlir   --canonicalize   --cse   --sccp   --symbol-dce  --loop-invariant-code-motion   --canonicalize   --cse   --convert-arith-to-llvm   --convert-func-to-llvm   --reconcile-unrealized-casts   -o test-s3.mlir
mlir-translate test-s3.mlir --mlir-to-llvmir > test-s4.ll
/home/tagliavini/toolchains/llvm-project/builds/INSTALL-REBASE/bin/opt  test-s4.ll -S -o test-s4.opt.ll
/home/tagliavini/toolchains/llvm-project/builds/INSTALL-REBASE/bin/llc -O3 -mtriple=riscv32-unknown-elf -mattr=+m,+c,+xpulpv, -relocation-model=pic -filetype=obj test-s4.opt.ll -o kernel.o




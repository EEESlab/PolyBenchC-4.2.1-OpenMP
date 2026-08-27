/**
 * This version is stamped on May 10, 2016
 *
 * Contact:
 *   Louis-Noel Pouchet <pouchet.ohio-state.edu>
 *   Tomofumi Yuki <tomofumi.yuki.fr>
 *
 * Web address: http://polybench.sourceforge.net
 */
/* seidel-2d.c: this file is part of PolyBench/C */

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <math.h>

/* Include polybench common header. */
#include <polybench.h>

/* Include benchmark-specific header. */
#include "seidel-2d.h"


/* Array initialization. */
static
void init_array (int n,
		 DATA_TYPE POLYBENCH_2D(A,N,N,n,n))
{
  int i, j;

  for (i = 0; i < n; i++)
    for (j = 0; j < n; j++)
      A[i][j] = ((DATA_TYPE) i*(j+2) + 2) / n;
}


/* DCE code. Must scan the entire live-out data.
   Can be used also to check the correctness of the output. */
static
void print_array(int n,
		 DATA_TYPE POLYBENCH_2D(A,N,N,n,n))

{
  int i, j;

  POLYBENCH_DUMP_START;
  POLYBENCH_DUMP_BEGIN("A");
  for (i = 0; i < n; i++)
    for (j = 0; j < n; j++) {
      if ((i * n + j) % 20 == 0) fprintf(POLYBENCH_DUMP_TARGET, "\n");
      fprintf(POLYBENCH_DUMP_TARGET, DATA_PRINTF_MODIFIER, A[i][j]);
    }
  POLYBENCH_DUMP_END("A");
  POLYBENCH_DUMP_FINISH;
}


/* Main computational kernel. The whole function will be timed,
   including the call and return. */
/* NOTE: Gauss-Seidel is an in-place stencil: A[i][j] reads the neighbours
   A[i-1][j-1..j+1] and A[i][j-1] that the same sweep has already updated.
   Both i and j therefore carry a true dependence, and putting an `omp for`
   on the i loop is a data race — the row above belongs to another thread, so
   each thread reads a mix of updated and stale values and the answer depends
   on where the block boundaries fall. It stays close enough to the right one
   to look plausible on a small dataset and drifts in the last printed digit
   on a large one, which is the worst way for a race to fail.

   The loop nest is skewed instead. Every dependence vector (di,dj) of the
   sweep — (1,1), (1,0), (1,-1) and (0,1) — is strictly positive along
   w = 2*i + j, so no two points of one anti-diagonal w depend on each other
   and the whole diagonal runs in parallel, while w itself stays sequential.
   The join that closes each diagonal is what separates it from the next, and
   it is load-bearing. The result is the sequential one, bit for bit, for any
   team size.

   The region is opened per diagonal rather than once around the t loop: the
   diagonal bounds are then computed by one thread outside any region, and the
   worksharing loop stays the immediate body of its `parallel`, which is the
   shape every other kernel here uses and the only one the PULP lowering is
   exercised on. Hoisting the region and nesting an `omp for` two sequential
   loops deep inside it hangs the cluster. */
static
void kernel_seidel_2d(int tsteps,
		      int n,
		      DATA_TYPE POLYBENCH_2D(A,N,N,n,n))
{
  int t, w, i, j, ilo, ihi;

#pragma scop
  for (t = 0; t <= _PB_TSTEPS - 1; t++)
    for (w = 3; w <= 3 * (_PB_N - 2); w++)
      {
	/* The diagonal 2*i + j == w, restricted to j = w - 2*i in [1, n-2]. */
	ihi = (w - 1) / 2;
	if (ihi > _PB_N - 2) ihi = _PB_N - 2;
	ilo = (w - (_PB_N - 2) + 1) / 2;
	if (ilo < 1) ilo = 1;

	#pragma omp parallel for private(j)
	for (i = ilo; i <= ihi; i++)
	  {
	    j = w - 2 * i;
	    A[i][j] = (A[i-1][j-1] + A[i-1][j] + A[i-1][j+1]
		       + A[i][j-1] + A[i][j] + A[i][j+1]
		       + A[i+1][j-1] + A[i+1][j] + A[i+1][j+1])/SCALAR_VAL(9.0);
	  }
      }
#pragma endscop

}


#ifdef PULP_TARGET
void cluster_main()
#else
int main(int argc, char** argv)
#endif
{
#ifdef PULP_TARGET
  volatile int argc = 1;
  volatile char *argv[] = { "", NULL };
#endif
  /* Retrieve problem size. */
  int n = N;
  int tsteps = TSTEPS;

  /* Variable declaration/allocation. */
  POLYBENCH_2D_ARRAY_DECL(A, DATA_TYPE, N, N, n, n);


  /* Initialize array(s). */
  init_array (n, POLYBENCH_ARRAY(A));

  /* Start timer. */
  polybench_start_instruments;

  /* Run kernel. */
  kernel_seidel_2d (tsteps, n, POLYBENCH_ARRAY(A));

  /* Stop and print timer. */
  polybench_stop_instruments;
  polybench_print_instruments;

  /* Prevent dead-code elimination. All live-out data must be printed
     by the function call in argument. */
  polybench_prevent_dce(print_array(n, POLYBENCH_ARRAY(A)));

  /* Be clean. */
  POLYBENCH_FREE_ARRAY(A);

#ifndef PULP_TARGET
  return 0;
#endif
}

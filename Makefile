
KERNEL_SRC ?= linear-algebra/blas/gemm/gemm-omp.c
KERNEL_DIR = $(dir $(KERNEL_SRC))

#APP_ARCH_LDFLAGS = -march=rv32imcXpulpv2 -mPE=8 -mFC=1

APP = test
APP_SRCS += utilities/pulp_main.c utilities/interface-adapter.c utilities/polybench.c
ifndef OMP_OPT
APP_SRCS += $(KERNEL_SRC)
endif

APP_CFLAGS += -I utilities -DPULP_TARGET -DMINI_DATASET -DPOLYBENCH_DUMP_ARRAYS -DPOLYBENCH_TIME
APP_CFLAGS += -I $(KERNEL_DIR)

APP_CFLAGS += -O3
APP_LDFLAGS += -O3 -lm 

ifdef OMP_OPT
APP_LDFLAGS += kernel.o -lm 
endif


ifdef OMP_NATIVE
CONFIG_OPENMP    = 1
endif

include $(RULES_DIR)/pmsis_rules.mk

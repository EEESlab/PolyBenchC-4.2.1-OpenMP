#!/usr/bin/env python3
"""
plot_speedup.py — Plot parallel speedup from test-parallel-speedup.sh CSV output.

Usage:
    python3 plot_speedup.py <results.csv> [output.png]

The CSV must have the columns produced by test-parallel-speedup.sh:
    kernel;case1_seq_cycles;case2_ref_par_cycles;
           case3_opt_seq_cycles;case4_opt_par_cycles;
           speedup_native;speedup_opt

Speedups plotted:
    Native  = case1 / case2  (clang -O3 seq → clang -O3 -fopenmp par)
    Our     = case1 / case4  (clang -O3 seq → CIR/MLIR -fopenmp par)
"""

import sys
import csv
import matplotlib.pyplot as plt
import numpy as np

# ── Args ─────────────────────────────────────────────────────────────────────
if len(sys.argv) < 2:
    print("Usage: python3 plot_speedup.py <results.csv> [output.png]")
    sys.exit(1)

csv_path   = sys.argv[1]
out_path   = sys.argv[2] if len(sys.argv) > 2 else csv_path.replace(".csv", ".png")

# ── Load CSV ──────────────────────────────────────────────────────────────────
kernels       = []
speedup_native = []
speedup_opt    = []

with open(csv_path, newline="") as f:
    reader = csv.DictReader(f, delimiter=";")
    for row in reader:
        kernels.append(row["kernel"])
        c1 = float(row["case1_seq_cycles"])
        c2 = float(row["case2_ref_par_cycles"])
        c4 = float(row["case4_opt_par_cycles"])
        # Both speedups use case1 as baseline so they are directly comparable
        speedup_native.append(c1 / c2 if c2 > 0 else 0)
        speedup_opt.append(c1 / c4   if c4 > 0 else 0)

# ── Plot ──────────────────────────────────────────────────────────────────────
x     = np.arange(len(kernels))
width = 0.35

fig, ax = plt.subplots(figsize=(max(8, len(kernels) * 0.6 + 2), 6))

bars_native = ax.bar(x - width / 2, speedup_native, width,
                     label="Native", color="#3a6fbf")
bars_opt    = ax.bar(x + width / 2, speedup_opt,    width,
                     label="Our",    color="#bf6a3a")

# ── Formatting ────────────────────────────────────────────────────────────────
ax.set_ylabel("Parallel Speedup")
ax.set_title("Parallel Speedup: Native (clang -fopenmp) vs Our (CIR/MLIR iomp)")
ax.set_xticks(x)
ax.set_xticklabels(kernels, rotation=45, ha="right", fontsize=9)
ax.set_ylim(bottom=0)
ax.yaxis.grid(True, linestyle="--", alpha=0.7)
ax.set_axisbelow(True)
ax.legend()

fig.tight_layout()
fig.savefig(out_path, dpi=150)
print(f"Saved: {out_path}")
plt.show()

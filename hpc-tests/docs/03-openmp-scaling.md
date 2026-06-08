# Test 03: OpenMP Thread Scaling

**Script:** `03-openmp-scaling.sbatch`
**Partition:** mit_quicktest
**Resources:** 1 node, 16 CPUs, 8 GB memory
**Run time:** ~3 minutes

## Why this test exists

Many user codes — MATLAB, R, OpenFOAM, LAMMPS, NumPy/SciPy — use OpenMP for
shared-memory parallelism. When thread scaling breaks, the symptom is "my job
uses 16 cores but runs at single-core speed." Users see CPU utilization at 100%
on one core and 0% on the others, or all cores busy but no speedup.

This is surprisingly common and hard to debug from the user side because
they can't tell whether the problem is their code, Slurm, or the node. This
test isolates the infrastructure: if a simple OpenMP reduction doesn't scale,
the problem is below the application layer.

Root causes this test catches:

- **Thread affinity broken** — all OpenMP threads pinned to the same core. Can
  happen after a Slurm cgroup misconfiguration or a bad `TaskPluginParam`
  setting.
- **cpuset/cgroup misconfiguration** — the job can see 16 cores via `nproc` but
  the cgroup only allows execution on a subset.
- **NUMA balancing issues** — threads running on one socket but accessing memory
  on another, causing cross-socket traffic that kills scaling.
- **Hyperthreading surprises** — if Slurm allocates hyperthreads instead of
  physical cores, scaling will plateau at the physical core count.

## What it does

Compiles a small C program that:

1. Allocates a 100-million-element array of doubles (~800 MB)
2. Initializes it with `sin()` values (to prevent compiler optimization)
3. Runs a parallel reduction: `sum += data[i]*data[i] + sin(data[i])`

This workload is both compute-bound (the `sin()` call) and memory-bound (the
array traversal), making it representative of real scientific codes.

The test runs at 1, 2, 4, 8, and 16 threads, measuring wall-clock time at each
level. It uses `OMP_PROC_BIND=spread` and `OMP_PLACES=threads` to distribute
threads across available hardware.

## How to read the output

```
Threads      Time (s)     Speedup    Efficiency
-------      --------     -------    ----------
1              2.4531       1.00x       100.0%
2              1.2389       1.98x        99.0%
4              0.6301       3.89x        97.3%
8              0.3245       7.56x        94.5%
16             0.1798      13.64x        85.3%

[PASS] Max speedup 13.64x >= 4.0x threshold
```

**Speedup** is how many times faster the N-thread run is compared to the
single-thread run. Perfect scaling would be Nx (16x at 16 threads).

**Efficiency** is speedup/threads as a percentage. 100% means perfect scaling;
below ~50% means something is limiting parallelism.

The pass threshold is 4x at 16 threads — deliberately conservative. Healthy
nodes typically achieve 10-14x. Below 4x indicates a real infrastructure
problem.

## What the scaling curve tells you

| Pattern | Diagnosis |
|---------|-----------|
| Near-linear (12-15x at 16T) | Healthy node, good affinity |
| Plateau at 8x | Likely 8 physical cores with hyperthreading — the remaining 8 "CPUs" are hyperthreads that don't help this workload |
| Flat (1-2x regardless of threads) | Thread affinity broken — all threads on one core |
| Good to 4T, drops after | NUMA boundary — threads beyond one socket hit remote memory |
| Erratic (non-monotonic) | Competing workload on the node, or OS scheduler instability |

## Common failure scenarios

| Failure | Likely cause |
|---------|-------------|
| Speedup < 2x at 16 threads | All threads pinned to same core — check Slurm `TaskPlugin` and cgroup config |
| Speedup plateaus at half the core count | Hyperthreading: Slurm allocating logical, not physical cores |
| `bc` command not found | `bc` not installed on compute node (used for pass/fail comparison) |
| Compilation fails | `gcc` or OpenMP runtime not available — run test 01 first |

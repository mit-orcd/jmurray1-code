# Test 02: STREAM Memory Bandwidth

**Script:** `02-memory-stream.sbatch`
**Partition:** mit_quicktest
**Resources:** 1 node, 16 CPUs, 32 GB memory
**Run time:** ~5 minutes

## Why this test exists

Memory bandwidth is the hidden bottleneck behind most HPC workloads. Users
rarely measure it directly, but when a node's bandwidth drops by 30%+, their
jobs silently slow down and they open tickets about "the cluster being slow."

This test gives you a concrete number you can compare against a known-good
baseline. It catches problems that are invisible to basic health checks:

- **Failed or degraded DIMMs** — a node keeps running with fewer active memory
  channels, but bandwidth drops proportionally. The OS won't log anything
  obvious.
- **NUMA misconfiguration after a BIOS update** — all memory traffic gets
  funneled through one socket instead of being balanced, halving effective
  bandwidth.
- **Memory interleaving disabled** — sometimes toggled accidentally during BIOS
  changes.
- **Kernel or firmware regressions** — OS patches can change NUMA balancing
  behavior.

## What it does

Compiles and runs the STREAM benchmark — the industry-standard test for
measuring sustainable memory bandwidth. STREAM performs four simple operations
on large arrays that don't fit in cache, forcing the CPU to go to main memory:

| Kernel | Operation | Bytes per element |
|--------|-----------|-------------------|
| **Copy** | `c[i] = a[i]` | 16 (read 8, write 8) |
| **Scale** | `b[i] = scalar * c[i]` | 16 (read 8, write 8) |
| **Add** | `c[i] = a[i] + b[i]` | 24 (read 16, write 8) |
| **Triad** | `a[i] = b[i] + scalar * c[i]` | 24 (read 16, write 8) |

The test uses 40 million element arrays (~305 MiB each, ~915 MiB total), which
is large enough to exceed any CPU cache. It runs with OpenMP across all 16
allocated CPUs with `OMP_PROC_BIND=spread` to distribute threads across NUMA
domains.

Each kernel runs 20 times. The output reports best, average, and worst
bandwidth in GB/s.

After the benchmark, a validation step checks that the final array values match
the expected result — confirming the computation was correct, not just fast.

## How to read the output

```
STREAM: Array size = 40000000 (305.2 MiB per array), Threads = 16

Function      Best GB/s    Avg GB/s   Worst GB/s
------------------------------------------------------
Copy            150.3        145.2        138.7
Scale           148.9        143.6        137.1
Add             155.1        150.4        142.3
Triad           154.8        149.9        141.5

[PASS] Validation OK (error: 0.00e+00)
```

**The number to focus on is Triad Best GB/s.** This is the most commonly cited
STREAM result and represents the peak sustainable memory bandwidth the node can
deliver.

## Expected ranges

These depend heavily on the node's hardware:

| Node type | CPUs | Expected Triad (GB/s) |
|-----------|------|----------------------|
| 96-core (dual socket) | 96 | 150-300 |
| 192-core (dual socket, DDR5) | 192 | 200-400 |
| 64-core (single socket) | 64 | 80-200 |

The pass threshold is set conservatively at 10 GB/s — anything below that
indicates a severe problem. In practice, you should compare results against
your own baselines for each node type.

## How to establish baselines

Run this test on several healthy nodes of the same type and record the Triad
numbers:

```bash
for node in node1600 node1601 node1602; do
    ./run-all.sh 02 --node=$node
done
```

The average across healthy nodes becomes your baseline. A node more than 20%
below baseline warrants investigation.

## Common failure scenarios

| Symptom | Likely cause |
|---------|-------------|
| Triad 50% below baseline | Failed DIMM(s) reducing active memory channels |
| All kernels well below expected | NUMA misconfiguration — check BIOS interleaving settings |
| High variance (worst << best) | Competing workload or OS jitter on the node |
| Validation error | Memory corruption — serious hardware problem, drain the node |

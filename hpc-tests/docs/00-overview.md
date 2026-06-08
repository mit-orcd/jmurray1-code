# HPC Test Suite Overview

A personal set of self-contained diagnostic jobs for validating cluster health.
Each test targets a specific subsystem — CPU, memory, network, GPU, storage —
so when something breaks you can isolate which layer is at fault.

## When to run these tests

- **After any maintenance window** — run the full suite (`./run-all.sh`) to
  confirm the cluster came back healthy before opening it to users.
- **After node reboots or BIOS/firmware updates** — target the affected nodes
  with `./run-all.sh --node=<nodename>`.
- **When investigating a user complaint** — pick the test that matches the
  symptom (see table below).
- **Periodically** — run the full suite weekly or monthly to establish baseline
  numbers. Gradual degradation (e.g. memory bandwidth slowly dropping) is only
  visible if you have historical data to compare against.

## Test inventory

| # | Script | Subsystem | Partition | Time | Doc |
|---|--------|-----------|-----------|------|-----|
| 01 | `01-cpu-smoke.sbatch` | CPU / Environment | mit_quicktest | ~1 min | [01-cpu-smoke.md](01-cpu-smoke.md) |
| 02 | `02-memory-stream.sbatch` | Memory bandwidth | mit_quicktest | ~5 min | [02-memory-stream.md](02-memory-stream.md) |
| 03 | `03-openmp-scaling.sbatch` | CPU parallelism | mit_quicktest | ~3 min | [03-openmp-scaling.md](03-openmp-scaling.md) |
| 04 | `04-mpi-pingpong.sbatch` | Network / MPI | mit_normal (2 nodes) | ~5 min | [04-mpi-pingpong.md](04-mpi-pingpong.md) |
| 05 | `05-gpu-health.sbatch` | GPU health | mit_normal_gpu | ~5 min | [05-gpu-health.md](05-gpu-health.md) |
| 06 | `06-gpu-compute.sbatch` | GPU performance | mit_normal_gpu | ~5 min | [06-gpu-compute.md](06-gpu-compute.md) |
| 07 | `07-storage-io.sbatch` | Filesystem I/O | mit_quicktest | ~5 min | [07-storage-io.md](07-storage-io.md) |

## Matching symptoms to tests

| User complaint | Start with |
|----------------|------------|
| "My job won't start" / "Slurm is broken" | 01 (cpu-smoke) |
| "The cluster is slow" (general) | 02 (memory-stream), 07 (storage-io) |
| "My multi-threaded job doesn't scale" | 03 (openmp-scaling) |
| "My MPI job is slow across nodes" | 04 (mpi-pingpong) |
| "GPU errors" / "CUDA crashes" / "NaN in training" | 05 (gpu-health) |
| "GPU job is slower than expected" | 06 (gpu-compute) |
| "conda is slow" / "import takes forever" / "checkpoints are slow" | 07 (storage-io) |

## Usage

```bash
cd ~/git/jmurray1-code/hpc-tests

# Run all tests
./run-all.sh

# Run by category
./run-all.sh cpu          # tests 01, 02, 03, 07
./run-all.sh gpu          # tests 05, 06
./run-all.sh mpi          # test 04

# Run specific tests
./run-all.sh 01 05

# Target a specific node
./run-all.sh cpu --node=node1607

# Check results when jobs complete
./check-results.sh

# Check results for a specific job
./check-results.sh <jobid>

# Check all historical results
./check-results.sh --all
```

## How results work

Every test prints `[PASS]` or `[FAIL]` for each check it performs. The
`check-results.sh` script scans the output files, counts passes and failures,
and prints a color-coded summary with key metrics (bandwidth, speedup, TFLOPS,
latency) extracted from each test.

Job output files go to `output/` (git-ignored). The file naming convention is
`<test-name>_<jobid>.out`, so you can always trace a result back to a specific
Slurm job.

## How the tests are built

Each `.sbatch` script is self-contained. It embeds its own C or CUDA source
code as a heredoc, compiles it in a temp directory on the compute node, runs
it, and cleans up. There are no external dependencies beyond what's available
via `module load` (gcc, openmpi, cuda). This means you can copy any single
script to another system and run it — no build step required.

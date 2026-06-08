# Test 05: GPU Health Check

**Script:** `05-gpu-health.sbatch`
**Partition:** mit_normal_gpu
**Resources:** 1 node, 1 GPU, 4 CPUs, 16 GB memory
**Run time:** ~5 minutes

## Why this test exists

GPUs fail in ways that CPUs don't. A GPU can appear "up" in `nvidia-smi` but
have uncorrected ECC errors that silently corrupt computation, or run at
throttled clocks due to thermal problems, or have a firmware mismatch with the
driver. Users experience these as wrong results, NaN explosions in training, or
`CUDA_ERROR_ILLEGAL_ADDRESS` crashes — all of which look like application bugs.

This test catches the hardware-level problems before users hit them:

- **Uncorrected ECC errors** — the #1 source of silent data corruption on GPUs.
  A single uncorrected error means the GPU returned a wrong result without
  reporting it.
- **Thermal throttling** — fan failures, blocked airflow, or bad thermal paste
  cause the GPU to reduce clocks to avoid damage. The GPU still "works" but at
  a fraction of its rated speed.
- **Driver/CUDA version mismatches** — especially common after rolling OS
  updates where the driver gets updated but the CUDA toolkit doesn't, or vice
  versa.
- **GPU memory defects** — bad memory cells that store incorrect values.

Run this on every GPU node after maintenance, after driver updates, or when a
user reports GPU errors.

## What it checks

### GPU Overview
Runs `nvidia-smi` to display the full GPU status panel and a structured query
for: GPU name, driver version, temperature, power draw, memory total/used, and
ECC error count.

### ECC Error Check (1 check)
Queries `nvidia-smi` for `ecc.errors.uncorrected.volatile.total`. This counter
tracks uncorrected errors since the last driver load. Any non-zero value means
the GPU has produced at least one corrupt result.

If the GPU doesn't support ECC (consumer GPUs), the check is skipped with a
pass.

### Temperature Check (1 check)
Reads the GPU die temperature. The threshold is 85C — above this, most GPUs
begin thermal throttling. At idle or under light load, a healthy GPU should be
well below this (30-50C).

### CUDA Toolchain (1 check)
Loads the CUDA module and verifies that `nvcc` (the CUDA compiler) is found.
Also reports the CUDA version and `CUDA_VISIBLE_DEVICES` value so you can
confirm Slurm assigned the expected GPU.

### CUDA Vector Add (1 check — in output, separate from the check count)
Compiles and runs a CUDA program on the GPU that:

1. Allocates three arrays of 1,048,576 floats (4 MB each) on the GPU
2. Fills `a[i] = sin(i)` and `b[i] = cos(i)` on the CPU
3. Copies them to GPU memory
4. Runs a CUDA kernel: `c[i] = a[i] + b[i]`
5. Copies the result back to the CPU
6. Checks every element: `|c[i] - (sin(i) + cos(i))| < 1e-5`

This validates the full CUDA stack: module loading, compilation with `nvcc`,
host-to-device memory copies, kernel launch and execution, device-to-host
copies, and numerical correctness.

### GPU Memory Scan (1 check — in output, separate from the check count)
This is the most thorough part of the test. It compiles and runs a CUDA program
that:

1. **Queries free GPU memory** via `cudaMemGetInfo` and allocates 50% of it
   (e.g., ~22.5 GiB on a 45 GiB L40S)
2. **Write pass** — launches a CUDA kernel (`memtest`) where each GPU thread
   writes its own index to a unique memory location:
   ```
   buf[0] = 0, buf[1] = 1, buf[2] = 2, ... buf[N-1] = N-1
   ```
   With 4-byte unsigned ints and ~22.5 GiB, this covers roughly 5.9 billion
   cells.
3. **Verify pass** — launches a second kernel (`memcheck`) where each thread
   reads back its location and checks the value:
   ```
   if (buf[i] != i) atomicAdd(errors, 1);
   ```
   `atomicAdd` is a thread-safe increment so concurrent threads can all report
   errors without racing.
4. **Reports the error count.** Zero errors means every cell stored and
   returned the correct value.

**What this proves:** If you write a known pattern to every cell and read back
the exact same values, the GPU memory is storing data correctly. A bit flip
from a bad DRAM cell, a failing memory controller, or an electrical problem
would cause at least one mismatch.

**What this doesn't catch:** This is a single-pass test. More thorough GPU
memory testers (NVIDIA's `dcgmi diag -r 3`) use multiple patterns (all-0s,
all-1s, checkerboard, walking-bit), retention tests (write, wait, read), and
multiple passes to catch intermittent faults. Think of this test as a quick
blood-pressure check; `dcgmi diag` is the full physical.

## How to read the output

```
--- GPU Overview ---
0, NVIDIA L40S, 590.48.01, 31, 33.00 W, 46068 MiB, 0 MiB, 0

--- ECC Error Check ---
[PASS] No uncorrected ECC errors

--- Temperature Check ---
  GPU temperature: 31C
[PASS] Temperature 31C < 85C

--- CUDA Toolchain ---
[PASS] nvcc is available
  CUDA version: Cuda compilation tools, release 12.9, V12.9.86
  CUDA_VISIBLE_DEVICES=0

--- CUDA Vector Add ---
Device: NVIDIA L40S
Compute: 8.9
Memory: 45460 MiB
SMs: 142
Vector add (1048576 elements): 24.828 ms
[PASS] Vector add correct

--- GPU Memory Scan ---
Testing 22513 MiB of GPU memory (45460 MiB total)...
[PASS] GPU memory scan: 0 errors

 Results: 3/3 passed, 0 failed
 Status: ALL PASS
```

The summary counts the three checked-by-infrastructure checks (ECC, temp,
nvcc). The vector-add and memory-scan report their own `[PASS]`/`[FAIL]` lines
in the output.

## Common failure scenarios

| Failure | Likely cause | Action |
|---------|-------------|--------|
| ECC errors > 0 | Bad GPU memory cells | Check `nvidia-smi -q -d ECC` for details. If persistent, RMA the GPU. A reboot clears volatile counters — if they return, the hardware is faulty. |
| Temperature >= 85C | Cooling problem | Check fans, airflow, thermal paste. GPU may be in a hot spot in the chassis. |
| nvcc not found | CUDA module missing | Check `module avail cuda` — may need to update module path after maintenance. |
| Vector add errors | Compute unit or memory fault | Serious — the GPU is producing wrong results. Drain node, run `dcgmi diag -r 3` for full diagnostics. |
| Memory scan errors | Bad GPU DRAM cells | Drain node, run `dcgmi diag -r 3`. If errors persist across reboots, RMA. |
| nvcc compilation fails | Driver/CUDA mismatch | Check `nvidia-smi` CUDA version vs. `nvcc --version`. They must be compatible. |

## Targeting specific GPU types

To test a specific GPU type, modify the `-G` flag:

```bash
sbatch -G l40s:1 05-gpu-health.sbatch   # L40S
sbatch -G h100:1 05-gpu-health.sbatch   # H100
sbatch -G h200:1 05-gpu-health.sbatch   # H200
```

## nvcc warnings

You may see:
```
nvcc warning : Support for offline compilation for architectures prior to
'<compute/sm/lto>_75' will be removed in a future release
```

This is harmless — it means future CUDA versions will drop support for very old
GPU architectures (pre-Turing). All GPUs in this cluster are newer than that.
Add `-Wno-deprecated-gpu-targets` to the `nvcc` flags to suppress.

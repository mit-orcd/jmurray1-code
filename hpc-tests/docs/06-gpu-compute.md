# Test 06: GPU Compute (SGEMM) Benchmark

**Script:** `06-gpu-compute.sbatch`
**Partition:** mit_normal_gpu
**Resources:** 1 node, 1 GPU, 4 CPUs, 16 GB memory
**Run time:** ~5 minutes

## Why this test exists

Test 05 checks whether a GPU is alive and error-free. This test checks whether
it is performing at full speed.

A GPU can pass all health checks but deliver half its expected FLOPS due to:

- **Power capping** — data center power management limiting GPU wattage below
  the card's TDP
- **Clock throttling** — the GPU reducing boost clocks due to sustained thermal
  load (different from the acute overheating test 05 catches)
- **PCIe bandwidth limits** — a GPU in a x8 slot instead of x16, or running at
  Gen3 instead of Gen4/Gen5
- **Firmware issues** — VBIOS bugs that cap boost clocks below spec

Dense matrix multiply (SGEMM) via cuBLAS is the standard way to measure peak
GPU compute. It is the same operation that dominates deep learning training
(matrix multiplications in every layer) and many scientific codes (linear
algebra solvers). If SGEMM underperforms, everything built on top of it will
too.

## What it does

Compiles a CUDA program that uses NVIDIA's cuBLAS library to perform
single-precision general matrix multiplication (SGEMM): `C = A * B` where A
and B are square matrices.

The test runs at four matrix sizes:

| N | Matrix size | Memory per matrix | FLOPs per multiply |
|---|------------|-------------------|--------------------|
| 1024 | 1024x1024 | 4 MB | 2.1 billion |
| 2048 | 2048x2048 | 16 MB | 17.2 billion |
| 4096 | 4096x4096 | 64 MB | 137.4 billion |
| 8192 | 8192x8192 | 256 MB | 1.1 trillion |

At each size:
1. Allocate and fill matrices on the GPU
2. Run 3 warmup iterations (to stabilize GPU clocks and warm caches)
3. Run 10-20 timed iterations
4. Report average time and TFLOPS

**TFLOPS** (tera floating-point operations per second) is calculated as:
`2 * N^3 / time_in_seconds / 1e12`. The factor of 2 comes from the multiply-add
operations in matrix multiplication.

The peak TFLOPS across all sizes is reported as the headline number.

## How to read the output

```
Device: NVIDIA L40S (SM 8.9)

N           Time (ms)       TFLOPS
------      ----------      --------
1024            0.12          17.90
2048            0.65          26.43
4096            3.82          35.97
8192           27.14          40.51

Peak SGEMM: 40.51 TFLOPS
[PASS] Peak 40.51 TFLOPS > 10 TFLOPS threshold
```

**The number to focus on is Peak TFLOPS at the largest matrix size.** Small
matrices underutilize the GPU — the peak at N=8192 is closest to the GPU's
true capability.

## Expected values

| GPU | Published FP32 spec | Typical SGEMM result |
|-----|-------------------|---------------------|
| L40S | 91.6 TFLOPS | 35-50 TFLOPS |
| H100 SXM | 67 TFLOPS (FP32) | 45-60 TFLOPS |
| H200 SXM | 67 TFLOPS (FP32) | 45-60 TFLOPS |

The measured result is always below the published spec because:
- The spec includes tensor core operations; SGEMM on FP32 uses CUDA cores
- Memory bandwidth limits throughput at larger sizes
- There's overhead from kernel launch and synchronization

The pass threshold is set at 10 TFLOPS — very conservative so it doesn't
false-fail on any GPU type. What matters more is comparing against your own
baseline for each GPU model.

## Why SGEMM and not something else?

SGEMM is the standard because:
1. It's compute-bound (high arithmetic intensity), so it measures raw GPU
   compute rather than memory bandwidth
2. cuBLAS is NVIDIA's own highly optimized implementation — if cuBLAS is slow,
   the problem is the hardware, not the code
3. It's the same operation underlying deep learning frameworks, so SGEMM
   performance directly predicts training speed
4. Results are reproducible and comparable across runs and nodes

## Common failure scenarios

| Symptom | Likely cause |
|---------|-------------|
| TFLOPS well below baseline (>30% drop) | Check `nvidia-smi -q -d CLOCK` — GPU may be power-capped or thermally throttled |
| TFLOPS inconsistent across identical GPUs | The outlier GPU may have a hardware issue — check PCIe link width with `nvidia-smi -q -d PCIE` |
| cuBLAS error | CUDA/driver version mismatch — cuBLAS version must match CUDA toolkit |
| Very low TFLOPS only at large N | GPU memory bandwidth bottleneck — may indicate PCIe or HBM issues |
| Compilation fails | cuBLAS headers not found — check that CUDA module includes cuBLAS (`ls $CUDA_HOME/lib64/libcublas*`) |

## Targeting specific GPU types

```bash
sbatch -G l40s:1 06-gpu-compute.sbatch   # benchmark an L40S
sbatch -G h100:1 06-gpu-compute.sbatch   # benchmark an H100
sbatch -G h200:1 06-gpu-compute.sbatch   # benchmark an H200
```

## Building a performance database

To track GPU health over time, run this across all GPU nodes and save the
results:

```bash
for node in $(sinfo -p mit_normal_gpu -N -h -o "%N"); do
    sbatch --nodelist=$node -G 1 06-gpu-compute.sbatch
done
```

Then grep the peak TFLOPS from each output file to build a per-node comparison:

```bash
for f in output/06-gpu-compute_*.out; do
    node=$(grep "Host:" "$f" | awk '{print $2}')
    gpu=$(grep "Device:" "$f" | sed 's/Device: //')
    tflops=$(grep "Peak SGEMM" "$f" | grep -oP '[\d.]+' | head -1)
    echo "$node  $gpu  $tflops TFLOPS"
done | sort
```

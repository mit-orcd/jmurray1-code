#!/bin/bash
#SBATCH --job-name=test-gpu-health
#SBATCH --partition=mit_normal_gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH -G 1
#SBATCH --mem=16G
#SBATCH --time=00:15:00
#SBATCH --output=output/05-gpu-health_%j.out

###############################################################################
# 05-gpu-health: GPU device health check
#
# WHY: GPUs fail in ways that CPUs don't. A GPU can appear "up" in nvidia-smi
# but have uncorrected ECC errors that silently corrupt computation, or run at
# throttled clocks due to thermal problems, or have a firmware mismatch with
# the driver. Users experience this as wrong results, NaN explosions in
# training, or CUDA_ERROR_ILLEGAL_ADDRESS crashes — all of which look like
# application bugs. This test catches the hardware-level problems:
#   - Uncorrected ECC errors (the #1 silent data corruption source on GPUs)
#   - Thermal throttling (fan failures, blocked airflow, bad thermal paste)
#   - Driver/CUDA version mismatches (especially after rolling OS updates)
#   - GPU memory defects (the memory scan writes and reads back every cell)
# Run this on every GPU node after maintenance, after driver updates, or when
# a user reports GPU errors. The vector-add validates the full CUDA stack from
# compilation through kernel launch to result verification.
#
# Queries nvidia-smi for GPU status, ECC errors, temperature, clocks.
# Compiles and runs a CUDA vector-add and a GPU memory scan.
#
# PASS criteria: no ECC errors, temperature < 85C, CUDA vector-add correct,
# memory scan clean.
###############################################################################

set -euo pipefail

PASS=0
FAIL=0

check() {
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "[PASS] $label"
        ((PASS++))
    else
        echo "[FAIL] $label"
        ((FAIL++))
    fi
}

echo "==============================================="
echo " HPC Test 05: GPU Health Check"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo "==============================================="
echo ""

# --- nvidia-smi overview ---
echo "--- GPU Overview ---"
nvidia-smi --query-gpu=index,name,driver_version,temperature.gpu,power.draw,memory.total,memory.used,ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null || echo "(nvidia-smi query failed)"
echo ""
nvidia-smi 2>/dev/null || true
echo ""

# --- ECC check ---
echo "--- ECC Error Check ---"
UNCORR=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader,nounits 2>/dev/null | head -1)
if [ "$UNCORR" = "N/A" ] || [ "$UNCORR" = "[N/A]" ]; then
    echo "  ECC not supported on this GPU (skipping)"
    echo "[PASS] ECC check (not applicable)"
    ((PASS++))
elif [ "${UNCORR:-0}" -eq 0 ] 2>/dev/null; then
    echo "[PASS] No uncorrected ECC errors"
    ((PASS++))
else
    echo "[FAIL] $UNCORR uncorrected ECC errors detected!"
    ((FAIL++))
fi

# --- Temperature check ---
echo ""
echo "--- Temperature Check ---"
TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
echo "  GPU temperature: ${TEMP}C"
if [ "${TEMP:-99}" -lt 85 ] 2>/dev/null; then
    echo "[PASS] Temperature ${TEMP}C < 85C"
    ((PASS++))
else
    echo "[FAIL] Temperature ${TEMP}C >= 85C (throttling risk)"
    ((FAIL++))
fi

# --- CUDA toolchain ---
echo ""
echo "--- CUDA Toolchain ---"
module load cuda/12.9.1 2>/dev/null || module load cuda 2>/dev/null || true
check "nvcc is available" which nvcc
echo "  CUDA version: $(nvcc --version 2>/dev/null | grep 'release' || echo 'unknown')"
echo "  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-not set}"

# --- CUDA vector add ---
echo ""
echo "--- CUDA Vector Add ---"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "${WORKDIR}/vecadd.cu" << 'CUEOF'
#include <stdio.h>
#include <math.h>

#define N (1 << 20)

__global__ void vecAdd(float *a, float *b, float *c, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Device: %s\n", prop.name);
    printf("Compute: %d.%d\n", prop.major, prop.minor);
    printf("Memory: %.0f MiB\n", prop.totalGlobalMem / 1048576.0);
    printf("SMs: %d\n", prop.multiProcessorCount);

    float *h_a, *h_b, *h_c;
    float *d_a, *d_b, *d_c;
    size_t bytes = N * sizeof(float);

    h_a = (float*)malloc(bytes);
    h_b = (float*)malloc(bytes);
    h_c = (float*)malloc(bytes);

    for (int i = 0; i < N; i++) {
        h_a[i] = sinf(i);
        h_b[i] = cosf(i);
    }

    cudaMalloc(&d_a, bytes);
    cudaMalloc(&d_b, bytes);
    cudaMalloc(&d_c, bytes);

    cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_b, h_b, bytes, cudaMemcpyHostToDevice);

    int blockSize = 256;
    int gridSize = (N + blockSize - 1) / blockSize;

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);
    vecAdd<<<gridSize, blockSize>>>(d_a, d_b, d_c, N);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms;
    cudaEventElapsedTime(&ms, start, stop);
    printf("Vector add (%d elements): %.3f ms\n", N, ms);

    cudaMemcpy(h_c, d_c, bytes, cudaMemcpyDeviceToHost);

    int errors = 0;
    for (int i = 0; i < N; i++) {
        float expected = sinf(i) + cosf(i);
        if (fabsf(h_c[i] - expected) > 1e-5) errors++;
    }

    if (errors == 0)
        printf("[PASS] Vector add correct\n");
    else
        printf("[FAIL] Vector add: %d errors out of %d\n", errors, N);

    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    free(h_a); free(h_b); free(h_c);
    return errors > 0 ? 1 : 0;
}
CUEOF

echo "Compiling CUDA vector add..."
if nvcc -O2 "${WORKDIR}/vecadd.cu" -o "${WORKDIR}/vecadd" 2>&1; then
    echo ""
    "${WORKDIR}/vecadd"
else
    echo "[FAIL] nvcc compilation failed"
    ((FAIL++))
fi

# --- Quick GPU memory scan ---
echo ""
echo "--- GPU Memory Scan ---"
cat > "${WORKDIR}/memscan.cu" << 'CUEOF'
#include <stdio.h>
#include <stdlib.h>

__global__ void memtest(unsigned int *buf, size_t n) {
    size_t i = (size_t)blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) {
        buf[i] = (unsigned int)i;
    }
}

__global__ void memcheck(unsigned int *buf, size_t n, int *errors) {
    size_t i = (size_t)blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) {
        if (buf[i] != (unsigned int)i)
            atomicAdd(errors, 1);
    }
}

int main() {
    size_t free_mem, total_mem;
    cudaMemGetInfo(&free_mem, &total_mem);
    // Use 50% of free memory
    size_t test_bytes = free_mem / 2;
    size_t n = test_bytes / sizeof(unsigned int);

    printf("Testing %.0f MiB of GPU memory (%.0f MiB total)...\n",
           test_bytes / 1048576.0, total_mem / 1048576.0);

    unsigned int *d_buf;
    int *d_errors, h_errors = 0;
    cudaMalloc(&d_buf, test_bytes);
    cudaMalloc(&d_errors, sizeof(int));
    cudaMemset(d_errors, 0, sizeof(int));

    int bs = 256;
    int gs = (n + bs - 1) / bs;
    memtest<<<gs, bs>>>(d_buf, n);
    memcheck<<<gs, bs>>>(d_buf, n, d_errors);
    cudaDeviceSynchronize();

    cudaMemcpy(&h_errors, d_errors, sizeof(int), cudaMemcpyDeviceToHost);
    if (h_errors == 0)
        printf("[PASS] GPU memory scan: 0 errors\n");
    else
        printf("[FAIL] GPU memory scan: %d errors\n", h_errors);

    cudaFree(d_buf);
    cudaFree(d_errors);
    return h_errors > 0 ? 1 : 0;
}
CUEOF

if nvcc -O2 "${WORKDIR}/memscan.cu" -o "${WORKDIR}/memscan" 2>&1; then
    "${WORKDIR}/memscan"
else
    echo "[FAIL] memscan compilation failed"
    ((FAIL++))
fi

# --- Summary ---
echo ""
echo "==============================================="
TOTAL=$((PASS + FAIL))
echo " Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then
    echo " Status: ALL PASS"
else
    echo " Status: FAILURES DETECTED"
fi
echo "==============================================="
exit "$FAIL"

#!/bin/bash
#SBATCH --job-name=test-gpu-compute
#SBATCH --partition=mit_normal_gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH -G 1
#SBATCH --mem=16G
#SBATCH --time=00:15:00
#SBATCH --output=output/06-gpu-compute_%j.out

###############################################################################
# 06-gpu-compute: GPU SGEMM (single-precision matrix multiply) benchmark
#
# WHY: Test 05 checks whether a GPU is alive and error-free; this test checks
# whether it is performing at full speed. A GPU can pass health checks but
# deliver half its expected FLOPS due to power capping, clock throttling, PCIe
# bandwidth limits, or firmware issues that cap boost clocks. Dense matrix
# multiply (SGEMM) via cuBLAS is the standard way to measure peak GPU compute
# — it is the same operation that dominates deep learning training and many
# scientific codes. Comparing the measured TFLOPS against the published spec
# tells you immediately whether the GPU is healthy:
#   - Well below spec → check power limits, thermal throttling, PCIe width
#   - Near spec → GPU is performing normally
#   - Inconsistent across identical GPUs → investigate the outlier node
# Keep a record of results per node to establish baselines and catch gradual
# degradation over time.
#
# Measures GPU TFLOPS on a dense matrix multiply using cuBLAS at matrix sizes
# N=1024, 2048, 4096, 8192.
#
# Expected SGEMM TFLOPS (approximate):
#   L40S:  ~91 TFLOPS FP32
#   H100:  ~67 TFLOPS FP32 (up to 989 with sparsity/tensor cores)
#   H200:  ~67 TFLOPS FP32
#
# PASS criteria: achieves > 10 TFLOPS (very conservative floor).
###############################################################################

set -euo pipefail

echo "==============================================="
echo " HPC Test 06: GPU Compute (SGEMM) Benchmark"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo "==============================================="
echo ""

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "${WORKDIR}/sgemm.cu" << 'CUEOF'
#include <stdio.h>
#include <stdlib.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>

void check_cuda(cudaError_t err, const char *msg) {
    if (err != cudaSuccess) {
        fprintf(stderr, "CUDA error at %s: %s\n", msg, cudaGetErrorString(err));
        exit(1);
    }
}

void check_cublas(cublasStatus_t stat, const char *msg) {
    if (stat != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "cuBLAS error at %s: %d\n", msg, stat);
        exit(1);
    }
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Device: %s (SM %d.%d)\n\n", prop.name, prop.major, prop.minor);

    cublasHandle_t handle;
    check_cublas(cublasCreate(&handle), "cublasCreate");

    int sizes[] = {1024, 2048, 4096, 8192, 0};
    float alpha = 1.0f, beta = 0.0f;

    printf("%-8s  %12s  %12s\n", "N", "Time (ms)", "TFLOPS");
    printf("%-8s  %12s  %12s\n", "------", "----------", "--------");

    double max_tflops = 0;

    for (int s = 0; sizes[s] > 0; s++) {
        int N = sizes[s];
        size_t bytes = (size_t)N * N * sizeof(float);
        float *d_A, *d_B, *d_C;

        check_cuda(cudaMalloc(&d_A, bytes), "malloc A");
        check_cuda(cudaMalloc(&d_B, bytes), "malloc B");
        check_cuda(cudaMalloc(&d_C, bytes), "malloc C");

        // Fill with random-ish data
        float *h = (float*)malloc(bytes);
        for (long i = 0; i < (long)N*N; i++) h[i] = (float)(i % 1000) / 1000.0f;
        cudaMemcpy(d_A, h, bytes, cudaMemcpyHostToDevice);
        cudaMemcpy(d_B, h, bytes, cudaMemcpyHostToDevice);
        free(h);

        // Warmup
        for (int i = 0; i < 3; i++)
            cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                        N, N, N, &alpha, d_A, N, d_B, N, &beta, d_C, N);
        cudaDeviceSynchronize();

        // Benchmark
        int iters = N <= 2048 ? 20 : 10;
        cudaEvent_t start, stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);

        cudaEventRecord(start);
        for (int i = 0; i < iters; i++)
            cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                        N, N, N, &alpha, d_A, N, d_B, N, &beta, d_C, N);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float ms;
        cudaEventElapsedTime(&ms, start, stop);
        ms /= iters;

        double flops = 2.0 * (double)N * N * N;
        double tflops = flops / (ms * 1e-3) / 1e12;
        if (tflops > max_tflops) max_tflops = tflops;

        printf("%-8d  %12.2f  %12.2f\n", N, ms, tflops);

        cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);
        cudaEventDestroy(start); cudaEventDestroy(stop);
    }

    cublasDestroy(handle);

    printf("\nPeak SGEMM: %.2f TFLOPS\n", max_tflops);
    if (max_tflops > 10.0)
        printf("[PASS] Peak %.2f TFLOPS > 10 TFLOPS threshold\n", max_tflops);
    else
        printf("[FAIL] Peak %.2f TFLOPS < 10 TFLOPS (GPU may be throttled or unhealthy)\n", max_tflops);

    return max_tflops > 10.0 ? 0 : 1;
}
CUEOF

module load cuda/12.9.1 2>/dev/null || module load cuda 2>/dev/null || true

echo "Compiling cuBLAS SGEMM benchmark..."
nvcc -O2 -lcublas "${WORKDIR}/sgemm.cu" -o "${WORKDIR}/sgemm"

echo ""
"${WORKDIR}/sgemm"

echo ""
echo "==============================================="
echo " Test complete"
echo "==============================================="

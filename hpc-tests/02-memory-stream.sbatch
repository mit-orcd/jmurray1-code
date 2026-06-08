#!/bin/bash
#SBATCH --job-name=test-mem-stream
#SBATCH --partition=mit_quicktest
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --time=00:15:00
#SBATCH --output=output/02-memory-stream_%j.out

###############################################################################
# 02-memory-stream: STREAM memory bandwidth benchmark
#
# WHY: Memory bandwidth is the hidden bottleneck behind most HPC workloads.
# Users rarely measure it directly, but when a node's STREAM Triad number drops
# by 30%+, their jobs silently slow down and they open tickets about "the
# cluster being slow." Common root causes this test catches:
#   - Failed or degraded DIMMs (node runs but at reduced bandwidth)
#   - NUMA misconfiguration after a BIOS update (all memory traffic funneled
#     through one socket)
#   - Memory interleaving disabled or channel imbalance
#   - Kernel or firmware regressions after OS patching
# The STREAM benchmark is the industry-standard way to measure achievable
# memory bandwidth. Running it after maintenance gives you a concrete number
# to compare against the node's known-good baseline.
#
# Compiles and runs the STREAM benchmark with OpenMP. Measures Copy, Scale,
# Add, Triad bandwidth.
#
# Expected ranges (per socket, DDR5 server):
#   Copy:  80-250 GB/s   (depends on core count and memory channels)
#   Triad: 70-230 GB/s
#
# PASS criteria: all four kernels complete and report bandwidth > 10 GB/s
###############################################################################

set -euo pipefail

echo "==============================================="
echo " HPC Test 02: STREAM Memory Bandwidth"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo " CPUs: $(nproc)"
echo "==============================================="
echo ""

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "${WORKDIR}/stream.c" << 'CEOF'
/*
 * Minimal STREAM benchmark (Triad-focused).
 * Based on McCalpin's STREAM but simplified for portability.
 */
#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <math.h>
#include <sys/time.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#ifndef STREAM_ARRAY_SIZE
#define STREAM_ARRAY_SIZE 40000000
#endif
#define NTIMES 20

static double a[STREAM_ARRAY_SIZE], b[STREAM_ARRAY_SIZE], c[STREAM_ARRAY_SIZE];

static double mysecond() {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return (double)tp.tv_sec + (double)tp.tv_usec * 1.e-6;
}

int main() {
    double scalar = 3.0;
    double times[4][NTIMES];
    double avgtime[4] = {0}, maxtime[4] = {0}, mintime[4];
    double bytes[4];

    bytes[0] = 2 * sizeof(double) * STREAM_ARRAY_SIZE; // Copy
    bytes[1] = 2 * sizeof(double) * STREAM_ARRAY_SIZE; // Scale
    bytes[2] = 3 * sizeof(double) * STREAM_ARRAY_SIZE; // Add
    bytes[3] = 3 * sizeof(double) * STREAM_ARRAY_SIZE; // Triad

    for (int i = 0; i < 4; i++) mintime[i] = DBL_MAX;

    int nthreads = 1;
#ifdef _OPENMP
    #pragma omp parallel
    #pragma omp master
    nthreads = omp_get_num_threads();
#endif
    printf("STREAM: Array size = %d (%.1f MiB per array), Threads = %d\n",
           STREAM_ARRAY_SIZE,
           (double)STREAM_ARRAY_SIZE * sizeof(double) / 1048576.0,
           nthreads);

    // Initialize
    #pragma omp parallel for
    for (int j = 0; j < STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0; b[j] = 2.0; c[j] = 0.0;
    }

    for (int k = 0; k < NTIMES; k++) {
        // Copy: c = a
        times[0][k] = mysecond();
        #pragma omp parallel for
        for (int j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j];
        times[0][k] = mysecond() - times[0][k];

        // Scale: b = scalar*c
        times[1][k] = mysecond();
        #pragma omp parallel for
        for (int j = 0; j < STREAM_ARRAY_SIZE; j++) b[j] = scalar * c[j];
        times[1][k] = mysecond() - times[1][k];

        // Add: c = a+b
        times[2][k] = mysecond();
        #pragma omp parallel for
        for (int j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j] + b[j];
        times[2][k] = mysecond() - times[2][k];

        // Triad: a = b+scalar*c
        times[3][k] = mysecond();
        #pragma omp parallel for
        for (int j = 0; j < STREAM_ARRAY_SIZE; j++) a[j] = b[j] + scalar * c[j];
        times[3][k] = mysecond() - times[3][k];
    }

    for (int k = 1; k < NTIMES; k++) {
        for (int j = 0; j < 4; j++) {
            avgtime[j] += times[j][k];
            if (times[j][k] < mintime[j]) mintime[j] = times[j][k];
            if (times[j][k] > maxtime[j]) maxtime[j] = times[j][k];
        }
    }

    const char *label[] = {"Copy", "Scale", "Add", "Triad"};
    printf("\n%-10s  %11s  %11s  %11s\n", "Function", "Best GB/s", "Avg GB/s", "Worst GB/s");
    printf("------------------------------------------------------\n");
    int pass = 1;
    for (int j = 0; j < 4; j++) {
        avgtime[j] /= (NTIMES - 1);
        double best  = 1.0e-9 * bytes[j] / mintime[j];
        double avg   = 1.0e-9 * bytes[j] / avgtime[j];
        double worst = 1.0e-9 * bytes[j] / maxtime[j];
        printf("%-10s  %8.1f     %8.1f     %8.1f\n", label[j], best, avg, worst);
        if (best < 10.0) pass = 0;
    }
    printf("\n");

    // Validation
    double aj = 1.0, bj = 2.0, cj = 0.0;
    for (int k = 0; k < NTIMES; k++) {
        cj = aj; bj = scalar*cj; cj = aj+bj; aj = bj+scalar*cj;
    }
    double err = fabs(a[STREAM_ARRAY_SIZE/2] - aj) / aj;
    if (err > 1.0e-10) {
        printf("[FAIL] Validation error: %.2e\n", err);
        pass = 0;
    } else {
        printf("[PASS] Validation OK (error: %.2e)\n", err);
    }

    return pass ? 0 : 1;
}
CEOF

module load gcc/12.2.0 2>/dev/null || true
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-16}
export OMP_PROC_BIND=spread
export OMP_PLACES=threads

echo "Compiling STREAM benchmark..."
gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=40000000 \
    "${WORKDIR}/stream.c" -o "${WORKDIR}/stream" -lm

echo "Running with OMP_NUM_THREADS=${OMP_NUM_THREADS}..."
echo ""
"${WORKDIR}/stream"

echo ""
echo "==============================================="
echo " Test complete"
echo "==============================================="

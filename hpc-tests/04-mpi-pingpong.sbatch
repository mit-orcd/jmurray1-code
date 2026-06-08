#!/bin/bash
#SBATCH --job-name=test-mpi-pingpong
#SBATCH --partition=mit_normal
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G
#SBATCH --time=00:15:00
#SBATCH --output=output/04-mpi-pingpong_%j.out

###############################################################################
# 04-mpi-pingpong: Inter-node MPI latency and bandwidth
#
# WHY: Multi-node MPI jobs are the workloads most sensitive to network health.
# A single bad cable, a misconfigured switch port, or a downed InfiniBand link
# can degrade one node pair while everything else looks fine — users see their
# 64-node job run 10x slower than expected and blame the application. Ping-pong
# is the most basic fabric diagnostic: it isolates raw point-to-point latency
# and bandwidth between exactly two nodes, independent of application behavior.
# Run this:
#   - After network maintenance or switch firmware updates
#   - When users report multi-node jobs are slow but single-node jobs are fine
#   - With --node=<suspect_node> to test a specific node pair
#   - Periodically to establish latency/bandwidth baselines per node generation
# The latency at small message sizes tells you about fabric overhead; the
# bandwidth at large sizes tells you about link capacity. Both should be
# consistent across node pairs of the same type.
#
# Runs a ping-pong test between two nodes at various message sizes.
# Measures latency (small messages) and bandwidth (large messages).
#
# Expected ranges (InfiniBand HDR/NDR):
#   Latency (8 bytes):  1-5 us
#   Bandwidth (4 MB):   10-25 GB/s
#
# PASS criteria: latency < 50 us, bandwidth > 1 GB/s
###############################################################################

set -euo pipefail

echo "==============================================="
echo " HPC Test 04: MPI Ping-Pong"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Nodes: ${SLURM_NODELIST:-N/A}"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo "==============================================="
echo ""

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "${WORKDIR}/pingpong.c" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mpi.h>

#define WARMUP 100
#define ITERATIONS 1000
#define MAX_SIZE (4 * 1024 * 1024)

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    char hostname[256];
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(hostname, sizeof(hostname));

    printf("Rank %d on %s\n", rank, hostname);
    MPI_Barrier(MPI_COMM_WORLD);

    if (size != 2) {
        if (rank == 0) printf("ERROR: need exactly 2 ranks\n");
        MPI_Finalize();
        return 1;
    }

    char *buf = malloc(MAX_SIZE);
    memset(buf, 'x', MAX_SIZE);

    if (rank == 0) {
        printf("\n%-12s  %12s  %12s\n", "Size (bytes)", "Latency (us)", "BW (GB/s)");
        printf("%-12s  %12s  %12s\n", "------------", "------------", "---------");
    }

    int sizes[] = {8, 64, 512, 4096, 32768, 262144, 1048576, 4194304, -1};
    double min_latency = 1e9, max_bw = 0;

    for (int s = 0; sizes[s] > 0; s++) {
        int nbytes = sizes[s];
        int iters = nbytes > 65536 ? 200 : ITERATIONS;

        // warmup
        for (int i = 0; i < WARMUP; i++) {
            if (rank == 0) {
                MPI_Send(buf, nbytes, MPI_BYTE, 1, 0, MPI_COMM_WORLD);
                MPI_Recv(buf, nbytes, MPI_BYTE, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            } else {
                MPI_Recv(buf, nbytes, MPI_BYTE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Send(buf, nbytes, MPI_BYTE, 0, 0, MPI_COMM_WORLD);
            }
        }

        MPI_Barrier(MPI_COMM_WORLD);
        double t0 = MPI_Wtime();

        for (int i = 0; i < iters; i++) {
            if (rank == 0) {
                MPI_Send(buf, nbytes, MPI_BYTE, 1, 0, MPI_COMM_WORLD);
                MPI_Recv(buf, nbytes, MPI_BYTE, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            } else {
                MPI_Recv(buf, nbytes, MPI_BYTE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Send(buf, nbytes, MPI_BYTE, 0, 0, MPI_COMM_WORLD);
            }
        }

        double elapsed = MPI_Wtime() - t0;
        double latency_us = elapsed / (2.0 * iters) * 1e6;
        double bw_gbs = (double)nbytes / (elapsed / (2.0 * iters)) / 1e9;

        if (nbytes <= 64 && latency_us < min_latency) min_latency = latency_us;
        if (bw_gbs > max_bw) max_bw = bw_gbs;

        if (rank == 0)
            printf("%-12d  %12.2f  %12.3f\n", nbytes, latency_us, bw_gbs);
    }

    if (rank == 0) {
        printf("\nSummary: min latency = %.2f us, max bandwidth = %.3f GB/s\n", min_latency, max_bw);
        if (min_latency < 50.0 && max_bw > 1.0)
            printf("[PASS] Latency < 50 us and bandwidth > 1 GB/s\n");
        else
            printf("[FAIL] Latency=%.2f us (want <50), BW=%.3f GB/s (want >1)\n", min_latency, max_bw);
    }

    free(buf);
    MPI_Finalize();
    return 0;
}
CEOF

module load gcc/12.2.0 2>/dev/null || true
module load openmpi/4.1.4 2>/dev/null || true

echo "Compiling MPI ping-pong..."
mpicc -O2 "${WORKDIR}/pingpong.c" -o "${WORKDIR}/pingpong"

echo "Running across nodes: ${SLURM_NODELIST}"
echo ""
srun "${WORKDIR}/pingpong"

echo ""
echo "==============================================="
echo " Test complete"
echo "==============================================="

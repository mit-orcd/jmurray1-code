#!/bin/bash
#SBATCH --job-name=test-omp-scaling
#SBATCH --partition=mit_quicktest
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=8G
#SBATCH --time=00:10:00
#SBATCH --output=output/03-openmp-scaling_%j.out

###############################################################################
# 03-openmp-scaling: OpenMP thread scaling test
#
# WHY: Many user codes (MATLAB, R, OpenFOAM, LAMMPS) use OpenMP for
# shared-memory parallelism. When thread scaling breaks — a node shows 1x
# speedup regardless of core count — the symptom is "my job uses 16 cores but
# runs at single-core speed." This is surprisingly common and hard to debug
# from the user side. Root causes this test catches:
#   - Thread affinity not working (all threads pinned to one core)
#   - cpuset/cgroup misconfiguration in Slurm (job sees cores but can't use
#     them)
#   - NUMA balancing issues causing cross-socket memory traffic
#   - Hyperthreading providing less benefit than expected
# The scaling curve (speedup at 1/2/4/8/16 threads) is more informative than a
# single-threaded benchmark — it tells you whether adding cores actually helps.
#
# Runs a parallel reduction at 1, 2, 4, 8, 16 threads and reports wall time
# and speedup.
#
# PASS criteria: 16-thread speedup >= 4x over single-thread.
###############################################################################

set -euo pipefail

echo "==============================================="
echo " HPC Test 03: OpenMP Thread Scaling"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo " CPUs available: $(nproc)"
echo "==============================================="
echo ""

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "${WORKDIR}/omp_scale.c" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <omp.h>

#define N 100000000

int main(int argc, char *argv[]) {
    int nthreads = atoi(argv[1]);
    omp_set_num_threads(nthreads);

    double *data = malloc(N * sizeof(double));
    if (!data) { fprintf(stderr, "malloc failed\n"); return 1; }

    #pragma omp parallel for
    for (long i = 0; i < N; i++)
        data[i] = sin((double)i * 1.0e-8);

    double t0 = omp_get_wtime();

    double sum = 0.0;
    #pragma omp parallel for reduction(+:sum)
    for (long i = 0; i < N; i++)
        sum += data[i] * data[i] + sin(data[i]);

    double elapsed = omp_get_wtime() - t0;

    printf("%d %.4f %.6e\n", nthreads, elapsed, sum);

    free(data);
    return 0;
}
CEOF

module load gcc/12.2.0 2>/dev/null || true
export OMP_PROC_BIND=spread
export OMP_PLACES=threads

echo "Compiling OpenMP scaling test..."
gcc -O3 -fopenmp "${WORKDIR}/omp_scale.c" -o "${WORKDIR}/omp_scale" -lm

echo ""
printf "%-10s  %10s  %10s  %10s\n" "Threads" "Time (s)" "Speedup" "Efficiency"
printf "%-10s  %10s  %10s  %10s\n" "-------" "--------" "-------" "----------"

BASELINE=""
PASS=1
for T in 1 2 4 8 16; do
    if [ "$T" -gt "$(nproc)" ]; then
        break
    fi
    LINE=$("${WORKDIR}/omp_scale" "$T")
    TIME=$(echo "$LINE" | awk '{print $2}')

    if [ -z "$BASELINE" ]; then
        BASELINE=$TIME
    fi

    SPEEDUP=$(echo "$BASELINE $TIME" | awk '{printf "%.2f", $1/$2}')
    EFF=$(echo "$SPEEDUP $T" | awk '{printf "%.1f%%", 100*$1/$2}')
    printf "%-10d  %10.4f  %10s  %10s\n" "$T" "$TIME" "${SPEEDUP}x" "$EFF"
done

MAX_SPEEDUP=$(echo "$BASELINE" | awk -v t="$TIME" '{printf "%.2f", $1/t}')
echo ""
if (( $(echo "$MAX_SPEEDUP >= 4.0" | bc -l) )); then
    echo "[PASS] Max speedup ${MAX_SPEEDUP}x >= 4.0x threshold"
else
    echo "[FAIL] Max speedup ${MAX_SPEEDUP}x < 4.0x threshold (possible affinity/NUMA issue)"
    PASS=0
fi

echo ""
echo "==============================================="
echo " Test complete"
echo "==============================================="
exit $((1 - PASS))

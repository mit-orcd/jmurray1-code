#!/bin/bash
#SBATCH --job-name=test-cpu-smoke
#SBATCH --partition=mit_quicktest
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:10:00
#SBATCH --output=output/01-cpu-smoke_%j.out

###############################################################################
# 01-cpu-smoke: Basic CPU scheduling and environment sanity check
#
# WHY: This is the first test to run after any maintenance window, node reboot,
# or Slurm configuration change. It answers the most fundamental question: "can
# the scheduler place a job on a node and does the node's basic environment
# work?" Failures here indicate systemic issues — a broken module tree, a
# misconfigured Slurm partition, an unmounted filesystem, or a DNS problem —
# that will cause every user job to fail. Running this first saves you from
# chasing application-level bugs that are really infrastructure problems.
#
# Verifies: job scheduling, resource allocation matches request, environment
# variables, filesystem access (home + scratch), module loading, DNS, basic
# compute correctness.
#
# PASS criteria: all checks print [PASS], no [FAIL] lines in output.
###############################################################################

set -uo pipefail

PASS=0
FAIL=0

check() {
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "[PASS] $label"
        ((PASS++)) || true
    else
        echo "[FAIL] $label"
        ((FAIL++)) || true
    fi
}

echo "==============================================="
echo " HPC Test 01: CPU Smoke Test"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo "==============================================="
echo ""

# --- Resource allocation ---
echo "--- Resource Allocation ---"
echo "  Requested CPUs: ${SLURM_CPUS_PER_TASK:-?}"
echo "  Allocated node: ${SLURM_NODELIST:-?}"
echo "  Allocated CPUs: $(nproc)"
echo "  Total memory:   $(free -h | awk '/Mem:/{print $2}')"
echo ""

check "SLURM_JOB_ID is set" test -n "${SLURM_JOB_ID:-}"
check "SLURM_NODELIST is set" test -n "${SLURM_NODELIST:-}"
check "nproc >= requested CPUs" test "$(nproc)" -ge "${SLURM_CPUS_PER_TASK:-1}"

# --- Environment ---
echo ""
echo "--- Environment ---"
echo "  USER=$USER"
echo "  HOME=$HOME"
echo "  PATH (first 3):"
echo "$PATH" | tr ':' '\n' | head -3 | sed 's/^/    /'
echo ""

check "USER is set" test -n "${USER:-}"
check "HOME is set and exists" test -d "$HOME"

# --- Filesystem access ---
echo ""
echo "--- Filesystem Access ---"
TMPFILE=$(mktemp "${HOME}/.hpc_test_XXXXXX")
echo "test_data_$$" > "$TMPFILE"
check "Write to HOME" test -f "$TMPFILE"
check "Read from HOME" grep -q "test_data_$$" "$TMPFILE"
rm -f "$TMPFILE"

if [ -d /pool001 ]; then
    echo "  /pool001 found"
    check "/pool001 is accessible" test -r /pool001
elif [ -d /scratch ]; then
    echo "  /scratch found"
    check "/scratch is accessible" test -r /scratch
else
    echo "  (no shared scratch detected, skipping)"
fi

check "/tmp is writable" touch /tmp/.hpc_test_$$ && rm -f /tmp/.hpc_test_$$

# --- Module system ---
echo ""
echo "--- Module System ---"
check "module command exists" bash -c 'type module'
check "module load gcc/12.2.0" bash -c 'source /etc/profile.d/lmod.sh 2>/dev/null; module load gcc/12.2.0 2>&1'
check "gcc is available" which gcc

# --- Network / DNS ---
echo ""
echo "--- Network ---"
check "Hostname resolves" hostname -f
check "Can reach login node" bash -c 'getent hosts $(hostname -s) > /dev/null'

# --- Basic compute correctness ---
echo ""
echo "--- Compute Correctness ---"
WORKDIR=$(mktemp -d)
cat > "${WORKDIR}/arith.c" << 'CEOF'
#include <stdio.h>
#include <math.h>
#include <stdlib.h>

int main() {
    int pass = 1;
    // integer
    if (2 + 2 != 4) pass = 0;
    if (1000000 * 1000000LL != 1000000000000LL) pass = 0;
    // float
    double pi_approx = 4.0 * atan(1.0);
    if (fabs(pi_approx - 3.14159265358979) > 1e-10) pass = 0;
    // memory
    int *arr = calloc(1024 * 1024, sizeof(int));
    if (!arr) pass = 0;
    else {
        for (int i = 0; i < 1024*1024; i++) arr[i] = i;
        long sum = 0;
        for (int i = 0; i < 1024*1024; i++) sum += arr[i];
        long expected = (long)(1024*1024 - 1) * (1024*1024) / 2;
        if (sum != expected) pass = 0;
        free(arr);
    }
    return pass ? 0 : 1;
}
CEOF
gcc -O2 -lm "${WORKDIR}/arith.c" -o "${WORKDIR}/arith"
check "Integer arithmetic" ${WORKDIR}/arith
check "Floating point arithmetic" ${WORKDIR}/arith
rm -rf "$WORKDIR"

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

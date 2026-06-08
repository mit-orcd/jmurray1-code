#!/bin/bash
###############################################################################
# run-all.sh — Submit all HPC test jobs and print job IDs
#
# Usage:
#   ./run-all.sh              # Run all tests
#   ./run-all.sh cpu          # Run CPU-only tests (01-03, 07)
#   ./run-all.sh gpu          # Run GPU tests (05-06)
#   ./run-all.sh mpi          # Run MPI test (04)
#   ./run-all.sh 01 03 05     # Run specific tests by number
#
# Use --node=<nodename> to target a specific node (adds --nodelist constraint).
###############################################################################

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p output

NODE_CONSTRAINT=""
TESTS=()

for arg in "$@"; do
    case "$arg" in
        --node=*)
            NODE_CONSTRAINT="--nodelist=${arg#--node=}"
            ;;
        cpu)
            TESTS+=(01 02 03 07)
            ;;
        gpu)
            TESTS+=(05 06)
            ;;
        mpi)
            TESTS+=(04)
            ;;
        all)
            TESTS+=(01 02 03 04 05 06 07)
            ;;
        [0-9][0-9])
            TESTS+=("$arg")
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [cpu|gpu|mpi|all|NN...] [--node=<name>]"
            exit 1
            ;;
    esac
done

if [ ${#TESTS[@]} -eq 0 ]; then
    TESTS=(01 02 03 04 05 06 07)
fi

# Deduplicate and sort
TESTS=($(printf '%s\n' "${TESTS[@]}" | sort -u))

echo "============================================"
echo " HPC Test Suite — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

SUBMITTED=0
SKIPPED=0
JOBIDS=()

for num in "${TESTS[@]}"; do
    SCRIPT=$(ls ${num}-*.sbatch 2>/dev/null | head -1)
    if [ -z "$SCRIPT" ]; then
        echo "  [SKIP] No script found for test ${num}"
        ((SKIPPED++))
        continue
    fi

    EXTRA_ARGS=""
    if [ -n "$NODE_CONSTRAINT" ]; then
        EXTRA_ARGS="$NODE_CONSTRAINT"
    fi

    JOBID=$(sbatch $EXTRA_ARGS "$SCRIPT" 2>&1 | grep -oP '\d+$' || true)
    if [ -n "$JOBID" ]; then
        echo "  [SUBMITTED] ${SCRIPT} -> Job ${JOBID}"
        JOBIDS+=("$JOBID")
        ((SUBMITTED++))
    else
        echo "  [ERROR] Failed to submit ${SCRIPT}"
        ((SKIPPED++))
    fi
done

echo ""
echo "Submitted: ${SUBMITTED}, Skipped: ${SKIPPED}"
echo ""

if [ ${#JOBIDS[@]} -gt 0 ]; then
    echo "Job IDs: ${JOBIDS[*]}"
    echo ""
    echo "Monitor with:"
    echo "  squeue -u $USER"
    echo ""
    echo "Check results when complete:"
    echo "  ./check-results.sh"
    echo ""
    echo "Or watch a specific job:"
    echo "  tail -f output/*_<JOBID>.out"
fi

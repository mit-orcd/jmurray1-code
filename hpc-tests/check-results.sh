#!/bin/bash
###############################################################################
# check-results.sh — Parse and summarize HPC test results
#
# Usage:
#   ./check-results.sh             # Check latest results
#   ./check-results.sh <jobid>     # Check a specific job
#   ./check-results.sh --all       # Check all results in output/
###############################################################################

set -euo pipefail
cd "$(dirname "$0")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ ! -d output ]; then
    echo "No output directory found. Run tests first with ./run-all.sh"
    exit 1
fi

get_files() {
    if [ "${1:-}" = "--all" ]; then
        ls -1t output/*.out 2>/dev/null
    elif [ -n "${1:-}" ]; then
        ls -1t output/*_"${1}".out 2>/dev/null
    else
        # Latest result per test number
        for prefix in 01 02 03 04 05 06 07; do
            ls -1t output/${prefix}-*_*.out 2>/dev/null | head -1
        done
    fi
}

FILES=$(get_files "${1:-}")

if [ -z "$FILES" ]; then
    echo "No result files found."
    exit 1
fi

echo "============================================"
echo " HPC Test Results Summary"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

for f in $FILES; do
    if [ ! -f "$f" ]; then continue; fi

    BASENAME=$(basename "$f")
    TESTNAME=$(echo "$BASENAME" | sed 's/_[0-9]*\.out$//')
    JOBID=$(echo "$BASENAME" | grep -oP '\d+(?=\.out)')

    PASSES=$(grep -c '^\[PASS\]' "$f" 2>/dev/null || true)
    FAILS=$(grep -c '^\[FAIL\]' "$f" 2>/dev/null || true)
    TOTAL=$((PASSES + FAILS))

    ((TOTAL_PASS += PASSES))
    ((TOTAL_FAIL += FAILS))
    ((TOTAL_TESTS++))

    if [ "$FAILS" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
        STATUS="${GREEN}PASS${NC}"
    elif [ "$FAILS" -gt 0 ]; then
        STATUS="${RED}FAIL${NC}"
    else
        STATUS="${YELLOW}NO CHECKS${NC}"
    fi

    printf "  %-30s  Job %-10s  %s/%s checks  " "$TESTNAME" "$JOBID" "$PASSES" "$TOTAL"
    echo -e "$STATUS"

    # Print any FAIL lines
    if [ "$FAILS" -gt 0 ]; then
        grep '^\[FAIL\]' "$f" | sed 's/^/    /'
    fi

    # Print key metrics
    case "$TESTNAME" in
        02-memory-stream*)
            TRIAD=$(grep -P '^Triad' "$f" 2>/dev/null | awk '{print $2}' || true)
            if [ -n "$TRIAD" ]; then
                echo "    Triad bandwidth: ${TRIAD} GB/s"
            fi
            ;;
        03-openmp-scaling*)
            SPEEDUP=$(grep 'speedup' "$f" 2>/dev/null | grep -oP '[\d.]+x' | head -1 || true)
            if [ -n "$SPEEDUP" ]; then
                echo "    Max speedup: ${SPEEDUP}"
            fi
            ;;
        04-mpi-pingpong*)
            SUMMARY=$(grep 'Summary:' "$f" 2>/dev/null || true)
            if [ -n "$SUMMARY" ]; then
                echo "    $SUMMARY"
            fi
            ;;
        05-gpu-health*)
            GPU=$(grep '^Device:' "$f" 2>/dev/null | head -1 || true)
            if [ -n "$GPU" ]; then
                echo "    $GPU"
            fi
            ;;
        06-gpu-compute*)
            PEAK=$(grep 'Peak SGEMM' "$f" 2>/dev/null || true)
            if [ -n "$PEAK" ]; then
                echo "    $PEAK"
            fi
            ;;
    esac
done

echo ""
echo "============================================"
echo -e " Overall: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed across ${TOTAL_TESTS} test(s)"
if [ "$TOTAL_FAIL" -eq 0 ] && [ "$TOTAL_PASS" -gt 0 ]; then
    echo -e " ${GREEN}ALL PASS${NC}"
elif [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e " ${RED}FAILURES DETECTED${NC}"
fi
echo "============================================"

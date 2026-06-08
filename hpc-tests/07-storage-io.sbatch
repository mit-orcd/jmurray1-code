#!/bin/bash
#SBATCH --job-name=test-storage-io
#SBATCH --partition=mit_quicktest
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:15:00
#SBATCH --output=output/07-storage-io_%j.out

###############################################################################
# 07-storage-io: Filesystem I/O throughput test
#
# WHY: Shared filesystem performance is the single most common source of
# "the cluster is slow" tickets, and the hardest to diagnose after the fact.
# A job that does heavy I/O (writing checkpoints, reading training data,
# logging) can stall for minutes if the NFS/Lustre server is overloaded, a
# network path is degraded, or a storage node is rebuilding a RAID array.
# This test gives you concrete numbers to compare against:
#   - Your own baseline from the last time the filesystem was healthy
#   - Local /tmp (which bypasses the network and isolates node-local disks)
# The metadata test (1000 file create/stat/delete) is especially important:
# many Python and conda workflows do thousands of small file operations, and
# metadata-heavy workloads can be 100x slower than sequential I/O on the same
# filesystem. If users complain "conda is slow" or "import takes forever,"
# this test quantifies the problem.
#
# Measures sequential write and read throughput using dd, plus metadata
# operation rates, on home directory and local /tmp.
#
# Tests:
#   1. Sequential write (1 GB)
#   2. Sequential read (256 MB)
#   3. Small-file create/stat/delete (metadata ops, 1000 files)
###############################################################################

set -euo pipefail

echo "==============================================="
echo " HPC Test 07: Storage I/O Throughput"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $(hostname)"
echo " Job ID: ${SLURM_JOB_ID:-N/A}"
echo "==============================================="
echo ""

PASS=0
FAIL=0

run_io_test() {
    local label="$1"
    local testdir="$2"
    local testfile="${testdir}/.hpc_iotest_$$"

    echo "--- ${label} (${testdir}) ---"

    if [ ! -d "$testdir" ] || [ ! -w "$testdir" ]; then
        echo "  (directory not available, skipping)"
        echo ""
        return
    fi

    df -h "$testdir" 2>/dev/null | tail -1 | awk '{print "  Filesystem: "$1" Size: "$2" Avail: "$4}'

    # Sequential write (1 GB)
    echo ""
    echo "  Sequential write (1 GB):"
    sync
    WRITE_OUT=$( { dd if=/dev/zero of="$testfile" bs=1M count=1024 conv=fdatasync 2>&1; } )
    WRITE_SPEED=$(echo "$WRITE_OUT" | grep -oP '[\d.]+ [MG]B/s' | tail -1)
    WRITE_MB=$(echo "$WRITE_OUT" | grep -oP '([\d.]+) [MG]B/s' | tail -1 | awk '{print $1}')
    # Handle GB/s vs MB/s
    if echo "$WRITE_OUT" | grep -q 'GB/s'; then
        WRITE_MB=$(echo "$WRITE_MB" | awk '{printf "%.0f", $1 * 1024}')
    fi
    echo "    ${WRITE_SPEED:-unknown}"

    # Sequential read (drop caches not available as non-root, so read back)
    echo ""
    echo "  Sequential read (1 GB):"
    # Write a fresh file to avoid cache hits on the same file
    dd if=/dev/urandom of="${testfile}.src" bs=1M count=256 2>/dev/null
    sync
    READ_OUT=$( { dd if="${testfile}.src" of=/dev/null bs=1M 2>&1; } )
    READ_SPEED=$(echo "$READ_OUT" | grep -oP '[\d.]+ [MG]B/s' | tail -1)
    echo "    ${READ_SPEED:-unknown} (may include cache)"

    # Metadata ops: create/stat/delete 1000 small files
    echo ""
    echo "  Metadata ops (1000 files create+stat+delete):"
    local metadir="${testdir}/.hpc_metatest_$$"
    mkdir -p "$metadir"

    local t0=$(date +%s%N)
    for i in $(seq 1 1000); do
        echo "x" > "${metadir}/f${i}"
    done
    local t1=$(date +%s%N)
    local create_ms=$(( (t1 - t0) / 1000000 ))

    t0=$(date +%s%N)
    for i in $(seq 1 1000); do
        stat "${metadir}/f${i}" > /dev/null 2>&1
    done
    t1=$(date +%s%N)
    local stat_ms=$(( (t1 - t0) / 1000000 ))

    t0=$(date +%s%N)
    rm -rf "$metadir"
    t1=$(date +%s%N)
    local del_ms=$(( (t1 - t0) / 1000000 ))

    echo "    Create: ${create_ms} ms  Stat: ${stat_ms} ms  Delete: ${del_ms} ms"

    # Cleanup
    rm -f "$testfile" "${testfile}.src"

    echo ""
}

# Test home directory
run_io_test "Home directory" "$HOME"

# Test /tmp (local disk)
run_io_test "Local /tmp" "/tmp"

# Test scratch if available
for scratch in /pool001/${USER} /scratch/${USER}; do
    if [ -d "$scratch" ]; then
        run_io_test "Scratch" "$scratch"
        break
    fi
done

# Overall assessment
echo "==============================================="
echo " Summary"
echo "==============================================="
echo ""
echo " Compare the numbers above against your baselines."
echo " Typical healthy ranges:"
echo "   NFS/Lustre home: write 100-500 MB/s, read 200-1000 MB/s"
echo "   Local /tmp SSD:  write 500-3000 MB/s, read 1000-5000 MB/s"
echo "   Metadata (NFS):  create 200-2000 ms for 1000 files"
echo ""
echo "==============================================="
echo " Test complete"
echo "==============================================="

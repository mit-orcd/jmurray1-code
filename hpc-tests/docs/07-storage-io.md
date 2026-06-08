# Test 07: Storage I/O Throughput

**Script:** `07-storage-io.sbatch`
**Partition:** mit_quicktest
**Resources:** 1 node, 4 CPUs, 8 GB memory
**Run time:** ~5 minutes

## Why this test exists

Shared filesystem performance is the single most common source of "the cluster
is slow" tickets, and the hardest to diagnose after the fact. A job doing heavy
I/O — writing checkpoints, reading training data, logging — can stall for
minutes if the NFS/Lustre server is overloaded, a network path is degraded, or
a storage node is rebuilding a RAID array.

This test gives you concrete numbers to compare against:
- **Your own baseline** from the last time the filesystem was healthy
- **Local /tmp** — which bypasses the network and isolates node-local disk
  performance

The metadata test (1000 file create/stat/delete) is especially important. Many
Python and conda workflows do thousands of small file operations at startup,
and metadata-heavy workloads can be 100x slower than sequential I/O on the same
filesystem. If users complain "conda is slow" or "import takes forever," this
test quantifies the problem.

## What it does

The test runs three benchmarks on each available filesystem (home directory,
`/tmp`, and scratch if present):

### 1. Sequential Write (1 GB)
```bash
dd if=/dev/zero of=testfile bs=1M count=1024 conv=fdatasync
```
Writes 1 GB of zeros in 1 MB blocks with `fdatasync` — which forces the data
to be flushed to the storage server before `dd` reports completion. This gives
you the *actual* write throughput, not just the speed of filling OS buffers.

### 2. Sequential Read (256 MB)
```bash
dd if=testfile of=/dev/null bs=1M
```
Reads 256 MB of previously-written random data back. Note: because we can't
drop the page cache as a non-root user, this may partially read from OS cache
rather than hitting the filesystem. The number is still useful as an upper
bound, and on a busy cluster with memory pressure, the cache is typically cold.

### 3. Metadata Operations (1000 files)
Creates 1000 small files, stats each one, then deletes them all. Reports the
time in milliseconds for each phase:

- **Create** — measures how fast the filesystem can handle file creation (inode
  allocation, directory entry creation)
- **Stat** — measures metadata lookup speed (does the filesystem cache inodes?)
- **Delete** — measures file removal speed (inode deallocation, directory update)

## How to read the output

```
--- Home directory (/home/jmurray1) ---
  Filesystem: nfs-server:/export/home Size: 50T Avail: 23T

  Sequential write (1 GB):
    267 MB/s

  Sequential read (256 MB):
    1.2 GB/s (may include cache)

  Metadata ops (1000 files create+stat+delete):
    Create: 1823 ms  Stat: 342 ms  Delete: 1156 ms

--- Local /tmp ---
  Sequential write (1 GB):
    1.8 GB/s

  Sequential read (256 MB):
    4.2 GB/s (may include cache)

  Metadata ops (1000 files create+stat+delete):
    Create: 45 ms  Stat: 12 ms  Delete: 38 ms
```

**Key comparisons:**
- Home vs. /tmp write speed tells you the shared filesystem overhead. If home
  is 10x slower than /tmp, that's the network + storage server cost.
- Metadata create time on home tells you how painful conda/pip installs will be.
  Over 5000 ms for 1000 files means users will see multi-minute pauses during
  `import numpy`.

## Expected ranges

| Filesystem | Sequential write | Sequential read | Create 1000 files |
|-----------|-----------------|----------------|-------------------|
| NFS home | 100-500 MB/s | 200-1000 MB/s | 500-3000 ms |
| Lustre scratch | 500-5000 MB/s | 1000-10000 MB/s | 200-1000 ms |
| Local /tmp (SSD) | 500-3000 MB/s | 1000-5000 MB/s | 20-100 ms |
| Local /tmp (NVMe) | 1000-5000 MB/s | 2000-7000 MB/s | 10-50 ms |

These vary widely depending on hardware, network load, and how many other users
are hitting the filesystem simultaneously.

## This test doesn't have pass/fail checks

Unlike the other tests, the storage test reports numbers without automated
pass/fail thresholds. This is intentional — filesystem performance is too
variable and too dependent on concurrent load to set meaningful fixed
thresholds. Instead, the value of this test is in:

1. **Comparing against your own baselines** — run it when the filesystem is
   healthy and save the numbers
2. **Comparing home vs. /tmp** — /tmp isolates node-local performance and
   tells you whether the bottleneck is the network filesystem or the node
   itself
3. **Comparing across nodes** — if one node has 10x worse I/O than its
   neighbors, that node's network path to storage may be degraded

## Common issues and what the numbers reveal

| Symptom in the numbers | Likely cause |
|----------------------|-------------|
| Home write < 50 MB/s | NFS server overloaded or degraded storage path |
| Home write fine, but metadata > 5000 ms | NFS metadata server bottleneck (common with many small files) |
| /tmp write < 100 MB/s | Node-local disk failing or nearly full |
| Huge gap between home read and write | Read is coming from OS page cache; write shows actual filesystem speed |
| All numbers terrible on one node | Node's network link to storage may be down or degraded |

## Tips for users with I/O-heavy workloads

When users complain about slow I/O, run this test on their node, then advise:

- **Training data**: Copy to `/tmp` at job start, read from there during
  training (fast local SSD), copy results back to home at job end
- **Conda environments**: Install to `/tmp` or a local path, not home
  directory
- **Checkpointing**: Write checkpoints to scratch (parallel filesystem), not
  home (NFS)
- **Logging**: Write logs to `/tmp`, copy to home at job end

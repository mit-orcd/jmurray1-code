# Test 04: MPI Ping-Pong

**Script:** `04-mpi-pingpong.sbatch`
**Partition:** mit_normal
**Resources:** 2 nodes, 1 task per node, 4 CPUs each, 4 GB memory
**Run time:** ~5 minutes

## Why this test exists

Multi-node MPI jobs are the workloads most sensitive to network health. A
single bad cable, a misconfigured switch port, or a downed InfiniBand link can
degrade one node pair while everything else looks fine. Users see their 64-node
job run 10x slower than expected and blame the application.

Ping-pong is the most basic network fabric diagnostic. It isolates raw
point-to-point latency and bandwidth between exactly two nodes, independent of
any application behavior. It's the network equivalent of test 01's smoke test:
if this fails, nothing multi-node will work correctly.

Run this:
- After network maintenance or switch firmware updates
- When users report multi-node jobs are slow but single-node jobs are fine
- With `--node=<suspect_node>` to test a specific node pair
- Periodically to establish latency/bandwidth baselines per node generation

## What it does

The test compiles a small MPI C program and runs it across two nodes using
`srun`. The program performs a classic ping-pong: rank 0 sends a message to
rank 1, rank 1 sends it back. This round trip is timed.

The test runs at 8 message sizes, from 8 bytes to 4 MB:

| Size | What it measures |
|------|-----------------|
| 8 bytes | Raw latency — how long it takes to send a minimal message. Dominated by software stack overhead and fabric switching time. |
| 64 bytes | Still latency-dominated. |
| 512 bytes - 4 KB | Transition zone between latency-bound and bandwidth-bound. |
| 32 KB - 4 MB | Bandwidth-dominated. Large enough that transfer time dominates overhead. |

At each size, the test does 100 warmup iterations (to prime MPI buffers and
fabric paths) followed by 200-1000 timed iterations. It reports:

- **Latency** in microseconds — the one-way time for a message (half the round
  trip)
- **Bandwidth** in GB/s — how fast data actually moves

## How to read the output

```
Rank 0 on node1600
Rank 1 on node1601

Size (bytes)  Latency (us)      BW (GB/s)
------------  ------------      ---------
8                 1.85          0.004
64                1.92          0.032
512               2.15          0.228
4096              3.41          1.149
32768             7.82          4.012
262144           22.45         11.178
1048576          73.21         13.717
4194304         271.33         14.809

Summary: min latency = 1.85 us, max bandwidth = 14.809 GB/s
[PASS] Latency < 50 us and bandwidth > 1 GB/s
```

**Two numbers matter most:**

1. **Min latency (small messages):** Tells you about fabric overhead. On
   InfiniBand HDR (200 Gb/s), expect 1-3 us. On NDR (400 Gb/s), expect 1-2
   us. Ethernet will be 20-50 us.

2. **Max bandwidth (large messages):** Tells you about link capacity. HDR
   should deliver 20-24 GB/s. NDR should deliver 40-48 GB/s. If you're seeing
   half that, a link may be running at reduced width or speed.

## The pass/fail thresholds

The thresholds are deliberately loose:
- Latency < 50 us (catches Ethernet fallback or broken RDMA)
- Bandwidth > 1 GB/s (catches total fabric failure)

In practice, healthy InfiniBand should be well above these. The loose
thresholds avoid false failures on heterogeneous clusters where some nodes
might use different interconnects.

## Common failure scenarios

| Symptom | Likely cause |
|---------|-------------|
| Latency 20-50 us (expected 1-3) | Falling back to TCP/Ethernet instead of RDMA/InfiniBand |
| Bandwidth ~1 GB/s (expected 10-20) | InfiniBand link running at reduced width (4x instead of 4x HDR) |
| Bandwidth ~half of expected | One of two link lanes is down |
| Job fails to start | MPI can't communicate between nodes — check firewall, fabric manager |
| One node pair slow, others fine | Bad cable or port on that specific node — check `ibstat` on the node |
| Highly variable latency | Network congestion or competing traffic from other jobs |

## Targeting specific nodes

To test a specific suspect node pair:

```bash
sbatch --nodelist=node1600,node1601 04-mpi-pingpong.sbatch
```

Or via the runner:

```bash
./run-all.sh 04 --node=node1600
```

Note: `--node` in `run-all.sh` adds a `--nodelist` constraint, but for this
2-node test Slurm still picks the second node. To pin both nodes, submit
directly with `sbatch --nodelist=nodeA,nodeB`.

## Comparing against baselines

Run this across several node pairs of the same type to establish what "normal"
looks like:

```bash
for node in node1600 node1602 node1604; do
    sbatch --nodelist=${node},node1601 04-mpi-pingpong.sbatch
done
```

The latency and bandwidth numbers should be consistent (within ~10%) across
all pairs connected to the same switch. Large outliers indicate a problem on
the specific node or its link.

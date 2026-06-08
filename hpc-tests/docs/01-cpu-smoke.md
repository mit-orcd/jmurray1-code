# Test 01: CPU Smoke Test

**Script:** `01-cpu-smoke.sbatch`
**Partition:** mit_quicktest
**Resources:** 1 node, 4 CPUs, 8 GB memory
**Run time:** ~1 minute

## Why this test exists

This is the first test to run after any maintenance window, node reboot, or
Slurm configuration change. It answers the most fundamental question: "Can the
scheduler place a job on a node and does the node's basic environment work?"

Failures here indicate systemic problems — a broken module tree, a
misconfigured Slurm partition, an unmounted filesystem, or a DNS issue — that
will cause *every* user job to fail. Running this first saves you from chasing
application-level bugs that are really infrastructure problems.

## What it checks (16 checks)

### Resource Allocation (3 checks)
- `SLURM_JOB_ID` is set — confirms the job is actually running under Slurm
- `SLURM_NODELIST` is set — confirms a node was allocated
- `nproc >= requested CPUs` — confirms the node exposes at least as many CPUs
  as were requested

### Environment (2 checks)
- `$USER` is set — basic environment variable
- `$HOME` exists and is a directory — user's home is mounted

### Filesystem Access (4 checks)
- Write a temp file to `$HOME` — home directory is writable
- Read the temp file back — home directory is readable
- `/scratch` (or `/pool001`) is accessible — shared scratch filesystem is mounted
- `/tmp` is writable — node-local temp space works

### Module System (3 checks)
- `module` command exists — Lmod is loaded in the job environment
- `module load gcc/12.2.0` succeeds — module tree is intact and accessible
- `gcc` binary is found in `$PATH` — the loaded module actually works

### Network (2 checks)
- `hostname -f` resolves — DNS is functioning on the compute node
- `getent hosts $(hostname)` works — the node can resolve its own name

### Compute Correctness (2 checks)
- Compiles and runs a small C program that tests integer arithmetic, 64-bit
  multiplication, floating-point math (`pi = 4 * atan(1)`), and a 4 MB memory
  allocation with sum verification
- The same binary is run twice (one check labeled "Integer," one "Floating
  point") — in practice both pass or fail together, but having two check lines
  makes the output clearer

## How to read the output

```
[PASS] SLURM_JOB_ID is set
[PASS] SLURM_NODELIST is set
[PASS] nproc >= requested CPUs
...
 Results: 16/16 passed, 0 failed
 Status: ALL PASS
```

Every check prints `[PASS]` or `[FAIL]`. The summary at the bottom gives a
total count. The script exits with code 0 on all-pass and non-zero (equal to
the failure count) on any failure, so `sacct` will show `COMPLETED` vs `FAILED`
even without reading the output.

## Common failure scenarios

| Failure | Likely cause |
|---------|-------------|
| Job never starts | Partition misconfigured, node drained, scheduler down |
| `HOME is set and exists` fails | NFS mount problem — home directory not mounted on compute node |
| `Write to HOME` fails | Filesystem full or read-only mount |
| `/scratch is accessible` fails | Scratch filesystem not mounted on this node |
| `module command exists` fails | Lmod not sourced in job environment (check `/etc/profile.d/lmod.sh`) |
| `module load gcc` fails | Module tree path changed or missing after maintenance |
| `Hostname resolves` fails | DNS not working on compute node — check `/etc/resolv.conf` |
| `Integer arithmetic` fails | Severely broken toolchain or hardware fault (very rare) |

## Troubleshooting

If this test fails, it typically means something fundamental is broken on the
node. Before investigating further:

1. Check if the failure is node-specific: resubmit with
   `./run-all.sh 01 --node=<different_node>`
2. If it fails on all nodes, the problem is likely infrastructure-wide (NFS,
   module tree, Slurm config)
3. If it fails on one node, drain that node and investigate: `ssh <node>` and
   check mounts (`df -h`), DNS (`host google.com`), modules (`module avail`)

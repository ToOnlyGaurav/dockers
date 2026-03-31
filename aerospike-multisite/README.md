# Aerospike Multi-Site Strong Consistency Cluster

A Docker-based **7-node Aerospike Enterprise** cluster simulating a two-datacenter topology with **Strong Consistency (SC)**, **rack-aware RF=4 replication**, and a **quorum tie-breaker** node.

---

## Architecture

```
 ╔═══════════════════════════════════════════════════════════════════╗
 ║  DC1 — Active                                                     ║
 ║                                                                   ║
 ║   ┌─── Site 1 (Rack 1) ──────────────┐                           ║
 ║   │  site1-node1   172.28.0.11  A1   │  host: :3000/:3001/       ║
 ║   │  site1-node2   172.28.0.12  A2   │        :3100/:3101/       ║
 ║   │  site1-node3   172.28.0.13  A3   │        :3200/:3201/       ║
 ║   └──────────────────────────────────┘                           ║
 ║                                                                   ║
 ║   ┌─── Quorum (Rack 3) ──────────────┐                           ║
 ║   │  quorum-node   172.28.0.31  C1   │  host: :3600/:3601/       ║
 ║   │  (tie-breaker, 0 partitions)     │        :3602/:3603        ║
 ║   └──────────────────────────────────┘                           ║
 ╚═══════════════════════════════════════════════════════════════════╝
                          │
                          │  (mesh heartbeats: 172.28.0.0/24)
                          │
 ╔═══════════════════════════════════════════════════════════════════╗
 ║  DC2 — Standby                                                    ║
 ║                                                                   ║
 ║   ┌─── Site 2 (Rack 2) ──────────────┐                           ║
 ║   │  site2-node1   172.28.0.21  B1   │  host: :3300/:3301/       ║
 ║   │  site2-node2   172.28.0.22  B2   │        :3400/:3401/       ║
 ║   │  site2-node3   172.28.0.23  B3   │        :3500/:3501/       ║
 ║   └──────────────────────────────────┘                           ║
 ╚═══════════════════════════════════════════════════════════════════╝
```

### Node Reference

| DC | Site / Rack | Container | Node ID | IP | Host Ports (svc/fabric/hb/info) |
|---|---|---|---|---|---|
| DC1 | Site 1 (Rack 1) | `site1-node1` | A1 | 172.28.0.11 | 3000 / 3001 / 3002 / 3003 |
| DC1 | Site 1 (Rack 1) | `site1-node2` | A2 | 172.28.0.12 | 3100 / 3101 / 3102 / 3103 |
| DC1 | Site 1 (Rack 1) | `site1-node3` | A3 | 172.28.0.13 | 3200 / 3201 / 3202 / 3203 |
| DC1 | Quorum (Rack 3) | `quorum-node` | C1 | 172.28.0.31 | 3600 / 3601 / 3602 / 3603 |
| DC2 | Site 2 (Rack 2) | `site2-node1` | B1 | 172.28.0.21 | 3300 / 3301 / 3302 / 3303 |
| DC2 | Site 2 (Rack 2) | `site2-node2` | B2 | 172.28.0.22 | 3400 / 3401 / 3402 / 3403 |
| DC2 | Site 2 (Rack 2) | `site2-node3` | B3 | 172.28.0.23 | 3500 / 3501 / 3502 / 3503 |

---

## Design

### Quorum math

The quorum node (C1) lives in **DC1**, giving DC1 a permanent 4-node majority (3 Site1 + 1 Quorum = 4 of 7):

| Surviving nodes | Count | Meets min-cluster-size? | Result |
|---|---|---|---|
| DC1 alone (Site1 + Quorum) | 4 | Yes (4 ≥ 4) | **Operational** |
| DC2 alone (Site2) | 3 | No  (3 < 4) | **Halts — no split-brain** |
| DC1 + DC2 | 7 | Yes | **Fully operational** |

### Key parameters

| Parameter | Design intent | Current `aerospike.conf.template` |
|---|---|---|
| Cluster name | `multisite-sc` | `multisite-sc` |
| Namespace | `mynamespace` | `mynamespace` |
| Replication factor | 4 | 4 |
| `active-rack` | 1 (Site1 = primary) | **2** (Site2 = primary — user-modified) |
| `min-cluster-size` | 4 (split-brain prevention) | 4 |
| `strong-consistency` | true | true |
| `commit-to-device` | true | true |
| Heartbeat interval | 250 ms | 250 ms |
| Heartbeat timeout | 10 × 250 ms = 2.5 s | 2.5 s |
| `default-ttl` | 0 (never expire) | 0 |
| `max-record-size` | 1 MB | 1 MB |
| Storage | file-backed, 4 GB/node | 4 GB/node |
| Storage path | `/etc/aerospike/data/aerospike.dat` | same |

> **Note on active-rack and min-cluster-size:** The logical design uses `active-rack=1` (all masters on Site 1) and `min-cluster-size=4`. The config template currently has `active-rack=2` and `min-cluster-size=3` due to a previous Site-2-only recovery test (`R5`). To restore the designed configuration, run **O4** (switch active-rack to 1) after starting the cluster, or manually edit `configs/aerospike.conf.template` and restart.

### Replication layout with RF=4

With RF=4 across 2 data racks (Rack3/C1 is quiesced and holds 0 partitions):
- **Rack 1 (Site1)**: 2 copies per partition
- **Rack 2 (Site2)**: 2 copies per partition
- **Rack 3 (Quorum/C1)**: 0 copies (quiesced)

Effect: losing either entire site still leaves 2 copies on the surviving site.

### Quorum node auto-quiesce

C1 uses `AUTO_QUIESCE=true` in `docker-compose.yml`. The `entrypoint_multisite.sh` runs a **quiesce-keeper** background loop that:
1. Waits for `cluster_size >= 2`
2. Issues `manage quiesce with 172.28.0.31:3000` + `manage recluster`
3. Monitors every 30 s and re-applies quiesce if it is removed

This means C1 is automatically quiesced on **every** container start — no manual quiesce step is needed.

---

## Prerequisites

1. **Docker** and **Docker Compose** v2+
2. **Base image `myubuntu`** — `Dockerfile` builds `FROM myubuntu` (Ubuntu 24.04). Build or pull from the parent `dockers/` directory.
3. **Aerospike Enterprise binaries** — under `binaries/` (server 8.1.1.2, tools 12.1.1, Ubuntu 24.04, **aarch64**). Replace with amd64 binaries if needed.
4. **Enterprise trial license** — `configs/trial-features.conf` (8-node trial, expires **2026-05-25**).
5. **Platform** — defaults to `linux/arm64`. Override with `PLATFORM=linux/amd64` env var for x86 machines.
6. **Python `rich`** (optional) — for the terminal dashboard: `pip install rich`

---

## Quick Start

```bash
# Full start from scratch (build + up + roster + quiesce + verify)
./scripts/run.sh

# Skip docker build (images already built)
./scripts/run.sh --no-build

# Configure only (containers already running)
./scripts/run.sh --skip-up
```

`run.sh` does everything in sequence:
1. Stops any stale containers from previous topologies
2. `docker compose up -d [--build]`
3. Waits for all 7 containers to report `healthy`
4. Waits for `cluster_size=7`
5. Sets the SC roster (reads `observed_nodes`, strips the `M<n>|` prefix, calls `roster-set`)
6. Reclusters + revives any dead partitions
7. Waits for `cluster-stable:`
8. Verifies C1 is quiesced (auto-quiesced by the quiesce-keeper in the entrypoint)
9. Runs a write/read smoke test via `aql`

> **Why a roster is required:** In SC mode, Aerospike will not assign partition ownership (and thus reject all reads/writes with error -8) until the roster is explicitly committed via `roster-set`. The roster is persisted in SMD (System Metadata) and survives restarts.

---

## Stopping and Cleanup

```bash
# Stop containers, preserve data volumes
docker compose down

# Stop and delete all data (full wipe)
docker compose down -v

# Nuclear option: remove named volumes by prefix
docker volume ls | grep '^ms_' | awk '{print $2}' | xargs docker volume rm
```

Data volumes are named `ms_<node>_<type>` (e.g., `ms_site1_node1_data`). There are **21 volumes** total (7 nodes × 3 each: `data`, `smd`, `log`).

---

## Connecting to the Cluster

```bash
# aql from inside a container
docker exec -it site1-node1 aql -h 172.28.0.11 -p 3000

# asinfo from inside a container
docker exec site1-node1 asinfo -v "statistics" -h 172.28.0.11 -p 3000

# From the host (if Aerospike tools are installed locally)
aql -h 127.0.0.1 -p 3000
asadm -h 127.0.0.1 -p 3000
```

```sql
-- Basic CRUD
INSERT INTO mynamespace.test (PK, value) VALUES ('k1', 'hello')
SELECT * FROM mynamespace.test WHERE PK = 'k1'
DELETE FROM mynamespace.test WHERE PK = 'k1'
```

---

## Scripts Reference

### `scripts/run.sh` — Full cluster startup

```
./scripts/run.sh [--no-build] [--skip-up]
```

| Flag | Effect |
|---|---|
| *(none)* | Build images + start containers + configure cluster |
| `--no-build` | Skip `docker build`, use existing image |
| `--skip-up` | Skip `docker compose up`, run roster/quiesce/verify only |

---

### `scripts/set-roster.sh` — Standalone roster helper

A focused script that only handles the SC roster: reads `observed_nodes`, sets the roster, reclusters, and revives dead partitions. Used when the cluster is already running and only needs a roster re-sync (e.g., after a node rejoin).

---

### `scripts/validate-cluster.sh` — 7-step health check

Runs a structured health verification:
1. All 7 containers healthy
2. `cluster_size = 7`
3. Cluster stability (`cluster-stable:`)
4. Rack distribution (`rack-id` per node)
5. SC enabled + roster status
6. Write/read smoke test
7. `asadm` summary

---

### `scripts/cluster-visualizer.py` — Live terminal dashboard

```bash
pip install rich                              # one-time setup
python3 scripts/cluster-visualizer.py        # auto-refresh every 2 s
python3 scripts/cluster-visualizer.py --interval 5   # custom interval
python3 scripts/cluster-visualizer.py --once         # single snapshot
```

Shows:
- **Overall health**: `HEALTHY` / `DEGRADED` / `MIGRATING` / `STOP WRITES` / `SPLIT BRAIN` / `CLUSTER DOWN`
- **Per-node cards** grouped by DC (DC1 = Site1+Quorum, DC2 = Site2): status, uptime, objects, disk, migrations
- **Topology**: DC1 `[Site1(R1)[A1 A2 A3] + Quorum(R3)[C1]]` ↔ DC2 `[Site2(R2)[B1 B2 B3]]`
- **SC roster and partition status** in the header

---

### `scripts/simulate-failures.sh` — Interactive failure simulation

```bash
./scripts/simulate-failures.sh [--log <file>]
```

Interactive menu with **26 scenarios** across 7 categories. Each scenario confirms before executing, shows expected vs actual assertions, and guides recovery. An audit log is written to `/tmp/aerospike-sim-<timestamp>.log` (or `--log <file>`).

#### Node Failures

| Code | Description |
|---|---|
| **N1** | Single node failure — pick any node interactively |
| **N2** | Tie-breaker failure — stop C1 (quorum-node) |
| **N3** | Active-rack node failure — stop one Site1 master node |

#### Site / DC Failures

| Code | Description |
|---|---|
| **S1** | Site 1 failure — stop all A1-A3 (all masters lost if active-rack=1) |
| **S2** | Site 2 failure — stop all B1-B3 (replicas lost if active-rack=1) |
| **S3** | DC1 failure — stop Site1 + Quorum (A1-A3 + C1); only Site2 survives (3 nodes) |
| **S4** | DC2 failure — stop Site2 only (B1-B3); DC1 unaffected |

#### Network Partitions (iptables-based, nodes stay running)

| Code | Description |
|---|---|
| **P1** | Isolate Site1 — block Site1 from Site2+Quorum |
| **P2** | Isolate Site2 — block Site2 from Site1+Quorum |
| **P3** | Isolate Quorum node — block C1 from all data nodes |
| **P4** | Site1 vs Site2 — block Site1↔Site2; C1 sees both (tie-breaker test) |

#### Split Brain (destructive — data diverges permanently)

| Code | Description |
|---|---|
| **SB** | DC1 vs DC2 forced write divergence — partition + manual DC2 roster override + concurrent writes to same keys from both sides |

The SB scenario demonstrates why SC `roster` + `min-cluster-size` guards exist and what happens when an operator bypasses them. Recovery requires R4 with permanent data loss on the losing side.

#### Degraded Modes

| Code | Description |
|---|---|
| **D1** | Site1 degraded — stop 2 of 3 Site1 nodes (A1+A2), keep A3 |
| **D2** | Site2 degraded — stop 2 of 3 Site2 nodes, keep 1 |
| **D3** | Quorum + 1 data node — stop C1 + one Site1 node |
| **D4** | Cascading failure — stop C1 first, then an entire site |

#### Recovery

| Code | Description |
|---|---|
| **R1** | Recover all stopped nodes (start + revive + recluster + re-quiesce C1) |
| **R2** | Recover a specific stopped node (interactive pick) |
| **R3** | Heal all network partitions (flush iptables + revive + recluster) |
| **R4** | Full recovery — heal network + start all nodes + re-sync roster + revive + recluster + re-quiesce C1 |
| **R5** | Site2-only recovery — shrink roster to B1-B3 only (active-rack=2, mcs=2); use after permanent DC1 loss |

#### Operations

| Code | Description |
|---|---|
| **O1** | Roster update — re-sync roster to `observed_nodes` or remove a lost node permanently |
| **O2** | Quiesce toggle — quiesce or un-quiesce C1 (or any node) |
| **O3** | Rolling restart — restart nodes one-by-one with health check between each |
| **O4** | Switch active-rack — move all 4096 master partitions to a different rack/site |

| Code | Description |
|---|---|
| **ST** | Cluster status check (non-destructive) |

---

### `scripts/validate-scenarios.sh` — Automated scenario validation

```bash
./scripts/validate-scenarios.sh [--skip-start] [TEST_ID...]
```

Starts the cluster via `run.sh` (unless `--skip-start`), then runs up to **14 scenarios** end-to-end with automated assertions. Detects `active-rack` and `min-cluster-size` from the live cluster at startup so all assertions are config-aware.

| Flag | Effect |
|---|---|
| *(none)* | Run all 14 tests from scratch |
| `--skip-start` | Use existing running cluster |
| `TEST_ID...` | Run only specified tests (e.g., `S1 S2 P1`) |

**Test IDs:** `BASELINE  N1  N2  N3  S1  S2  S3  P1  P2  P3  D1  D3  D4  O2`

Each test:
1. Executes the failure scenario
2. Runs assertions (`PASS` / `FAIL` / `WARN`)
3. Runs full recovery (`R4`) to restore a clean 7-node cluster
4. Repeats for the next test

Final output: pass/fail count per test and overall result.

---

## Aerospike Commands Reference

All examples use `site1-node1` as the target. Substitute any running node. The `-t 5000` flag is a 5 000 ms timeout; omit for interactive use.

```
# Shorthand used throughout this section
NODE=site1-node1
IP=172.28.0.11
NS=mynamespace
```

---

### `asinfo` — Low-level info / control wire protocol

`asinfo` speaks directly to the Aerospike info port (3000). All commands are sent as `asinfo -v "<command>" -h <ip> -p 3000`.

#### Cluster health

```bash
# Is asd responding? Returns "ok"
docker exec $NODE asinfo -v "status" -h $IP -p 3000

# Full cluster statistics (cluster_size, cluster_key, cluster_integrity, …)
docker exec $NODE asinfo -v "statistics" -h $IP -p 3000

# Verify the cluster is stable (all nodes agree on partition map)
# Returns cluster-key on success; "unstable" or an ERROR string if not ready
docker exec $NODE asinfo -v "cluster-stable:" -h $IP -p 3000

# Node's own service metadata (node-id, address, build version, …)
docker exec $NODE asinfo -v "service" -h $IP -p 3000

# List all currently connected nodes from this node's perspective
docker exec $NODE asinfo -v "peers-read-all" -h $IP -p 3000

# Read current configuration for the service context
docker exec $NODE asinfo -v "get-config:context=service" -h $IP -p 3000

# Read current configuration for a namespace
docker exec $NODE asinfo -v "get-config:context=namespace;id=$NS" -h $IP -p 3000

# Aerospike build / version
docker exec $NODE asinfo -v "build" -h $IP -p 3000
```

Key statistics extracted from `statistics` output:

| Statistic | Meaning |
|---|---|
| `cluster_size` | Number of nodes currently in the cluster |
| `cluster_key` | All nodes must share the same key — divergence = split |
| `cluster_integrity` | `true` = all nodes agree on the cluster view |
| `principal` | Node ID of the current principal (accepts `recluster:`) |
| `migrate_tx_partitions_remaining` | Partitions still being sent out |
| `migrate_rx_partitions_remaining` | Partitions still being received |

```bash
# Extract a single statistic
docker exec $NODE asinfo -v "statistics" -h $IP -p 3000 \
  | tr ';' '\n' | grep '^cluster_size='

# Check if migrations are still in progress (both should be 0 when done)
docker exec $NODE asinfo -v "statistics" -h $IP -p 3000 \
  | tr ';' '\n' | grep 'migrate_.*_remaining'
```

#### Namespace health

```bash
# All namespace stats in one shot
docker exec $NODE asinfo -v "namespace/$NS" -h $IP -p 3000

# Pretty-print (one stat per line)
docker exec $NODE asinfo -v "namespace/$NS" -h $IP -p 3000 | tr ';' '\n'
```

Key namespace statistics:

| Statistic | Meaning |
|---|---|
| `effective_replication_factor` | Actual RF in effect (may differ from config if nodes are down) |
| `active-rack` | Rack whose nodes hold all master partitions |
| `master_objects` | Count of master partition objects on this node |
| `prole_objects` | Count of replica objects on this node |
| `unavailable_partitions` | Partitions with no available master (SC: writes blocked for these) |
| `dead_partitions` | Partitions with no copies anywhere (must `revive:`) |
| `stop_writes` | `true` = namespace has stopped accepting new writes |
| `effective_is_quiesced` | `true` = this node holds 0 partitions (pure tie-breaker) |
| `pending_quiesce` | `true` = quiesce is pending next recluster |
| `nodes_quiesced` | Count of quiesced nodes in the cluster |
| `migrate_tx_partitions_remaining` | Partitions being migrated out of this node |
| `migrate_rx_partitions_remaining` | Partitions being migrated into this node |

```bash
# Extract specific namespace stats
docker exec $NODE asinfo -v "namespace/$NS" -h $IP -p 3000 \
  | tr ';' '\n' | grep -E '^(stop_writes|unavailable|dead_partitions|effective_replication)'

# Check quiesce state on C1
docker exec quorum-node asinfo -v "namespace/$NS" -h 172.28.0.31 -p 3000 \
  | tr ';' '\n' | grep 'quiesce'

# Watch migration progress across all nodes (run in a loop)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  echo -n "$c: "
  docker exec "$c" asinfo -v "namespace/$NS" -h "$ip" -p 3000 2>/dev/null \
    | tr ';' '\n' | grep 'migrate_.*_remaining' | tr '\n' '  '
  echo
done
```

---

### SC Roster management

Strong Consistency mode will **reject all reads and writes** until the roster is set. The roster tells Aerospike which nodes are the authoritative members of the cluster.

#### Read roster state

```bash
# Full roster info: roster, pending_roster, observed_nodes, roster_rack
docker exec $NODE asinfo -v "roster:namespace=$NS" -h $IP -p 3000

# Pretty-print
docker exec $NODE asinfo -v "roster:namespace=$NS" -h $IP -p 3000 | tr ':' '\n'
```

Roster output fields:

| Field | Meaning |
|---|---|
| `roster` | The committed roster — nodes that Aerospike currently recognises as authoritative |
| `pending_roster` | The roster set via `roster-set` but not yet committed (applied after next `recluster:`) |
| `observed_nodes` | Nodes the cluster currently sees, with `M<rack>\|` active-rack prefix |
| `roster_rack` | Rack IDs of committed roster nodes |

**`observed_nodes` format:**
```
M2|A1@1,A2@1,A3@1,B1@2,B2@2,B3@2,C1@3
 ↑  └── NodeID@RackID (no prefix needed for roster-set)
 └── M<active_rack>| prefix — strip this before roster-set
```

#### Set / update roster

```bash
# Step 1: read observed_nodes
OBSERVED=$(docker exec $NODE asinfo -v "roster:namespace=$NS" -h $IP -p 3000 \
  | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)

# Step 2: strip the M<n>| prefix
NODES=$(echo "$OBSERVED" | sed 's/^M[0-9]*|//')

# Step 3: set the roster (returns "ok" on success)
docker exec $NODE asinfo \
  -v "roster-set:namespace=$NS;nodes=$NODES" \
  -h $IP -p 3000

# Step 4: recluster to commit (must reach the principal — loop all nodes)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  result=$(docker exec "$c" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
  if [ "$result" = "ok" ]; then echo "recluster accepted by $c"; break; fi
done
```

#### Set roster with explicit active-rack prefix

Include `M<rack>|` to encode which rack should hold all masters:
```bash
# Pin masters to Rack 1 (Site1)
docker exec $NODE asinfo \
  -v "roster-set:namespace=$NS;nodes=M1|A1@1,A2@1,A3@1,B1@2,B2@2,B3@2,C1@3" \
  -h $IP -p 3000

# Pin masters to Rack 2 (Site2) — after active-rack switch to Site2
docker exec $NODE asinfo \
  -v "roster-set:namespace=$NS;nodes=M2|A1@1,A2@1,A3@1,B1@2,B2@2,B3@2,C1@3" \
  -h $IP -p 3000
```

#### Shrink roster (permanent node removal / site failover)

```bash
# Site2-only roster (after permanent DC1 loss, active-rack=2)
docker exec site2-node1 asinfo \
  -v "roster-set:namespace=$NS;nodes=M2|B1@2,B2@2,B3@2" \
  -h 172.28.0.21 -p 3000
# Then recluster + revive (see below)
```

---

### Partition management

#### Recluster

`recluster:` must be sent to the **principal node** — any other node returns `ignored-by-non-principal`. The scripts loop all nodes until one returns `ok`.

```bash
# Try recluster on each node until the principal accepts
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  result=$(docker exec "$c" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
  echo "$c: $result"
  [ "$result" = "ok" ] && break
done

# Find the principal node first (then send directly)
docker exec $NODE asinfo -v "statistics" -h $IP -p 3000 \
  | tr ';' '\n' | grep '^principal='
```

#### Revive dead partitions

Required when the cluster restarts with stale data files from a previous run or after a catastrophic multi-node failure.

```bash
# Revive on all nodes (safe to call on every node; no-op if nothing to revive)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  echo -n "$c: "
  docker exec "$c" asinfo -v "revive:namespace=$NS" -h "$ip" -p 3000 2>/dev/null
done
# Follow with recluster (above)
```

---

### Runtime configuration changes

These take effect immediately without a restart. They reset to the config-file value on next container restart.

```bash
# Lower min-cluster-size (e.g., for Site2-only 3-node operation after DC1 loss)
docker exec $NODE asinfo \
  -v "set-config:context=service;min-cluster-size=2" \
  -h $IP -p 3000

# Restore min-cluster-size to normal
docker exec $NODE asinfo \
  -v "set-config:context=service;min-cluster-size=4" \
  -h $IP -p 3000

# Switch active-rack to Rack 2 (move masters to Site2)
docker exec $NODE asinfo \
  -v "set-config:context=namespace;id=$NS;active-rack=2" \
  -h $IP -p 3000

# Switch active-rack back to Rack 1 (move masters to Site1)
docker exec $NODE asinfo \
  -v "set-config:context=namespace;id=$NS;active-rack=1" \
  -h $IP -p 3000

# Verify the change took effect
docker exec $NODE asinfo \
  -v "get-config:context=service" -h $IP -p 3000 \
  | tr ';' '\n' | grep 'min-cluster-size'

docker exec $NODE asinfo \
  -v "namespace/$NS" -h $IP -p 3000 \
  | tr ';' '\n' | grep 'active-rack'
```

---

### Quiesce management (`asinfo` low-level)

These are the low-level `asinfo` equivalents of the `asadm manage quiesce` commands.

```bash
# Quiesce this node (prevents partition assignment on next recluster)
docker exec $NODE asinfo -v "quiesce:" -h $IP -p 3000
# Then recluster so the quiesce takes effect
# (see recluster section above)

# Un-quiesce this node (re-enables partition assignment)
docker exec $NODE asinfo -v "quiesce-undo:" -h $IP -p 3000
# Then recluster

# Check quiesce state
docker exec $NODE asinfo -v "namespace/$NS" -h $IP -p 3000 \
  | tr ';' '\n' | grep -E '(effective_is_quiesced|pending_quiesce|nodes_quiesced)'
```

---

### `asadm` — Management console

`asadm` is a higher-level management client. It connects to the cluster and routes commands automatically. Always use `--enable` to enter privileged/management mode.

```bash
# Interactive console (connects to the full cluster via seed node)
docker exec -it $NODE asadm -h $IP -p 3000
# Inside the console, type 'enable' then issue management commands

# One-shot non-interactive form used in scripts
docker exec $NODE asadm --enable -e "<command>" -h $IP -p 3000
```

#### Quiesce / un-quiesce

```bash
# Quiesce C1 (tie-breaker) — prevents partition assignment
docker exec quorum-node asadm --enable \
  -e "manage quiesce with 172.28.0.31:3000" \
  -h 172.28.0.31 -p 3000

# Un-quiesce C1 — re-enables partition assignment on C1
docker exec quorum-node asadm --enable \
  -e "manage quiesce with 172.28.0.31:3000 undo" \
  -h 172.28.0.31 -p 3000

# Alternative syntax (older Aerospike versions)
docker exec quorum-node asadm --enable \
  -e "manage undo quiesce with 172.28.0.31:3000" \
  -h 172.28.0.31 -p 3000

# Quiesce any data node (e.g., to drain it before maintenance)
docker exec site1-node1 asadm --enable \
  -e "manage quiesce with 172.28.0.11:3000" \
  -h 172.28.0.11 -p 3000
```

After any quiesce/un-quiesce, **always recluster** for the change to take effect:
```bash
# Recluster via asadm (sends to the cluster's principal automatically)
docker exec $NODE asadm --enable -e "manage recluster" -h $IP -p 3000
```

#### Cluster summary and info

```bash
# Full cluster summary (nodes, builds, migrations, master/replica counts)
docker exec $NODE asadm -h $IP -p 3000 -e "summary"

# Show all nodes and their status
docker exec $NODE asadm -h $IP -p 3000 -e "info network"

# Show namespace info across all nodes
docker exec $NODE asadm -h $IP -p 3000 -e "info namespace"

# Show per-node configuration
docker exec $NODE asadm -h $IP -p 3000 -e "info config"

# Show partition distribution
docker exec $NODE asadm -h $IP -p 3000 -e "show statistics namespace"

# Show roster
docker exec $NODE asadm -h $IP -p 3000 -e "show roster"
```

#### Rolling restart via asadm

```bash
# Restart a single node safely
docker exec $NODE asadm --enable \
  -e "manage recluster" -h $IP -p 3000
```

---

### `aql` — SQL-like query client

```bash
# Interactive AQL shell
docker exec -it $NODE aql -h $IP -p 3000

# One-shot query
docker exec $NODE aql -h $IP -p 3000 -c "<query>"
```

#### CRUD

```bash
# INSERT (PK is the primary key, remaining fields are bins)
docker exec $NODE aql -h $IP -p 3000 \
  -c "INSERT INTO $NS.test (PK, name, value) VALUES ('key1', 'alice', 42)"

# SELECT by primary key
docker exec $NODE aql -h $IP -p 3000 \
  -c "SELECT * FROM $NS.test WHERE PK = 'key1'"

# SELECT all records in a set (full scan — use carefully on large data)
docker exec $NODE aql -h $IP -p 3000 \
  -c "SELECT * FROM $NS.test"

# UPDATE (INSERT is idempotent — re-insert to update bins)
docker exec $NODE aql -h $IP -p 3000 \
  -c "INSERT INTO $NS.test (PK, value) VALUES ('key1', 99)"

# DELETE by primary key
docker exec $NODE aql -h $IP -p 3000 \
  -c "DELETE FROM $NS.test WHERE PK = 'key1'"
```

#### TTL

```bash
# Insert with TTL of 3600 seconds (1 hour)
docker exec $NODE aql -h $IP -p 3000 \
  -c "INSERT INTO $NS.test (PK, v) VALUES ('temp', 'data') WITH TTL 3600"

# Insert with TTL = 0 (never expire, uses namespace default-ttl=0)
docker exec $NODE aql -h $IP -p 3000 \
  -c "INSERT INTO $NS.test (PK, v) VALUES ('perm', 'data') WITH TTL 0"

# Insert with TTL = -1 (use namespace default-ttl)
docker exec $NODE aql -h $IP -p 3000 \
  -c "INSERT INTO $NS.test (PK, v) VALUES ('k', 'v') WITH TTL -1"
```

#### Cross-DC read verification (split-brain check)

```bash
# Write a record from DC1 (site1-node1) and verify DC2 replicates it
docker exec site1-node1 aql -h 172.28.0.11 -p 3000 \
  -c "INSERT INTO $NS.test (PK, dc) VALUES ('xdc_test', 'dc1')"

# Read from DC2 — should return dc='dc1' if replication is healthy
docker exec site2-node1 aql -h 172.28.0.21 -p 3000 \
  -c "SELECT * FROM $NS.test WHERE PK = 'xdc_test'"

# Write from DC2 (only valid if DC2 is active-rack or cluster is in DC2-only mode)
docker exec site2-node1 aql -h 172.28.0.21 -p 3000 \
  -c "INSERT INTO $NS.test (PK, dc) VALUES ('xdc_test2', 'dc2')"
```

#### Secondary indexes

```bash
# Create a secondary index on a bin
docker exec $NODE aql -h $IP -p 3000 \
  -c "CREATE INDEX idx_name ON $NS.test (name) STRING"

# Query using secondary index
docker exec $NODE aql -h $IP -p 3000 \
  -c "SELECT * FROM $NS.test WHERE name = 'alice'"

# Drop the index
docker exec $NODE aql -h $IP -p 3000 \
  -c "DROP INDEX $NS idx_name"
```

#### Truncate / namespace operations

```bash
# Truncate a set (delete all records in the set, non-blocking)
docker exec $NODE aql -h $IP -p 3000 \
  -c "TRUNCATE $NS.test"

# Show all sets and record counts
docker exec $NODE aql -h $IP -p 3000 \
  -c "SHOW SETS"

# Show all secondary indexes
docker exec $NODE aql -h $IP -p 3000 \
  -c "SHOW INDEXES"
```

---

### Composite operational recipes

#### Full post-restart recovery

```bash
NS=mynamespace

# 1. Wait for all 7 nodes to be in the cluster
until [ "$(docker exec site1-node1 asinfo -v statistics -h 172.28.0.11 -p 3000 2>/dev/null \
           | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2)" = "7" ]; do
  echo "Waiting for cluster_size=7..."; sleep 3
done

# 2. Revive dead partitions on all nodes
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  docker exec "$c" asinfo -v "revive:namespace=$NS" -h "$ip" -p 3000 2>/dev/null
done

# 3. Re-set the SC roster from observed_nodes
SEED=site1-node1; SEED_IP=172.28.0.11
OBSERVED=$(docker exec $SEED asinfo -v "roster:namespace=$NS" -h $SEED_IP -p 3000 \
  | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
NODES=$(echo "$OBSERVED" | sed 's/^M[0-9]*|//')
docker exec $SEED asinfo -v "roster-set:namespace=$NS;nodes=$NODES" -h $SEED_IP -p 3000

# 4. Recluster (try all nodes until principal accepts)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  result=$(docker exec "$c" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
  [ "$result" = "ok" ] && echo "recluster: $c" && break
done

# 5. Wait for cluster-stable
until docker exec $SEED asinfo -v "cluster-stable:" -h $SEED_IP -p 3000 2>/dev/null \
      | grep -qv 'unstable\|ERROR'; do
  echo "Waiting for cluster-stable..."; sleep 3
done

# 6. Re-quiesce C1 (quiesce is not persistent across restarts without AUTO_QUIESCE)
docker exec quorum-node asadm --enable \
  -e "manage quiesce with 172.28.0.31:3000" -h 172.28.0.31 -p 3000
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  result=$(docker exec "$c" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
  [ "$result" = "ok" ] && break
done
echo "Recovery complete."
```

> **Shortcut:** `./scripts/run.sh --skip-up` does all of the above automatically.

#### Switch active-rack from Site1 to Site2

```bash
NS=mynamespace
NEW_RACK=2

# 1. Set active-rack=2 on all nodes
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  docker exec "$c" asinfo \
    -v "set-config:context=namespace;id=$NS;active-rack=$NEW_RACK" \
    -h "$ip" -p 3000 2>/dev/null
done

# 2. Read observed_nodes (will now have M2| prefix after recluster)
SEED=site1-node1; SEED_IP=172.28.0.11
docker exec $SEED asinfo -v "recluster:" -h $SEED_IP -p 3000 2>/dev/null || true
sleep 5
OBSERVED=$(docker exec $SEED asinfo -v "roster:namespace=$NS" -h $SEED_IP -p 3000 \
  | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)

# 3. Re-set roster with new M2| prefix
NODES=$(echo "$OBSERVED" | sed 's/^M[0-9]*|//')
docker exec $SEED asinfo \
  -v "roster-set:namespace=$NS;nodes=M${NEW_RACK}|${NODES}" \
  -h $SEED_IP -p 3000

# 4. Final recluster
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  result=$(docker exec "$c" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
  [ "$result" = "ok" ] && echo "recluster: $c" && break
done
# Masters migrate to Site2 (Rack 2). Also update aerospike.conf.template.
```

> **Shortcut:** Use **O4** in `simulate-failures.sh`.

#### Verify replication factor and data distribution

```bash
# Check effective RF on all nodes
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  rf=$(docker exec "$c" asinfo -v "namespace/$NS" -h "$ip" -p 3000 2>/dev/null \
       | tr ';' '\n' | grep '^effective_replication_factor=' | cut -d'=' -f2)
  echo "$c: effective_RF=$rf"
done

# Count master objects per node (should all be on active-rack)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
  masters=$(docker exec "$c" asinfo -v "namespace/$NS" -h "$ip" -p 3000 2>/dev/null \
            | tr ';' '\n' | grep '^master_objects=' | cut -d'=' -f2)
  rack=$(docker exec "$c" asinfo -v "namespace/$NS" -h "$ip" -p 3000 2>/dev/null \
         | tr ';' '\n' | grep '^rack-id=' | cut -d'=' -f2)
  echo "$c (rack=$rack): master_objects=${masters:-0}"
done
```

---

### SC Roster — Key Concepts

| Operation | Command | Notes |
|---|---|---|
| Read current roster | `asinfo -v "roster:namespace=mynamespace"` | Shows `roster`, `pending_roster`, `observed_nodes` |
| Set roster | `asinfo -v "roster-set:namespace=mynamespace;nodes=<list>"` | `nodes` must match `observed_nodes` with `M<n>\|` prefix stripped |
| Recluster | `asinfo -v "recluster:"` | Must be sent to the **principal node** (scripts loop all nodes until one accepts) |
| Revive dead partitions | `asinfo -v "revive:namespace=mynamespace"` | Required after a restart with stale data — send on all nodes |
| Check cluster stable | `asinfo -v "cluster-stable:"` | Returns cluster key on success; error string if unstable |
| Check quiesce | `asinfo -v "namespace/mynamespace" \| tr ';' '\n' \| grep quiesce` | `effective_is_quiesced=true` means 0 partitions |
| Quiesce node (asadm) | `asadm --enable -e "manage quiesce with <ip>:3000"` | Requires recluster to take effect |
| Un-quiesce node (asadm) | `asadm --enable -e "manage quiesce with <ip>:3000 undo"` | Requires recluster to take effect |
| Quiesce node (asinfo) | `asinfo -v "quiesce:"` | Low-level; requires recluster |
| Un-quiesce node (asinfo) | `asinfo -v "quiesce-undo:"` | Low-level; requires recluster |

**`observed_nodes` format:** `M<active_rack>|<NodeID>@<RackID>,...`
Strip the `M<n>|` prefix before passing to `roster-set`. The scripts do this automatically.

---

## Internal Wiring

### How config gets into containers

`configs/aerospike.conf.template` contains `${NODE_ID}`, `${RACK_ID}`, `${SERVICE_ADDRESS}`, and `${MESH_SEED_LIST}` placeholders. At container start, `entrypoint_multisite.sh`:
1. Validates `NODE_ID`, `RACK_ID`, `SERVICE_ADDRESS` env vars (set in `docker-compose.yml`)
2. Expands `MESH_SEEDS` (comma-separated `ip:port` list) into `mesh-seed-address-port` lines
3. Runs `envsubst` to produce `/etc/aerospike/config/aerospike.conf`
4. Execs `asd` (or runs it with the quiesce-keeper for `AUTO_QUIESCE=true` nodes)

### Mesh seed list (all 7 IPs)

All nodes seed to all others:
```
172.28.0.11:3002  172.28.0.12:3002  172.28.0.13:3002
172.28.0.21:3002  172.28.0.22:3002  172.28.0.23:3002
172.28.0.31:3002
```
Seeding to self is harmless — Aerospike ignores it.

### Network partition simulation

`simulate-failures.sh` uses `iptables` (`-A INPUT -s <ip> -j DROP` + `-A OUTPUT -d <ip> -j DROP`) inside each container. Containers have `cap_add: [NET_ADMIN]` for this reason. Heal with `iptables -F` on affected containers (R3/R4 do this automatically).

### Named volumes

21 Docker volumes (named `ms_<node>_<type>`):

```
ms_site1_node1_data    ms_site1_node2_data    ms_site1_node3_data
ms_site1_node1_smd     ms_site1_node2_smd     ms_site1_node3_smd
ms_site1_node1_log     ms_site1_node2_log     ms_site1_node3_log
ms_site2_node1_data    ms_site2_node2_data    ms_site2_node3_data
ms_site2_node1_smd     ms_site2_node2_smd     ms_site2_node3_smd
ms_site2_node1_log     ms_site2_node2_log     ms_site2_node3_log
ms_quorum_node_data    ms_quorum_node_smd     ms_quorum_node_log
```

`smd` volumes hold SC roster state. If a cluster starts with stale SMD from a prior run with a different topology, dead partitions will appear — the roster needs to be re-set and `revive:` issued.

---

## Failure Scenarios Analysis

> **Baseline:** `active-rack=1` — Site 1 holds all 4096 master partitions (~1365 per node).
> With `active-rack=2` the Site 1 / Site 2 roles reverse.
> **SC read policy:** In `strong-consistency=true` mode, reads go to master by default — read availability equals write availability per partition. A relaxed client read policy (non-master replica) can survive master loss but sacrifices linearizability.

### Legend

| Symbol | Meaning |
|---|---|
| ✅ Full | All 4096 partitions available |
| ⚠️ ~67% | ~2731 / 4096 partitions available (2 of 3 Site1 nodes up) |
| ⚠️ ~33% | ~1365 / 4096 partitions available (1 of 3 Site1 nodes up) |
| ❌ None | All operations halted (cluster below MCS or all masters lost) |
| ⏳ Brief | Short interruption during operation (typically < 10 s) |
| ⚠️ RF↓ | Accessible but replication factor reduced — durability at risk |
| ⚠️ Diverged | Both sides writable but writing different values to the same keys |

---

### Node Failures

N1 and N2 have identical data availability — the difference is loss of the tie-breaker in N2.

| ID | Node Lost | Reads | Writes | Unavail Partitions | Auto-Recover | Notes |
|---|---|---|---|---|---|---|
| **N1** | 1 Site2 replica node (B1, B2, or B3) | ✅ Full | ✅ Full | 0 | Yes | Masters on Site1 untouched. ⚠️ RF↓ until node returns. Cluster 6/7 ≥ 4. |
| **N2** | Quorum node C1 | ✅ Full | ✅ Full | 0 | Yes | C1 holds 0 data partitions. Cluster 6/7 ≥ 4. **Tie-breaker lost** — next site failure leaves only 3 data nodes, which falls below MCS=4. |
| **N3** | 1 Site1 master node (A1, A2, or A3) | ⚠️ ~67% | ⚠️ ~67% | ~1365 | **No** | SC never auto-promotes replicas. ~1365 partitions masterless. Cluster 6/7 ≥ 4 but affected keys are unavailable. Restart the node to recover (R1/R2). |

---

### Site / DC Failures

S2 and S4 are equivalent — DC2 contains only Site2.

| ID | What Fails | Nodes Lost | Remaining | Reads | Writes | Unavail Partitions | Auto-Recover | Notes |
|---|---|---|---|---|---|---|---|---|
| **S1** | Site 1 (all masters) | A1+A2+A3 | B1-B3 + C1 = 4 | ❌ None | ❌ None | 4096 | **No** | All 4096 masters gone. Cluster 4 ≥ 4 so MCS met, but every partition is masterless. Restore Site1 (R1/R4) **or** promote Site2 via switch active-rack (O4). |
| **S2 / S4** | Site 2 / DC2 | B1+B2+B3 | A1-A3 + C1 = 4 | ✅ Full | ✅ Full | 0 | Yes | Masters on Site1 intact. ⚠️ RF↓ — only 1 copy per partition (Site1) until Site2 returns. Cluster 4/7 at MCS edge. |
| **S3** | DC1 (Site1 + Quorum) | A1-A3 + C1 | B1-B3 = 3 | ❌ None | ❌ None | 4096 | **No** | 3 < MCS=4: cluster halts completely. All masters + tie-breaker gone. **Catastrophic.** Must restore ≥1 DC1 node before any recovery is possible (R1/R4). |

---

### Network Partitions

Each network partition creates two independent sides. Availability is listed per side — clients connecting to different sides see different behavior.

| ID | Network Split | DC1 Side (Site1+C1) | | DC2 Side (Site2) | | Key Insight |
|---|---|---|---|---|---|---|
| | | **Reads** | **Writes** | **Reads** | **Writes** | |
| **P1** | Site1 isolated from Site2+C1 | ❌ None | ❌ None | ❌ None | ❌ None | **Both sides dead.** Site1 (3) < MCS=4 halts. Site2+C1 (4) has quorum but all masters are stranded on Site1 — SC never promotes replicas. |
| **P2** | Site2 isolated from Site1+C1 | ✅ Full | ✅ Full | ❌ None | ❌ None | **Designed failover.** DC1 fully operational (4 nodes + all masters). DC2 halts (3 < MCS=4). |
| **P3** | C1 isolated from all data nodes | ✅ Full | ✅ Full | ✅ Full | ✅ Full | 6 data nodes remain on the data plane ≥ MCS=4. C1 alone halts but holds no data. **Tie-breaker gone** — next partition has no decisive vote. |
| **P4** | Site1 ↔ Site2 severed (C1 sees both) | ✅ Full | ✅ Full | ❌ None | ❌ None | C1 is co-located in DC1: Site1+C1 = 4 wins. Site2 (3) halts. Same outcome as P2 in practice. |
| **SB** | DC1 ↔ DC2 (forced) | ⚠️ Diverged | ⚠️ Diverged | ⚠️ Diverged | ⚠️ Diverged | **Catastrophic.** SC guards manually bypassed on DC2. Both sides accept writes to the same keys; data permanently diverges. On heal, one side's writes are irrecoverably lost. **Educational only — never run on production data.** |

> **P1 vs P2 asymmetry:** With `active-rack=1` all masters live on Site1. In P2 (Site2 isolated) Site1+C1 keeps the masters → DC1 stays operational. In P1 (Site1 isolated) Site1 has the masters but only 3 nodes — below MCS=4 — so it halts, and Site2+C1 cannot promote without a roster change.

Recovery for all partitions: R3 (heal network) or R4 (full recovery). Re-quiesce C1 after P3.

---

### Degraded Modes (Multi-Failure)

| ID | Failure Combination | Nodes Lost | Remaining | Reads | Writes | Unavail Partitions | Auto-Recover | Notes |
|---|---|---|---|---|---|---|---|---|
| **D1** | 2 of 3 Site1 nodes | A1+A2 (any 2) | A3 + B1-B3 + C1 = 5 | ⚠️ ~33% | ⚠️ ~33% | ~2731 | **No** | Only 1 Site1 node survives. ~2731 masters lost. Cluster 5 ≥ 4 so still up, severely degraded. SC will not auto-promote. |
| **D2** | 2 of 3 Site2 nodes | B1+B2 (any 2) | A1-A3 + B3 + C1 = 5 | ✅ Full | ✅ Full | 0 | Yes | Masters on Site1 unaffected. ⚠️ RF↓ — replica coverage reduced. Cluster 5 ≥ 4. |
| **D3** | Quorum + 1 data node | C1 + 1 node | 5 nodes | Depends | Depends | ~1365 (Site1 node) or 0 (Site2 node) | **No** | Tie-breaker lost. If the data node is a Site1 node: partial degradation (~1365 unavailable). If Site2: no data impact but cluster is one site-failure away from halting (5 − 3 = 2 < MCS=4). |
| **D4** | Quorum + full site | C1 + A1-A3 or B1-B3 | 3 nodes | ❌ None | ❌ None | 4096 (if Site1) | **No** | 3 < MCS=4: cluster halts. Cascading failure — removing C1 first eliminates the safety margin, then losing a full site crosses the threshold. **Catastrophic.** |

---

### Recovery Actions

| ID | Action | Read Impact | Write Impact | Details |
|---|---|---|---|---|
| **R1** | Recover all | ⏳ → ✅ Full | ⏳ → ✅ Full | Starts all stopped nodes, flushes iptables, revives dead partitions, reclusters, re-quiesces C1. Waits for cluster_size=7. |
| **R2** | Recover one node | ⏳ → partial restore | ⏳ → partial restore | Restarts one selected node. Revives its partitions. Re-quiesces C1 if C1 was the target. |
| **R3** | Heal network only | ⏳ Brief | ⏳ Brief | Flushes all iptables DROP rules. Nodes rejoin, partitions revived, recluster triggered. No node restarts. |
| **R4** | Full recovery + roster re-sync | ⏳ → ✅ Full | ⏳ → ✅ Full | Most thorough: heal network + restart nodes + roster re-sync + revive + recluster + re-quiesce + verify. Use after any SC roster corruption or master loss. |
| **R5** | Promote Site2 only | ✅ Full (Site2 as master) | ✅ Full (Site2 as master) | **Destructive / irreversible.** Permanently drops Site1 and C1 from roster. Shrinks to 3-node cluster (B1-B3), sets active-rack=2, mcs=2. Use only after confirmed permanent Site1 loss. |

---

### Operational Changes

| ID | Operation | Read Impact | Write Impact | Duration | Notes |
|---|---|---|---|---|---|
| **O1** | Roster update / re-sync | ⏳ Brief (~5 s) | ⏳ Brief (~5 s) | ~5 s | Required after any node removal or addition. Triggers recluster. |
| **O2** | Quiesce / un-quiesce C1 | ✅ None | ✅ None | Instant | C1 holds 0 data partitions — no data impact. Not persistent: must re-apply after restart. |
| **O3** | Rolling restart (per node) | ⏳ ~1365 partitions brief / Site1 node | ⏳ Same | ~25 s / node | Site2 node restarts have zero data impact. Site1 restarts cause brief master unavailability per node. |
| **O4** | Switch active-rack | ⏳ Migration | ⏳ Migration | Minutes | Moves all 4096 master partitions to the target rack. Per-partition brief pause during migration. Updates config template for persistence. |

---

### Quick-Reference Summary

| Scenario | Reads | Writes | Severity | Auto-Recover | Script |
|---|---|---|---|---|---|
| Site2 / DC2 failure (S2, S4, D2) | ✅ Full | ✅ Full | Low | Yes | R1 / R4 |
| Quorum node C1 failure (N2) | ✅ Full | ✅ Full | Low (fragile) | Yes | R1 / R2 + re-quiesce |
| Single Site2 replica node (N1) | ✅ Full | ✅ Full | Low | Yes | R1 / R2 |
| Quorum isolated (P3) | ✅ Full | ✅ Full | Medium (fragile) | Yes | R3 + re-quiesce |
| Site2 isolated — designed (P2, P4) | ✅ DC1 | ✅ DC1 | Low | Yes | R3 / R4 |
| 1 Site1 master node (N3) | ⚠️ ~67% | ⚠️ ~67% | Medium | **No** | R1 / R2 |
| Quorum + Site2 node (D3 — Site2) | ✅ Full | ✅ Full | Medium (fragile) | **No** | R1 / R4 |
| Quorum + Site1 node (D3 — Site1) | ⚠️ ~67% | ⚠️ ~67% | High | **No** | R1 / R4 |
| 2 Site1 master nodes (D1) | ⚠️ ~33% | ⚠️ ~33% | High | **No** | R1 / R4 |
| Site1 isolated — both sides dead (P1) | ❌ None | ❌ None | High | **No** | R3 / R4 |
| All masters lost — Site1 down (S1) | ❌ None | ❌ None | Critical | **No** | R1/R4 or O4 |
| DC1 failure — Site1+Quorum (S3, D4) | ❌ None | ❌ None | Catastrophic | **No** | Restore ≥1 DC1 node first |
| **Split-brain (SB)** | ⚠️ Diverged | ⚠️ Diverged | Catastrophic | **No** | R4 + inevitable data loss |

---

### Observed Behavior (Tested Scenarios)

The following scenarios have been exercised against this cluster and document actual observed behavior — not just theoretical expectations.

> **Cluster baseline for these observations:** `active-rack=2` (Site 2 holds master partitions), `min-cluster-size=3`, `replication-factor=4`.

#### Happy Path — Cluster Remains Fully Available

**Scenario H1 — Non-active rack (Site 1) degrades**
- **What happened:** Site 1 nodes (rack 1, replica holders) were stopped.
- **Observed:** Traffic continued without interruption. Site 2 already held all master partitions (`active-rack=2`). Read and write availability: 100%.
- **Why it works:** In SC mode, masters are on Site 2. Site 1 holds only replicas. Losing replicas does not affect master availability — the cluster stays above `min-cluster-size` with Site 2 + quorum-node.
- **Trade-off:** RF dropped from 4 to 2 (only Site 2 copies remain). Durability is reduced until Site 1 returns.

**Scenario H2 — Active rack (Site 2) degrades; tie-breaker present**
- **What happened:** Site 2 nodes (rack 2, master holders) were stopped. Quorum node (C1) remained running.
- **Observed:** After recluster, traffic started flowing to Site 1. Reads and writes served from Site 1 at full availability.
- **Why it works:** The tie-breaker (C1) gave Site 1 + C1 = 4 nodes, meeting `min-cluster-size=4`. Aerospike SC promoted Site 1 replicas to masters automatically. No manual intervention required.
- **Operational note:** `active-rack` setting influences master placement preference, but SC will promote replicas when a sufficient quorum exists regardless of rack affinity.

---

#### Non-Happy Path — Manual Intervention or Degraded State

**Scenario N1 — Single node failure (master partition reallocation)**
- **What happened:** One Site 2 master node went down.
- **Observed:** ~1365 master partitions became unavailable (those pinned to the failed node). SC does not auto-promote replicas. Cluster stayed above MCS but those partitions were inaccessible.
- **Resolution:** Restart the failed node. Partitions revive automatically on rejoin.
- **Key insight:** SC never promotes replicas without a full quorum of the partition's replica set. A single-node master failure = partial unavailability, not automatic recovery.

**Scenario N2 — Site 1 + tie-breaker (C1) failure**
- **What happened:** All Site 1 nodes and the quorum node were stopped. Only Site 2 (3 nodes) remained.
- **Observed:** Cluster halted. 3 nodes < `min-cluster-size=4`; Site 2 alone could not form a quorum. No reads or writes accepted.
- **Manual intervention required:**
  1. Update the SC roster to remove Site 1 nodes and C1 (drop them from the roster).
  2. Set `active-rack=2` in the namespace config (if not already).
  3. Reduce `min-cluster-size` to 3 to allow Site 2 alone to form a cluster.
  4. Recluster and revive.
- **Result after intervention:** Site 2 formed a 3-node cluster. RF reduced from 4 to 3 (only 3 nodes in roster). Writes accepted.
- **Risk:** RF=3 with only 3 nodes means no redundancy — losing any one more node = data loss.

**Scenario N3 — Tie-breaker (C1) node restart**
- **What happened:** Quorum node C1 was restarted (e.g., after a crash or rolling maintenance).
- **Observed:** C1 rejoined the cluster as a full participant — started accepting master and replica partitions — because the quiesce state is not persisted across restarts.
- **Required action:** Must re-quiesce C1 immediately after restart:
  ```bash
  docker exec quorum-node asinfo -v "quiesce:" -h 172.28.0.31 -p 3000
  # then recluster so the quiesce takes effect
  docker exec site1-node1 asinfo -v "recluster:" -h 172.28.0.11 -p 3000
  ```
- **Why this matters:** C1 is meant to be a tie-breaker only — holding 0 data partitions. If it holds partitions, a C1 failure causes data unavailability instead of being harmless.

**Scenario N4 — DC link broken (Site 1 + tie-breaker isolated from Site 2)**
- **What happened:** Network partition isolating DC1 (Site 1 + C1) from DC2 (Site 2).
- **Observed:** DC1 side (4 nodes) retained quorum and continued serving traffic normally. DC2 side (3 nodes) fell below MCS and halted.
- **Split-brain risk:** If `min-cluster-size` was manually lowered on DC2 (or SC guards bypassed), both sides could accept writes to the same keys — causing permanent data divergence on heal. This cluster's default config prevents this, but it is the primary risk of a DC link failure.
- **Recovery:** Heal the network (flush iptables). Both sides merge, DC2 nodes catch up from DC1. No data loss if SC guards were not bypassed.

---

## Project Structure

```
aerospike-multisite/
│
├── docker-compose.yml              # 7-node topology (DC1=Site1+Quorum, DC2=Site2)
├── Dockerfile                      # FROM myubuntu + Aerospike EE 8.1.1.2 (aarch64)
├── entrypoint_multisite.sh         # Renders config template + runs asd + quiesce-keeper
│
├── configs/
│   ├── aerospike.conf.template     # Config template with ${NODE_ID}, ${RACK_ID} etc.
│   ├── aerospike_8.conf            # Single-node fallback config (Aerospike 8.x)
│   └── trial-features.conf         # Enterprise trial license (8-node, expires 2026-05-25)
│
├── scripts/
│   ├── run.sh                      # Full cluster startup: up + roster + quiesce + verify
│   ├── set-roster.sh               # Standalone SC roster set/re-sync helper
│   ├── validate-cluster.sh         # 7-step health check
│   ├── simulate-failures.sh        # Interactive failure simulator (26 scenarios: N1-N3, S1-S4,
│   │                               #   P1-P4, SB, D1-D4, R1-R5, O1-O4, ST)
│   ├── validate-scenarios.sh       # Automated end-to-end scenario validation (14 tests,
│   │                               #   active-rack-aware assertions)
│   └── cluster-visualizer.py       # Live terminal dashboard (pip install rich)
│
├── binaries/                       # Aerospike server + tools .deb packages (aarch64)
├── data/                           # Placeholder
└── remote/                         # Placeholder
```

---

## Troubleshooting

### "Node not found for partition 0" (error -8)

The SC roster has not been set. Run:
```bash
./scripts/run.sh --skip-up
# or, if the cluster is already configured but needs a re-sync:
./scripts/set-roster.sh
```

Verify: `docker exec site1-node1 asinfo -v 'roster:namespace=mynamespace' -h 172.28.0.11 -p 3000`
If `roster=null`, the roster is not set.

### Dead partitions after restart (4096 dead-partitions)

The cluster restarted with stale data from a different topology or roster. The SMD knows about nodes that are no longer in the roster. Fix:
```bash
# Revive on all nodes, then recluster
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  docker exec "$c" asinfo -v "revive:namespace=mynamespace" -h $(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c") -p 3000
done
# Recluster (try all nodes; only the principal accepts)
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  result=$(docker exec "$c" asinfo -v "recluster:" -p 3000 2>/dev/null)
  [ "$result" = "ok" ] && echo "Accepted by $c" && break
done
```
Or just run `./scripts/run.sh --skip-up`.

### `cluster_size` shows > 7 after topology change

Old containers from a previous topology (e.g., `site3-node*`) are still running and have rejoined the mesh. `run.sh` automatically detects and stops stale containers before starting. If running manually:
```bash
docker stop site3-node1 site3-node2 site3-node3 2>/dev/null || true
```

### `ignored-by-non-principal` on `recluster:`

The `recluster:` command must be sent to the current **principal node** (the one holding the succession list). The scripts use a loop that tries all nodes until one responds `ok`. Do not use `asadm manage recluster` for scripted usage — send `asinfo -v "recluster:"` to each node until `ok`.

### Network conflict: "Pool overlaps with other one on this address space"

The `172.28.0.0/24` subnet conflicts with an existing Docker network:
```bash
docker network ls
docker network inspect <conflicting-network> | grep Subnet
```
Either remove the conflicting network or change the subnet in `docker-compose.yml` (and update all IP references in all scripts and configs).

### Platform mismatch (Apple Silicon / x86)

The Dockerfile defaults to `linux/arm64`. For x86:
```bash
PLATFORM=linux/amd64 docker compose up -d --build
```
Also replace the `binaries/` contents with amd64 `.deb` packages.

### License expired

Check `configs/trial-features.conf`. The current trial expires **2026-05-25**. If expired, `asd` will fail to start. Obtain a new trial license from [aerospike.com](https://aerospike.com) and replace the file.

### Containers exit with code 1 (config error)

```bash
docker logs site1-node1 | tail -50
```
Common causes:
- `trial-features.conf` expired or missing
- `write-block-size` directive used (obsolete in Aerospike 8.x — use `flush-size`)
- Template variable not substituted (`${NODE_ID}` literally in the generated config — means `envsubst` failed or `MESH_SEEDS` was empty)

---

## State Sync Reference

This section captures the complete current system state for context restoration in future sessions.

### Aerospike build
- Server: `8.1.1.2`
- Tools: `12.1.1`
- Ubuntu: `24.04`
- Architecture: `aarch64` (ARM64)
- Docker image tag: `myubuntu-noble_aerospike-multisite`

### Current `configs/aerospike.conf.template` key values
```
min-cluster-size 3        # ← user-modified; design intent is 4
active-rack 2             # ← user-modified; design intent is 1 (Site1 as primary)
replication-factor 4
strong-consistency true
strong-consistency-allow-expunge true
commit-to-device true
heartbeat interval 250 / timeout 10
```

### Environment variables injected per node

| Env var | Source | Example |
|---|---|---|
| `NODE_ID` | `docker-compose.yml` | `A1`, `B3`, `C1` |
| `RACK_ID` | `docker-compose.yml` | `1` (Site1), `2` (Site2), `3` (Quorum) |
| `SERVICE_ADDRESS` | `docker-compose.yml` | `172.28.0.11` |
| `MESH_SEEDS` | `docker-compose.yml` | `172.28.0.11:3002,...,172.28.0.31:3002` |
| `AUTO_QUIESCE` | `docker-compose.yml` (quorum-node only) | `true` |
| `AEROSPIKE_NAMESPACE` | `docker-compose.yml` (quorum-node only) | `mynamespace` |

### Key constants used across all scripts

| Constant | Value |
|---|---|
| Namespace | `mynamespace` |
| Cluster name | `multisite-sc` |
| Seed container | `site1-node1` |
| Seed IP | `172.28.0.11` |
| Quorum container | `quorum-node` |
| Quorum IP | `172.28.0.31` |
| Quorum node ID | `C1` |
| Site1 containers | `site1-node1`, `site1-node2`, `site1-node3` |
| Site1 IPs | `172.28.0.11`, `172.28.0.12`, `172.28.0.13` |
| Site1 node IDs | `A1`, `A2`, `A3` |
| Site2 containers | `site2-node1`, `site2-node2`, `site2-node3` |
| Site2 IPs | `172.28.0.21`, `172.28.0.22`, `172.28.0.23` |
| Site2 node IDs | `B1`, `B2`, `B3` |
| Docker network | `as-multisite` |
| Subnet | `172.28.0.0/24` |
| Gateway | `172.28.0.1` |

### Simulate-failures.sh scenario dispatch table

```
N1 → scenario_single_node          N2 → scenario_tiebreaker_failure
N3 → scenario_active_rack_node
S1 → scenario_site1_failure        S2 → scenario_site2_failure
S3 → scenario_dc1_failure          S4 → scenario_dc2_failure
P1 → scenario_net_isolate_site1    P2 → scenario_net_isolate_site2
P3 → scenario_net_isolate_quorum   P4 → scenario_net_site_vs_site
SB → scenario_split_brain
D1 → scenario_site1_degraded       D2 → scenario_site2_degraded
D3 → scenario_quorum_plus_one      D4 → scenario_cascading
R1 → scenario_recover_all          R2 → scenario_recover_specific
R3 → scenario_heal_network         R4 → scenario_full_recovery
R5 → scenario_recover_site2_only
O1 → scenario_roster_update        O2 → scenario_quiesce_toggle
O3 → scenario_rolling_restart      O4 → scenario_switch_active_rack
ST → status_check
```

# Aerospike Multi-Site Strong Consistency Cluster

A Docker-based 7-node Aerospike Enterprise cluster with **Strong Consistency (SC)** and **rack-aware replication** across 3 simulated sites.

## Architecture

```
              Docker Network: as-multisite (172.28.0.0/24)

  +---------- SITE 1 (Rack 1) ----------+   +---------- SITE 2 (Rack 2) ----------+
  |                                      |   |                                      |
  |  site1-node1  site1-node2            |   |  site2-node1  site2-node2            |
  |  172.28.0.11  172.28.0.12            |   |  172.28.0.21  172.28.0.22            |
  |  :3000-3003   :3100-3103             |   |  :3300-3303   :3400-3403             |
  |                                      |   |                                      |
  |           site1-node3                |   |           site2-node3                |
  |           172.28.0.13                |   |           172.28.0.23                |
  |           :3200-3203                 |   |           :3500-3503                 |
  +--------------------------------------+   +--------------------------------------+
                           \                      /
                            \                    /
                       +-------- QUORUM (Rack 3) --------+
                       |                                  |
                       |          quorum-node             |
                       |          172.28.0.31             |
                       |          :3600-3603              |
                       |       (Tie-breaker node)         |
                       +----------------------------------+
```

| Site | Container | IP | Host Ports (service/fabric/heartbeat/info) |
|---|---|---|---|
| Site 1 (Rack 1) | site1-node1 | 172.28.0.11 | 3000 / 3001 / 3002 / 3003 |
| Site 1 (Rack 1) | site1-node2 | 172.28.0.12 | 3100 / 3101 / 3102 / 3103 |
| Site 1 (Rack 1) | site1-node3 | 172.28.0.13 | 3200 / 3201 / 3202 / 3203 |
| Site 2 (Rack 2) | site2-node1 | 172.28.0.21 | 3300 / 3301 / 3302 / 3303 |
| Site 2 (Rack 2) | site2-node2 | 172.28.0.22 | 3400 / 3401 / 3402 / 3403 |
| Site 2 (Rack 2) | site2-node3 | 172.28.0.23 | 3500 / 3501 / 3502 / 3503 |
| Quorum (Rack 3) | quorum-node | 172.28.0.31 | 3600 / 3601 / 3602 / 3603 |

**Design highlights:**
- **Replication factor 3** -- one copy per rack/site, ensuring data survives the loss of any single site.
- **`active-rack=1`** -- all master partitions are pinned to Rack 1 (Site 1). Reads and writes are served from Site 1; Site 2 and Quorum hold replicas only.
- **Quorum node quiesced** -- C1 is quiesced after roster setup so it holds zero partitions (master or replica). It participates only in cluster formation and voting, acting as a pure tie-breaker.
- **`min-cluster-size=4`** -- prevents split-brain. The 3+3+1 topology guarantees the surviving majority (other site + quorum = 4 nodes) can continue writes while the minority (3 nodes) stops.
- **Mesh heartbeats** with 250ms intervals (2.5s failure detection).
- **`commit-to-device=true`** -- all writes are flushed to storage before acknowledgement.

## Prerequisites

1. **Docker** and **Docker Compose** (v2+)
2. **Base image `myubuntu`** -- the Dockerfile builds `FROM myubuntu`. You must have this base image available locally before building. Build or pull it from the parent `dockers/` repository if needed.
3. **Aerospike Enterprise binaries** -- already included under `binaries/` (server 8.1.1.2, tools 12.1.1, Ubuntu 24.04 aarch64).
4. **Trial license** -- included in `configs/trial-features.conf` (8-node trial, expires **2026-05-25**).

## Steps to Run

### Step 1: Build and start the cluster

```bash
docker compose up -d --build
```

This builds the custom Aerospike image and starts all 7 containers. The startup order is managed via `depends_on` in the compose file.

Wait for all containers to become healthy:

```bash
docker compose ps
```

All 7 containers should show `healthy` status (may take 30-60 seconds).

### Step 2: Set the roster (REQUIRED before any reads/writes)

**Strong Consistency mode rejects all reads and writes until the roster is explicitly set.**
Without a roster, queries will fail with:

```
Error: (-8) Node not found for partition 0
```

Run the roster setup script:

```bash
./scripts/set-roster.sh
```

This script:
1. Connects to `site1-node1` and reads the currently observed nodes
2. Sets the roster to include all observed nodes
3. Sends `recluster:` to the principal node (tries all nodes automatically)
4. Revives any dead partitions on all nodes (needed after restarts with stale data)
5. Reclusters again and waits for the cluster to stabilize
6. Verifies the roster was applied

> **Note:** `roster-set` can be sent to any node, but `recluster:` must be sent to
> the cluster's **principal node**. The script handles this by trying all nodes
> until one accepts.

### Step 3: Quiesce the quorum node (RECOMMENDED)

The quorum node (C1) exists solely as a tie-breaker for split-brain prevention. It should not hold any master or replica partitions. Quiescing it ensures Aerospike excludes it from partition ownership:

```bash
# From any node that has asadm (quorum-node used here for clarity)
docker exec quorum-node asadm --enable -e "manage quiesce with 172.28.0.31:3000"
docker exec quorum-node asadm --enable -e "manage recluster"
```

After this:
- C1 holds **0 master and 0 replica** partitions
- All masters remain on Site 1 (Rack 1) thanks to `active-rack=1`
- Replicas are distributed across Site 1 and Site 2 nodes only
- C1 still participates in cluster formation and voting (quorum)

Verify quiesce status:

```bash
docker exec quorum-node asinfo -v "namespace/mynamespace" | tr ';' '\n' | grep quiesce
# Expected: pending_quiesce=true, effective_is_quiesced=true, nodes_quiesced=1
```

> **Note:** Quiesce is not persistent across restarts. If the cluster is rebuilt (`docker compose down && up`), you must re-run both `set-roster.sh` (Step 2) and the quiesce commands (Step 3).

> **To undo quiesce:** Run `manage quiesce with 172.28.0.31:3000 undo` followed by `manage recluster`.

### Step 4: Validate the cluster

```bash
./scripts/validate-cluster.sh
```

This runs a 7-step automated check:
1. Cluster formation (waits for all 7 nodes to join, up to 120s)
2. Cluster stability (all nodes share the same cluster-key)
3. Rack-aware distribution
4. Strong Consistency enabled
5. Roster status
6. Write/read smoke test (cross-site replication)
7. `asadm` cluster summary

### Step 5: Connect and use the cluster

Connect via any node's service port using `aql`, `asadm`, or any Aerospike client:

```bash
# Connect via site1-node1 (host port 3000)
docker exec -it site1-node1 aql -h 172.28.0.11 -p 3000

# Connect via site2-node1 (host port 3300)
docker exec -it site2-node1 aql -h 172.28.0.21 -p 3000
```

Or if you have the Aerospike tools installed locally:

```bash
aql -h 127.0.0.1 -p 3000
asadm -h 127.0.0.1 -p 3000
```

Example queries:

```sql
INSERT INTO mynamespace (PK, name) VALUES ('key1', 'hello')
SELECT * FROM mynamespace WHERE PK = 'key1'
SELECT * FROM mynamespace
```

### Step 6: Monitor the cluster (optional)

```bash
pip install rich   # one-time setup
python3 scripts/cluster-visualizer.py
```

A live terminal dashboard that auto-refreshes every 2 seconds, showing:
- **Cluster health** at a glance: `HEALTHY`, `DEGRADED`, `MIGRATING`, `STOP WRITES`, `SPLIT BRAIN`, or `CLUSTER DOWN`
- **Per-node cards** grouped by site with status, uptime, object counts, disk usage, migration progress
- **Topology diagram** with color-coded node availability and principal indicator
- **Roster & SC status** in the header

Options:

```bash
python3 scripts/cluster-visualizer.py --interval 5   # custom refresh (5s)
python3 scripts/cluster-visualizer.py --once           # single snapshot, no loop
```

### Step 7: Test fault tolerance (optional)

```bash
./scripts/simulate-failures.sh
```

Interactive menu with 8 scenarios:
1. **Single node failure** -- stop one node, cluster continues
2. **Tie-breaker failure** -- stop quorum-node
3. **Entire site failure** -- stop all 3 nodes in a site
4. **Network partition** -- iptables-based split between sites
5. **Node recovery** -- restart stopped nodes
6. **Roster update** -- add/remove nodes from the roster
7. **Rolling restart** -- restart nodes one-by-one within a site
8. **Cluster status** -- check current state

## Stopping and Cleaning Up

```bash
# Stop the cluster (preserves data volumes)
docker compose down

# Stop and remove all data volumes
docker compose down -v
```

## Troubleshooting

### "Node not found for partition 0" (error code -8)

This means the **roster has not been set**. In Strong Consistency mode, Aerospike does not assign partition ownership until the roster is explicitly configured. All reads and writes will fail with this error until you run:

```bash
./scripts/set-roster.sh
```

You can verify the roster status with:

```bash
docker exec site1-node1 asinfo -v 'roster:namespace=mynamespace' -h 172.28.0.11 -p 3000
```

If the output shows `roster=null`, the roster is not set.

### Dead partitions after restart (4096 dead-partitions, cluster unstable)

When the cluster restarts with data files from a previous run, all 4096 partitions may be in a "dead" state. The `set-roster.sh` script handles this automatically by running `revive:namespace=mynamespace` on all nodes. If you need to do it manually:

```bash
# Revive on all nodes
for c in site1-node1 site1-node2 site1-node3 site2-node1 site2-node2 site2-node3 quorum-node; do
  docker exec $c asinfo -v "revive:namespace=mynamespace"
done

# Then recluster (must be sent to the principal -- try all nodes)
docker exec quorum-node asinfo -v "recluster:" -h 172.28.0.31 -p 3000
```

### Network conflict: "Pool overlaps with other one on this address space"

The Docker network subnet `172.28.0.0/24` may conflict with an existing Docker network. Check with:

```bash
docker network ls
docker network inspect <network-name> | grep Subnet
```

Either remove the conflicting network or change the subnet in `docker-compose.yml` (and update all IP references in `docker-compose.yml`, `scripts/*.sh`).

### Platform mismatch (Apple Silicon / ARM)

The `PLATFORM` build arg in `docker-compose.yml` defaults to `linux/arm64`. If you're on an x86/amd64 machine, override it:

```bash
PLATFORM=linux/amd64 docker compose up -d --build
```

You will also need amd64 Aerospike binaries in the `binaries/` directory.

### Containers restarting with exit code 127

This means a required command is missing in the image. The Dockerfile installs `gettext-base` (for `envsubst`). If you see this error, ensure the Dockerfile includes:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base && rm -rf /var/lib/apt/lists/*
```

### Aerospike config errors (exit code 1)

Check container logs: `docker logs <container-name>`. Common issues:
- **`write-block-size` is obsolete** in Aerospike 8.x -- use `flush-size` instead.
- Ensure the `trial-features.conf` license has not expired.

## Project Structure

```
aerospike-multisite/
├── docker-compose.yml              # 7-node cluster orchestration
├── Dockerfile                      # Image build (Ubuntu + Aerospike EE 8.1.1.2)
├── entrypoint_multisite.sh         # Container entrypoint (template rendering + asd)
├── entrypoint.sh                   # Legacy simple entrypoint (not used)
├── aerospike.conf.template         # Root-level copy of config template
├── script.sh                       # Standalone build helper
├── configs/
│   ├── aerospike.conf.template     # Aerospike config template (envsubst placeholders)
│   ├── aerospike_8.conf            # Single-node dev config (fallback)
│   └── trial-features.conf        # Enterprise trial license (expires 2026-05-25)
├── scripts/
│   ├── set-roster.sh               # Set SC roster (required for writes)
│   ├── validate-cluster.sh         # 7-step cluster health check
│   ├── simulate-failures.sh        # Interactive failure simulation (8 scenarios)
│   └── cluster-visualizer.py       # Live terminal dashboard (requires: pip install rich)
├── binaries/                       # Aerospike server + tools .deb packages
├── data/                           # Placeholder for local data
└── remote/                         # Placeholder
```

## Configuration Reference

| Parameter | Value | Notes |
|---|---|---|
| Cluster name | `multisite-sc` | Shared by all nodes |
| Namespace | `mynamespace` | Used by all scripts and config |
| Replication factor | 3 | One copy per rack |
| Active rack | 1 (Site 1) | All masters pinned to Rack 1 |
| Quorum node quiesced | yes | C1 holds 0 partitions, pure tie-breaker |
| Strong Consistency | enabled | Requires roster to be set |
| `min-cluster-size` | 4 | Split-brain prevention |
| Storage | file-backed, 4GB per node | `/etc/aerospike/data/aerospike.dat` |
| `commit-to-device` | true | Required for SC durability |
| Heartbeat interval | 250ms | ~2.5s failure detection |
| `proto-fd-max` | 15000 | Max client connections |
| `default-ttl` | 0 | Records never expire |
| `max-record-size` | 1MB | Per-record limit |

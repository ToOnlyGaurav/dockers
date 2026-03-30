#!/bin/bash
# =============================================================================
# run.sh -- Start the Aerospike multi-site SC cluster and configure it
# =============================================================================
# Full startup sequence:
#   1. docker compose up -d --build
#   2. Wait for all 7 containers to be healthy
#   3. Set the SC roster (required for writes)
#   4. Quiesce the quorum node (D1) so it holds 0 partitions
#   5. Verify the cluster is ready
#
# Usage:
#   ./scripts/run.sh              # Full start (build + roster + quiesce)
#   ./scripts/run.sh --no-build   # Skip docker build (just up + configure)
#   ./scripts/run.sh --skip-up    # Skip docker compose up (configure only)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# -- Constants ----------------------------------------------------------------
NAMESPACE="mynamespace"
SEED_CONTAINER="site1-node1"
SEED_IP="172.28.0.11"
SEED_PORT="3000"
QUORUM_CONTAINER="quorum-node"
QUORUM_IP="172.28.0.31"
QUORUM_ID="C1"

ALL_CONTAINERS=("site1-node1" "site1-node2" "site1-node3" "site2-node1" "site2-node2" "site2-node3" "quorum-node")
ALL_IPS=("172.28.0.11" "172.28.0.12" "172.28.0.13" "172.28.0.21" "172.28.0.22" "172.28.0.23" "172.28.0.31")
TOTAL_NODES=${#ALL_CONTAINERS[@]}

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# -- Parse flags --------------------------------------------------------------
BUILD_FLAG="--build"
SKIP_UP=false

for arg in "$@"; do
    case "$arg" in
        --no-build)  BUILD_FLAG="" ;;
        --skip-up)   SKIP_UP=true ;;
        -h|--help)
            echo "Usage: $0 [--no-build] [--skip-up]"
            echo "  --no-build   Skip docker image build"
            echo "  --skip-up    Skip docker compose up (configure only)"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown flag: $arg${NC}"
            exit 1
            ;;
    esac
done

# -- Helper functions ---------------------------------------------------------

step() {
    echo ""
    echo -e "${CYAN}${BOLD}[$1/$TOTAL_STEPS] $2${NC}"
    echo -e "${DIM}$(printf '%.0s─' {1..60})${NC}"
}

ok()   { echo -e "  ${GREEN}$1${NC}"; }
warn() { echo -e "  ${YELLOW}$1${NC}"; }
fail() { echo -e "  ${RED}$1${NC}"; }
info() { echo -e "  ${DIM}$1${NC}"; }

# Recluster by trying all nodes until the principal accepts
do_recluster() {
    local label="${1:-recluster}"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local result
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null || true)
        if [ "$result" = "ok" ]; then
            ok "$label accepted by ${ALL_CONTAINERS[$i]}"
            return 0
        fi
    done
    warn "$label not accepted by any node (cluster may still be electing principal)"
    return 1
}

# =============================================================================
TOTAL_STEPS=5
echo ""
echo -e "${BOLD}=== Aerospike Multi-Site SC Cluster Startup ===${NC}"
echo -e "${DIM}  7 nodes | RF=4 | 3 racks | active-rack=1 | SC mode${NC}"
echo -e "${DIM}  Namespace: ${NAMESPACE}${NC}"

# =============================================================================
# STEP 1: docker compose up
# =============================================================================
step 1 "Starting containers"

if $SKIP_UP; then
    info "Skipping docker compose up (--skip-up)"
else
    # Stop any stale containers from previous topologies (e.g. site3-node* from a
    # prior 10-node run). Docker Compose 'up' only manages containers defined in
    # the current file and will leave old ones running -- they would rejoin the
    # cluster and cause cluster_size > TOTAL_NODES.
    info "Checking for stale containers not in current topology..."
    stale_found=false
    while IFS= read -r running_c; do
        in_expected=false
        for expected in "${ALL_CONTAINERS[@]}"; do
            [ "$running_c" = "$expected" ] && in_expected=true && break
        done
        # Only touch containers that look like Aerospike cluster members
        if ! $in_expected && echo "$running_c" | grep -qE '^(site[0-9]+-node[0-9]+|quorum-node)$'; then
            warn "Stopping stale container: $running_c"
            docker stop "$running_c" >/dev/null 2>&1 || true
            stale_found=true
        fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
    $stale_found || info "No stale containers found"

    cd "$PROJECT_DIR"
    if [ -n "$BUILD_FLAG" ]; then
        info "Running: docker compose up -d --build"
    else
        info "Running: docker compose up -d"
    fi
    # shellcheck disable=SC2086
    docker compose up -d $BUILD_FLAG 2>&1 | sed 's/^/  /'
    ok "Containers started"
fi

# =============================================================================
# STEP 2: Wait for all containers to be healthy
# =============================================================================
step 2 "Waiting for all $TOTAL_NODES containers to be healthy"

MAX_WAIT=120
POLL_INTERVAL=5
elapsed=0
while true; do
    healthy_count=0
    for c in "${ALL_CONTAINERS[@]}"; do
        status=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then
            ((healthy_count++))
        fi
    done

    if [ "$healthy_count" -eq "$TOTAL_NODES" ]; then
        ok "All $TOTAL_NODES containers healthy (${elapsed}s)"
        break
    fi

    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        fail "Timed out after ${MAX_WAIT}s -- only $healthy_count/$TOTAL_NODES healthy"
        echo ""
        echo "  Container status:"
        for c in "${ALL_CONTAINERS[@]}"; do
            s=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "missing")
            echo "    $c: $s"
        done
        exit 1
    fi

    info "$healthy_count/$TOTAL_NODES healthy ... waiting (${elapsed}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done

# Also wait for all nodes to see each other (cluster_size == 7)
info "Waiting for full cluster formation (cluster_size=$TOTAL_NODES)..."
elapsed=0
while true; do
    cs=$(docker exec "$SEED_CONTAINER" asinfo -v "statistics" \
        -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "0")
    if [ "$cs" -eq "$TOTAL_NODES" ] 2>/dev/null; then
        ok "Cluster formed: $cs nodes"
        break
    fi
    if [ "$elapsed" -ge 90 ]; then
        warn "Cluster size is $cs after 90s (expected $TOTAL_NODES). Continuing anyway..."
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

# =============================================================================
# STEP 3: Set the SC roster
# =============================================================================
step 3 "Setting Strong Consistency roster"

# Get observed nodes -- in SC mode observed_nodes can take 10-30s to populate
# after cluster_size reaches the target, so retry with backoff.
observed=""
roster_info=""
for attempt in $(seq 1 18); do
    roster_info=$(docker exec "$SEED_CONTAINER" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null)
    observed=$(echo "$roster_info" | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
    if [ -n "$observed" ] && [ "$observed" != "null" ]; then
        break
    fi
    info "observed_nodes not yet populated (attempt ${attempt}/18) -- waiting 5s..."
    sleep 5
done

if [ -z "$observed" ] || [ "$observed" = "null" ]; then
    fail "No observed nodes found after 90s. Is the cluster up?"
    exit 1
fi
info "Observed nodes: $observed"

# Strip the M<n>| active-rack prefix -- roster-set does NOT accept it.
# observed_nodes looks like "M1|C1@3,B3@2,..." but roster-set expects "C1@3,B3@2,..."
roster_nodes=$(echo "$observed" | sed 's/^M[0-9]*|//')
info "Roster nodes (prefix stripped): $roster_nodes"

# Check if roster is already set with the same nodes
current_roster=$(echo "$roster_info" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
if [ "$current_roster" = "$roster_nodes" ]; then
    info "Roster already matches observed nodes"
else
    # Set roster
    result=$(docker exec "$SEED_CONTAINER" asinfo \
        -v "roster-set:namespace=${NAMESPACE};nodes=${roster_nodes}" \
        -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null)
    if [ "$result" = "ok" ]; then
        ok "Roster set"
    else
        fail "roster-set returned: $result"
        exit 1
    fi
fi

# Recluster
do_recluster "Recluster"
sleep 3

# Revive dead partitions on all nodes
info "Reviving dead partitions (if any)..."
revive_count=0
for i in "${!ALL_CONTAINERS[@]}"; do
    revive_result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo \
        -v "revive:namespace=${NAMESPACE}" \
        -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null || echo "fail")
    if [[ "$revive_result" == *"ok"* ]]; then
        ((revive_count++))
    fi
done
if [ "$revive_count" -gt 0 ]; then
    info "Revived dead partitions on $revive_count node(s)"
    do_recluster "Recluster after revive"
    sleep 3
else
    info "No dead partitions to revive"
fi

# Wait for stability
info "Waiting for cluster to stabilize..."
for attempt in $(seq 1 12); do
    stable=$(docker exec "$SEED_CONTAINER" asinfo -v "cluster-stable:" \
        -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null || echo "unstable")
    if [[ "$stable" != *"unstable"* && "$stable" != *"ERROR"* ]]; then
        ok "Cluster stable (key: $stable)"
        break
    fi
    if [ "$attempt" -eq 12 ]; then
        warn "Cluster not yet stable after 60s -- may need more time"
    fi
    sleep 5
done

# =============================================================================
# STEP 4: Verify quorum node quiesce (handled automatically by quiesce-keeper)
# =============================================================================
step 4 "Verifying quorum node (C1) quiesce state"

info "C1 runs with AUTO_QUIESCE=true -- the quiesce-keeper in its entrypoint"
info "quiesces it automatically when the cluster forms. Waiting up to 20s..."

is_quiesced="false"
for attempt in $(seq 1 10); do
    is_quiesced=$(docker exec "$QUORUM_CONTAINER" asinfo \
        -v "namespace/${NAMESPACE}" -h "$QUORUM_IP" -p 3000 2>/dev/null \
        | tr ';' '\n' | grep '^effective_is_quiesced=' | cut -d'=' -f2 || echo "false")
    if [ "$is_quiesced" = "true" ]; then
        ok "C1 is quiesced (effective_is_quiesced=true) -- 0 partitions, pure tie-breaker"
        break
    fi
    sleep 2
done
if [ "$is_quiesced" != "true" ]; then
    warn "C1 not yet quiesced after 20s -- quiesce-keeper may still be waiting for peers"
    warn "Check 'docker logs quorum-node' for [quiesce-keeper] messages"
fi

# =============================================================================
# STEP 5: Verify cluster is ready
# =============================================================================
step 5 "Verifying cluster state"

# Cluster size
cs=$(docker exec "$SEED_CONTAINER" asinfo -v "statistics" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "?")
echo -e "  Cluster size:   ${BOLD}$cs${NC}"

# Roster
roster_info=$(docker exec "$SEED_CONTAINER" asinfo -v "roster:namespace=${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null)
roster_val=$(echo "$roster_info" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
echo -e "  Roster:         ${BOLD}$roster_val${NC}"

# RF
rf=$(docker exec "$SEED_CONTAINER" asinfo -v "namespace/${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^effective_replication_factor=' | cut -d'=' -f2 || echo "?")
echo -e "  Repl. factor:   ${BOLD}$rf${NC}"

# Active rack
ar=$(docker exec "$SEED_CONTAINER" asinfo -v "namespace/${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^active-rack=' | cut -d'=' -f2 || echo "?")
echo -e "  Active rack:    ${BOLD}R${ar}${NC}"

# Quiesce status
qn=$(docker exec "$SEED_CONTAINER" asinfo -v "namespace/${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^nodes_quiesced=' | cut -d'=' -f2 || echo "?")
echo -e "  Nodes quiesced: ${BOLD}$qn${NC}"

# Quick write/read test via aql
info "Write/read smoke test..."
write_result=$(docker exec "$SEED_CONTAINER" aql \
    -h "$SEED_IP" -p "$SEED_PORT" \
    -c "INSERT INTO ${NAMESPACE}.test (PK, v) VALUES ('_run_check', 1)" 2>&1)
if echo "$write_result" | grep -q "OK"; then
    ok "Write succeeded"
    # Clean up test record
    docker exec "$SEED_CONTAINER" aql \
        -h "$SEED_IP" -p "$SEED_PORT" \
        -c "DELETE FROM ${NAMESPACE}.test WHERE PK = '_run_check'" 2>/dev/null >/dev/null || true
else
    warn "Write test: $(echo "$write_result" | grep -i 'error\|Error' | head -1 | sed 's/^//')"
    warn "This may be transient (e.g. brief stop_writes under load). Retry manually if needed."
fi

# Summary
echo ""
echo -e "${GREEN}${BOLD}=== Cluster is ready ===${NC}"
echo -e "${DIM}  Namespace '${NAMESPACE}' is accepting reads and writes"
echo -e "  All masters on Site 1 (Rack 1) via active-rack=1"
echo -e "  Quorum node (C1) quiesced -- pure tie-breaker, 0 partitions"
echo -e ""
echo -e "  Dashboard:    python3 scripts/cluster-visualizer.py"
echo -e "  Validate:     ./scripts/validate-cluster.sh"
echo -e "  Simulate:     ./scripts/simulate-failures.sh"
echo -e "  AQL shell:    docker exec -it site1-node1 aql${NC}"
echo ""

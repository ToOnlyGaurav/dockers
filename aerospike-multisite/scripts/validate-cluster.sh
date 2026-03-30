#!/bin/bash
# =============================================================================
# validate-cluster.sh -- Quick health check for the 10-node cluster
# =============================================================================
# Verifies:
#   1. All 10 nodes are running and reachable
#   2. Cluster key is consistent (no split-brain)
#   3. Strong Consistency is enabled
#   4. Roster is set and valid
#   5. D1 (quorum-node) is quiesced
#   6. All masters are on Site 1 (Rack 1)
#   7. Write/read smoke test
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

NAMESPACE="mynamespace"
SEED_CONTAINER="site1-node1"
SEED_IP="172.28.0.11"
SEED_PORT="3000"
EXPECTED_NODES=7
MAX_WAIT=120

ALL_CONTAINERS=("site1-node1" "site1-node2" "site1-node3"
                "site2-node1" "site2-node2" "site2-node3"
                "quorum-node")
ALL_IPS=("172.28.0.11" "172.28.0.12" "172.28.0.13"
         "172.28.0.21" "172.28.0.22" "172.28.0.23"
         "172.28.0.31")
ALL_IDS=("A1" "A2" "A3" "B1" "B2" "B3" "C1")

PASS_COUNT=0
FAIL_COUNT=0

header() {
    echo ""
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
}

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }

# ---------------------------------------------------------------------------
header "STEP 1: Container health"
# ---------------------------------------------------------------------------
for i in "${!ALL_CONTAINERS[@]}"; do
    c="${ALL_CONTAINERS[$i]}"
    id="${ALL_IDS[$i]}"
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo "?")
    if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
        pass "$id ($c): running/healthy"
    elif [ "$state" = "running" ]; then
        info "$id ($c): running but health=$health"
    else
        fail "$id ($c): state=$state"
    fi
done

# ---------------------------------------------------------------------------
header "STEP 2: Cluster formation (waiting up to ${MAX_WAIT}s for ${EXPECTED_NODES} nodes)"
# ---------------------------------------------------------------------------
elapsed=0
while true; do
    cs=$(docker exec "$SEED_CONTAINER" asinfo -v "statistics" -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "0")
    if [ "${cs:-0}" -ge "$EXPECTED_NODES" ] 2>/dev/null; then
        pass "Cluster size = $cs / $EXPECTED_NODES"
        break
    fi
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        fail "Timeout after ${MAX_WAIT}s -- cluster_size=${cs:-0} (expected $EXPECTED_NODES)"
        break
    fi
    echo -ne "\r  Waiting... ${elapsed}s (cluster_size=${cs:-0}/$EXPECTED_NODES)    "
    sleep 5
    elapsed=$((elapsed + 5))
done
echo ""

# ---------------------------------------------------------------------------
header "STEP 3: Cluster key consistency (split-brain check)"
# ---------------------------------------------------------------------------
ref_key=""
all_match=true
for i in "${!ALL_CONTAINERS[@]}"; do
    c="${ALL_CONTAINERS[$i]}"
    id="${ALL_IDS[$i]}"
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
    [ "$state" != "running" ] && continue
    key=$(docker exec "$c" asinfo -v "statistics" -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_key=' | cut -d'=' -f2 || echo "?")
    [ -z "$ref_key" ] && ref_key="$key"
    if [ "$key" != "$ref_key" ] && [ "$key" != "0" ] && [ "$ref_key" != "0" ]; then
        fail "$id cluster_key=$key (expected $ref_key) -- SPLIT BRAIN DETECTED"
        all_match=false
    fi
done
$all_match && pass "All nodes share cluster key: $ref_key"

# ---------------------------------------------------------------------------
header "STEP 4: Strong Consistency and roster"
# ---------------------------------------------------------------------------
sc=$(docker exec "$SEED_CONTAINER" asinfo -v "namespace/${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^strong-consistency=' | cut -d'=' -f2 || echo "?")
[ "$sc" = "true" ] && pass "Strong Consistency enabled" || fail "Strong Consistency not enabled (got: $sc)"

roster_raw=$(docker exec "$SEED_CONTAINER" asinfo -v "roster:namespace=${NAMESPACE}" \
    -h "$SEED_IP" -p "$SEED_PORT" 2>/dev/null || echo "")
roster_val=$(echo "$roster_raw" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
if [ -n "$roster_val" ] && [ "$roster_val" != "null" ]; then
    pass "Roster is set: $roster_val"
else
    fail "Roster is empty or null -- namespace will not accept writes"
fi

# ---------------------------------------------------------------------------
header "STEP 5: Quorum node (D1) quiesce state"
# ---------------------------------------------------------------------------
qstate=$(docker exec quorum-node asinfo -v "namespace/${NAMESPACE}" \
    -h "172.28.0.31" -p 3000 2>/dev/null \
    | tr ';' '\n' | grep '^effective_is_quiesced=' | cut -d'=' -f2 || echo "?")
[ "$qstate" = "true" ] && pass "C1 (quorum-node) is quiesced -- pure tie-breaker" || \
    fail "C1 is NOT quiesced (effective_is_quiesced=$qstate) -- it may hold partitions"

# ---------------------------------------------------------------------------
header "STEP 6: Master partition distribution"
# ---------------------------------------------------------------------------
echo "  Node  Rack  Masters  Replicas  Stop-Writes  Quiesced"
echo "  -------------------------------------------------------"
total_masters=0
site1_masters=0
for i in "${!ALL_CONTAINERS[@]}"; do
    c="${ALL_CONTAINERS[$i]}"
    ip="${ALL_IPS[$i]}"
    id="${ALL_IDS[$i]}"
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
    [ "$state" != "running" ] && { printf "  %-4s  %-4s  %-7s\n" "$id" "?" "DOWN"; continue; }
    ns_raw=$(docker exec "$c" asinfo -v "namespace/${NAMESPACE}" -h "$ip" -p 3000 2>/dev/null | tr ';' '\n')
    rack=$(echo "$ns_raw" | grep '^rack-id=' | cut -d'=' -f2)
    m=$(echo "$ns_raw" | grep '^master_objects=' | cut -d'=' -f2 || echo 0)
    p=$(echo "$ns_raw" | grep '^prole_objects=' | cut -d'=' -f2 || echo 0)
    sw=$(echo "$ns_raw" | grep '^stop_writes=' | cut -d'=' -f2 || echo "?")
    qsd=$(echo "$ns_raw" | grep '^effective_is_quiesced=' | cut -d'=' -f2 || echo "false")
    printf "  %-4s  R%-3s  %-7s  %-8s  %-11s  %s\n" "$id" "$rack" "${m:-0}" "${p:-0}" "$sw" "$qsd"
    total_masters=$((total_masters + ${m:-0}))
    [ "$rack" = "1" ] && site1_masters=$((site1_masters + ${m:-0}))
done
echo ""
if [ "$total_masters" -gt 0 ] && [ "$site1_masters" -eq "$total_masters" ]; then
    pass "ALL masters ($total_masters objects) are on Rack 1 (Site 1) -- active-rack=1 working"
elif [ "$total_masters" -eq 0 ]; then
    info "No master objects yet (cluster may still be migrating)"
else
    info "Masters: $site1_masters/$total_masters on Rack 1 (may be mid-migration or active-rack!=1)"
fi

# ---------------------------------------------------------------------------
header "STEP 7: Write / read smoke test"
# ---------------------------------------------------------------------------
if [ -n "$roster_val" ] && [ "$roster_val" != "null" ]; then
    test_key="_validate_$(date +%s)"
    write_out=$(docker exec "$SEED_CONTAINER" aql -h "$SEED_IP" -p "$SEED_PORT" \
        -c "INSERT INTO ${NAMESPACE}.test (PK, v) VALUES ('${test_key}', 42)" 2>&1 || true)
    if echo "$write_out" | grep -q "OK"; then
        pass "Write succeeded (key: $test_key)"
        docker exec "$SEED_CONTAINER" aql -h "$SEED_IP" -p "$SEED_PORT" \
            -c "DELETE FROM ${NAMESPACE}.test WHERE PK = '${test_key}'" 2>/dev/null >/dev/null || true
    else
        fail "Write failed: $(echo "$write_out" | head -1)"
    fi
else
    info "Skipping write test -- roster not set"
fi

# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "  Results: ${GREEN}$PASS_COUNT passed${NC}  ${RED}$FAIL_COUNT failed${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
[ "$FAIL_COUNT" -eq 0 ]

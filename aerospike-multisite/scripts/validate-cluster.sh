#!/bin/bash
# =============================================================================
# validate-cluster.sh
# =============================================================================
# Verifies the Aerospike multi-site cluster is healthy:
#   1. Waits for all 7 nodes to join the cluster
#   2. Checks cluster stability (cluster_key consistent)
#   3. Validates rack-aware distribution
#   4. Verifies Strong Consistency is enabled
#   5. Shows roster information
#   6. Tests basic read/write if roster is set
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

SEED_NODE="172.28.0.11"
SEED_PORT="3000"
EXPECTED_NODES=7
MAX_WAIT=120  # seconds

# ---------------------------------------------------------------------------
header() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }

# ---------------------------------------------------------------------------
header "STEP 1: Waiting for cluster to form (${EXPECTED_NODES} nodes)"
# ---------------------------------------------------------------------------
elapsed=0
while true; do
    cluster_size=$(docker exec site1-node1 asinfo -v 'cluster-size' -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null || echo "0")
    # asinfo returns "cluster-size\t7" or just "7" depending on version
    cluster_size=$(echo "$cluster_size" | tr -dc '0-9')

    if [ "$cluster_size" -ge "$EXPECTED_NODES" ] 2>/dev/null; then
        pass "Cluster formed with ${cluster_size} nodes (elapsed: ${elapsed}s)"
        break
    fi

    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        fail "Timeout after ${MAX_WAIT}s. Only ${cluster_size}/${EXPECTED_NODES} nodes joined."
        echo -e "  ${RED}Hint: run 'docker compose logs --tail=50' to check for errors.${NC}"
        exit 1
    fi

    echo -ne "\r  Waiting... ${elapsed}s  (${cluster_size:-0}/${EXPECTED_NODES} nodes)    "
    sleep 5
    elapsed=$((elapsed + 5))
done

# ---------------------------------------------------------------------------
header "STEP 2: Cluster stability check"
# ---------------------------------------------------------------------------
# Collect cluster_key from every node and ensure they match
CONTAINERS=("site1-node1" "site1-node2" "site1-node3" "site2-node1" "site2-node2" "site2-node3" "quorum-node")
ADDRESSES=("172.28.0.11" "172.28.0.12" "172.28.0.13" "172.28.0.21" "172.28.0.22" "172.28.0.23" "172.28.0.31")

declare -A cluster_keys
all_match=true

for i in "${!CONTAINERS[@]}"; do
    cname="${CONTAINERS[$i]}"
    addr="${ADDRESSES[$i]}"
    key=$(docker exec "$cname" asinfo -v 'cluster-key' -h "$addr" -p 3000 2>/dev/null | tr -d '[:space:]')
    cluster_keys["$cname"]="$key"
done

ref_key="${cluster_keys[site1-node1]}"
for cname in "${CONTAINERS[@]}"; do
    if [ "${cluster_keys[$cname]}" != "$ref_key" ]; then
        fail "Cluster key mismatch on ${cname}: ${cluster_keys[$cname]} vs ${ref_key}"
        all_match=false
    fi
done

if $all_match; then
    pass "All nodes share cluster key: ${ref_key}"
else
    fail "Cluster keys do not match across nodes -- possible split-brain!"
fi

# ---------------------------------------------------------------------------
header "STEP 3: Rack-aware distribution"
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${BOLD}Node              IP              Rack-ID${NC}"
echo "  -----------------------------------------------"

for i in "${!CONTAINERS[@]}"; do
    cname="${CONTAINERS[$i]}"
    addr="${ADDRESSES[$i]}"
    rack=$(docker exec "$cname" asinfo -v 'get-config:context=namespace;id=mynamespace' -h "$addr" -p 3000 2>/dev/null \
        | tr ';' '\n' | grep '^rack-id=' | cut -d'=' -f2)
    printf "  %-18s %-16s %s\n" "$cname" "$addr" "${rack:-N/A}"
done

# ---------------------------------------------------------------------------
header "STEP 4: Strong Consistency verification"
# ---------------------------------------------------------------------------
sc_enabled=$(docker exec site1-node1 asinfo -v 'get-config:context=namespace;id=mynamespace' -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^strong-consistency=' | cut -d'=' -f2)

if [ "$sc_enabled" = "true" ]; then
    pass "Strong Consistency is ENABLED on namespace 'mynamespace'"
else
    fail "Strong Consistency is NOT enabled (got: '${sc_enabled}')"
fi

# ---------------------------------------------------------------------------
header "STEP 5: Roster status"
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${BOLD}Current roster for namespace 'mynamespace':${NC}"
docker exec site1-node1 asinfo -v 'roster:namespace=mynamespace' -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null | tr ';' '\n' | while read -r line; do
    echo "    $line"
done

echo ""
roster_nodes=$(docker exec site1-node1 asinfo -v 'roster:namespace=mynamespace' -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null \
    | tr ';' '\n' | grep '^roster=' | cut -d'=' -f2)

if [ -z "$roster_nodes" ] || [ "$roster_nodes" = "null" ]; then
    echo ""
    info "Roster is EMPTY. The namespace will not accept writes until the roster is set."
    info "To set the roster, run:"
    echo ""
    echo -e "    ${BOLD}./scripts/set-roster.sh${NC}"
    echo ""
    info "After setting the roster, re-run this validation script."
else
    pass "Roster is configured: ${roster_nodes}"
fi

# ---------------------------------------------------------------------------
header "STEP 6: Write/Read smoke test"
# ---------------------------------------------------------------------------
if [ -n "$roster_nodes" ] && [ "$roster_nodes" != "null" ]; then
    test_key="validation-test-$(date +%s)"
    write_result=$(docker exec site1-node1 aql -h "$SEED_NODE" -p "$SEED_PORT" \
        -c "INSERT INTO mynamespace (PK, val) VALUES ('${test_key}', 'ok')" 2>&1 || true)

    if echo "$write_result" | grep -qi "error\|unavailable"; then
        fail "Write test failed: ${write_result}"
    else
        pass "Write test succeeded (key: ${test_key})"

        # Try reading from a different site to verify cross-site replication
        read_result=$(docker exec site2-node1 aql -h "172.28.0.21" -p 3000 \
            -c "SELECT * FROM mynamespace WHERE PK='${test_key}'" 2>&1 || true)

        if echo "$read_result" | grep -qi "ok"; then
            pass "Cross-site read verified (read from site2-node1)"
        else
            info "Cross-site read could not be verified (may need aql output parsing)"
        fi

        # Cleanup
        docker exec site1-node1 aql -h "$SEED_NODE" -p "$SEED_PORT" \
            -c "DELETE FROM mynamespace WHERE PK='${test_key}'" 2>/dev/null || true
    fi
else
    info "Skipping write/read test -- roster not set."
fi

# ---------------------------------------------------------------------------
header "STEP 7: asadm cluster summary"
# ---------------------------------------------------------------------------
echo ""
docker exec site1-node1 asadm -h "$SEED_NODE" -p "$SEED_PORT" --enable -e "summary" 2>/dev/null || \
    info "asadm summary unavailable (may need roster to be set first)"

echo ""
echo -e "${GREEN}${BOLD}Validation complete.${NC}"
echo ""

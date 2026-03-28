#!/bin/bash
# =============================================================================
# set-roster.sh
# =============================================================================
# Sets the roster for the Strong Consistency namespace 'mynamespace'.
# In SC mode, the namespace will reject all writes until the roster is
# explicitly configured. This script:
#   1. Discovers all node IDs currently in the cluster
#   2. Sets the observed-nodes list as the roster
#   3. Triggers a recluster
#   4. Revives any dead partitions (needed after restart with stale data)
#   5. Reclusters again and waits for cluster stability
# =============================================================================
set -euo pipefail

SEED_NODE="172.28.0.11"
SEED_PORT="3000"
NAMESPACE="mynamespace"
CONTAINER="site1-node1"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${CYAN}=== Setting roster for namespace '${NAMESPACE}' ===${NC}"
echo ""

# Get current roster info
roster_info=$(docker exec "$CONTAINER" asinfo -v "roster:namespace=${NAMESPACE}" -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null)
echo -e "${YELLOW}Current roster info:${NC}"
echo "$roster_info" | tr ':' '\n' | sed 's/^/  /'
echo ""

# Extract observed nodes
observed=$(echo "$roster_info" | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)

if [ -z "$observed" ] || [ "$observed" = "null" ]; then
    echo -e "\033[0;31m[ERROR] No observed nodes found. Is the cluster up?\033[0m"
    exit 1
fi

echo -e "${YELLOW}Observed nodes: ${observed}${NC}"
echo ""

# Set the roster to the observed nodes
echo -e "${CYAN}Setting roster...${NC}"
result=$(docker exec "$CONTAINER" asinfo -v "roster-set:namespace=${NAMESPACE};nodes=${observed}" -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null)
echo "  roster-set result: $result"
echo ""

# Trigger recluster to apply the change
# recluster: must be sent to the principal node. Try all nodes until one accepts.
echo -e "${CYAN}Triggering recluster...${NC}"
ALL_CONTAINERS=("site1-node1" "site1-node2" "site1-node3" "site2-node1" "site2-node2" "site2-node3" "quorum-node")
ALL_IPS=("172.28.0.11" "172.28.0.12" "172.28.0.13" "172.28.0.21" "172.28.0.22" "172.28.0.23" "172.28.0.31")
recluster_done=false
for i in "${!ALL_CONTAINERS[@]}"; do
    node="${ALL_CONTAINERS[$i]}"
    ip="${ALL_IPS[$i]}"
    recluster_result=$(docker exec "$node" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
    if [ "$recluster_result" = "ok" ]; then
        echo "  recluster result: $recluster_result (via $node)"
        recluster_done=true
        break
    fi
done
if ! $recluster_done; then
    echo -e "\033[0;31m[WARN] recluster was not accepted by any node. The cluster may need more time to elect a principal.\033[0m"
fi
echo ""

# Wait a moment for the recluster to propagate
sleep 3

# Revive dead partitions (needed when cluster restarts with stale data files)
echo -e "${CYAN}Reviving dead partitions on all nodes (if any)...${NC}"
for i in "${!ALL_CONTAINERS[@]}"; do
    node="${ALL_CONTAINERS[$i]}"
    ip="${ALL_IPS[$i]}"
    revive_result=$(docker exec "$node" asinfo -v "revive:namespace=${NAMESPACE}" -h "$ip" -p 3000 2>/dev/null || echo "fail")
    echo "  $node: $revive_result"
done
echo ""

# Recluster again after revive to finalize partition assignments
echo -e "${CYAN}Triggering recluster after revive...${NC}"
for i in "${!ALL_CONTAINERS[@]}"; do
    node="${ALL_CONTAINERS[$i]}"
    ip="${ALL_IPS[$i]}"
    recluster_result=$(docker exec "$node" asinfo -v "recluster:" -h "$ip" -p 3000 2>/dev/null || true)
    if [ "$recluster_result" = "ok" ]; then
        echo "  recluster result: $recluster_result (via $node)"
        break
    fi
done
echo ""

# Wait for cluster to stabilize
echo -e "${CYAN}Waiting for cluster to stabilize...${NC}"
for attempt in $(seq 1 12); do
    stable=$(docker exec "$CONTAINER" asinfo -v "cluster-stable:" -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null || echo "unstable")
    if [[ "$stable" != *"unstable"* && "$stable" != *"ERROR"* ]]; then
        echo "  Cluster is stable (key: $stable)"
        break
    fi
    if [ "$attempt" -eq 12 ]; then
        echo -e "\033[1;33m  [WARN] Cluster not yet stable after 60s. It may need more time.\033[0m"
    fi
    sleep 5
done
echo ""

# Verify
echo -e "${CYAN}Verifying roster after set:${NC}"
docker exec "$CONTAINER" asinfo -v "roster:namespace=${NAMESPACE}" -h "$SEED_NODE" -p "$SEED_PORT" 2>/dev/null | tr ':' '\n' | sed 's/^/  /'
echo ""

echo -e "${GREEN}${BOLD}Roster set successfully. The namespace should now accept writes.${NC}"
echo ""

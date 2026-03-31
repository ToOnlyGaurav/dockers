#!/bin/bash
# =============================================================================
# simulate-failures.sh
# =============================================================================
# Interactive menu to simulate failure scenarios for the Aerospike
# Multi-Site Strong Consistency cluster.
#
# Topology:
#   Site 1 (Rack 1, A1-A3, active-rack, all masters)
#   Site 2 (Rack 2, B1-B3, replicas)
#   Quorum (Rack 3, C1, quiesced tie-breaker)
#
#   min-cluster-size = 4  (prevents 3-node minority from accepting writes)
#   replication-factor = 4 (copies spread across Site 1, 2; quorum quiesced)
#   active-rack = 1       (all masters pinned to Site 1)
#
# Categories:
#   NODE FAILURES      - Individual node stops
#   SITE/DC FAILURES   - Multi-node outages by site or DC
#   NETWORK PARTITIONS - iptables-based isolation (no container stop)
#   DEGRADED MODES     - Partial failures within a site
#   RECOVERY           - Bring nodes/sites back, heal partitions
#   OPERATIONS         - Roster, quiesce, rolling restart
#   STATUS             - Cluster health check
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="mynamespace"

# -- Node definitions ---------------------------------------------------------
ALL_CONTAINERS=("site1-node1" "site1-node2" "site1-node3" "site2-node1" "site2-node2" "site2-node3" "quorum-node")
ALL_IPS=(       "172.28.0.11"  "172.28.0.12"  "172.28.0.13"  "172.28.0.21"  "172.28.0.22"  "172.28.0.23"  "172.28.0.31")
ALL_IDS=(       "A1"           "A2"           "A3"           "B1"           "B2"           "B3"           "C1")

SITE1_CONTAINERS=("site1-node1" "site1-node2" "site1-node3")
SITE1_IPS=(       "172.28.0.11"  "172.28.0.12"  "172.28.0.13")

SITE2_CONTAINERS=("site2-node1" "site2-node2" "site2-node3")
SITE2_IPS=(       "172.28.0.21"  "172.28.0.22"  "172.28.0.23")

QUORUM_CONTAINER="quorum-node"
QUORUM_IP="172.28.0.31"

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================

# -- Audit log ----------------------------------------------------------------
LOG_FILE="${PROJECT_DIR}/simulate-failures.log"

# Write a timestamped entry to the audit log
# Usage: audit_log <category> <message>
#   category: SCENARIO | ASINFO | ASADM | IPTABLES | DOCKER | CONFIG | MENU | INFO
audit_log() {
    local category="$1"
    shift
    printf '%s  [%-8s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$category" "$*" >> "$LOG_FILE"
}

# Log a fully copy-pasteable command (docker exec asinfo/asadm/iptables, docker stop/start/restart)
# These lines are prefixed [CMD     ] so you can extract them with:
#   grep '\[CMD' simulate-failures.log
log_cmd() {
    printf '%s  [CMD     ]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Log the result of the most recent CMD entry
log_result() {
    printf '%s  [RESULT  ]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Initialize log session
audit_log "INFO" "========== Session started (PID $$) =========="
echo -e "  ${DIM}Audit log: ${LOG_FILE}${NC}"

header() {
    audit_log "SCENARIO" ">>> $1"
    echo ""
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo ""
}

subheader() {
    echo -e "  ${YELLOW}${BOLD}--- $1 ---${NC}"
}

ok()   { echo -e "  ${GREEN}$1${NC}"; }
warn() { echo -e "  ${YELLOW}$1${NC}"; }
fail() { echo -e "  ${RED}$1${NC}"; }
info() { echo -e "  ${DIM}$1${NC}"; }
note() { echo -e "  ${BOLD}$1${NC}"; }

separator() {
    echo -e "  ${DIM}$(printf '%.0s-' {1..56})${NC}"
}

press_enter() {
    echo ""
    while read -r -t 0.1 _ 2>/dev/null; do :; done
    read -rp "  Press ENTER to return to menu..." _
}

# Return the Docker state of a container ("running", "exited", "stopped", …)
container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "stopped"
}

# Prompt for y/n confirmation; returns 1 if user declines. Usage: confirm_proceed [prompt] || return
confirm_proceed() {
    local prompt="${1:-Proceed? (y/n): }"
    local answer
    while read -r -t 0.1 _ 2>/dev/null; do :; done
    read -rp "  $prompt" answer
    [ "$answer" = "y" ]
}

# Find a running container that actually responds to asinfo
find_running_seed() {
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" = "running" ]; then
            # Verify Aerospike is actually reachable (quick 2s timeout probe)
            local probe
            probe=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "status" \
                -h "${ALL_IPS[$i]}" -p 3000 -t 2000 2>/dev/null || echo "")
            if [ "$probe" = "ok" ]; then
                echo "${ALL_CONTAINERS[$i]}|${ALL_IPS[$i]}"
                return
            fi
        fi
    done
    # Fallback: return first running container even if probe failed (caller handles)
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" = "running" ]; then
            echo "${ALL_CONTAINERS[$i]}|${ALL_IPS[$i]}"
            return
        fi
    done
    echo ""
}

# Reliable asinfo wrapper: adds timeout, retries on the given node, then failover
# Usage: asinfo_cmd <container> <ip> <asinfo-value-string>
# Returns: asinfo output on stdout; returns 1 if all retries/failover exhausted
ASINFO_TIMEOUT=5000   # milliseconds
ASINFO_RETRIES=3
asinfo_cmd() {
    local container="$1" ip="$2" cmd="$3"
    local attempt result

    log_cmd "docker exec $container asinfo -v \"$cmd\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"

    # Try the requested node first (with retries)
    for (( attempt=1; attempt<=ASINFO_RETRIES; attempt++ )); do
        result=$(docker exec "$container" asinfo -v "$cmd" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
        # ERROR:* means server rejected/timed-out; empty means no response
        if [ -n "$result" ] && [[ ! "$result" =~ ^ERROR: ]]; then
            log_result "-> OK (attempt $attempt on $container): ${result:0:200}"
            echo "$result"
            return 0
        fi
        [ "$attempt" -lt "$ASINFO_RETRIES" ] && sleep 1
    done

    # Failover: try every other running node
    for i in "${!ALL_CONTAINERS[@]}"; do
        [ "${ALL_CONTAINERS[$i]}" = "$container" ] && continue
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        [ "$state" != "running" ] && continue
        log_cmd "docker exec ${ALL_CONTAINERS[$i]} asinfo -v \"$cmd\" -h ${ALL_IPS[$i]} -p 3000 -t $ASINFO_TIMEOUT  # failover"
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "$cmd" \
            -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
        if [ -n "$result" ] && [[ ! "$result" =~ ^ERROR: ]]; then
            log_result "-> OK (failover to ${ALL_CONTAINERS[$i]}): ${result:0:200}"
            echo "$result"
            return 0
        fi
    done

    # All nodes failed
    log_result "-> FAILED: all nodes exhausted for cmd='$cmd'"
    echo ""
    return 1
}

# Strip the M<n>| active-rack prefix from roster/observed_nodes values
# e.g. "M1|C1@3,B3@2,B1@2" -> "C1@3,B3@2,B1@2"
strip_roster_prefix() {
    echo "$1" | sed 's/^M[0-9]*|//'
}

# Get cluster_size from statistics (not the broken asinfo -v cluster-size)
get_cluster_size() {
    local container="$1" ip="$2"
    docker exec "$container" asinfo -v "statistics" -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "?"
}

# Get namespace stat
get_ns_stat() {
    local container="$1" ip="$2" stat="$3"
    docker exec "$container" asinfo -v "namespace/${NAMESPACE}" -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep "^${stat}=" | cut -d'=' -f2 || echo "?"
}

# Recluster by trying all running nodes until the principal accepts
do_recluster() {
    local label="${1:-Recluster}"
    audit_log "ASINFO" "do_recluster: $label -- trying all running nodes"
    info "$label: trying all running nodes..."
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" != "running" ]; then
            continue
        fi
        local result
        info "  -> ${ALL_CONTAINERS[$i]}: asinfo -v \"recluster:\""
        log_cmd "docker exec ${ALL_CONTAINERS[$i]} asinfo -v \"recluster:\" -h ${ALL_IPS[$i]} -p 3000 -t $ASINFO_TIMEOUT"
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true)
        log_result "-> ${ALL_CONTAINERS[$i]}: $result"
        if [ "$result" = "ok" ]; then
            audit_log "ASINFO" "  -> $label accepted by ${ALL_CONTAINERS[$i]}"
            ok "$label accepted by ${ALL_CONTAINERS[$i]}"
            return 0
        fi
        info "     (result: ${result:-<empty>} -- not principal, trying next)"
    done
    audit_log "ASINFO" "  -> $label not accepted by any node"
    warn "$label not accepted by any node"
    return 1
}

# Stop containers (accepts array of container names)
stop_nodes() {
    local nodes=("$@")
    for n in "${nodes[@]}"; do
        local state
        state=$(container_state "$n")
        if [ "$state" = "running" ]; then
            log_cmd "docker stop $n"
            echo -e "  ${RED}Stopping $n ...${NC}"
            docker stop "$n" >/dev/null 2>&1
        else
            info "$n already stopped"
        fi
    done
}

# Start containers (accepts array of container names)
start_nodes() {
    local nodes=("$@")
    for n in "${nodes[@]}"; do
        local state
        state=$(container_state "$n")
        if [ "$state" != "running" ]; then
            log_cmd "docker start $n"
            echo -e "  ${GREEN}Starting $n ...${NC}"
            docker start "$n" >/dev/null 2>&1
        else
            info "$n already running"
        fi
    done
}

# Wait for cluster to detect change
wait_detect() {
    local secs="${1:-10}"
    info "Waiting ${secs}s for cluster to detect change..."
    sleep "$secs"
}

# Apply iptables rules to isolate a set of containers from another set
# Usage: isolate_nodes <src_containers_csv> <src_ips_csv> <dst_containers_csv> <dst_ips_csv>
isolate_bidirectional() {
    local -a src_containers dst_containers src_ips dst_ips
    IFS=',' read -ra src_containers <<< "$1"
    IFS=',' read -ra src_ips       <<< "$2"
    IFS=',' read -ra dst_containers <<< "$3"
    IFS=',' read -ra dst_ips       <<< "$4"

    audit_log "IPTABLES" "isolate_bidirectional: src=[${src_containers[*]}] dst=[${dst_containers[*]}]"

    # src -> dst: block
    for sc in "${src_containers[@]}"; do
        for dip in "${dst_ips[@]}"; do
            log_cmd "docker exec $sc iptables -A OUTPUT -d $dip -j DROP"
            docker exec "$sc" iptables -A OUTPUT -d "$dip" -j DROP 2>/dev/null || true
            log_cmd "docker exec $sc iptables -A INPUT -s $dip -j DROP"
            docker exec "$sc" iptables -A INPUT  -s "$dip" -j DROP 2>/dev/null || true
        done
    done
    # dst -> src: block (true bidirectional)
    for dc in "${dst_containers[@]}"; do
        for sip in "${src_ips[@]}"; do
            log_cmd "docker exec $dc iptables -A OUTPUT -d $sip -j DROP"
            docker exec "$dc" iptables -A OUTPUT -d "$sip" -j DROP 2>/dev/null || true
            log_cmd "docker exec $dc iptables -A INPUT -s $sip -j DROP"
            docker exec "$dc" iptables -A INPUT  -s "$sip" -j DROP 2>/dev/null || true
        done
    done
}

# Flush iptables on all running nodes
flush_all_iptables() {
    audit_log "IPTABLES" "flush_all_iptables: flushing rules on all running nodes"
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "$c")
        if [ "$state" = "running" ]; then
            log_cmd "docker exec $c iptables -F"
            docker exec "$c" iptables -F 2>/dev/null || true
        fi
    done
}

# Print expected outcome box
expected() {
    echo ""
    note "Expected outcome:"
    while IFS= read -r line; do
        echo -e "  ${DIM}  $line${NC}"
    done <<< "$@"
    echo ""
}

# =============================================================================
# Status check
# =============================================================================
status_check() {
    header "Cluster Status"

    subheader "Container states"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}"
        local id="${ALL_IDS[$i]}"
        local state health
        state=$(container_state "$c")
        health=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "-")
        if [ "$state" = "running" ]; then
            echo -e "    ${GREEN}[RUNNING]${NC}  ${BOLD}$id${NC}  $c  ($health)"
        else
            local state_upper
            state_upper=$(echo "$state" | tr '[:lower:]' '[:upper:]')
            echo -e "    ${RED}[${state_upper}]${NC}  ${BOLD}$id${NC}  $c"
        fi
    done

    echo ""
    local seed_info
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then
        fail "No running nodes found!"
        return
    fi
    local seed_c seed_ip
    seed_c="${seed_info%%|*}"
    seed_ip="${seed_info##*|}"

    subheader "Cluster info (from $seed_c)"
    local cs
    cs=$(get_cluster_size "$seed_c" "$seed_ip")
    echo -e "    Cluster size: ${BOLD}$cs${NC}"

    local roster_info
    log_cmd "docker exec $seed_c asinfo -v \"roster:namespace=${NAMESPACE}\" -h $seed_ip -p 3000 -t $ASINFO_TIMEOUT"
    roster_info=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
    local roster_val
    roster_val=$(echo "$roster_info" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    echo -e "    Roster:       ${BOLD}$roster_val${NC}"

    local _ns_seed rf ar nq sw
    log_cmd "docker exec $seed_c asinfo -v \"namespace/${NAMESPACE}\" -h $seed_ip -p 3000 -t $ASINFO_TIMEOUT"
    _ns_seed=$(docker exec "$seed_c" asinfo -v "namespace/${NAMESPACE}" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
    rf=$(echo "$_ns_seed" | grep '^effective_replication_factor=' | cut -d'=' -f2)
    ar=$(echo "$_ns_seed" | grep '^active-rack='                  | cut -d'=' -f2)
    nq=$(echo "$_ns_seed" | grep '^nodes_quiesced='               | cut -d'=' -f2)
    sw=$(echo "$_ns_seed" | grep '^stop_writes='                  | cut -d'=' -f2)
    echo -e "    RF: ${BOLD}$rf${NC}  Active-rack: ${BOLD}R${ar}${NC}  Quiesced: ${BOLD}$nq${NC}  stop_writes: ${BOLD}$sw${NC}"

    echo ""
    subheader "Per-node partition ownership"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" ip="${ALL_IPS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then
            echo -e "    ${RED}$id  DOWN${NC}"
            continue
        fi
        local _ns_node m_obj p_obj objects sw_node mig_tx mig_rx
        log_cmd "docker exec $c asinfo -v \"namespace/${NAMESPACE}\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        _ns_node=$(docker exec "$c" asinfo -v "namespace/${NAMESPACE}" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
        m_obj=$(echo "$_ns_node"  | grep '^master_objects='                    | cut -d'=' -f2)
        p_obj=$(echo "$_ns_node"  | grep '^prole_objects='                     | cut -d'=' -f2)
        objects=$(echo "$_ns_node" | grep '^objects='                          | cut -d'=' -f2)
        mig_tx=$(echo "$_ns_node" | grep '^migrate_tx_partitions_remaining='   | cut -d'=' -f2)
        mig_rx=$(echo "$_ns_node" | grep '^migrate_rx_partitions_remaining='   | cut -d'=' -f2)
        sw_node=$(echo "$_ns_node" | grep '^stop_writes='                      | cut -d'=' -f2)
        local sw_tag=""
        if [ "$sw_node" = "true" ]; then
            local q
            q=$(echo "$_ns_node" | grep '^effective_is_quiesced=' | cut -d'=' -f2)
            if [ "$q" = "true" ]; then
                sw_tag=" ${DIM}(quiesced)${NC}"
            else
                sw_tag=" ${RED}STOP-WRITES${NC}"
            fi
        fi
        local mig_tag=""
        local mig_total=$(( ${mig_tx:-0} + ${mig_rx:-0} ))
        if [ "$mig_total" -gt 0 ] 2>/dev/null; then
            mig_tag=" ${CYAN}Mig:${mig_total}${NC}"
        fi
        echo -e "    ${BOLD}$id${NC}  MObj:$m_obj PObj:$p_obj Tot:$objects$mig_tag$sw_tag"
    done

    echo ""
    subheader "iptables rules (non-empty)"
    local has_rules=false
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then continue; fi
        local count
        count=$(docker exec "$c" iptables -L -n 2>/dev/null | grep -c "DROP" || true)
        count=$(echo "$count" | tr -d '[:space:]')
        count=${count:-0}
        if [ "$count" -gt 0 ] 2>/dev/null; then
            echo -e "    ${YELLOW}$id ($c): $count DROP rules active${NC}"
            has_rules=true
        fi
    done
    if ! $has_rules; then
        info "  No iptables DROP rules on any node"
    fi
    echo ""
}

# =============================================================================
# NODE FAILURES
# =============================================================================

scenario_single_node() {
    header "Single Node Failure"
    echo "  Pick a node to stop:"
    echo ""
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        local tag=""
        if [ "$state" != "running" ]; then tag=" ${RED}(already stopped)${NC}"; fi
        echo -e "    $((i+1)). ${BOLD}${ALL_IDS[$i]}${NC}  ${ALL_CONTAINERS[$i]}$tag"
    done
    echo ""
    read -rp "  Select node (1-7): " choice
    if [[ ! "$choice" =~ ^[1-7]$ ]]; then fail "Invalid selection"; return; fi
    local idx=$((choice - 1))
    local node="${ALL_CONTAINERS[$idx]}" id="${ALL_IDS[$idx]}"

    echo ""
    stop_nodes "$node"
    wait_detect 10
    status_check

    expected "Cluster size drops to 6. If the stopped node held masters (Site 1),
those partitions become unavailable until migration or roster change.
Cluster stays operational (6 >= min-cluster-size=4).
Recovery: use R1 (recover all) or R4 (full recovery)."
}

scenario_tiebreaker_failure() {
    header "Tie-Breaker (Quorum) Node Failure"
    echo "  This stops C1 (${QUORUM_IP}), the quiesced quorum node."
    echo "  C1 holds 0 partitions but contributes to quorum for split-brain prevention."
    echo ""
    confirm_proceed || return

    stop_nodes "$QUORUM_CONTAINER"
    wait_detect 10
    status_check

    expected "Cluster size drops to 6 (still >= 4, operational).
No data loss -- C1 held 0 partitions.
DANGER: If a full site now fails (3 nodes), only 3 remain (< min-cluster-size=4).
Losing a full site will drop below 4 and stop writes.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

scenario_active_rack_node() {
    header "Active-Rack Node Failure (Master Node)"
    echo "  Site 1 (Rack 1) holds ALL master partitions via active-rack=1."
    echo "  Stopping one Site 1 node removes ~1365 masters from service."
    echo ""
    echo "  Pick a Site 1 node:"
    for i in "${!SITE1_CONTAINERS[@]}"; do
        echo "    $((i+1)). ${ALL_IDS[$i]}  ${SITE1_CONTAINERS[$i]}"
    done
    echo ""
    read -rp "  Select (1-3): " choice
    if [[ ! "$choice" =~ ^[1-3]$ ]]; then fail "Invalid selection"; return; fi
    local idx=$((choice - 1))
    local node="${SITE1_CONTAINERS[$idx]}"

    stop_nodes "$node"
    wait_detect 10
    status_check

    expected "~1365 master partitions lose their master. In SC mode these partitions
become unavailable for both reads AND writes until the master returns.
(linearize-read is mandatory in SC -- replicas cannot serve reads.)
Remaining Site 1 nodes still serve their ~2731 masters normally.
Cluster size drops to 6 (>= min-cluster-size=4, operational).
Recovery: use R2 (recover specific node) or R1 (recover all)."
}

# =============================================================================
# SITE/DC FAILURES
# =============================================================================

scenario_site1_failure() {
    header "Site 1 Failure (Active-Rack -- All Masters Lost)"
    echo "  Stopping ALL 3 nodes in Site 1 (A1, A2, A3)."
    echo "  This removes the entire active-rack where all 4096 masters reside."
    echo ""
    echo -e "  ${RED}${BOLD}WARNING: All master partitions will be lost!${NC}"
    echo "  Cluster: Site 2 (3) + Quorum (1) = 4 nodes (= min-cluster-size=4)"
    echo ""
    confirm_proceed || return

    stop_nodes "${SITE1_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 4 (B1, B2, B3, C1). Meets min-cluster-size=4.
ALL 4096 master partitions are unavailable (they were on Site 1).
Namespace enters stop_writes=true because masters are gone.
Site 2 holds replicas but cannot promote them without roster change.
Recovery: use R1 (recover all) or R4 (full recovery) to bring Site 1 back.
For permanent Site 1 loss, use O1 (roster update) to remove Site 1 nodes."
}

scenario_site2_failure() {
    header "Site 2 Failure (Replica Site)"
    echo "  Stopping ALL 3 nodes in Site 2 (B1, B2, B3)."
    echo "  Site 2 holds only replicas (active-rack=1 puts all masters on Site 1)."
    echo ""
    echo "  Cluster: Site 1 (3) + Quorum (1) = 4 nodes (= min-cluster-size=4)"
    echo ""
    confirm_proceed || return

    stop_nodes "${SITE2_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 4 (A1, A2, A3, C1). Meets min-cluster-size=4.
All masters still on Site 1 -- reads and writes continue normally.
Replication factor effectively drops: Site 2 replicas are gone.
Data is less protected until Site 2 recovers.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

scenario_dc1_failure() {
    header "DC1 Failure (Site 1 + Quorum Node)"
    echo "  Stopping Site 1 (A1-A3, all masters) AND the Quorum node (C1)."
    echo "  Stopping 4 nodes: site1-node1, site1-node2, site1-node3, quorum-node."
    echo ""
    echo "  Cluster: Site 2 (3) = 3 nodes (< min-cluster-size=4, cluster STOPS)"
    echo ""
    confirm_proceed || return

    stop_nodes "${SITE1_CONTAINERS[@]}" "$QUORUM_CONTAINER"
    wait_detect 15
    status_check

    expected "Cluster size = 3 (B1, B2, B3). Below min-cluster-size=4 -- DANGEROUS.
ALL 4096 master partitions are unavailable (were on Site 1).
Namespace enters stop_writes=true -- masters gone, cluster halted (below quorum).
Site 2 holds replicas but cluster is below minimum size and cannot form.
Recovery: use R1 (recover all) or R4 (full recovery).
For permanent Site 1 loss: use O1 (roster update) to remove Site 1 nodes, O4 for active-rack."
}

scenario_dc2_failure() {
    header "DC2 Failure (Site 2 Only)"
    echo "  DC2 = Site 2 (B1-B3, replicas only)."
    echo "  Stopping 3 nodes: site2-node1, site2-node2, site2-node3."
    echo ""
    echo "  Cluster: Site 1 (3) + Quorum (1) = 4 (= min-cluster-size=4)"
    echo ""
    confirm_proceed || return

    stop_nodes "${SITE2_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Same as Site 2 failure. Cluster size = 4, operational.
Masters on Site 1 unaffected. Writes continue.
Site 2 replica redundancy lost until DC2 recovers.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

# =============================================================================
# NETWORK PARTITIONS (iptables -- nodes stay running but can't communicate)
# =============================================================================

scenario_split_brain() {
    header "SPLIT BRAIN SIMULATION: DC1 vs DC2 Forced Write Divergence"
    echo ""
    echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║  DESTRUCTIVE EDUCATIONAL SCENARIO -- DATA WILL DIVERGE      ║${NC}"
    echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This scenario deliberately creates a split-brain condition by:"
    echo "    1. Network-partitioning DC1 (Site1+Quorum) from DC2 (Site2)"
    echo "    2. Bypassing SC roster/min-cluster-size guards on DC2 via manual"
    echo "       roster-set (simulating an operator emergency failover gone wrong)"
    echo "    3. Writing to BOTH clusters independently, producing divergent data"
    echo ""
    echo "  Architecture under test:"
    echo "    DC1 [A1,A2,A3 (Site1) + C1 (Quorum)] = 4 nodes -- has all masters"
    echo "    DC2 [B1,B2,B3 (Site2)]                = 3 nodes -- has all replicas"
    echo ""
    echo "  Why SC normally prevents this:"
    echo "    min-cluster-size and the committed roster block a minority partition"
    echo "    from forming an independent write-accepting cluster."
    echo "    This scenario shows what happens when those safeguards are bypassed."
    echo ""
    echo -e "  ${YELLOW}Recovery after this scenario requires R4 (full recovery) and will"
    echo -e "  PERMANENTLY LOSE whichever side's writes are not in the winning roster.${NC}"
    echo ""
    confirm_proceed "Proceed with split-brain simulation? (y/n): " || return

    # =========================================================================
    # PHASE 1: Verify pre-conditions and write a baseline record
    # =========================================================================
    echo ""
    subheader "PHASE 1: Pre-flight checks and baseline write"

    # Verify all 7 nodes are running
    local missing=()
    for c in "${ALL_CONTAINERS[@]}"; do
        [ "$(container_state "$c")" != "running" ] && missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        fail "Some nodes are not running: ${missing[*]}"
        fail "Run R4 (full recovery) first to bring up all 7 nodes."
        return
    fi
    ok "All 7 nodes running"

    # Verify no pre-existing iptables partitions
    local has_rules=false
    for c in "${ALL_CONTAINERS[@]}"; do
        local cnt
        cnt=$(docker exec "$c" iptables -L -n 2>/dev/null | grep -c "DROP" || true)
        if [ "${cnt:-0}" -gt 0 ]; then has_rules=true; break; fi
    done
    if $has_rules; then
        warn "Pre-existing iptables DROP rules detected. Flushing first..."
        flush_all_iptables
        ok "iptables flushed"
    else
        ok "No pre-existing iptables rules"
    fi

    # Capture current min-cluster-size (so we know what to restore)
    local dc1_seed_c="site1-node1"
    local dc1_seed_ip="172.28.0.11"
    local dc2_seed_c="site2-node1"
    local dc2_seed_ip="172.28.0.21"

    local orig_mcs
    orig_mcs=$(docker exec "$dc1_seed_c" asinfo \
        -v "get-config:context=service" \
        -h "$dc1_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep '^min-cluster-size=' | cut -d'=' -f2 || echo "unknown")
    info "Current min-cluster-size: ${orig_mcs}"

    # Capture current roster (to know what to restore)
    local orig_roster
    orig_roster=$(docker exec "$dc1_seed_c" asinfo \
        -v "roster:namespace=${NAMESPACE}" \
        -h "$dc1_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2 || echo "")
    info "Current roster:           ${orig_roster}"

    # Write a baseline record visible to both sides before partition
    local baseline_key="_sb_baseline_$(date +%s)"
    info "Writing baseline record (PK=${baseline_key}) before partition..."
    local bw_result
    bw_result=$(docker exec "$dc1_seed_c" aql \
        -h "$dc1_seed_ip" -p 3000 \
        -c "INSERT INTO ${NAMESPACE}.splitbrain (PK, written_by, ts) VALUES ('${baseline_key}', 'pre_partition', 1)" 2>&1 || echo "FAIL")
    if echo "$bw_result" | grep -q "OK"; then
        ok "Baseline record written (${baseline_key}) -- both sides should see it"
    else
        warn "Baseline write failed: $(echo "$bw_result" | tail -1)"
        warn "Cluster may have stop_writes. Continuing anyway..."
    fi

    # =========================================================================
    # PHASE 2: Network partition -- sever DC1 <-> DC2 link
    # =========================================================================
    echo ""
    subheader "PHASE 2: Severing DC1 <-> DC2 network link (iptables DROP)"
    echo ""
    echo "  Rules to apply:"
    echo "    Site1 (A1-A3) <--> Site2 (B1-B3)  : BLOCKED"
    echo "    Quorum (C1)   <--> Site2 (B1-B3)  : BLOCKED"
    echo "    Site1 (A1-A3) <--> Quorum (C1)    : ALLOWED  (same DC1)"
    echo ""
    echo "  Expected sub-clusters after heartbeat timeout (~2.5s * 10 = 25s):"
    echo "    DC1: [A1,A2,A3,C1] = 4 nodes -- meets min-cluster-size, MASTERS INTACT"
    echo "    DC2: [B1,B2,B3]    = 3 nodes -- STOPS writes (quorum violated)"
    echo ""
    confirm_proceed "Apply partition now? (y/n): " || return

    # Block Site1 <-> Site2
    local s1c s1i s2c s2i
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    isolate_bidirectional "$s1c" "$s1i" "$s2c" "$s2i"
    ok "Site1 <-> Site2 traffic BLOCKED"

    # Block Quorum <-> Site2
    isolate_bidirectional "$QUORUM_CONTAINER" "$QUORUM_IP" "$s2c" "$s2i"
    ok "Quorum (C1) <-> Site2 traffic BLOCKED"
    ok "Site1 <-> Quorum (C1) traffic UNBLOCKED (same DC1)"

    info "Waiting 30s for heartbeat timeout and sub-cluster formation..."
    sleep 30

    # Show DC1 perspective
    echo ""
    note "DC1 cluster state (from ${dc1_seed_c}):"
    local dc1_cs dc1_sw dc1_unav
    dc1_cs=$(get_cluster_size "$dc1_seed_c" "$dc1_seed_ip")
    dc1_sw=$(get_ns_stat "$dc1_seed_c" "$dc1_seed_ip" "stop_writes")
    dc1_unav=$(get_ns_stat "$dc1_seed_c" "$dc1_seed_ip" "unavailable_partitions")
    echo -e "    cluster_size=${BOLD}${dc1_cs}${NC}  stop_writes=${BOLD}${dc1_sw:-?}${NC}  unavailable_partitions=${BOLD}${dc1_unav:-?}${NC}"
    if [ "${dc1_sw:-1}" = "false" ] || [ "${dc1_sw:-1}" = "0" ]; then
        ok "DC1: OPERATIONAL -- masters intact, accepting writes"
    else
        warn "DC1: stop_writes=true (may need more time to re-elect)"
    fi

    # Show DC2 perspective
    note "DC2 cluster state (from ${dc2_seed_c}):"
    local dc2_cs dc2_sw dc2_unav
    dc2_cs=$(get_cluster_size "$dc2_seed_c" "$dc2_seed_ip")
    dc2_sw=$(get_ns_stat "$dc2_seed_c" "$dc2_seed_ip" "stop_writes")
    dc2_unav=$(get_ns_stat "$dc2_seed_c" "$dc2_seed_ip" "unavailable_partitions")
    echo -e "    cluster_size=${BOLD}${dc2_cs}${NC}  stop_writes=${BOLD}${dc2_sw:-?}${NC}  unavailable_partitions=${BOLD}${dc2_unav:-?}${NC}"
    if [ "${dc2_sw:-0}" = "true" ] || [ "${dc2_sw:-0}" = "1" ]; then
        ok "DC2: stop_writes=true -- SC protections working as designed"
    else
        warn "DC2: stop_writes unexpectedly false (may need more time)"
    fi
    echo ""
    info "Aerospike SC is working correctly: DC2 minority is blocked from writing."
    info "Now we will simulate an operator bypassing these protections on DC2..."

    # =========================================================================
    # PHASE 3: Force DC2 active -- operator bypasses SC guards (THE MISTAKE)
    # =========================================================================
    echo ""
    subheader "PHASE 3: OPERATOR MISTAKE -- Forcing DC2 active via manual roster override"
    echo ""
    echo -e "  ${RED}${BOLD}WARNING: You are about to simulate an incorrect emergency procedure.${NC}"
    echo "  In a real incident, an operator might do this to 'recover' DC2 quickly"
    echo "  without knowing DC1 is still alive and accepting writes."
    echo ""
    echo "  Steps to be executed on DC2 (B1-B3) ONLY:"
    echo "    a) Lower min-cluster-size to 2  (bypass quorum check)"
    echo "    b) Set active-rack=2            (promote DC2 replicas to masters)"
    echo "    c) roster-set to B1-B3 only     (detach from DC1 roster)"
    echo "    d) Recluster + revive           (unlock dead partitions)"
    echo ""
    echo -e "  ${RED}After this, BOTH DC1 and DC2 will be writing to the same namespace independently.${NC}"
    echo -e "  ${RED}THIS IS THE SPLIT-BRAIN CONDITION.${NC}"
    echo ""
    confirm_proceed "Execute the operator mistake on DC2? (y/n): " || return

    # Step a: Lower min-cluster-size to 2 on DC2 nodes
    info "Step a: Lowering min-cluster-size to 2 on DC2 nodes..."
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local c="${SITE2_CONTAINERS[$i]}" ip="${SITE2_IPS[$i]}"
        local r
        log_cmd "docker exec $c asinfo -v \"set-config:context=service;min-cluster-size=2\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        r=$(docker exec "$c" asinfo \
            -v "set-config:context=service;min-cluster-size=2" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
        log_result "-> $r"
        [ "$r" = "ok" ] && ok "$c: min-cluster-size=2" || warn "$c: returned '$r'"
    done

    # Step b: Set active-rack=2 on DC2 nodes
    info "Step b: Setting active-rack=2 on DC2 nodes..."
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local c="${SITE2_CONTAINERS[$i]}" ip="${SITE2_IPS[$i]}"
        local r
        log_cmd "docker exec $c asinfo -v \"set-config:context=namespace;id=${NAMESPACE};active-rack=2\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        r=$(docker exec "$c" asinfo \
            -v "set-config:context=namespace;id=${NAMESPACE};active-rack=2" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
        log_result "-> $r"
        [ "$r" = "ok" ] && ok "$c: active-rack=2" || warn "$c: returned '$r'"
    done

    # Pre-recluster on DC2 so observed_nodes gets M2| prefix
    info "Pre-recluster on DC2 to refresh observed_nodes..."
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local r
        r=$(docker exec "${SITE2_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${SITE2_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true)
        [ "$r" = "ok" ] && { ok "Recluster accepted by ${SITE2_CONTAINERS[$i]}"; break; }
    done
    sleep 8

    # Step c: Get observed_nodes from DC2, build Site2-only roster
    info "Step c: Building and setting DC2-only roster (B1-B3, Rack 2)..."
    local dc2_observed dc2_roster_raw dc2_stripped dc2_filtered new_dc2_roster
    dc2_roster_raw=$(docker exec "$dc2_seed_c" asinfo \
        -v "roster:namespace=${NAMESPACE}" \
        -h "$dc2_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
    dc2_observed=$(echo "$dc2_roster_raw" | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
    info "DC2 observed_nodes: ${dc2_observed:-<empty>}"

    if [ -z "$dc2_observed" ] || [ "$dc2_observed" = "null" ]; then
        warn "observed_nodes empty on DC2. Retrying after 15s..."
        sleep 15
        dc2_roster_raw=$(docker exec "$dc2_seed_c" asinfo \
            -v "roster:namespace=${NAMESPACE}" \
            -h "$dc2_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
        dc2_observed=$(echo "$dc2_roster_raw" | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
        info "DC2 observed_nodes (retry): ${dc2_observed:-<empty>}"
    fi

    dc2_stripped=$(strip_roster_prefix "${dc2_observed:-}")
    # Keep only Rack 2 nodes (@2 suffix)
    dc2_filtered=$(echo "$dc2_stripped" | tr ',' '\n' | grep '@2$' | paste -sd',' -)

    if [ -z "$dc2_filtered" ]; then
        # Fall back to hardcoded DC2 node IDs if observed_nodes is not helpful
        warn "No @2 nodes found in observed_nodes -- using hardcoded B1-B3 node IDs"
        # Try to get node IDs from DC2 service info
        local b1_id b2_id b3_id
        b1_id=$(docker exec "site2-node1" asinfo -v "service" -h "172.28.0.21" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | grep -o 'node-id=[^;]*' | cut -d'=' -f2 || echo "B1")
        b2_id=$(docker exec "site2-node2" asinfo -v "service" -h "172.28.0.22" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | grep -o 'node-id=[^;]*' | cut -d'=' -f2 || echo "B2")
        b3_id=$(docker exec "site2-node3" asinfo -v "service" -h "172.28.0.23" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | grep -o 'node-id=[^;]*' | cut -d'=' -f2 || echo "B3")
        dc2_filtered="${b1_id}@2,${b2_id}@2,${b3_id}@2"
        info "Using fallback IDs: $dc2_filtered"
    fi

    new_dc2_roster="M2|${dc2_filtered}"
    info "New DC2 roster: $new_dc2_roster"

    log_cmd "docker exec $dc2_seed_c asinfo -v \"roster-set:namespace=${NAMESPACE};nodes=${new_dc2_roster}\" -h $dc2_seed_ip -p 3000 -t $ASINFO_TIMEOUT"
    local rs_result
    rs_result=$(docker exec "$dc2_seed_c" asinfo \
        -v "roster-set:namespace=${NAMESPACE};nodes=${new_dc2_roster}" \
        -h "$dc2_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
    log_result "-> $rs_result"
    if [ "$rs_result" = "ok" ]; then
        ok "DC2 roster set to ${new_dc2_roster}"
    else
        fail "roster-set on DC2 failed: $rs_result"
        warn "Partition may need more time. Wait and retry, or continue to see partial split-brain."
    fi

    # Step d: Recluster on DC2 only (loop Site2 nodes)
    info "Step d: Reclustering DC2 sub-cluster..."
    local dc2_recluster_ok=false
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local r
        r=$(docker exec "${SITE2_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${SITE2_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true)
        if [ "$r" = "ok" ]; then
            ok "DC2 recluster accepted by ${SITE2_CONTAINERS[$i]}"
            dc2_recluster_ok=true
            break
        fi
    done
    $dc2_recluster_ok || warn "DC2 recluster not accepted -- may need more time"
    sleep 10

    # Revive dead partitions on DC2 only
    info "Reviving dead partitions on DC2 (B1-B3)..."
    local dc2_revived=0
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local r
        r=$(docker exec "${SITE2_CONTAINERS[$i]}" asinfo \
            -v "revive:namespace=${NAMESPACE}" \
            -h "${SITE2_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "error")
        [ "$r" = "ok" ] && dc2_revived=$((dc2_revived + 1))
    done
    [ "$dc2_revived" -gt 0 ] && ok "Revived dead partitions on $dc2_revived DC2 node(s)"

    # Final DC2 recluster after revive
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local r
        r=$(docker exec "${SITE2_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${SITE2_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true)
        if [ "$r" = "ok" ]; then
            ok "DC2 final recluster accepted by ${SITE2_CONTAINERS[$i]}"
            break
        fi
    done
    sleep 8

    # Verify DC2 is now accepting writes
    dc2_sw=$(get_ns_stat "$dc2_seed_c" "$dc2_seed_ip" "stop_writes")
    dc2_cs=$(get_cluster_size "$dc2_seed_c" "$dc2_seed_ip")
    echo ""
    note "DC2 state after forced activation:"
    echo -e "    cluster_size=${BOLD}${dc2_cs}${NC}  stop_writes=${BOLD}${dc2_sw:-?}${NC}"
    if [ "${dc2_sw:-1}" = "false" ] || [ "${dc2_sw:-1}" = "0" ]; then
        echo -e "  ${RED}${BOLD}>>> DC2 IS NOW ACCEPTING WRITES -- SPLIT BRAIN IS ACTIVE <<<${NC}"
    else
        warn "DC2 still has stop_writes=true. Partition or roster may need more time."
        warn "The split-brain may still occur. Continue to see the write divergence attempt."
    fi

    # =========================================================================
    # PHASE 4: Write divergent data to both clusters
    # =========================================================================
    echo ""
    subheader "PHASE 4: Writing divergent data to BOTH clusters simultaneously"
    echo ""
    echo "  Both DC1 and DC2 now believe they are the authoritative cluster."
    echo "  We will write different values to the SAME key from each side."
    echo ""

    local conflict_key="_sb_conflict_$(date +%s)"
    local dc1_only_key="_sb_dc1_only_$(date +%s)"
    local dc2_only_key="_sb_dc2_only_$(date +%s)"

    # Write DC1-exclusive record
    info "Writing DC1-exclusive record (${dc1_only_key}) via site1-node1..."
    local dc1_excl_result
    dc1_excl_result=$(docker exec "$dc1_seed_c" aql \
        -h "$dc1_seed_ip" -p 3000 \
        -c "INSERT INTO ${NAMESPACE}.splitbrain (PK, written_by, cluster, ts) VALUES ('${dc1_only_key}', 'dc1', 'site1_only', 1)" 2>&1 || echo "FAIL")
    if echo "$dc1_excl_result" | grep -q "OK"; then
        ok "DC1 exclusive write: ${dc1_only_key} -- SUCCESS"
    else
        warn "DC1 exclusive write failed: $(echo "$dc1_excl_result" | tail -1)"
    fi

    # Write DC2-exclusive record
    info "Writing DC2-exclusive record (${dc2_only_key}) via site2-node1..."
    local dc2_excl_result
    dc2_excl_result=$(docker exec "$dc2_seed_c" aql \
        -h "$dc2_seed_ip" -p 3000 \
        -c "INSERT INTO ${NAMESPACE}.splitbrain (PK, written_by, cluster, ts) VALUES ('${dc2_only_key}', 'dc2', 'site2_only', 1)" 2>&1 || echo "FAIL")
    if echo "$dc2_excl_result" | grep -q "OK"; then
        ok "DC2 exclusive write: ${dc2_only_key} -- SUCCESS"
    else
        warn "DC2 exclusive write failed: $(echo "$dc2_excl_result" | tail -1)"
    fi

    # Write SAME key with DIFFERENT values to both clusters
    info "Writing CONFLICT KEY (${conflict_key}) to DC1 with value 'written_from_dc1'..."
    local dc1_conf_result
    dc1_conf_result=$(docker exec "$dc1_seed_c" aql \
        -h "$dc1_seed_ip" -p 3000 \
        -c "INSERT INTO ${NAMESPACE}.splitbrain (PK, written_by, value) VALUES ('${conflict_key}', 'dc1', 'written_from_dc1')" 2>&1 || echo "FAIL")
    if echo "$dc1_conf_result" | grep -q "OK"; then
        ok "DC1 conflict write: ${conflict_key} = 'written_from_dc1' -- SUCCESS"
    else
        warn "DC1 conflict write failed: $(echo "$dc1_conf_result" | tail -1)"
    fi

    info "Writing CONFLICT KEY (${conflict_key}) to DC2 with value 'written_from_dc2'..."
    local dc2_conf_result
    dc2_conf_result=$(docker exec "$dc2_seed_c" aql \
        -h "$dc2_seed_ip" -p 3000 \
        -c "INSERT INTO ${NAMESPACE}.splitbrain (PK, written_by, value) VALUES ('${conflict_key}', 'dc2', 'written_from_dc2')" 2>&1 || echo "FAIL")
    if echo "$dc2_conf_result" | grep -q "OK"; then
        ok "DC2 conflict write: ${conflict_key} = 'written_from_dc2' -- SUCCESS"
    else
        warn "DC2 conflict write failed: $(echo "$dc2_conf_result" | tail -1)"
    fi

    # Read the conflict key back from both sides
    echo ""
    note "Reading conflict key '${conflict_key}' from EACH CLUSTER:"
    info "  DC1 reads (via site1-node1):"
    docker exec "$dc1_seed_c" aql \
        -h "$dc1_seed_ip" -p 3000 \
        -c "SELECT * FROM ${NAMESPACE}.splitbrain WHERE PK = '${conflict_key}'" 2>&1 \
        | sed 's/^/      /'
    info "  DC2 reads (via site2-node1):"
    docker exec "$dc2_seed_c" aql \
        -h "$dc2_seed_ip" -p 3000 \
        -c "SELECT * FROM ${NAMESPACE}.splitbrain WHERE PK = '${conflict_key}'" 2>&1 \
        | sed 's/^/      /'

    # Confirm DC1 cannot see DC2's exclusive record and vice versa
    echo ""
    note "Cross-cluster read isolation (each cluster only sees its own writes):"
    info "  DC1 trying to read DC2's exclusive key (${dc2_only_key}):"
    docker exec "$dc1_seed_c" aql \
        -h "$dc1_seed_ip" -p 3000 \
        -c "SELECT * FROM ${NAMESPACE}.splitbrain WHERE PK = '${dc2_only_key}'" 2>&1 \
        | grep -v "^$\|^Aerospike\|^Copyright\|^User\|^Version" | sed 's/^/      /' | head -5
    info "  DC2 trying to read DC1's exclusive key (${dc1_only_key}):"
    docker exec "$dc2_seed_c" aql \
        -h "$dc2_seed_ip" -p 3000 \
        -c "SELECT * FROM ${NAMESPACE}.splitbrain WHERE PK = '${dc1_only_key}'" 2>&1 \
        | grep -v "^$\|^Aerospike\|^Copyright\|^User\|^Version" | sed 's/^/      /' | head -5

    # =========================================================================
    # PHASE 5: Show the diverged cluster state
    # =========================================================================
    echo ""
    subheader "PHASE 5: Cluster state -- both sides think they are authoritative"

    note "DC1 (Site1 + Quorum) perspective:"
    local _dc1_ns
    _dc1_ns=$(docker exec "$dc1_seed_c" asinfo -v "namespace/${NAMESPACE}" \
        -h "$dc1_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
    local _dc1_rf _dc1_ar _dc1_sw _dc1_cs _dc1_roster
    _dc1_cs=$(get_cluster_size "$dc1_seed_c" "$dc1_seed_ip")
    _dc1_rf=$(echo "$_dc1_ns" | grep '^effective_replication_factor=' | cut -d'=' -f2)
    _dc1_ar=$(echo "$_dc1_ns" | grep '^active-rack='                  | cut -d'=' -f2)
    _dc1_sw=$(echo "$_dc1_ns" | grep '^stop_writes='                  | cut -d'=' -f2)
    _dc1_roster=$(docker exec "$dc1_seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$dc1_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    echo -e "    cluster_size: ${BOLD}${_dc1_cs}${NC}"
    echo -e "    stop_writes:  ${BOLD}${_dc1_sw:-?}${NC}"
    echo -e "    active-rack:  ${BOLD}R${_dc1_ar:-?}${NC}"
    echo -e "    eff. RF:      ${BOLD}${_dc1_rf:-?}${NC}"
    echo -e "    roster:       ${BOLD}${_dc1_roster:-?}${NC}"

    echo ""
    note "DC2 (Site2 only) perspective:"
    local _dc2_ns
    _dc2_ns=$(docker exec "$dc2_seed_c" asinfo -v "namespace/${NAMESPACE}" \
        -h "$dc2_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
    local _dc2_rf _dc2_ar _dc2_sw _dc2_cs _dc2_roster
    _dc2_cs=$(get_cluster_size "$dc2_seed_c" "$dc2_seed_ip")
    _dc2_rf=$(echo "$_dc2_ns" | grep '^effective_replication_factor=' | cut -d'=' -f2)
    _dc2_ar=$(echo "$_dc2_ns" | grep '^active-rack='                  | cut -d'=' -f2)
    _dc2_sw=$(echo "$_dc2_ns" | grep '^stop_writes='                  | cut -d'=' -f2)
    _dc2_roster=$(docker exec "$dc2_seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$dc2_seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    echo -e "    cluster_size: ${BOLD}${_dc2_cs}${NC}"
    echo -e "    stop_writes:  ${BOLD}${_dc2_sw:-?}${NC}"
    echo -e "    active-rack:  ${BOLD}R${_dc2_ar:-?}${NC}"
    echo -e "    eff. RF:      ${BOLD}${_dc2_rf:-?}${NC}"
    echo -e "    roster:       ${BOLD}${_dc2_roster:-?}${NC}"

    echo ""
    echo -e "  ${RED}${BOLD}SPLIT BRAIN SUMMARY:${NC}"
    echo -e "  ${RED}  DC1 roster: ${_dc1_roster:-unknown}${NC}"
    echo -e "  ${RED}  DC2 roster: ${_dc2_roster:-unknown}${NC}"
    echo -e "  ${RED}  Both clusters are independently authoritative for namespace '${NAMESPACE}'.${NC}"
    echo -e "  ${RED}  Writes on DC1 are NOT replicated to DC2 and vice versa.${NC}"
    echo -e "  ${RED}  Data written since the partition on either side is EXCLUSIVE to that cluster.${NC}"

    # =========================================================================
    # PHASE 6: Recovery guidance
    # =========================================================================
    expected "WHAT HAPPENED:
  1. Network partition isolated DC1 (A1-A3+C1) from DC2 (B1-B3).
  2. SC protections correctly blocked DC2 from accepting writes.
  3. An operator bypassed those protections (roster-set + mcs lowering on DC2).
  4. Both clusters wrote to the same namespace -- data is now diverged.

HOW AEROSPIKE SC SHOULD HAVE PROTECTED YOU:
  - min-cluster-size >= 4 would have blocked DC2 (only 3 nodes) from forming.
  - The committed roster prevents a sub-cluster from electing without all members.
  - Never lower min-cluster-size or force roster-set on a partitioned minority
    without 100% certainty the other side is completely dead.

RECOVERY (DATA LOSS IS UNAVOIDABLE):
  1. Decide which side wins: DC1 (original masters) or DC2 (forced writes).
  2. Run R4 (Full Recovery) to:
     a. Flush all iptables rules (heal the network partition)
     b. Restore min-cluster-size to original (${orig_mcs:-4}) on all nodes
     c. Force a roster-set with the winning side's observed_nodes
     d. Recluster + revive dead partitions
  3. The LOSING side's writes since the partition are permanently erased.
     (DC1 wins by default -- it has the original committed masters.)

LESSON:
  Strong Consistency mode is only as strong as your operational procedures.
  Split-brain in SC mode is possible when operators bypass the roster/mcs guards.
  Keys written: baseline=${baseline_key}
               dc1_only=${dc1_only_key}
               dc2_only=${dc2_only_key}
               conflict=${conflict_key}"
}

scenario_net_isolate_site1() {
    header "Network Partition: Isolate Site 1"
    echo "  Site 1 (A1-A3) will be network-isolated from Site 2 + Quorum."
    echo "  All nodes stay running, but Site 1 cannot communicate with anyone else."
    echo ""
    echo "  Split: [A1,A2,A3] vs [B1,B2,B3,C1]"
    echo ""
    confirm_proceed || return

    info "Applying iptables rules..."
    local s1c s1i othersc othersi
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    othersc=$(IFS=','; echo "${SITE2_CONTAINERS[*]},$QUORUM_CONTAINER")
    othersi=$(IFS=','; echo "${SITE2_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s1c" "$s1i" "$othersc" "$othersi"
    ok "Site 1 isolated (bidirectional iptables DROP)"
    wait_detect 15
    status_check

    expected "TWO sub-clusters form:
  Minority: Site 1 (3 nodes) < min-cluster-size=4 --> STOPS (quorum violated)
  Majority: Site 2 + Quorum (4 nodes) >= 4 --> cluster alive, BUT DATA UNAVAILABLE
WARNING: The majority side has NO masters -- all 4096 are on Site 1 (minority).
In SC mode masters are never promoted during a network partition.
Result: BOTH sides are IO-dead. Neither can serve reads or writes.
Heal the partition immediately. No data is lost; masters resume on reconnect.
Recovery: use R3 (heal network partitions) or R4 (full recovery)."
}

scenario_net_isolate_site2() {
    header "Network Partition: Isolate Site 2"
    echo "  Site 2 (B1-B3) will be network-isolated from Site 1 + Quorum."
    echo "  All nodes stay running, but Site 2 cannot communicate with anyone else."
    echo ""
    echo "  Split: [B1,B2,B3] vs [A1,A2,A3,C1]"
    echo ""
    confirm_proceed || return

    info "Applying iptables rules..."
    local s2c s2i othersc othersi
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    othersc=$(IFS=','; echo "${SITE1_CONTAINERS[*]},$QUORUM_CONTAINER")
    othersi=$(IFS=','; echo "${SITE1_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s2c" "$s2i" "$othersc" "$othersi"
    ok "Site 2 isolated (bidirectional iptables DROP)"
    wait_detect 15
    status_check

    expected "TWO sub-clusters form:
  Minority: Site 2 (3 nodes) < min-cluster-size=4 --> STOPS writes
  Majority: Site 1 + Quorum (4 nodes) >= 4 --> masters intact, operational
This is the DESIGNED scenario: masters on Site 1 continue, data is safe.
Recovery: use R3 (heal network partitions) or R4 (full recovery)."
}

scenario_net_isolate_quorum() {
    header "Network Partition: Isolate Quorum Node"
    echo "  Quorum (C1) will be network-isolated from all data nodes."
    echo "  The 6 data nodes can still see each other."
    echo ""
    echo "  Split: [C1] vs [A1,A2,A3,B1,B2,B3]"
    echo ""
    confirm_proceed || return

    info "Applying iptables rules..."
    local alldata alldataips
    alldata=$(IFS=','; echo "${SITE1_CONTAINERS[*]},${SITE2_CONTAINERS[*]}")
    alldataips=$(IFS=','; echo "${SITE1_IPS[*]},${SITE2_IPS[*]}")
    isolate_bidirectional "$QUORUM_CONTAINER" "$QUORUM_IP" "$alldata" "$alldataips"
    ok "Quorum node isolated (bidirectional iptables DROP)"
    wait_detect 15
    status_check

    expected "TWO sub-clusters:
  Majority: 6 data nodes (>= min-cluster-size=4) --> operational
  Minority: C1 alone (1 < 4) --> stops
C1 was quiesced with 0 partitions, so no data impact.
The cluster loses its tie-breaker: if one site now also fails (3 nodes),
the remaining 3-node group is below min-cluster-size=4 (fragile). Heal quickly!
Recovery: use R3 (heal network partitions) or R4 (full recovery)."
}

scenario_net_site_vs_site() {
    header "Network Partition: Site 1 vs Site 2 (Quorum Sees Both)"
    echo "  Site 1 and Site 2 cannot communicate with each other."
    echo "  Quorum (C1) can still reach both sites."
    echo ""
    echo "  Split: [A1,A2,A3]--X--[B1,B2,B3]   C1 sees both"
    echo ""
    confirm_proceed || return

    info "Applying iptables rules (Site1 <-> Site2 only)..."
    local s1c s1i s2c s2i
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    isolate_bidirectional "$s1c" "$s1i" "$s2c" "$s2i"
    ok "Site 1 <-> Site 2 link severed. Quorum (C1) can see both."
    wait_detect 15
    status_check

    expected "Aerospike mesh heartbeat requires DIRECT pairwise TCP between all nodes.
C1 cannot forward heartbeats between Site 1 and Site 2.
Since A1-A3 and B1-B3 cannot reach each other directly, the cluster WILL split.
Each node drops unreachable peers from its succession list.
  Likely outcome: Site 1 + C1 (4 nodes, has masters) stays alive.
                  Site 2 alone (3 nodes) stops (below min-cluster-size=4).
  Edge case: cluster may fragment differently depending on timing.
Recovery: use R3 (heal network partitions) or R4 (full recovery)."
}

# =============================================================================
# DEGRADED MODES (partial failures)
# =============================================================================

scenario_site1_degraded() {
    header "Site 1 Degraded (Lose 2 of 3 Active-Rack Nodes)"
    echo "  Stop 2 of 3 Site 1 nodes, leaving only 1 master node."
    echo "  ~2700 of 4096 master partitions lose their primary."
    echo ""
    echo "  Pick which node to KEEP running:"
    for i in "${!SITE1_CONTAINERS[@]}"; do
        echo "    $((i+1)). ${ALL_IDS[$i]}  ${SITE1_CONTAINERS[$i]}"
    done
    echo ""
    read -rp "  Keep node (1-3): " choice
    if [[ ! "$choice" =~ ^[1-3]$ ]]; then fail "Invalid selection"; return; fi
    local keep_idx=$((choice - 1))

    local to_stop=()
    for i in "${!SITE1_CONTAINERS[@]}"; do
        if [ "$i" -ne "$keep_idx" ]; then
            to_stop+=("${SITE1_CONTAINERS[$i]}")
        fi
    done

    echo ""
    echo "  Keeping: ${SITE1_CONTAINERS[$keep_idx]}"
    echo "  Stopping: ${to_stop[*]}"
    echo ""
    confirm_proceed || return

    stop_nodes "${to_stop[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 5 (1 Site1 + 3 Site2 + C1). Still >= 4.
~2731 master partitions lost (were on stopped nodes).
Only ~1365 masters remain on the surviving Site 1 node.
Namespace likely enters stop_writes for affected partitions.
Demonstrates that losing most of the active rack is severe.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

scenario_site2_degraded() {
    header "Site 2 Degraded (Lose 2 of 3 Replica Nodes)"
    echo "  Stop 2 of 3 Site 2 nodes. Only 1 replica holder remains."
    echo ""
    echo "  Pick which node to KEEP running:"
    for i in "${!SITE2_CONTAINERS[@]}"; do
        echo "    $((i+1)). ${ALL_IDS[$((i+3))]}  ${SITE2_CONTAINERS[$i]}"
    done
    echo ""
    read -rp "  Keep node (1-3): " choice
    if [[ ! "$choice" =~ ^[1-3]$ ]]; then fail "Invalid selection"; return; fi
    local keep_idx=$((choice - 1))

    local to_stop=()
    for i in "${!SITE2_CONTAINERS[@]}"; do
        if [ "$i" -ne "$keep_idx" ]; then
            to_stop+=("${SITE2_CONTAINERS[$i]}")
        fi
    done

    echo ""
    echo "  Keeping: ${SITE2_CONTAINERS[$keep_idx]}"
    echo "  Stopping: ${to_stop[*]}"
    echo ""
    confirm_proceed || return

    stop_nodes "${to_stop[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 5 (3 Site1 + 1 Site2 + C1). Still >= 4.
All masters intact on Site 1 -- reads and writes continue.
Site 2 replica coverage reduced: only 1 Site 2 node holds replicas.
Less severe than Site 1 degradation since masters are unaffected.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

scenario_quorum_plus_one() {
    header "Quorum + One Data Node Failure"
    echo "  Stop the quorum node AND one data node."
    echo "  Tests what happens when the tie-breaker and a data node fail together."
    echo ""
    echo "  Pick a data node to also stop:"
    for i in 0 1 2 3 4 5; do
        echo "    $((i+1)). ${ALL_IDS[$i]}  ${ALL_CONTAINERS[$i]}"
    done
    echo ""
    read -rp "  Select data node (1-6): " choice
    if [[ ! "$choice" =~ ^[1-6]$ ]]; then fail "Invalid selection"; return; fi
    local idx=$((choice - 1))

    echo ""
    echo "  Stopping: quorum-node + ${ALL_CONTAINERS[$idx]}"
    echo ""
    confirm_proceed || return

    stop_nodes "$QUORUM_CONTAINER" "${ALL_CONTAINERS[$idx]}"
    wait_detect 10
    status_check

    expected "Cluster size = 5. Still >= min-cluster-size=4.
Quorum tie-breaker lost. If a further site failure occurs (3 nodes),
only 2 remain (< 4) and the cluster stops writes.
Impact on data depends on which data node was stopped.
Recovery: use R1 (recover all) or R4 (full recovery)."
}

# =============================================================================
# CASCADING FAILURES
# =============================================================================

scenario_cascading() {
    header "Cascading Failure: Quorum Down, Then Full Site"
    echo "  Step 1: Stop the quorum node (C1)"
    echo "  Step 2: Then stop an entire site"
    echo "  This simulates the worst-case cascade."
    echo ""
    echo "  After quorum is down, which site to also take down?"
    echo "    1. Site 1 (masters) -- will leave 3 nodes (< min-cluster-size=4, cluster STOPS)"
    echo "    2. Site 2 (replicas) -- will leave 3 nodes (< min-cluster-size=4, cluster STOPS)"
    echo ""
    read -rp "  Select site (1-2): " site_choice
    if [[ ! "$site_choice" =~ ^[1-2]$ ]]; then fail "Invalid selection"; return; fi

    echo ""
    echo -e "  ${RED}${BOLD}WARNING: Cluster will be at or below min-cluster-size!${NC}"
    confirm_proceed || return

    echo ""
    subheader "Step 1: Stopping quorum node"
    stop_nodes "$QUORUM_CONTAINER"
    wait_detect 10
    echo ""
    local seed_info seed_c seed_ip
    seed_info=$(find_running_seed)
    if [ -n "$seed_info" ]; then
        seed_c="${seed_info%%|*}"
        seed_ip="${seed_info##*|}"
        local cs
        cs=$(get_cluster_size "$seed_c" "$seed_ip")
        info "Cluster size after quorum loss: $cs"
    fi

    echo ""
    subheader "Step 2: Stopping site"
    if [ "$site_choice" = "1" ]; then
        stop_nodes "${SITE1_CONTAINERS[@]}"
    else
        stop_nodes "${SITE2_CONTAINERS[@]}"
    fi
    wait_detect 15
    status_check

    expected "Cluster size = 3 (below min-cluster-size=4).
The cluster halts entirely -- losing quorum and then a full site drops below minimum.
This is the cascading failure scenario: losing the tie-breaker first removes the
safety margin, and then losing a full site stops the cluster.
Recovery: use R1 (recover all) or R4 (full recovery) to start nodes."
}

# =============================================================================
# RECOVERY
# =============================================================================

# Helper: revive dead partitions on all running nodes
_revive_all() {
    audit_log "ASINFO" "_revive_all: reviving dead partitions on all running nodes"
    info "Reviving dead partitions on all running nodes..."
    local revived=0
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" != "running" ]; then continue; fi
        local result
        log_cmd "docker exec ${ALL_CONTAINERS[$i]} asinfo -v \"revive:namespace=${NAMESPACE}\" -h ${ALL_IPS[$i]} -p 3000 -t $ASINFO_TIMEOUT"
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo \
            -v "revive:namespace=${NAMESPACE}" \
            -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "error")
        log_result "-> $result"
        if [ "$result" = "ok" ]; then
            revived=$((revived + 1))
        fi
    done
    if [ "$revived" -gt 0 ]; then
        ok "Revive issued on $revived node(s)"
    else
        info "No nodes needed reviving (or none accepted)"
    fi
}

# Helper: check if quorum node needs re-quiescing and do it
_ensure_quorum_quiesced() {
    local state
    state=$(container_state "$QUORUM_CONTAINER")
    if [ "$state" != "running" ]; then
        info "Quorum node is not running -- skipping quiesce check"
        return
    fi
    local q
    q=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    if [ "$q" = "true" ]; then
        ok "Quorum node (C1) is already quiesced"
    else
        warn "Quorum node (C1) is NOT quiesced -- re-quiescing..."
        log_cmd "docker exec $QUORUM_CONTAINER asadm --enable -e \"manage quiesce with ${QUORUM_IP}:3000\""
        docker exec "$QUORUM_CONTAINER" asadm --enable \
            -e "manage quiesce with ${QUORUM_IP}:3000" 2>&1 | sed 's/^/    /'
        do_recluster "Recluster after C1 quiesce" || true
        sleep 5
        q=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
        if [ "$q" = "true" ]; then
            ok "Quorum node (C1) re-quiesced successfully"
        else
            fail "Failed to re-quiesce C1 -- run O2 manually"
        fi
    fi
}

# Helper: detect and report iptables DROP rules
_has_iptables_rules() {
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then continue; fi
        local count
        count=$(docker exec "$c" iptables -L -n 2>/dev/null | grep -c "DROP" || true)
        count=$(echo "$count" | tr -d '[:space:]')
        if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Helper: wait for target cluster size with timeout
_wait_for_cluster_size() {
    local target="$1" timeout_secs="${2:-60}" label="${3:-cluster}"
    local elapsed=0 interval=5
    info "Waiting up to ${timeout_secs}s for ${label} to reach cluster_size=$target..."
    while [ "$elapsed" -lt "$timeout_secs" ]; do
        local seed_info
        seed_info=$(find_running_seed)
        if [ -n "$seed_info" ]; then
            local sc="${seed_info%%|*}" si="${seed_info##*|}"
            local cs
            cs=$(get_cluster_size "$sc" "$si")
            cs=$(echo "$cs" | tr -d '[:space:]')
            if [ "$cs" = "$target" ]; then
                ok "Cluster size reached $target"
                return 0
            fi
            info "  cluster_size=$cs (target=$target, ${elapsed}s elapsed)"
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    warn "Timed out waiting for cluster_size=$target (waited ${timeout_secs}s)"
    return 1
}

scenario_recover_all() {
    header "Recover All Stopped Nodes"

    # ---- Detect state ----
    local stopped=()
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "$c")
        [ "$state" != "running" ] && stopped+=("$c")
    done

    local has_net_rules=false
    if _has_iptables_rules; then has_net_rules=true; fi

    # ---- Summary ----
    subheader "Current state"
    if [ ${#stopped[@]} -gt 0 ]; then
        warn "Stopped nodes (${#stopped[@]}): ${stopped[*]}"
    else
        ok "All nodes are already running"
    fi
    if $has_net_rules; then
        warn "iptables DROP rules detected on one or more nodes"
    fi
    echo ""

    if [ ${#stopped[@]} -eq 0 ] && ! $has_net_rules; then
        ok "Nothing to recover -- cluster is fully healthy!"
        status_check
        return
    fi

    confirm_proceed "Recover all? (y/n): " || return

    # ---- Step 1: Heal network if needed ----
    if $has_net_rules; then
        echo ""
        subheader "Step 1: Healing network partitions"
        flush_all_iptables
        ok "All iptables rules flushed"
    fi

    # ---- Step 2: Start stopped nodes ----
    if [ ${#stopped[@]} -gt 0 ]; then
        echo ""
        subheader "Step 2: Starting ${#stopped[@]} stopped node(s)"
        start_nodes "${stopped[@]}"
    fi

    # ---- Step 3: Wait for cluster to reform ----
    echo ""
    subheader "Step 3: Waiting for cluster to reform"
    _wait_for_cluster_size 7 120 "recovery" || true

    # ---- Step 4: Revive dead partitions ----
    echo ""
    subheader "Step 4: Reviving dead partitions"
    _revive_all

    # ---- Step 5: Recluster ----
    echo ""
    subheader "Step 5: Triggering recluster"
    do_recluster "Recluster after recovery" || true
    sleep 5

    # ---- Step 6: Re-quiesce quorum node if needed ----
    echo ""
    subheader "Step 6: Checking quorum node quiesce"
    _ensure_quorum_quiesced

    # ---- Step 7: Wait for migrations ----
    echo ""
    subheader "Step 7: Waiting for migrations to settle"
    info "Waiting 10s for partition migrations..."
    sleep 10

    # ---- Final status ----
    echo ""
    subheader "Recovery complete"
    status_check
}

scenario_recover_specific() {
    header "Recover Specific Node"
    local stopped=() stopped_ids=() stopped_ips=()
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" != "running" ]; then
            stopped+=("${ALL_CONTAINERS[$i]}")
            stopped_ids+=("${ALL_IDS[$i]}")
            stopped_ips+=("${ALL_IPS[$i]}")
        fi
    done

    if [ ${#stopped[@]} -eq 0 ]; then
        ok "All nodes are already running!"
        return
    fi

    echo "  Stopped nodes:"
    for i in "${!stopped[@]}"; do
        local extra=""
        if [ "${stopped[$i]}" = "$QUORUM_CONTAINER" ]; then
            extra=" ${YELLOW}(quorum/tie-breaker)${NC}"
        fi
        echo -e "    $((i+1)). ${BOLD}${stopped_ids[$i]}${NC}  ${stopped[$i]}$extra"
    done
    echo ""
    read -rp "  Select node (1-${#stopped[@]}): " choice
    local idx=$((choice - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#stopped[@]} ]; then
        fail "Invalid selection"
        return
    fi

    local node="${stopped[$idx]}"
    local node_id="${stopped_ids[$idx]}"
    local node_ip="${stopped_ips[$idx]}"

    echo ""
    subheader "Recovering $node_id ($node)"

    # ---- Step 1: Start the node ----
    start_nodes "$node"
    info "Waiting 15s for $node_id to rejoin..."
    sleep 15

    # ---- Step 2: Revive dead partitions on all running nodes ----
    _revive_all

    # ---- Step 3: Recluster ----
    do_recluster "Recluster after recovering $node_id" || true
    sleep 5

    # ---- Step 4: Re-quiesce if this was the quorum node ----
    if [ "$node" = "$QUORUM_CONTAINER" ]; then
        echo ""
        info "Recovered node is the quorum node (C1) -- re-quiescing..."
        _ensure_quorum_quiesced
    fi

    # ---- Step 5: Wait for migrations ----
    info "Waiting 10s for migrations to settle..."
    sleep 10

    # ---- Final status ----
    echo ""
    subheader "Recovery complete"
    status_check
}

scenario_heal_network() {
    header "Heal All Network Partitions"

    # ---- Detect ----
    local has_rules=false rule_nodes=()
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then continue; fi
        local count
        count=$(docker exec "$c" iptables -L -n 2>/dev/null | grep -c "DROP" || true)
        count=$(echo "$count" | tr -d '[:space:]')
        if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
            has_rules=true
            rule_nodes+=("$id($count rules)")
        fi
    done

    if ! $has_rules; then
        ok "No iptables DROP rules found on any node -- network is clean."
        return
    fi

    subheader "Detected DROP rules"
    for rn in "${rule_nodes[@]}"; do
        warn "  $rn"
    done
    echo ""
    confirm_proceed "Flush all iptables rules and heal? (y/n): " || return

    # ---- Step 1: Flush iptables ----
    echo ""
    subheader "Step 1: Flushing iptables on all running nodes"
    flush_all_iptables
    ok "All iptables rules flushed"

    # ---- Step 2: Wait for cluster to re-merge ----
    echo ""
    subheader "Step 2: Waiting for cluster to re-merge"
    _wait_for_cluster_size 7 60 "network heal" || true

    # ---- Step 3: Revive dead partitions (partitions may be dead after split) ----
    echo ""
    subheader "Step 3: Reviving dead partitions"
    _revive_all

    # ---- Step 4: Recluster ----
    echo ""
    subheader "Step 4: Triggering recluster"
    do_recluster "Recluster after network heal" || true
    sleep 5

    # ---- Step 5: Re-quiesce quorum node if needed ----
    echo ""
    subheader "Step 5: Checking quorum node quiesce"
    _ensure_quorum_quiesced

    # ---- Step 6: Wait for migrations ----
    echo ""
    subheader "Step 6: Waiting for migrations to settle"
    info "Waiting 10s for partition migrations..."
    sleep 10

    # ---- Final status ----
    echo ""
    subheader "Network heal complete"
    status_check
}

scenario_full_recovery() {
    header "Full Recovery (Fix Everything)"
    echo "  This is a one-shot recovery that will:"
    echo "    1. Heal all network partitions (flush iptables)"
    echo "    2. Start all stopped nodes"
    echo "    3. Wait for full cluster reformation (7 nodes)"
    echo "    4. Revive dead partitions on all nodes"
    echo "    5. Trigger recluster"
    echo "    6. Re-quiesce the quorum node (C1) if needed"
    echo "    7. Wait for migrations and verify health"
    echo ""

    # ---- Detect state ----
    local stopped=() running_count=0
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then
            stopped+=("$c")
        else
            running_count=$((running_count + 1))
        fi
    done

    local has_net_rules=false
    if _has_iptables_rules; then has_net_rules=true; fi

    subheader "Current state"
    echo -e "    Running: ${GREEN}${running_count}${NC}  Stopped: ${RED}${#stopped[@]}${NC}  Network issues: $(if $has_net_rules; then echo -e "${YELLOW}YES${NC}"; else echo -e "${GREEN}NO${NC}"; fi)"
    if [ ${#stopped[@]} -gt 0 ]; then
        warn "Stopped: ${stopped[*]}"
    fi
    echo ""

    if [ ${#stopped[@]} -eq 0 ] && ! $has_net_rules; then
        # Still run revive + quiesce check in case cluster has dead partitions
        info "All nodes running, no network issues. Checking for dead partitions..."
        echo ""
    fi

    confirm_proceed "Run full recovery? (y/n): " || return

    # ---- Step 1: Heal network ----
    echo ""
    subheader "Step 1/7: Healing network partitions"
    if $has_net_rules; then
        flush_all_iptables
        ok "All iptables rules flushed"
    else
        ok "No iptables rules to flush"
    fi

    # ---- Step 2: Start stopped nodes ----
    echo ""
    subheader "Step 2/7: Starting stopped nodes"
    if [ ${#stopped[@]} -gt 0 ]; then
        start_nodes "${stopped[@]}"
    else
        ok "All nodes already running"
    fi

    # ---- Step 3: Wait for full cluster ----
    echo ""
    subheader "Step 3/7: Waiting for full cluster (7 nodes)"
    _wait_for_cluster_size 7 120 "full recovery" || true

    # ---- Step 4: Re-sync roster to observed nodes ----
    # In SC mode the roster must be explicitly re-committed after failures that
    # left dead partitions; without this step stop_writes stays true even after
    # all nodes are back.
    echo ""
    subheader "Step 4/7: Re-syncing SC roster"
    local _seed_info _sc _si
    _seed_info=$(find_running_seed)
    if [ -n "$_seed_info" ]; then
        _sc="${_seed_info%%|*}"
        _si="${_seed_info##*|}"
        local _roster_raw _observed _current_roster _roster_nodes
        _roster_raw=$(docker exec "$_sc" asinfo -v "roster:namespace=${NAMESPACE}" \
            -h "$_si" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
        _observed=$(echo "$_roster_raw" | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
        _current_roster=$(echo "$_roster_raw" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
        # Strip the M<n>| active-rack prefix before comparing/setting
        _roster_nodes=$(echo "$_observed" | sed 's/^M[0-9]*|//')
        if [ -z "$_observed" ] || [ "$_observed" = "null" ]; then
            warn "observed_nodes not yet populated -- skipping roster re-sync (cluster still forming)"
        elif [ "$_current_roster" = "$_roster_nodes" ]; then
            ok "Roster already matches observed nodes"
        else
            info "Observed: $_observed"
            info "Setting roster to observed nodes..."
            local _set_result
            _set_result=$(docker exec "$_sc" asinfo \
                -v "roster-set:namespace=${NAMESPACE};nodes=${_roster_nodes}" \
                -h "$_si" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "error")
            if [ "$_set_result" = "ok" ]; then
                ok "Roster re-set: $_roster_nodes"
            else
                warn "roster-set returned: $_set_result"
            fi
            do_recluster "Recluster after roster re-sync" || true
            sleep 3
        fi
    else
        warn "No running seed -- skipping roster re-sync"
    fi

    # ---- Step 5: Revive dead partitions ----
    echo ""
    subheader "Step 5/7: Reviving dead partitions"
    _revive_all
    do_recluster "Recluster after revive" || true
    sleep 5

    # ---- Step 6: Re-quiesce quorum node ----
    echo ""
    subheader "Step 6/7: Ensuring quorum node is quiesced"
    _ensure_quorum_quiesced

    # ---- Step 7: Wait for migrations and verify ----
    echo ""
    subheader "Step 7/7: Waiting for cluster to stabilize"
    info "Waiting for cluster stability..."
    local _stable
    for _attempt in $(seq 1 12); do
        _stable=$(docker exec "$_sc" asinfo -v "cluster-stable:" \
            -h "$_si" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "unstable")
        if [[ "$_stable" != *"unstable"* && "$_stable" != *"ERROR"* && -n "$_stable" ]]; then
            ok "Cluster stable (key: $_stable)"
            break
        fi
        [ "$_attempt" -eq 12 ] && warn "Cluster not yet stable after 60s -- migrations may still be in progress"
        sleep 5
    done

    # ---- Final verification ----
    echo ""
    subheader "Full recovery complete"
    local _fv_seed
    _fv_seed=$(find_running_seed)
    if [ -n "$_fv_seed" ]; then
        local _fv_sc="${_fv_seed%%|*}" _fv_si="${_fv_seed##*|}"
        local _fv_cs _fv_sw _fv_nq _fv_unavail
        _fv_cs=$(get_cluster_size "$_fv_sc" "$_fv_si")
        _fv_sw=$(get_ns_stat "$_fv_sc" "$_fv_si" "stop_writes")
        _fv_nq=$(get_ns_stat "$_fv_sc" "$_fv_si" "nodes_quiesced")
        _fv_unavail=$(get_ns_stat "$_fv_sc" "$_fv_si" "unavailable_partitions")
        echo ""
        if [ "$_fv_cs" = "7" ] && [ "$_fv_sw" = "false" ] && [ "${_fv_unavail:-0}" = "0" ]; then
            ok "HEALTHY: cluster_size=7, stop_writes=false, unavailable_partitions=0, nodes_quiesced=$_fv_nq"
        else
            warn "cluster_size=$_fv_cs, stop_writes=$_fv_sw, unavailable_partitions=${_fv_unavail:-?}, nodes_quiesced=$_fv_nq"
            [ "$_fv_cs" != "7" ]          && fail "Cluster did not reach size 7 -- some nodes may still be joining"
            [ "$_fv_sw" = "true" ]        && fail "stop_writes still true -- try running R4 again after migrations settle"
            [ "${_fv_unavail:-0}" != "0" ] && fail "unavailable_partitions=${_fv_unavail} -- roster or revive may be needed"
        fi
    fi
    echo ""
    status_check
}

# =============================================================================
# OPERATIONS
# =============================================================================

scenario_roster_update() {
    header "Roster Update"
    local seed_info
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then fail "No running nodes!"; return; fi
    local seed_c="${seed_info%%|*}" seed_ip="${seed_info##*|}"

    # Pre-flight: verify cluster is healthy enough for roster changes
    local cs
    cs=$(get_cluster_size "$seed_c" "$seed_ip")
    if [ "$cs" = "?" ] || [ "$cs" = "0" ]; then
        fail "Cluster is not formed (cluster_size=$cs). Cannot modify roster."
        fail "Start all nodes first (R1/R4), then retry."
        return
    fi
    local integrity
    integrity=$(docker exec "$seed_c" asinfo -v "statistics" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_integrity=' | cut -d'=' -f2 || echo "false")
    if [ "$integrity" != "true" ]; then
        fail "Cluster integrity is false (cluster_size=$cs). Roster changes require a stable cluster."
        fail "Recover the cluster first (R1/R4), then retry."
        return
    fi
    ok "Pre-flight: cluster_size=$cs, integrity=true"
    echo ""

    subheader "Current roster"
    local roster_raw
    roster_raw=$(asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" || echo "")
    if [ -z "$roster_raw" ]; then
        fail "Cannot reach any node to read roster. Is the cluster running?"
        return
    fi
    echo "$roster_raw" | tr ':' '\n' | sed 's/^/    /'
    echo ""

    echo "  Options:"
    echo "    1. Re-sync roster to current observed nodes"
    echo "    2. Remove a specific node from roster"
    echo ""
    read -rp "  Select (1-2): " choice

    case "$choice" in
        1)
            local observed
            observed=$(asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" \
                | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
            if [ -z "$observed" ]; then
                fail "Failed to read observed_nodes (asinfo timeout/error). Retry after cluster stabilizes."
                return
            fi
            # Keep M<n>| prefix intact -- it encodes the active rack in the roster
            info "Setting roster to: $observed"
            local set_result
            set_result=$(asinfo_cmd "$seed_c" "$seed_ip" \
                "roster-set:namespace=${NAMESPACE};nodes=${observed}" || echo "")
            if [ -z "$set_result" ] || [[ "$set_result" =~ ^ERROR: ]]; then
                fail "roster-set failed: ${set_result:-timeout}. Cluster may be unstable."
                return
            fi
            ok "roster-set: $set_result"
            do_recluster "Recluster after roster update" || true
            sleep 5
            echo ""
            subheader "Updated roster"
            asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" \
                | tr ':' '\n' | sed 's/^/    /'
            ;;
        2)
            local current_roster
            current_roster=$(asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" \
                | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
            if [ -z "$current_roster" ]; then
                fail "Failed to read current roster. Retry after cluster stabilizes."
                return
            fi
            # Extract M<n>| prefix to restore later; strip only for display/manipulation
            local m_prefix
            m_prefix=$(echo "$current_roster" | grep -o '^M[0-9]*|' || echo "")
            local bare_roster
            bare_roster=$(strip_roster_prefix "$current_roster")
            echo "  Current: $bare_roster"
            echo ""
            echo "  (Node IDs are hex strings with rack suffix, e.g. BB4401B1E7FC3B8@3)"
            read -rp "  Enter node-id to REMOVE (copy exactly from roster above): " remove_id
            local new_roster
            new_roster=$(echo "$bare_roster" | tr ',' '\n' | grep -vxF "$remove_id" | paste -sd',' -)
            echo "  New roster: ${m_prefix}${new_roster}"
            read -rp "  Confirm? (y/n): " confirm
            if [ "$confirm" = "y" ]; then
                local set_result
                set_result=$(asinfo_cmd "$seed_c" "$seed_ip" \
                    "roster-set:namespace=${NAMESPACE};nodes=${m_prefix}${new_roster}" || echo "")
                if [ -z "$set_result" ] || [[ "$set_result" =~ ^ERROR: ]]; then
                    fail "roster-set failed: ${set_result:-timeout}"
                    return
                fi
                ok "roster-set: $set_result"
                do_recluster "Recluster after roster change" || true
                sleep 5
                echo ""
                subheader "Updated roster"
                asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" \
                    | tr ':' '\n' | sed 's/^/    /'
            fi
            ;;
        *) fail "Invalid selection" ;;
    esac
    echo ""
}

scenario_quiesce_toggle() {
    header "Quiesce / Un-quiesce Node"
    echo "  Options:"
    echo "    1. Quiesce C1 (quorum-node) -- make it a pure tie-breaker"
    echo "    2. Un-quiesce C1 -- give it partitions again"
    echo "    3. Quiesce a specific data node"
    echo ""
    read -rp "  Select (1-3): " choice

    case "$choice" in
        1)
            local q
            q=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
            if [ "$q" = "true" ]; then
                ok "C1 is already quiesced."
                return
            fi
            info "Quiescing C1..."
            log_cmd "docker exec $QUORUM_CONTAINER asadm --enable -e \"manage quiesce with ${QUORUM_IP}:3000\""
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage quiesce with ${QUORUM_IP}:3000" 2>&1 | sed 's/^/    /'
            do_recluster "Recluster after C1 quiesce" || true
            sleep 5
            ok "C1 quiesced."
            ;;
        2)
            info "Un-quiescing C1..."
            log_cmd "docker exec $QUORUM_CONTAINER asadm --enable -e \"manage quiesce with ${QUORUM_IP}:3000 undo\""
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage quiesce with ${QUORUM_IP}:3000 undo" 2>&1 | sed 's/^/    /'
            do_recluster "Recluster after C1 un-quiesce" || true
            sleep 5
            ok "C1 un-quiesced. It will now receive replica partitions."
            ;;
        3)
            echo "  Pick a data node to quiesce:"
            for i in 0 1 2 3 4 5; do
                echo "    $((i+1)). ${ALL_IDS[$i]}  ${ALL_CONTAINERS[$i]}"
            done
            echo ""
            read -rp "  Select (1-6): " nchoice
            if [[ ! "$nchoice" =~ ^[1-6]$ ]]; then fail "Invalid"; return; fi
            local nidx=$((nchoice - 1))
            local nc="${ALL_CONTAINERS[$nidx]}" nip="${ALL_IPS[$nidx]}"
            info "Quiescing ${ALL_IDS[$nidx]}..."
            log_cmd "docker exec $nc asadm --enable -e \"manage quiesce with ${nip}:3000\""
            docker exec "$nc" asadm --enable \
                -e "manage quiesce with ${nip}:3000" 2>&1 | sed 's/^/    /'
            do_recluster "Recluster after ${ALL_IDS[$nidx]} quiesce" || true
            sleep 5
            ok "${ALL_IDS[$nidx]} quiesced."
            ;;
        *) fail "Invalid selection" ;;
    esac
    echo ""
    status_check
}

scenario_rolling_restart() {
    header "Rolling Restart"
    echo "  Which group to rolling-restart?"
    echo "    1. Site 1 (A1, A2, A3)"
    echo "    2. Site 2 (B1, B2, B3)"
    echo "    3. Quorum (C1)"
    echo "    4. All nodes (Site 1 -> Site 2 -> Quorum)"
    echo ""
    read -rp "  Select (1-4): " choice

    local nodes=()
    case "$choice" in
        1) nodes=("${SITE1_CONTAINERS[@]}") ;;
        2) nodes=("${SITE2_CONTAINERS[@]}") ;;
        3) nodes=("$QUORUM_CONTAINER") ;;
        4) nodes=("${SITE1_CONTAINERS[@]}" "${SITE2_CONTAINERS[@]}" "$QUORUM_CONTAINER") ;;
        *) fail "Invalid selection"; return ;;
    esac

    echo ""
    for node in "${nodes[@]}"; do
        echo -e "  ${YELLOW}Restarting ${node}...${NC}"
        log_cmd "docker restart $node"
        docker restart "$node" >/dev/null 2>&1
        info "Waiting 25s for $node to rejoin..."
        sleep 25

        local seed_info
        seed_info=$(find_running_seed)
        if [ -n "$seed_info" ]; then
            local sc="${seed_info%%|*}" si="${seed_info##*|}"
            local cs
            cs=$(get_cluster_size "$sc" "$si")
            ok "$node restarted. Cluster size: $cs"
        fi
        echo ""
    done

    # Revive + recluster
    audit_log "ASINFO" "rolling_restart: reviving dead partitions on all nodes"
    _revive_all
    do_recluster "Recluster after rolling restart" || true
    sleep 5
    ok "Rolling restart complete."

    # Re-quiesce the quorum node -- quiesce is NOT persistent across restarts.
    echo ""
    subheader "Re-quiescing quorum node"
    _ensure_quorum_quiesced

    echo ""
    status_check
}

scenario_switch_active_rack() {
    header "Switch Active Rack (Move Masters to Another Site)"

    # Find a running seed to query current active-rack
    local seed_info
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then fail "No running nodes!"; return; fi
    local seed_c="${seed_info%%|*}" seed_ip="${seed_info##*|}"

    local current_ar
    current_ar=$(get_ns_stat "$seed_c" "$seed_ip" "active-rack")
    current_ar=${current_ar:-0}

    local current_label="unknown"
    case "$current_ar" in
        1) current_label="Rack 1 (Site 1)" ;;
        2) current_label="Rack 2 (Site 2)" ;;
        0) current_label="None (disabled)" ;;
    esac

    echo "  Current active-rack: ${current_ar} = ${current_label}"
    echo ""
    echo "  Select new active-rack:"
    echo "    1. Rack 1 -- Site 1 (A1, A2, A3)  [default/original]"
    echo "    2. Rack 2 -- Site 2 (B1, B2, B3)"
    echo "    0. Disable active-rack (masters spread across all racks)"
    echo ""
    read -rp "  New active-rack (0/1/2): " new_ar

    if [[ ! "$new_ar" =~ ^[012]$ ]]; then
        fail "Invalid selection. Must be 0, 1, or 2."
        return
    fi

    if [ "$new_ar" = "$current_ar" ]; then
        warn "Active-rack config is already $new_ar, but the roster encoding may be missing."
        warn "Re-applying to ensure the M${new_ar}| prefix is present in the roster..."
    fi

    local new_label="unknown"
    case "$new_ar" in
        0) new_label="None (disabled)" ;;
        1) new_label="Rack 1 (Site 1)" ;;
        2) new_label="Rack 2 (Site 2)" ;;
    esac

    echo ""
    echo -e "  ${YELLOW}Switching active-rack: ${current_ar} (${current_label}) --> ${new_ar} (${new_label})${NC}"
    echo "  This will migrate ALL 4096 master partitions to the new rack."
    echo "  During migration, some writes may briefly pause."
    echo ""
    confirm_proceed || return

    echo ""
    # -------------------------------------------------------------------------
    # Step 1: Apply runtime active-rack on every running node
    # -------------------------------------------------------------------------
    info "Step 1/4: Applying active-rack=$new_ar on all running nodes..."
    local apply_count=0
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" ip="${ALL_IPS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(container_state "$c")
        if [ "$state" != "running" ]; then
            info "$id ($c) is not running -- skipped"
            continue
        fi
        local result
        log_cmd "docker exec $c asinfo -v \"set-config:context=namespace;id=${NAMESPACE};active-rack=${new_ar}\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        result=$(docker exec "$c" asinfo \
            -v "set-config:context=namespace;id=${NAMESPACE};active-rack=${new_ar}" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
        log_result "-> $result"
        if [ "$result" = "ok" ]; then
            ok "$id ($c): active-rack set to $new_ar"
            apply_count=$((apply_count + 1))
        else
            fail "$id ($c): failed to set active-rack ($result)"
        fi
    done

    if [ "$apply_count" -eq 0 ]; then
        fail "Could not set active-rack on any node!"
        return
    fi

    echo ""
    # -------------------------------------------------------------------------
    # Step 2: Recluster FIRST so nodes update observed_nodes M-prefix
    # -------------------------------------------------------------------------
    # After set-config, each node knows the new active-rack, but the
    # observed_nodes encoding (M1|..., M2|...) only updates after a
    # recluster. We must recluster BEFORE reading observed_nodes,
    # otherwise the roster-set will carry the OLD prefix and masters
    # stay pinned to the old rack.
    # -------------------------------------------------------------------------
    info "Step 2/4: Triggering recluster so nodes update observed_nodes M-prefix..."
    do_recluster "Recluster after set-config" || true

    info "Waiting 10s for observed_nodes to update with new M${new_ar}| prefix..."
    sleep 10

    # -------------------------------------------------------------------------
    # Step 3: Re-read observed_nodes (should now have M<new_ar>| prefix)
    #         and apply to roster via roster-set
    # -------------------------------------------------------------------------
    echo ""
    info "Step 3/4: Re-setting roster to match new active-rack encoding (M${new_ar}|)..."

    # Re-find a running seed (the original seed may have changed state)
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then fail "No running nodes to read roster!"; return; fi
    seed_c="${seed_info%%|*}"
    seed_ip="${seed_info##*|}"

    # Retry loop: wait for observed_nodes to carry the new M-prefix
    local observed="" retries=0 max_retries=6
    while [ "$retries" -lt "$max_retries" ]; do
        log_cmd "docker exec $seed_c asinfo -v \"roster:namespace=${NAMESPACE}\" -h $seed_ip -p 3000 -t $ASINFO_TIMEOUT"
        observed=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
            -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
            | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
        log_result "-> observed_nodes=$observed"
        if [ -z "$observed" ] || [ "$observed" = "null" ]; then
            fail "Could not read observed_nodes"
            retries=$((retries + 1))
            sleep 5
            continue
        fi
        # Check if at least one entry has the expected new prefix (e.g. M2|)
        # active-rack=0 means no prefix (or M0), active-rack=N means M<N>|
        if [ "$new_ar" = "0" ]; then
            # When disabling, entries should NOT have any M-prefix
            # (or they might still have the old prefix -- accept either)
            info "Observed nodes: $observed"
            break
        elif echo "$observed" | grep -q "M${new_ar}|"; then
            ok "Observed nodes have M${new_ar}| prefix"
            info "Observed nodes: $observed"
            break
        else
            warn "Observed nodes still have old prefix (attempt $((retries+1))/$max_retries): $observed"
            retries=$((retries + 1))
            if [ "$retries" -lt "$max_retries" ]; then
                info "Waiting 5s and retrying..."
                sleep 5
                # Retry recluster in case the first one didn't take effect
                do_recluster "Retry recluster" || true
                sleep 3
            fi
        fi
    done

    if [ "$retries" -ge "$max_retries" ] && [ "$new_ar" != "0" ]; then
        fail "observed_nodes never updated to M${new_ar}| prefix after $max_retries attempts"
        fail "The runtime set-config may not have taken effect. Check Aerospike logs."
        warn "Proceeding with current observed_nodes anyway: $observed"
    fi

    # Keep M<n>| active-rack prefix -- roster-set needs it to encode which rack
    # holds masters. Stripping it would leave no active-rack hint in the roster
    # and masters would not migrate to the new rack.
    local roster_result
    audit_log "ASINFO" "roster-set: namespace=${NAMESPACE} nodes=${observed} (on $seed_c)"
    roster_result=$(docker exec "$seed_c" asinfo \
        -v "roster-set:namespace=${NAMESPACE};nodes=${observed}" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
    if [ "$roster_result" = "ok" ]; then
        audit_log "ASINFO" "  -> roster-set: ok"
        ok "Roster updated successfully"
    else
        audit_log "ASINFO" "  -> roster-set FAILED: $roster_result"
        fail "roster-set failed: $roster_result"
    fi

    echo ""
    # -------------------------------------------------------------------------
    # Step 4: Final recluster to trigger partition migration with new roster
    # -------------------------------------------------------------------------
    info "Step 4/4: Final recluster to apply partition migration..."
    do_recluster "Recluster after roster update" || true

    # -------------------------------------------------------------------------
    # Update the config template so restarts also use the new active-rack
    # -------------------------------------------------------------------------
    echo ""
    local template_file="${PROJECT_DIR}/configs/aerospike.conf.template"
    if [ -f "$template_file" ]; then
        info "Updating ${template_file} to persist active-rack=${new_ar}..."
        audit_log "CONFIG" "sed -i: active-rack -> ${new_ar} in $template_file"
        if sed -i.bak "s/^[[:space:]]*active-rack[[:space:]]\{1,\}[0-9]\{1,\}/    active-rack ${new_ar}/" "$template_file" 2>/dev/null; then
            rm -f "${template_file}.bak" 2>/dev/null
            ok "Config template updated: active-rack ${new_ar} (persisted for restarts)"
        else
            warn "Could not update config template. Edit manually: active-rack ${new_ar}"
        fi
    else
        warn "Config template not found at $template_file"
        warn "Remember to update your aerospike.conf: active-rack ${new_ar}"
    fi

    echo ""
    info "Waiting 15s for migrations to begin..."
    sleep 15

    # Verify the change actually took effect
    echo ""
    subheader "Verification"
    local verify_ar
    verify_ar=$(get_ns_stat "$seed_c" "$seed_ip" "active-rack")
    if [ "$verify_ar" = "$new_ar" ]; then
        ok "Verified: active-rack is now $new_ar on $seed_c"
    else
        fail "Verification FAILED: active-rack is $verify_ar (expected $new_ar) on $seed_c"
    fi

    local verify_roster
    log_cmd "docker exec $seed_c asinfo -v \"roster:namespace=${NAMESPACE}\" -h $seed_ip -p 3000 -t $ASINFO_TIMEOUT"
    verify_roster=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    log_result "-> roster=$verify_roster"
    info "Current roster: $verify_roster"

    status_check

    expected "Active-rack changed from $current_ar to $new_ar.
Masters are migrating to the new rack.
Watch the visualizer for MIGRATING state -> HEALTHY.
All 4096 masters should move to Rack $new_ar ($new_label).
Config template updated -- restarts will also use active-rack $new_ar.
To revert: re-run O4 and select the original rack."
}

scenario_recover_site2_only() {
    header "Site 2 Only Recovery (Shrink Roster to Site 2)"
    echo "  Removes Site 1 (A1-A3) and Quorum (C1) from the roster."
    echo "  Reconfigures the cluster to run on Site 2 (B1-B3) with active-rack=2."
    echo "  Use this after permanent Site 1 loss to promote Site 2 replicas to masters."
    echo ""
    echo -e "  ${RED}${BOLD}WARNING: destructive -- Site 1 and Quorum nodes are dropped from the roster permanently.${NC}"
    echo "  Dead partitions will be revived (last committed data on Site 2 survives)."
    echo ""

    # ---- Current state snapshot ----
    local seed_info
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then
        fail "No running nodes found. Start Site 2 nodes (or use R1/R4) first."
        return
    fi
    local seed_c="${seed_info%%|*}" seed_ip="${seed_info##*|}"

    subheader "Current node states"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local st
        st=$(container_state "${ALL_CONTAINERS[$i]}")
        local color="$GREEN"
        [ "$st" != "running" ] && color="$RED"
        echo -e "    ${ALL_IDS[$i]}  ${ALL_CONTAINERS[$i]}: ${color}${st}${NC}"
    done
    echo ""

    subheader "Current roster / namespace stats"
    local roster_raw
    roster_raw=$(asinfo_cmd "$seed_c" "$seed_ip" "roster:namespace=${NAMESPACE}" 2>/dev/null || echo "")
    if [ -n "$roster_raw" ]; then
        echo "$roster_raw" | tr ':' '\n' | sed 's/^/    /'
    else
        warn "Roster unreadable"
    fi
    echo ""
    local _ns rf ar sw
    _ns=$(docker exec "$seed_c" asinfo -v "namespace/${NAMESPACE}" \
        -h "$seed_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
    rf=$(echo "$_ns" | grep '^effective_replication_factor=' | cut -d'=' -f2)
    ar=$(echo "$_ns" | grep '^active-rack='                  | cut -d'=' -f2)
    sw=$(echo "$_ns" | grep '^stop_writes='                  | cut -d'=' -f2)
    echo -e "    RF:${BOLD}${rf:-?}${NC}  Active-rack:${BOLD}R${ar:-?}${NC}  stop_writes:${BOLD}${sw:-?}${NC}"
    echo ""

    # Verify at least one Site 2 node is reachable via asinfo
    local s2_seed=""
    for i in "${!SITE2_CONTAINERS[@]}"; do
        if [ "$(container_state "${SITE2_CONTAINERS[$i]}")" = "running" ]; then
            local probe
            probe=$(docker exec "${SITE2_CONTAINERS[$i]}" asinfo -v "status" \
                -h "${SITE2_IPS[$i]}" -p 3000 -t 2000 2>/dev/null || echo "")
            if [ -n "$probe" ]; then
                s2_seed="${SITE2_CONTAINERS[$i]}|${SITE2_IPS[$i]}"
                break
            fi
        fi
    done
    if [ -z "$s2_seed" ]; then
        fail "No Site 2 node is reachable via asinfo. Start Site 2 nodes first."
        return
    fi

    echo ""
    confirm_proceed "Proceed with Site 2-only roster update? (y/n): " || return

    # ---- Step 0: Stop Site 1 and Quorum nodes if still running ----
    # They will be removed from the roster; leaving them running while
    # changing the roster to Site 2-only causes heartbeat instability.
    echo ""
    subheader "Step 0: Stopping Site 1 and Quorum nodes (they will leave the roster)"
    local unwanted_running=()
    for c in "${SITE1_CONTAINERS[@]}" "$QUORUM_CONTAINER"; do
        [ "$(container_state "$c")" = "running" ] && unwanted_running+=("$c")
    done
    if [ ${#unwanted_running[@]} -gt 0 ]; then
        warn "Still running: ${unwanted_running[*]}"
        warn "Stopping them now to prevent roster/heartbeat instability..."
        stop_nodes "${unwanted_running[@]}"
        info "Waiting 15s for cluster to re-form without stopped nodes..."
        sleep 15
    else
        ok "Site 1 and Quorum are already stopped -- safe to proceed"
    fi

    # ---- Step 1: Ensure Site 2 nodes are running ----
    echo ""
    subheader "Step 1: Ensuring Site 2 nodes are running"
    local to_start=()
    for c in "${SITE2_CONTAINERS[@]}"; do
        [ "$(container_state "$c")" != "running" ] && to_start+=("$c")
    done
    if [ ${#to_start[@]} -gt 0 ]; then
        info "Starting: ${to_start[*]}"
        start_nodes "${to_start[@]}"
        info "Waiting 20s for nodes to join..."
        sleep 20
    else
        ok "All Site 2 nodes are already running"
    fi

    # ---- Step 2: Lower min-cluster-size to 2 (3-node Site 2-only cluster) ----
    echo ""
    subheader "Step 2: Adjusting min-cluster-size to 2 (Site 2 = 3 nodes)"
    info "Lowering min-cluster-size to 2 on all reachable Site 2 nodes..."
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local c="${SITE2_CONTAINERS[$i]}" ip="${SITE2_IPS[$i]}"
        [ "$(container_state "$c")" != "running" ] && continue
        local r
        log_cmd "docker exec $c asinfo -v \"set-config:context=service;min-cluster-size=2\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        r=$(docker exec "$c" asinfo \
            -v "set-config:context=service;min-cluster-size=2" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
        log_result "-> $r"
        if [ "$r" = "ok" ]; then
            ok "$c: min-cluster-size=2"
        else
            warn "$c: set-config returned '$r' -- may require aerospike.conf edit + restart"
        fi
    done

    # ---- Step 3: Set active-rack=2 on all reachable Site 2 nodes ----
    echo ""
    subheader "Step 3: Setting active-rack=2 on Site 2 nodes"
    local nodes_updated=0
    for i in "${!SITE2_CONTAINERS[@]}"; do
        local c="${SITE2_CONTAINERS[$i]}" ip="${SITE2_IPS[$i]}"
        # Site 2 nodes are at ALL_IDS indices 3-5 (A1-A3 are 0-2, C1 is 6)
        local id="${ALL_IDS[$((i + 3))]}"
        [ "$(container_state "$c")" != "running" ] && continue
        local r
        log_cmd "docker exec $c asinfo -v \"set-config:context=namespace;id=${NAMESPACE};active-rack=2\" -h $ip -p 3000 -t $ASINFO_TIMEOUT"
        r=$(docker exec "$c" asinfo \
            -v "set-config:context=namespace;id=${NAMESPACE};active-rack=2" \
            -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "ERROR")
        log_result "-> $r"
        if [ "$r" = "ok" ]; then
            ok "$id ($c): active-rack=2"
            nodes_updated=$((nodes_updated + 1))
        else
            info "$id ($c): not updated (returned '$r')"
        fi
    done
    if [ "$nodes_updated" -eq 0 ]; then
        fail "Could not set active-rack on any node!"
        return
    fi

    # ---- Step 4: Recluster so observed_nodes updates to M2| prefix ----
    echo ""
    subheader "Step 4: Reclustering to refresh observed_nodes (M2| prefix)"
    do_recluster "Pre-roster recluster" || true
    info "Waiting 10s for observed_nodes to update..."
    sleep 10

    # ---- Step 5: Build Site 2-only roster and apply ----
    echo ""
    subheader "Step 5: Building and applying Site 2-only roster"

    local s2_c="${s2_seed%%|*}" s2_ip="${s2_seed##*|}"

    local observed
    log_cmd "docker exec $s2_c asinfo -v \"roster:namespace=${NAMESPACE}\" -h $s2_ip -p 3000 -t $ASINFO_TIMEOUT"
    observed=$(docker exec "$s2_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$s2_ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
    log_result "-> observed_nodes=$observed"

    if [ -z "$observed" ] || [ "$observed" = "null" ]; then
        fail "Could not read observed_nodes from $s2_c."
        fail "Cluster may not have formed yet. Wait and retry, or run R4 first."
        return
    fi
    info "Observed nodes: $observed"

    # Strip global M<n>| prefix, keep only Rack 2 nodes (@2 suffix), re-add M2| for roster-set
    local stripped
    stripped=$(strip_roster_prefix "$observed")

    local filtered_nodes
    filtered_nodes=$(echo "$stripped" | tr ',' '\n' | grep '@2$' | paste -sd',' -)

    if [ -z "$filtered_nodes" ]; then
        fail "No Site 2 node IDs (Rack 2) found in observed_nodes."
        fail "Full observed_nodes: $observed"
        warn "Site 2 nodes may not yet appear. Wait 30s and retry."
        return
    fi

    # Re-attach the M2| active-rack prefix so the roster encodes active-rack=2
    local new_roster="M2|${filtered_nodes}"
    info "New roster: $new_roster"

    local set_result
    audit_log "ASINFO" "roster-set: namespace=${NAMESPACE} nodes=${new_roster} (on $s2_c)"
    set_result=$(asinfo_cmd "$s2_c" "$s2_ip" \
        "roster-set:namespace=${NAMESPACE};nodes=${new_roster}" || echo "ERROR")
    if [ "$set_result" = "ok" ]; then
        ok "Roster updated to Site 2-only nodes (B1-B3)"
    else
        fail "roster-set failed: $set_result"
        return
    fi

    # ---- Step 6: Recluster to apply new roster ----
    echo ""
    subheader "Step 6: Reclustering with new roster"
    do_recluster "Recluster with Site 2-only roster" || true
    info "Waiting 15s for cluster to reform..."
    sleep 15

    # ---- Step 7: Revive dead partitions ----
    echo ""
    subheader "Step 7: Reviving dead partitions"
    _revive_all

    # ---- Step 8: Final recluster ----
    echo ""
    subheader "Step 8: Final recluster after revive"
    do_recluster "Final recluster" || true
    sleep 5

    # ---- Persist to config template ----
    echo ""
    local template_file="${PROJECT_DIR}/configs/aerospike.conf.template"
    if [ -f "$template_file" ]; then
        info "Persisting active-rack=2 and min-cluster-size=2 in config template..."
        if sed -i.bak \
            "s/^[[:space:]]*active-rack[[:space:]]\{1,\}[0-9]\{1,\}/    active-rack 2/" \
            "$template_file" 2>/dev/null; then
            rm -f "${template_file}.bak"
            ok "Config template: active-rack=2"
        fi
        if sed -i.bak \
            "s/^[[:space:]]*min-cluster-size[[:space:]]\{1,\}[0-9]\{1,\}/    min-cluster-size 2/" \
            "$template_file" 2>/dev/null; then
            rm -f "${template_file}.bak"
            ok "Config template: min-cluster-size=2"
        fi
    else
        warn "Config template not found. Manually set: active-rack 2, min-cluster-size 2 in aerospike.conf"
    fi

    echo ""
    status_check

    expected "Cluster now runs on: Site 2 (B1, B2, B3) only.
Roster: Site 1 (A1-A3) and Quorum (C1) permanently removed.
active-rack=2: all masters pinned to Site 2 (Rack 2).
min-cluster-size=2 (lowered for 3-node operation).
Dead partitions revived -- last committed data on Site 2 is now live.
To restore all sites: start A1-A3 + C1, run O1 (roster re-sync), then O4 to restore active-rack."
}

show_menu() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  Aerospike Multi-Site Failure Simulation${NC}"
    echo -e "${DIM}  7 nodes | RF=4 | 3 racks | active-rack=1 | SC mode${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}NODE FAILURES${NC}"
    echo "    N1. Single node failure              (pick any node)"
    echo "    N2. Tie-breaker failure               (stop C1)"
    echo "    N3. Active-rack node failure           (stop 1 Site 1 master node)"
    echo ""
    echo -e "  ${CYAN}${BOLD}SITE / DC FAILURES${NC}"
    echo "    S1. Site 1 failure                    (all masters lost)"
    echo "    S2. Site 2 failure                    (replicas lost)"
    echo "    S3. Site 1 + Quorum failure            (masters + tie-breaker -- at quorum edge)"
    echo "    S4. DC2 failure                       (Site 2 only)"
    echo ""
    echo -e "  ${CYAN}${BOLD}NETWORK PARTITIONS${NC}  ${DIM}(iptables, nodes stay running)${NC}"
    echo "    P1. Isolate Site 1                    (minority partition)"
    echo "    P2. Isolate Site 2                    (minority partition)"
    echo "    P3. Isolate Quorum node               (lose tie-breaker)"
    echo "    P4. Site 1 vs Site 2                  (Quorum sees both)"
    echo ""
    echo -e "  ${RED}${BOLD}SPLIT BRAIN${NC}  ${DIM}(destructive -- writes diverge permanently)${NC}"
    echo -e "    ${RED}SB. DC1 vs DC2 forced write divergence    (partition + roster override + concurrent writes)${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}DEGRADED MODES${NC}"
    echo "    D1. Site 1 degraded                   (lose 2 of 3 master nodes)"
    echo "    D2. Site 2 degraded                   (lose 2 of 3 replica nodes)"
    echo "    D3. Quorum + 1 data node              (lose tie-breaker + 1)"
    echo "    D4. Cascading failure                 (quorum down, then full site)"
    echo ""
    echo -e "  ${GREEN}${BOLD}RECOVERY${NC}"
    echo "    R1. Recover all stopped nodes          (start + revive + quiesce)"
    echo "    R2. Recover specific node               (start + revive + quiesce)"
    echo "    R3. Heal all network partitions          (flush + revive + quiesce)"
    echo -e "    R4. ${GREEN}Full recovery${NC}                      (network + nodes + everything)"
    echo -e "    R5. ${YELLOW}Site 2 only recovery${NC}               (shrink roster to Site 2, active-rack=2)"
    echo ""
    echo -e "  ${YELLOW}${BOLD}OPERATIONS${NC}"
    echo "    O1. Roster update                     (re-sync or remove node)"
    echo "    O2. Quiesce / un-quiesce              (toggle tie-breaker mode)"
    echo "    O3. Rolling restart                   (site or full cluster)"
    echo "    O4. Switch active-rack                (move masters to another site)"
    echo ""
    echo -e "  ${BOLD}STATUS${NC}"
    echo "    ST. Cluster status check"
    echo ""
    echo "    Q.  Exit"
    echo ""
}

# Main loop
while true; do
    show_menu
    # Flush any buffered stdin before prompting
    while read -r -t 0.1 _ 2>/dev/null; do :; done
    read -rp "  Select scenario: " selection
    selection=$(echo "$selection" | tr '[:lower:]' '[:upper:]')
    audit_log "MENU" "User selected: $selection"

    case "$selection" in
        N1) scenario_single_node ;;
        N2) scenario_tiebreaker_failure ;;
        N3) scenario_active_rack_node ;;

        S1) scenario_site1_failure ;;
        S2) scenario_site2_failure ;;
        S3) scenario_dc1_failure ;;
        S4) scenario_dc2_failure ;;

        P1) scenario_net_isolate_site1 ;;
        P2) scenario_net_isolate_site2 ;;
        P3) scenario_net_isolate_quorum ;;
        P4) scenario_net_site_vs_site ;;

        SB) scenario_split_brain ;;

        D1) scenario_site1_degraded ;;
        D2) scenario_site2_degraded ;;
        D3) scenario_quorum_plus_one ;;
        D4) scenario_cascading ;;

        R1) scenario_recover_all ;;
        R2) scenario_recover_specific ;;
        R3) scenario_heal_network ;;
        R4) scenario_full_recovery ;;
        R5) scenario_recover_site2_only ;;

        O1) scenario_roster_update ;;
        O2) scenario_quiesce_toggle ;;
        O3) scenario_rolling_restart ;;
        O4) scenario_switch_active_rack ;;

        ST) status_check ;;

        Q|EXIT|QUIT) audit_log "INFO" "========== Session ended =========="; echo "  Exiting."; exit 0 ;;

        *) fail "Unknown option: $selection" ;;
    esac

    press_enter
done

#!/bin/bash
# =============================================================================
# simulate-failures.sh
# =============================================================================
# Interactive menu to simulate failure scenarios for the Aerospike
# Multi-Site Strong Consistency cluster.
#
# Topology:
#   DC1 = Site 1 (Rack 1, A1-A3, active-rack, all masters)
#       + Quorum  (Rack 3, C1, quiesced tie-breaker)
#   DC2 = Site 2 (Rack 2, B1-B3, replicas only)
#
#   min-cluster-size = 4  (prevents 3-node minority from accepting writes)
#   replication-factor = 3 (one copy per rack)
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

# Flag: set to 1 by recovery_steps so the main loop skips press_enter
RECOVERY_HANDLED=0

header() {
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
    # Flush any buffered stdin (typed during sleep/wait periods)
    while read -r -t 0.1 _ 2>/dev/null; do :; done
    read -rp "  Press ENTER to return to menu..." _
}

# Find any running container to use as seed for asinfo commands
find_running_seed() {
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "${ALL_CONTAINERS[$i]}" 2>/dev/null || echo "stopped")
        if [ "$state" = "running" ]; then
            echo "${ALL_CONTAINERS[$i]}|${ALL_IPS[$i]}"
            return
        fi
    done
    echo ""
}

# Get cluster_size from statistics (not the broken asinfo -v cluster-size)
get_cluster_size() {
    local container="$1" ip="$2"
    docker exec "$container" asinfo -v "statistics" -h "$ip" -p 3000 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "?"
}

# Get namespace stat
get_ns_stat() {
    local container="$1" ip="$2" stat="$3"
    docker exec "$container" asinfo -v "namespace/${NAMESPACE}" -h "$ip" -p 3000 2>/dev/null \
        | tr ';' '\n' | grep "^${stat}=" | cut -d'=' -f2 || echo "?"
}

# Recluster by trying all running nodes until the principal accepts
do_recluster() {
    local label="${1:-Recluster}"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "${ALL_CONTAINERS[$i]}" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
            continue
        fi
        local result
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null || true)
        if [ "$result" = "ok" ]; then
            ok "$label accepted by ${ALL_CONTAINERS[$i]}"
            return 0
        fi
    done
    warn "$label not accepted by any node"
    return 1
}

# Stop containers (accepts array of container names)
stop_nodes() {
    local nodes=("$@")
    for n in "${nodes[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo "stopped")
        if [ "$state" = "running" ]; then
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
        state=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
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

    # src -> dst: block
    for sc in "${src_containers[@]}"; do
        for dip in "${dst_ips[@]}"; do
            docker exec "$sc" iptables -A OUTPUT -d "$dip" -j DROP 2>/dev/null || true
            docker exec "$sc" iptables -A INPUT  -s "$dip" -j DROP 2>/dev/null || true
        done
    done
    # dst -> src: block (true bidirectional)
    for dc in "${dst_containers[@]}"; do
        for sip in "${src_ips[@]}"; do
            docker exec "$dc" iptables -A OUTPUT -d "$sip" -j DROP 2>/dev/null || true
            docker exec "$dc" iptables -A INPUT  -s "$sip" -j DROP 2>/dev/null || true
        done
    done
}

# Flush iptables on all running nodes
flush_all_iptables() {
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
        if [ "$state" = "running" ]; then
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

# Interactive recovery steps with executable commands
# Usage: recovery_steps "step1" "step2" "step3" ...
#
# Steps containing "docker ..." commands (after ": " or starting with "docker")
# are marked as executable. The user can pick a step number to run it, or
# press ENTER to go back to the menu.
recovery_steps() {
    local -a steps=("$@")
    local -a cmds=()
    local total=${#steps[@]}

    # Extract executable command from each step (empty string if not executable)
    for step in "${steps[@]}"; do
        local cmd=""
        # Pattern: "description:  docker ..." or "  docker ..."
        if echo "$step" | grep -q 'docker '; then
            # Extract the docker command: everything from "docker" to end of string
            cmd=$(echo "$step" | sed -n 's/.*\(docker .*\)/\1/p')
            # Strip trailing parenthetical comments like "(adds 1 node, reaches 4)"
            cmd=$(echo "$cmd" | sed 's/  *([^)]*)[[:space:]]*$//')
            # Trim trailing whitespace
            cmd=$(echo "$cmd" | sed 's/[[:space:]]*$//')
            # If the extracted command contains shell loops or unexpanded variables, skip auto-exec
            if echo "$cmd" | grep -qE '(\$[a-zA-Z]|\\$|for |; do |; done)'; then
                cmd=""
            fi
        fi
        cmds+=("$cmd")
    done

    while true; do
        echo ""
        echo -e "  ${GREEN}${BOLD}Recovery steps:${NC}"
        local i=1
        for step in "${steps[@]}"; do
            if [ -n "${cmds[$((i-1))]}" ]; then
                echo -e "    ${GREEN}${BOLD}${i}.${NC} $step  ${GREEN}[runnable]${NC}"
            else
                echo -e "    ${GREEN}${i}.${NC} $step"
            fi
            i=$((i + 1))
        done
        echo ""
        echo -e "  ${DIM}Enter step number to execute, or press ENTER to return to menu${NC}"
        # Flush stdin before prompting
        while read -r -t 0.1 _ 2>/dev/null; do :; done
        read -rp "  Run step: " step_choice

        # Empty input = return to menu
        if [ -z "$step_choice" ]; then
            RECOVERY_HANDLED=1
            return
        fi

        # Validate input is a number in range
        if ! [[ "$step_choice" =~ ^[0-9]+$ ]] || [ "$step_choice" -lt 1 ] || [ "$step_choice" -gt "$total" ]; then
            fail "Invalid step number (1-$total)"
            continue
        fi

        local idx=$((step_choice - 1))
        local cmd="${cmds[$idx]}"

        if [ -z "$cmd" ]; then
            warn "Step $step_choice is informational only (no executable command)"
            # Check if it references a menu option
            if echo "${steps[$idx]}" | grep -q 'option \|menu:'; then
                info "Use the main menu to perform this action."
            elif echo "${steps[$idx]}" | grep -qiE 'wait|sleep'; then
                local secs
                secs=$(echo "${steps[$idx]}" | grep -oE '[0-9]+s' | head -1 | tr -d 's')
                if [ -n "$secs" ]; then
                    read -rp "  Wait ${secs}s now? (y/n): " wc
                    if [ "$wc" = "y" ]; then
                        info "Waiting ${secs}s..."
                        sleep "$secs"
                        ok "Done waiting."
                    fi
                fi
            fi
            continue
        fi

        echo ""
        echo -e "  ${CYAN}Executing:${NC} $cmd"
        echo ""
        eval "$cmd" 2>&1 | sed 's/^/    /'
        local rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then
            ok "Step $step_choice completed successfully."
        else
            fail "Step $step_choice failed (exit code $rc)."
        fi
    done
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
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "not found")
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
    roster_info=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$seed_ip" -p 3000 2>/dev/null || echo "")
    local roster_val
    roster_val=$(echo "$roster_info" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    echo -e "    Roster:       ${BOLD}$roster_val${NC}"

    local rf ar nq sw
    rf=$(get_ns_stat "$seed_c" "$seed_ip" "effective_replication_factor")
    ar=$(get_ns_stat "$seed_c" "$seed_ip" "active-rack")
    nq=$(get_ns_stat "$seed_c" "$seed_ip" "nodes_quiesced")
    sw=$(get_ns_stat "$seed_c" "$seed_ip" "stop_writes")
    echo -e "    RF: ${BOLD}$rf${NC}  Active-rack: ${BOLD}R${ar}${NC}  Quiesced: ${BOLD}$nq${NC}  stop_writes: ${BOLD}$sw${NC}"

    echo ""
    subheader "Per-node partition ownership"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" ip="${ALL_IPS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
            echo -e "    ${RED}$id  DOWN${NC}"
            continue
        fi
        local m_obj p_obj objects sw_node mig_tx mig_rx
        m_obj=$(get_ns_stat "$c" "$ip" "master_objects")
        p_obj=$(get_ns_stat "$c" "$ip" "prole_objects")
        objects=$(get_ns_stat "$c" "$ip" "objects")
        mig_tx=$(get_ns_stat "$c" "$ip" "migrate_tx_partitions_remaining")
        mig_rx=$(get_ns_stat "$c" "$ip" "migrate_rx_partitions_remaining")
        sw_node=$(get_ns_stat "$c" "$ip" "stop_writes")
        local sw_tag=""
        if [ "$sw_node" = "true" ]; then
            local q
            q=$(get_ns_stat "$c" "$ip" "effective_is_quiesced")
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
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
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
        state=$(docker inspect -f '{{.State.Status}}' "${ALL_CONTAINERS[$i]}" 2>/dev/null || echo "stopped")
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
Recovery: use option R1 (Recover all stopped nodes)."

    recovery_steps \
        "Start the stopped node:  docker start $node" \
        "Wait ~15s for the node to rejoin the cluster" \
        "Revive dead partitions:  docker exec $node asinfo -v 'revive:namespace=${NAMESPACE}' -h ${ALL_IPS[$idx]} -p 3000" \
        "Trigger recluster:       docker exec $node asinfo -v 'recluster:' -h ${ALL_IPS[$idx]} -p 3000" \
        "Verify cluster size = 7: select option ST (status check)" \
        "Re-quiesce C1 if it was restarted: select option O2"
}

scenario_tiebreaker_failure() {
    header "Tie-Breaker (Quorum) Node Failure"
    echo "  This stops C1 (${QUORUM_IP}), the quiesced quorum node."
    echo "  C1 holds 0 partitions but provides the 4th vote for split-brain prevention."
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "$QUORUM_CONTAINER"
    wait_detect 10
    status_check

    expected "Cluster size drops to 6 (still >= 4, operational).
No data loss -- C1 held 0 partitions.
DANGER: If a full site now fails, only 3 nodes remain (< 4) and
the cluster stops writes. The tie-breaker is critical for quorum
when one entire site is lost."

    recovery_steps \
        "Start the quorum node:   docker start quorum-node" \
        "Wait ~15s for C1 to rejoin the cluster" \
        "Revive dead partitions:  docker exec quorum-node asinfo -v 'revive:namespace=${NAMESPACE}' -h ${QUORUM_IP} -p 3000" \
        "Trigger recluster:       docker exec quorum-node asinfo -v 'recluster:' -h ${QUORUM_IP} -p 3000" \
        "Re-quiesce C1 (quiesce is NOT persistent across restarts):" \
        "  docker exec quorum-node asadm --enable -e 'manage quiesce with ${QUORUM_IP}:3000'" \
        "  docker exec quorum-node asadm --enable -e 'manage recluster'" \
        "Verify with option ST: cluster_size=7, nodes_quiesced=1" \
        "Or use menu: R1 (recover all) then O2 (re-quiesce C1)"
}

scenario_active_rack_node() {
    header "Active-Rack Node Failure (Master Node)"
    echo "  Site 1 (Rack 1) holds ALL master partitions via active-rack=1."
    echo "  Stopping one Site 1 node removes ~1350 masters from service."
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

    expected "~1350 master partitions lose their master. In SC mode these partitions
become unavailable for writes until rebalance/roster-change.
Remaining Site 1 nodes still serve their masters.
Replicas on Site 2 remain intact for reads (if linearize-read not required)."

    recovery_steps \
        "Start the stopped node:  docker start $node" \
        "Wait ~15s for the node to rejoin the cluster" \
        "Revive dead partitions on the recovered node:" \
        "  docker exec $node asinfo -v 'revive:namespace=${NAMESPACE}' -h ${SITE1_IPS[$idx]} -p 3000" \
        "Trigger recluster (try any node -- only principal accepts):" \
        "  docker exec site1-node1 asinfo -v 'recluster:' -h 172.28.0.11 -p 3000" \
        "Wait for migrations to complete (master partitions rebalance to Site 1)" \
        "Verify: all 4096 masters back on Site 1 via option ST" \
        "Or use menu: R2 (recover specific node)"
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
    echo "  Cluster: 3 remaining (Site 2) + 1 quorum = 4 nodes (= min-cluster-size)"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${SITE1_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 4 (B1, B2, B3, C1). Meets min-cluster-size=4.
ALL 4096 master partitions are unavailable (they were on Site 1).
Namespace enters stop_writes=true because masters are gone.
Site 2 holds replicas but cannot promote them without roster change.
To recover: bring Site 1 back (R1) or do a roster change to
remove Site 1 nodes and let Site 2 take over masters."

    recovery_steps \
        "Option A -- Bring Site 1 back (preferred, no data loss):" \
        "  docker start site1-node1 site1-node2 site1-node3" \
        "  Wait ~20s for all 3 nodes to rejoin" \
        "  Revive dead partitions on all nodes:" \
        "    for n in site1-node1 site1-node2 site1-node3; do docker exec \$n asinfo -v 'revive:namespace=${NAMESPACE}' -h \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$n) -p 3000; done" \
        "  Trigger recluster: docker exec site1-node1 asinfo -v 'recluster:' -h 172.28.0.11 -p 3000" \
        "  Re-quiesce C1: select option O2" \
        "  Verify: masters return to Site 1, stop_writes=false" \
        "" \
        "Option B -- Failover to Site 2 (if Site 1 is permanently lost):" \
        "  Remove Site 1 nodes from roster: select option O1 -> remove A1@1, A2@1, A3@1" \
        "  Recluster to let Site 2 promote replicas to masters" \
        "  WARNING: active-rack=1 config may conflict; masters will go to Site 2 only if" \
        "  Site 1 nodes are removed from roster" \
        "" \
        "Or use menu: R1 (recover all stopped nodes)"
}

scenario_site2_failure() {
    header "Site 2 Failure (Replica Site)"
    echo "  Stopping ALL 3 nodes in Site 2 (B1, B2, B3)."
    echo "  Site 2 holds only replicas (active-rack=1 puts all masters on Site 1)."
    echo ""
    echo "  Cluster: 3 remaining (Site 1) + 1 quorum = 4 nodes (= min-cluster-size)"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${SITE2_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 4 (A1, A2, A3, C1). Meets min-cluster-size=4.
All masters still on Site 1 -- reads and writes continue normally.
Replication factor effectively drops: replicas on Site 2 are gone.
Data is less protected until Site 2 recovers.
If the quorum node also fails now, cluster drops to 3 (< 4) --> stops."

    recovery_steps \
        "Start all Site 2 nodes:  docker start site2-node1 site2-node2 site2-node3" \
        "Wait ~20s for nodes to rejoin the cluster" \
        "Revive dead partitions on all Site 2 nodes:" \
        "  for n in site2-node1 site2-node2 site2-node3; do docker exec \$n asinfo -v 'revive:namespace=${NAMESPACE}' -h \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$n) -p 3000; done" \
        "Trigger recluster: docker exec site1-node1 asinfo -v 'recluster:' -h 172.28.0.11 -p 3000" \
        "Wait for migrations to complete (replicas re-sync to Site 2)" \
        "Verify: cluster_size=7, RF=3 effective, replicas on Site 2" \
        "Or use menu: R1 (recover all stopped nodes)"
}

scenario_dc1_failure() {
    header "DC1 Failure (Site 1 + Quorum Node)"
    echo "  DC1 includes Site 1 (A1-A3, all masters) AND the Quorum node (C1)."
    echo "  Stopping 4 nodes: site1-node1, site1-node2, site1-node3, quorum-node."
    echo ""
    echo -e "  ${RED}${BOLD}CATASTROPHIC: Only Site 2 (3 nodes) survives. < min-cluster-size=4${NC}"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${SITE1_CONTAINERS[@]}" "$QUORUM_CONTAINER"
    wait_detect 15
    status_check

    expected "Cluster size = 3 (B1, B2, B3). BELOW min-cluster-size=4.
Cluster STOPS all operations -- cannot form quorum.
All masters lost (were on Site 1). No reads, no writes.
This is the worst-case scenario -- demonstrates why DC1 is critical.
Recovery requires bringing back at least 1 DC1 node to reach 4."

    recovery_steps \
        "PRIORITY: Bring back at least 1 DC1 node to restore quorum (cluster_size >= 4):" \
        "  Fastest -- start quorum-node: docker start quorum-node" \
        "  Or start any Site 1 node:     docker start site1-node1" \
        "Wait ~15s for the node to rejoin (cluster_size becomes 4)" \
        "Then bring back remaining DC1 nodes:" \
        "  docker start site1-node1 site1-node2 site1-node3 quorum-node" \
        "Wait ~20s for full cluster reformation" \
        "Revive dead partitions on ALL nodes:" \
        "  for c in site1-node1 site1-node2 site1-node3 quorum-node; do docker exec \$c asinfo -v 'revive:namespace=${NAMESPACE}' ... ; done" \
        "Trigger recluster from any running node" \
        "Re-quiesce C1: select option O2" \
        "Verify: cluster_size=7, stop_writes=false, masters on Site 1" \
        "Or use menu: R1 (recover all) then O2 (re-quiesce)"
}

scenario_dc2_failure() {
    header "DC2 Failure (Site 2 Only)"
    echo "  DC2 = Site 2 (B1-B3, replicas only)."
    echo "  Stopping 3 nodes: site2-node1, site2-node2, site2-node3."
    echo ""
    echo "  Cluster: Site 1 (3) + Quorum (1) = 4 (= min-cluster-size)"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${SITE2_CONTAINERS[@]}"
    wait_detect 15
    status_check

    expected "Same as Site 2 failure. Cluster size = 4, operational.
Masters on Site 1 unaffected. Writes continue.
Replica redundancy reduced until DC2 recovers."

    recovery_steps \
        "Start all Site 2 nodes:  docker start site2-node1 site2-node2 site2-node3" \
        "Wait ~20s for nodes to rejoin" \
        "Revive dead partitions on Site 2 nodes" \
        "Trigger recluster from any running node" \
        "Wait for replica migrations to complete" \
        "Verify: cluster_size=7, replicas back on Site 2" \
        "Or use menu: R1 (recover all stopped nodes)"
}

# =============================================================================
# NETWORK PARTITIONS (iptables -- nodes stay running but can't communicate)
# =============================================================================

scenario_net_isolate_site1() {
    header "Network Partition: Isolate Site 1"
    echo "  Site 1 (A1-A3) will be network-isolated from Site 2 + Quorum."
    echo "  All nodes stay running, but Site 1 cannot communicate with anyone else."
    echo ""
    echo "  Split: [A1,A2,A3] vs [B1,B2,B3,C1]"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    info "Applying iptables rules..."
    local s1c s1i s2qc s2qi
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    s2qc=$(IFS=','; echo "${SITE2_CONTAINERS[*]},$QUORUM_CONTAINER")
    s2qi=$(IFS=','; echo "${SITE2_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s1c" "$s1i" "$s2qc" "$s2qi"
    ok "Site 1 isolated (bidirectional iptables DROP)"
    wait_detect 15
    status_check

    expected "TWO sub-clusters form:
  Minority: Site 1 (3 nodes) < min-cluster-size=4 --> STOPS writes
  Majority: Site 2 + Quorum (4 nodes) >= 4 --> remains operational
Site 1 nodes still running but isolated. SC prevents split-brain.
Heal with option R3 (Heal all network partitions)."

    recovery_steps \
        "Flush iptables on ALL nodes to heal the partition:" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c iptables -F; done" \
        "Wait ~15s for the cluster to re-merge into a single cluster" \
        "Verify cluster_size=7 and stop_writes=false" \
        "If partitions remain dead, revive on all nodes:" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c asinfo -v 'revive:namespace=${NAMESPACE}' ...; done" \
        "Trigger recluster" \
        "Or use menu: R3 (heal all network partitions)"
}

scenario_net_isolate_site2() {
    header "Network Partition: Isolate Site 2"
    echo "  Site 2 (B1-B3) will be network-isolated from Site 1 + Quorum."
    echo "  All nodes stay running, but Site 2 cannot communicate with anyone else."
    echo ""
    echo "  Split: [B1,B2,B3] vs [A1,A2,A3,C1]"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    info "Applying iptables rules..."
    local s2c s2i s1qc s1qi
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    s1qc=$(IFS=','; echo "${SITE1_CONTAINERS[*]},$QUORUM_CONTAINER")
    s1qi=$(IFS=','; echo "${SITE1_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s2c" "$s2i" "$s1qc" "$s1qi"
    ok "Site 2 isolated (bidirectional iptables DROP)"
    wait_detect 15
    status_check

    expected "TWO sub-clusters form:
  Minority: Site 2 (3 nodes) < min-cluster-size=4 --> STOPS writes
  Majority: Site 1 + Quorum (4 nodes) >= 4 --> masters intact, operational
This is the DESIGNED scenario: Site 1 + Quorum wins, data is safe.
Heal with option R3."

    recovery_steps \
        "Flush iptables on ALL nodes to heal the partition:" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c iptables -F; done" \
        "Wait ~15s for the cluster to re-merge" \
        "Verify cluster_size=7, masters on Site 1, replicas on Site 2" \
        "Revive dead partitions if needed, then recluster" \
        "Or use menu: R3 (heal all network partitions)"
}

scenario_net_isolate_quorum() {
    header "Network Partition: Isolate Quorum Node"
    echo "  Quorum (C1) will be network-isolated from both sites."
    echo "  The 6 data nodes can still see each other."
    echo ""
    echo "  Split: [C1] vs [A1,A2,A3,B1,B2,B3]"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

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
The cluster loses its tie-breaker safety net: if a site now also
partitions, neither 3-node group can reach 4. Heal quickly!"

    recovery_steps \
        "Flush iptables on ALL nodes (including C1):" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c iptables -F; done" \
        "Wait ~15s for C1 to rejoin the main cluster" \
        "Re-quiesce C1 if quiesce was lost during isolation:" \
        "  docker exec quorum-node asadm --enable -e 'manage quiesce with ${QUORUM_IP}:3000'" \
        "  docker exec quorum-node asadm --enable -e 'manage recluster'" \
        "Verify: cluster_size=7, nodes_quiesced=1" \
        "Or use menu: R3 (heal network) then O2 (re-quiesce)"
}

scenario_net_site_vs_site() {
    header "Network Partition: Site 1 vs Site 2 (Quorum Sees Both)"
    echo "  Site 1 and Site 2 cannot communicate with each other."
    echo "  BOTH sites can still reach the Quorum node."
    echo ""
    echo "  Split: [A1,A2,A3]--X--[B1,B2,B3]   C1 sees all"
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    info "Applying iptables rules (Site1 <-> Site2 only)..."
    local s1c s1i s2c s2i
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    isolate_bidirectional "$s1c" "$s1i" "$s2c" "$s2i"
    ok "Site 1 <-> Site 2 link severed. Quorum can see both."
    wait_detect 15
    status_check

    expected "Aerospike mesh heartbeat: each site still reaches C1.
Cluster MAY stay as one (C1 bridges both sides via fabric/heartbeat)
or MAY split depending on Aerospike's partition detection logic.
If it splits: Site 1 + C1 (4 nodes, has masters) wins.
              Site 2 alone (3 nodes) stops.
This demonstrates the quorum node's role as a network bridge."

    recovery_steps \
        "Flush iptables on ALL nodes to restore Site1 <-> Site2 connectivity:" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c iptables -F; done" \
        "Wait ~15s for the cluster to re-merge" \
        "If the cluster split, revive dead partitions on all nodes and recluster" \
        "Verify: cluster_size=7, all masters on Site 1, replicas on Site 2" \
        "Or use menu: R3 (heal all network partitions)"
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
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${to_stop[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 5 (1 Site1 + 3 Site2 + C1). Still >= 4.
~2700 master partitions lost (were on stopped nodes).
Only ~1350 masters remain on the surviving Site 1 node.
Namespace likely enters stop_writes for affected partitions.
Demonstrates that losing most of the active rack is severe."

    recovery_steps \
        "Start the 2 stopped Site 1 nodes:" \
        "  docker start ${to_stop[0]} ${to_stop[1]}" \
        "Wait ~20s for nodes to rejoin" \
        "Revive dead partitions on all nodes:" \
        "  for c in ${ALL_CONTAINERS[*]}; do docker exec \$c asinfo -v 'revive:namespace=${NAMESPACE}' ...; done" \
        "Trigger recluster from any running node" \
        "Wait for migrations (masters rebalance across all 3 Site 1 nodes)" \
        "Verify: cluster_size=7, all 4096 masters on Site 1, stop_writes=false" \
        "Or use menu: R1 (recover all stopped nodes)"
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
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "${to_stop[@]}"
    wait_detect 15
    status_check

    expected "Cluster size = 5 (3 Site1 + 1 Site2 + C1). Still >= 4.
All masters intact on Site 1 -- reads and writes continue.
Replica coverage reduced: only 1 Site 2 node holds replicas.
Less severe than Site 1 degradation since masters are unaffected."

    recovery_steps \
        "Start the 2 stopped Site 2 nodes:" \
        "  docker start ${to_stop[0]} ${to_stop[1]}" \
        "Wait ~20s for nodes to rejoin" \
        "Revive dead partitions on the recovered nodes" \
        "Trigger recluster" \
        "Wait for replica migrations to complete (replicas rebalance across Site 2)" \
        "Verify: cluster_size=7, replicas evenly distributed on Site 2" \
        "Or use menu: R1 (recover all stopped nodes)"
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
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    stop_nodes "$QUORUM_CONTAINER" "${ALL_CONTAINERS[$idx]}"
    wait_detect 10
    status_check

    expected "Cluster size = 5. Still >= min-cluster-size=4.
Quorum tie-breaker lost. If a further site failure occurs,
the cluster may not be able to form quorum.
Impact on data depends on which data node was stopped."

    recovery_steps \
        "Start both stopped nodes:" \
        "  docker start quorum-node ${ALL_CONTAINERS[$idx]}" \
        "Wait ~20s for both nodes to rejoin" \
        "Revive dead partitions on all nodes" \
        "Trigger recluster" \
        "Re-quiesce C1 (quiesce is NOT persistent across restarts):" \
        "  docker exec quorum-node asadm --enable -e 'manage quiesce with ${QUORUM_IP}:3000'" \
        "  docker exec quorum-node asadm --enable -e 'manage recluster'" \
        "Verify: cluster_size=7, nodes_quiesced=1" \
        "Or use menu: R1 (recover all) then O2 (re-quiesce)"
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
    echo "    1. Site 1 (masters) -- will leave 3 nodes (BELOW min-cluster-size)"
    echo "    2. Site 2 (replicas) -- will leave 3 nodes (BELOW min-cluster-size)"
    echo ""
    read -rp "  Select site (1-2): " site_choice
    if [[ ! "$site_choice" =~ ^[1-2]$ ]]; then fail "Invalid selection"; return; fi

    echo ""
    echo -e "  ${RED}${BOLD}WARNING: This will bring the cluster below min-cluster-size!${NC}"
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

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

    expected "Cluster size = 3. BELOW min-cluster-size=4.
Cluster is DEAD -- no reads, no writes, no quorum.
This is the scenario min-cluster-size is designed to prevent:
without the tie-breaker, losing one site = total outage.
Recovery: start at least 1 stopped node to reach 4."

    local stopped_site_name
    if [ "$site_choice" = "1" ]; then stopped_site_name="Site 1 + Quorum"; else stopped_site_name="Site 2 + Quorum"; fi
    recovery_steps \
        "URGENT: Restore at least 1 stopped node to get cluster_size >= 4:" \
        "  Fastest: docker start quorum-node   (adds 1 node, reaches 4)" \
        "Wait ~15s for quorum to reform" \
        "Then start the remaining stopped nodes:" \
        "  docker start site1-node1 site1-node2 site1-node3 quorum-node  (if Site 1 was stopped)" \
        "  docker start site2-node1 site2-node2 site2-node3 quorum-node  (if Site 2 was stopped)" \
        "Wait ~20s for full cluster reformation" \
        "Revive dead partitions on ALL nodes and recluster" \
        "Re-quiesce C1: select option O2" \
        "Verify: cluster_size=7, stop_writes=false" \
        "Or use menu: R1 (recover all) then O2 (re-quiesce)"
}

# =============================================================================
# RECOVERY
# =============================================================================

scenario_recover_all() {
    header "Recover All Stopped Nodes"
    local stopped=()
    for c in "${ALL_CONTAINERS[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
            stopped+=("$c")
        fi
    done

    if [ ${#stopped[@]} -eq 0 ]; then
        ok "All nodes are already running!"
        return
    fi

    echo "  Stopped nodes: ${stopped[*]}"
    echo ""
    read -rp "  Start all? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    start_nodes "${stopped[@]}"

    info "Waiting 20s for cluster to reform..."
    sleep 20

    # Revive dead partitions
    info "Reviving dead partitions on all nodes..."
    for i in "${!ALL_CONTAINERS[@]}"; do
        docker exec "${ALL_CONTAINERS[$i]}" asinfo \
            -v "revive:namespace=${NAMESPACE}" \
            -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null || true
    done
    do_recluster "Recluster after recovery" || true
    sleep 5
    status_check

    ok "If the cluster was previously quiesced, re-run quiesce (option O2)."
}

scenario_recover_specific() {
    header "Recover Specific Node"
    local stopped=()
    local stopped_ids=()
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "${ALL_CONTAINERS[$i]}" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
            stopped+=("${ALL_CONTAINERS[$i]}")
            stopped_ids+=("${ALL_IDS[$i]}")
        fi
    done

    if [ ${#stopped[@]} -eq 0 ]; then
        ok "All nodes are already running!"
        return
    fi

    echo "  Stopped nodes:"
    for i in "${!stopped[@]}"; do
        echo "    $((i+1)). ${stopped_ids[$i]}  ${stopped[$i]}"
    done
    echo ""
    read -rp "  Select node (1-${#stopped[@]}): " choice
    local idx=$((choice - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#stopped[@]} ]; then
        fail "Invalid selection"
        return
    fi

    start_nodes "${stopped[$idx]}"
    info "Waiting 15s for node to rejoin..."
    sleep 15

    # Revive on the recovered node
    local node_idx
    for i in "${!ALL_CONTAINERS[@]}"; do
        if [ "${ALL_CONTAINERS[$i]}" = "${stopped[$idx]}" ]; then
            node_idx=$i
            break
        fi
    done
    docker exec "${ALL_CONTAINERS[$node_idx]}" asinfo \
        -v "revive:namespace=${NAMESPACE}" \
        -h "${ALL_IPS[$node_idx]}" -p 3000 2>/dev/null || true
    do_recluster "Recluster after recovery" || true
    sleep 5
    status_check
}

scenario_heal_network() {
    header "Heal All Network Partitions"
    echo "  This flushes iptables on ALL running nodes, removing all DROP rules."
    echo ""
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    flush_all_iptables
    ok "All iptables rules flushed on all running nodes."
    info "Waiting 15s for cluster to re-merge..."
    sleep 15
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

    subheader "Current roster"
    docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$seed_ip" -p 3000 2>/dev/null | tr ':' '\n' | sed 's/^/    /'
    echo ""

    echo "  Options:"
    echo "    1. Re-sync roster to current observed nodes"
    echo "    2. Remove a specific node from roster"
    echo ""
    read -rp "  Select (1-2): " choice

    case "$choice" in
        1)
            local observed
            observed=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
                -h "$seed_ip" -p 3000 2>/dev/null \
                | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
            info "Setting roster to: $observed"
            docker exec "$seed_c" asinfo \
                -v "roster-set:namespace=${NAMESPACE};nodes=${observed}" \
                -h "$seed_ip" -p 3000 2>/dev/null
            do_recluster "Recluster after roster update" || true
            sleep 5
            echo ""
            subheader "Updated roster"
            docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
                -h "$seed_ip" -p 3000 2>/dev/null | tr ':' '\n' | sed 's/^/    /'
            ;;
        2)
            local current_roster
            current_roster=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
                -h "$seed_ip" -p 3000 2>/dev/null \
                | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
            echo "  Current: $current_roster"
            echo ""
            read -rp "  Enter node-id to REMOVE (e.g. C1@3): " remove_id
            local new_roster
            new_roster=$(echo "$current_roster" | tr ',' '\n' | grep -v "$remove_id" | paste -sd',' -)
            echo "  New roster: $new_roster"
            read -rp "  Confirm? (y/n): " confirm
            if [ "$confirm" = "y" ]; then
                docker exec "$seed_c" asinfo \
                    -v "roster-set:namespace=${NAMESPACE};nodes=${new_roster}" \
                    -h "$seed_ip" -p 3000 2>/dev/null
                do_recluster "Recluster after roster change" || true
                sleep 5
                echo ""
                subheader "Updated roster"
                docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
                    -h "$seed_ip" -p 3000 2>/dev/null | tr ':' '\n' | sed 's/^/    /'
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
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage quiesce with ${QUORUM_IP}:3000" 2>&1 | sed 's/^/    /'
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage recluster" 2>&1 | sed 's/^/    /'
            sleep 5
            ok "C1 quiesced."
            ;;
        2)
            info "Un-quiescing C1..."
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage quiesce with ${QUORUM_IP}:3000 undo" 2>&1 | sed 's/^/    /'
            docker exec "$QUORUM_CONTAINER" asadm --enable \
                -e "manage recluster" 2>&1 | sed 's/^/    /'
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
            docker exec "$nc" asadm --enable \
                -e "manage quiesce with ${nip}:3000" 2>&1 | sed 's/^/    /'
            docker exec "$nc" asadm --enable \
                -e "manage recluster" 2>&1 | sed 's/^/    /'
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
    echo "    3. All nodes (Site 1 -> Site 2 -> Quorum)"
    echo ""
    read -rp "  Select (1-3): " choice

    local nodes=()
    case "$choice" in
        1) nodes=("${SITE1_CONTAINERS[@]}") ;;
        2) nodes=("${SITE2_CONTAINERS[@]}") ;;
        3) nodes=("${SITE1_CONTAINERS[@]}" "${SITE2_CONTAINERS[@]}" "$QUORUM_CONTAINER") ;;
        *) fail "Invalid selection"; return ;;
    esac

    echo ""
    for node in "${nodes[@]}"; do
        echo -e "  ${YELLOW}Restarting ${node}...${NC}"
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
    info "Reviving dead partitions..."
    for i in "${!ALL_CONTAINERS[@]}"; do
        docker exec "${ALL_CONTAINERS[$i]}" asinfo \
            -v "revive:namespace=${NAMESPACE}" \
            -h "${ALL_IPS[$i]}" -p 3000 2>/dev/null || true
    done
    do_recluster "Recluster after rolling restart" || true
    sleep 5
    ok "Rolling restart complete."
    echo ""
    warn "NOTE: Quiesce is NOT persistent across restarts."
    warn "Re-run quiesce (option O2) if needed."
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
        3) current_label="Rack 3 (Quorum)" ;;
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
        ok "Active-rack is already set to $new_ar. No change needed."
        return
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
    read -rp "  Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    echo ""
    info "Applying active-rack=$new_ar on all running nodes..."
    local apply_count=0
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" ip="${ALL_IPS[$i]}" id="${ALL_IDS[$i]}"
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "stopped")
        if [ "$state" != "running" ]; then
            info "$id ($c) is not running -- skipped"
            continue
        fi
        local result
        result=$(docker exec "$c" asinfo \
            -v "set-config:context=namespace;id=${NAMESPACE};active-rack=${new_ar}" \
            -h "$ip" -p 3000 2>/dev/null || echo "ERROR")
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
    info "Re-setting roster to pick up new active-rack encoding (M${new_ar}|)..."
    # After set-config, observed_nodes updates its prefix (e.g. M2|...).
    # The roster must be re-set to match, otherwise the old M1| prefix
    # keeps masters pinned to the old rack.
    local observed
    observed=$(docker exec "$seed_c" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$seed_ip" -p 3000 2>/dev/null \
        | tr ':' '\n' | grep '^observed_nodes=' | cut -d'=' -f2)
    if [ -z "$observed" ] || [ "$observed" = "null" ]; then
        fail "Could not read observed_nodes to re-set roster"
        return
    fi
    info "New roster value: $observed"
    local roster_result
    roster_result=$(docker exec "$seed_c" asinfo \
        -v "roster-set:namespace=${NAMESPACE};nodes=${observed}" \
        -h "$seed_ip" -p 3000 2>/dev/null || echo "ERROR")
    if [ "$roster_result" = "ok" ]; then
        ok "Roster updated with M${new_ar}| prefix"
    else
        fail "roster-set failed: $roster_result"
    fi

    echo ""
    info "Triggering recluster to apply partition migration..."
    do_recluster "Recluster after active-rack change" || true

    echo ""
    info "Waiting 15s for migrations to begin..."
    sleep 15

    status_check

    expected "Active-rack changed from $current_ar to $new_ar.
Masters are migrating to the new rack.
Watch the visualizer for MIGRATING state -> HEALTHY.
All 4096 masters should move to Rack $new_ar ($new_label).
NOTE: This is a runtime change. If nodes restart, they will
revert to the value in aerospike.conf (active-rack 1)."

    recovery_steps \
        "To revert to Site 1 (original): re-run this option (O4) and select Rack 1" \
        "To verify migration complete: select option ST (status check)" \
        "To make permanent: edit configs/aerospike.conf.template and change 'active-rack 1' to 'active-rack $new_ar'" \
        "Watch the visualizer: masters should move from Site ${current_ar} to Site ${new_ar}"
}

show_menu() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  Aerospike Multi-Site Failure Simulation${NC}"
    echo -e "${DIM}  7 nodes | RF=3 | 3 racks | active-rack=1 | SC mode${NC}"
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
    echo "    S3. DC1 failure                       (Site 1 + Quorum -- catastrophic)"
    echo "    S4. DC2 failure                       (Site 2 only)"
    echo ""
    echo -e "  ${CYAN}${BOLD}NETWORK PARTITIONS${NC}  ${DIM}(iptables, nodes stay running)${NC}"
    echo "    P1. Isolate Site 1                    (minority partition)"
    echo "    P2. Isolate Site 2                    (minority partition)"
    echo "    P3. Isolate Quorum node               (lose tie-breaker)"
    echo "    P4. Site 1 vs Site 2                  (quorum bridges both)"
    echo ""
    echo -e "  ${CYAN}${BOLD}DEGRADED MODES${NC}"
    echo "    D1. Site 1 degraded                   (lose 2 of 3 master nodes)"
    echo "    D2. Site 2 degraded                   (lose 2 of 3 replica nodes)"
    echo "    D3. Quorum + 1 data node              (lose tie-breaker + 1)"
    echo "    D4. Cascading failure                 (quorum down, then full site)"
    echo ""
    echo -e "  ${GREEN}${BOLD}RECOVERY${NC}"
    echo "    R1. Recover all stopped nodes"
    echo "    R2. Recover specific node"
    echo "    R3. Heal all network partitions        (flush iptables)"
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
    RECOVERY_HANDLED=0
    show_menu
    # Flush any buffered stdin before prompting
    while read -r -t 0.1 _ 2>/dev/null; do :; done
    read -rp "  Select scenario: " selection
    selection=$(echo "$selection" | tr '[:lower:]' '[:upper:]')

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

        D1) scenario_site1_degraded ;;
        D2) scenario_site2_degraded ;;
        D3) scenario_quorum_plus_one ;;
        D4) scenario_cascading ;;

        R1) scenario_recover_all ;;
        R2) scenario_recover_specific ;;
        R3) scenario_heal_network ;;

        O1) scenario_roster_update ;;
        O2) scenario_quiesce_toggle ;;
        O3) scenario_rolling_restart ;;
        O4) scenario_switch_active_rack ;;

        ST) status_check ;;

        Q|EXIT|QUIT) echo "  Exiting."; exit 0 ;;

        *) fail "Unknown option: $selection" ;;
    esac

    # Skip press_enter if recovery_steps already handled user interaction
    if [ "$RECOVERY_HANDLED" -eq 1 ]; then
        RECOVERY_HANDLED=0
    else
        press_enter
    fi
done

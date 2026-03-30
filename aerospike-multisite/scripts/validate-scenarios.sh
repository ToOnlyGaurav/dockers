#!/bin/bash
# =============================================================================
# validate-scenarios.sh -- End-to-end scenario validation for the 7-node cluster
# =============================================================================
# Starts the cluster fresh via run.sh, then exercises each failure/recovery
# scenario non-interactively, asserting expected Aerospike state at each step.
#
# Topology: Site1 (Rack1, A1-A3) + Site2 (Rack2, B1-B3) + Quorum (Rack3, C1)
#           7 nodes | RF=4 | active-rack and min-cluster-size detected at runtime
#
# Usage:
#   ./scripts/validate-scenarios.sh              # Full run (start + all tests)
#   ./scripts/validate-scenarios.sh --skip-start # Skip run.sh (cluster already up)
#   ./scripts/validate-scenarios.sh --test T1,T2 # Run specific tests only
#   ./scripts/validate-scenarios.sh --list       # List all test IDs
#
# Test IDs:
#   BASELINE  - Cluster health baseline (7 nodes, SC, roster, C1 quiesced)
#   N1        - Single replica-node failure (B2)
#   N2        - Tiebreaker (C1) failure
#   N3        - Active-rack (Site1) node failure + unavailable partition check
#   S1        - Site 1 failure (all masters lost, cluster_size=4)
#   S2        - Site 2 failure (replica site, cluster stays operational)
#   S3        - DC1 failure (Site1 + C1, 3 nodes remain -- below min-cluster-size)
#   P2        - Network partition: isolate Site 2 (majority stays live)
#   P3        - Network partition: isolate Quorum C1 (6 data nodes stay live)
#   P1        - Network partition: isolate Site 1 (both halves IO-dead)
#   D1        - Site1 degraded (2 of 3 active-rack nodes down)
#   D3        - Quorum + one data node failure
#   D4        - Cascading failure (C1 down, then full Site2)
#   O2        - Quiesce verify (C1 effective_is_quiesced round-trip)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Constants ──────────────────────────────────────────────────────────────────
NAMESPACE="mynamespace"
ASINFO_TIMEOUT=5000   # ms

ALL_CONTAINERS=("site1-node1" "site1-node2" "site1-node3"
                "site2-node1" "site2-node2" "site2-node3"
                "quorum-node")
ALL_IPS=(       "172.28.0.11"  "172.28.0.12"  "172.28.0.13"
                "172.28.0.21"  "172.28.0.22"  "172.28.0.23"
                "172.28.0.31")
ALL_IDS=(       "A1" "A2" "A3" "B1" "B2" "B3" "C1")

SITE1_CONTAINERS=("site1-node1" "site1-node2" "site1-node3")
SITE1_IPS=(       "172.28.0.11"  "172.28.0.12"  "172.28.0.13")

SITE2_CONTAINERS=("site2-node1" "site2-node2" "site2-node3")
SITE2_IPS=(       "172.28.0.21"  "172.28.0.22"  "172.28.0.23")

QUORUM_CONTAINER="quorum-node"
QUORUM_IP="172.28.0.31"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Effective cluster config (populated by detect_cluster_config) ─────────────
# Detected from the running cluster; used to make assertions active-rack-aware.
EFFECTIVE_ACTIVE_RACK="1"   # rack that holds all master partitions
EFFECTIVE_MCS="4"            # min-cluster-size currently in effect

# ── Test tracking (bash 3.2 compatible -- no declare -A) ──────────────────────
# Results stored as dynamic variables: TEST_RESULT_<ID> and TEST_NOTE_<ID>
CURRENT_TEST=""

set_result() { local id="$1" val="$2"; eval "TEST_RESULT_${id}='${val}'"; }
get_result() { local id="$1"; eval "echo \"\${TEST_RESULT_${id}:-}\""; }
set_note()   { local id="$1"; shift; eval "TEST_NOTE_${id}='$*'"; }
get_note()   { local id="$1"; eval "echo \"\${TEST_NOTE_${id}:-}\""; }

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ── Argument parsing ───────────────────────────────────────────────────────────
SKIP_START=false
SELECTED_TESTS=""

ALL_TEST_IDS="BASELINE N1 N2 N3 S1 S2 S3 P2 P3 P1 D1 D3 D4 O2"

for arg in "$@"; do
    case "$arg" in
        --skip-start) SKIP_START=true ;;
        --list)
            echo "Available test IDs:"
            for t in $ALL_TEST_IDS; do echo "  $t"; done
            exit 0
            ;;
        --test=*)
            SELECTED_TESTS="${arg#--test=}"
            ;;
        --test)
            # handled below with shift -- not possible with for loop, handled via next arg
            ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            # Support --test T1,T2 by checking if previous was --test
            ;;
    esac
done

# Re-parse for --test <value> (two-argument form)
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
    if [ "${args[$i]}" = "--test" ] && [ $((i+1)) -lt ${#args[@]} ]; then
        SELECTED_TESTS="${args[$((i+1))]}"
    fi
done

# Determine which tests to run
if [ -n "$SELECTED_TESTS" ]; then
    RUN_TESTS=$(echo "$SELECTED_TESTS" | tr ',' ' ')
else
    RUN_TESTS="$ALL_TEST_IDS"
fi

# =============================================================================
# Low-level helpers
# =============================================================================

log() { echo -e "$*"; }
info() { echo -e "  ${DIM}$*${NC}"; }
ok()   { echo -e "  ${GREEN}$*${NC}"; }
warn() { echo -e "  ${YELLOW}$*${NC}"; }
fail_msg() { echo -e "  ${RED}$*${NC}"; }

section() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo ""
}

subsection() {
    echo ""
    echo -e "  ${YELLOW}${BOLD}── $* ──${NC}"
}

container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "stopped"
}

find_running_seed() {
    for i in "${!ALL_CONTAINERS[@]}"; do
        local state
        state=$(container_state "${ALL_CONTAINERS[$i]}")
        if [ "$state" = "running" ]; then
            local probe
            probe=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "status" \
                -h "${ALL_IPS[$i]}" -p 3000 -t 2000 2>/dev/null || echo "")
            if [ "$probe" = "ok" ]; then
                echo "${ALL_CONTAINERS[$i]}|${ALL_IPS[$i]}"
                return
            fi
        fi
    done
    # fallback: first running even if probe failed
    for i in "${!ALL_CONTAINERS[@]}"; do
        [ "$(container_state "${ALL_CONTAINERS[$i]}")" = "running" ] && \
            echo "${ALL_CONTAINERS[$i]}|${ALL_IPS[$i]}" && return
    done
    echo ""
}

get_cluster_size() {
    local container="$1" ip="$2"
    docker exec "$container" asinfo -v "statistics" -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo "?"
}

get_stat() {
    local container="$1" ip="$2" stat="$3"
    docker exec "$container" asinfo -v "statistics" -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep "^${stat}=" | cut -d'=' -f2 || echo "?"
}

get_ns_stat() {
    local container="$1" ip="$2" stat="$3"
    docker exec "$container" asinfo -v "namespace/${NAMESPACE}" -h "$ip" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep "^${stat}=" | cut -d'=' -f2 || echo "?"
}

seed_ns_stat() {
    local stat="$1"
    local seed_info
    seed_info=$(find_running_seed)
    [ -z "$seed_info" ] && echo "?" && return
    local sc="${seed_info%%|*}" si="${seed_info##*|}"
    get_ns_stat "$sc" "$si" "$stat"
}

seed_cluster_size() {
    local seed_info
    seed_info=$(find_running_seed)
    [ -z "$seed_info" ] && echo "?" && return
    local sc="${seed_info%%|*}" si="${seed_info##*|}"
    get_cluster_size "$sc" "$si"
}

stop_nodes() {
    for n in "$@"; do
        [ "$(container_state "$n")" = "running" ] && \
            docker stop "$n" >/dev/null 2>&1 && info "Stopped $n" || info "$n already stopped"
    done
}

start_nodes() {
    for n in "$@"; do
        [ "$(container_state "$n")" != "running" ] && \
            docker start "$n" >/dev/null 2>&1 && info "Started $n" || info "$n already running"
    done
}

flush_all_iptables() {
    for c in "${ALL_CONTAINERS[@]}"; do
        [ "$(container_state "$c")" = "running" ] && \
            docker exec "$c" iptables -F 2>/dev/null || true
    done
}

isolate_bidirectional() {
    local -a src_containers dst_containers src_ips dst_ips
    IFS=',' read -ra src_containers <<< "$1"
    IFS=',' read -ra src_ips       <<< "$2"
    IFS=',' read -ra dst_containers <<< "$3"
    IFS=',' read -ra dst_ips       <<< "$4"

    for sc in "${src_containers[@]}"; do
        for dip in "${dst_ips[@]}"; do
            docker exec "$sc" iptables -A OUTPUT -d "$dip" -j DROP 2>/dev/null || true
            docker exec "$sc" iptables -A INPUT  -s "$dip" -j DROP 2>/dev/null || true
        done
    done
    for dc in "${dst_containers[@]}"; do
        for sip in "${src_ips[@]}"; do
            docker exec "$dc" iptables -A OUTPUT -d "$sip" -j DROP 2>/dev/null || true
            docker exec "$dc" iptables -A INPUT  -s "$sip" -j DROP 2>/dev/null || true
        done
    done
}

do_recluster() {
    for i in "${!ALL_CONTAINERS[@]}"; do
        [ "$(container_state "${ALL_CONTAINERS[$i]}")" != "running" ] && continue
        local result
        result=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo -v "recluster:" \
            -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true)
        [ "$result" = "ok" ] && return 0
    done
    return 1
}

revive_all() {
    for i in "${!ALL_CONTAINERS[@]}"; do
        [ "$(container_state "${ALL_CONTAINERS[$i]}")" != "running" ] && continue
        docker exec "${ALL_CONTAINERS[$i]}" asinfo \
            -v "revive:namespace=${NAMESPACE}" \
            -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true
    done
}

ensure_quorum_quiesced() {
    [ "$(container_state "$QUORUM_CONTAINER")" != "running" ] && return 0
    local q
    q=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    if [ "$q" = "true" ]; then return 0; fi
    # Re-quiesce via asadm
    docker exec "$QUORUM_CONTAINER" asadm --enable \
        -e "manage quiesce with ${QUORUM_IP}:3000" 2>/dev/null >/dev/null || true
    do_recluster || true
    sleep 5
    q=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    [ "$q" = "true" ] && return 0 || return 1
}

wait_for_cluster_size() {
    local target="$1" timeout_secs="${2:-90}" interval=5 elapsed=0
    info "Waiting up to ${timeout_secs}s for cluster_size=${target}..."
    while [ "$elapsed" -lt "$timeout_secs" ]; do
        local cs
        cs=$(seed_cluster_size)
        cs=$(echo "$cs" | tr -d '[:space:]')
        if [ "$cs" = "$target" ]; then
            ok "cluster_size=${cs} reached"
            return 0
        fi
        printf '\r  cluster_size=%s (target=%s, %ds)   ' "$cs" "$target" "$elapsed"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    echo ""
    warn "Timed out waiting for cluster_size=${target} (last seen: $(seed_cluster_size))"
    return 1
}

wait_for_ns_stat() {
    # Wait until a namespace stat reaches an expected value
    # Usage: wait_for_ns_stat <stat> <expected_value> [timeout_secs]
    local stat="$1" expected="$2" timeout_secs="${3:-60}" interval=5 elapsed=0
    info "Waiting up to ${timeout_secs}s for ${stat}=${expected}..."
    while [ "$elapsed" -lt "$timeout_secs" ]; do
        local v
        v=$(seed_ns_stat "$stat")
        v=$(echo "$v" | tr -d '[:space:]')
        if [ "$v" = "$expected" ]; then
            ok "${stat}=${v}"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    warn "Timed out: ${stat}=$(seed_ns_stat "$stat") (expected=${expected})"
    return 1
}

# Read the effective active-rack and min-cluster-size from the running cluster.
# Call this once after the cluster is up; tests use EFFECTIVE_ACTIVE_RACK and
# EFFECTIVE_MCS so assertions stay correct regardless of config-template values.
detect_cluster_config() {
    local seed_info
    seed_info=$(find_running_seed)
    [ -z "$seed_info" ] && return
    local sc="${seed_info%%|*}" si="${seed_info##*|}"

    local ar mcs
    ar=$(get_ns_stat "$sc" "$si" "active-rack")
    mcs=$(docker exec "$sc" asinfo -v "get-config:context=service" \
        -h "$si" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null \
        | tr ';' '\n' | grep '^min-cluster-size=' | cut -d'=' -f2 || echo "")

    [ -n "$ar" ]  && EFFECTIVE_ACTIVE_RACK="$ar"
    [ -n "$mcs" ] && EFFECTIVE_MCS="$mcs"

    info "Detected cluster config: active-rack=${EFFECTIVE_ACTIVE_RACK}  min-cluster-size=${EFFECTIVE_MCS}"
}

# =============================================================================
# Assertion engine
# =============================================================================

ASSERT_PASS=0
ASSERT_FAIL=0

assert_eq() {
    # assert_eq <label> <actual> <expected>
    local label="$1" actual="$2" expected="$3"
    actual=$(echo "$actual" | tr -d '[:space:]')
    expected=$(echo "$expected" | tr -d '[:space:]')
    if [ "$actual" = "$expected" ]; then
        ok "  ASSERT PASS  ${label}: ${actual} = ${expected}"
        ASSERT_PASS=$((ASSERT_PASS + 1))
        return 0
    else
        fail_msg "  ASSERT FAIL  ${label}: got '${actual}', expected '${expected}'"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        return 1
    fi
}

assert_gt() {
    # assert_gt <label> <actual> <threshold>
    local label="$1" actual="$2" threshold="$3"
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        ok "  ASSERT PASS  ${label}: ${actual} > ${threshold}"
        ASSERT_PASS=$((ASSERT_PASS + 1))
        return 0
    else
        fail_msg "  ASSERT FAIL  ${label}: got '${actual}', expected > ${threshold}"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        return 1
    fi
}

assert_le() {
    local label="$1" actual="$2" threshold="$3"
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [ "$actual" -le "$threshold" ] 2>/dev/null; then
        ok "  ASSERT PASS  ${label}: ${actual} <= ${threshold}"
        ASSERT_PASS=$((ASSERT_PASS + 1))
        return 0
    else
        fail_msg "  ASSERT FAIL  ${label}: got '${actual}', expected <= ${threshold}"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        return 1
    fi
}

assert_ge() {
    local label="$1" actual="$2" threshold="$3"
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [ "$actual" -ge "$threshold" ] 2>/dev/null; then
        ok "  ASSERT PASS  ${label}: ${actual} >= ${threshold}"
        ASSERT_PASS=$((ASSERT_PASS + 1))
        return 0
    else
        fail_msg "  ASSERT FAIL  ${label}: got '${actual}', expected >= ${threshold}"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        return 1
    fi
}

# =============================================================================
# Test lifecycle
# =============================================================================

begin_test() {
    CURRENT_TEST="$1"
    ASSERT_PASS=0
    ASSERT_FAIL=0
    section "TEST ${CURRENT_TEST}: $2"
}

end_test() {
    echo ""
    if [ "$ASSERT_FAIL" -eq 0 ]; then
        ok "${BOLD}TEST ${CURRENT_TEST}: PASS (${ASSERT_PASS} assertions)${NC}"
        set_result "$CURRENT_TEST" "PASS"
        set_note   "$CURRENT_TEST" "${ASSERT_PASS} assertions"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail_msg "${BOLD}TEST ${CURRENT_TEST}: FAIL (${ASSERT_FAIL} failed, ${ASSERT_PASS} passed)${NC}"
        set_result "$CURRENT_TEST" "FAIL"
        set_note   "$CURRENT_TEST" "${ASSERT_FAIL} failures"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    CURRENT_TEST=""
}

skip_test() {
    local id="$1" reason="$2"
    warn "TEST ${id}: SKIP -- ${reason}"
    set_result "$id" "SKIP"
    set_note   "$id" "$reason"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

should_run() {
    local id="$1"
    for t in $RUN_TESTS; do
        [ "$t" = "$id" ] && return 0
    done
    return 1
}

# =============================================================================
# Full recovery (used between tests to restore 7-node healthy state)
# =============================================================================

full_recovery() {
    subsection "Full recovery: restoring 7-node cluster"

    # 1. Flush all iptables
    flush_all_iptables
    info "iptables flushed on all running nodes"

    # 2. Start all stopped nodes
    local any_started=false
    for c in "${ALL_CONTAINERS[@]}"; do
        if [ "$(container_state "$c")" != "running" ]; then
            docker start "$c" >/dev/null 2>&1 && info "Started $c" || warn "Failed to start $c"
            any_started=true
        fi
    done

    # 3. Wait for full cluster
    wait_for_cluster_size 7 120 || warn "Cluster did not fully re-form in time"

    # 4. Revive dead partitions + recluster
    revive_all
    do_recluster || true
    sleep 5

    # 5. Re-quiesce C1
    ensure_quorum_quiesced || warn "Could not re-quiesce C1"

    # 6. Give migrations a moment to settle
    sleep 10

    local cs
    cs=$(seed_cluster_size)
    if [ "$cs" = "7" ]; then
        ok "Full recovery complete: cluster_size=7"
    else
        warn "Recovery: cluster_size=${cs} (expected 7)"
    fi
    echo ""
}

# =============================================================================
# Baseline assertions (used both in BASELINE test and as sanity checks)
# =============================================================================

assert_baseline() {
    local cs
    cs=$(seed_cluster_size)

    assert_eq "cluster_size" "$cs" "7"

    local seed_info
    seed_info=$(find_running_seed)
    if [ -z "$seed_info" ]; then
        fail_msg "  ASSERT FAIL  No running seed node"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        return
    fi
    local sc="${seed_info%%|*}" si="${seed_info##*|}"

    # SC enabled
    assert_eq "strong-consistency" \
        "$(get_ns_stat "$sc" "$si" "strong-consistency")" "true"

    # Roster must be set (non-null, non-empty)
    local roster_raw
    roster_raw=$(docker exec "$sc" asinfo -v "roster:namespace=${NAMESPACE}" \
        -h "$si" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || echo "")
    local roster_val
    roster_val=$(echo "$roster_raw" | tr ':' '\n' | grep '^roster=' | cut -d'=' -f2)
    if [ -n "$roster_val" ] && [ "$roster_val" != "null" ]; then
        ok "  ASSERT PASS  roster is set: ${roster_val:0:60}..."
        ASSERT_PASS=$((ASSERT_PASS + 1))
    else
        fail_msg "  ASSERT FAIL  roster is empty or null"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
    fi

    # C1 quiesced
    assert_eq "C1 effective_is_quiesced" \
        "$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")" "true"

    # No unavailable partitions
    assert_eq "unavailable_partitions" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    # All masters on the active-rack (detected at runtime)
    local total_masters=0 active_rack_masters=0
    for i in "${!ALL_CONTAINERS[@]}"; do
        [ "$(container_state "${ALL_CONTAINERS[$i]}")" != "running" ] && continue
        local ns_raw
        ns_raw=$(docker exec "${ALL_CONTAINERS[$i]}" asinfo \
            -v "namespace/${NAMESPACE}" -h "${ALL_IPS[$i]}" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null | tr ';' '\n')
        local m rack
        m=$(echo "$ns_raw" | grep '^master_objects=' | cut -d'=' -f2 || echo 0)
        rack=$(echo "$ns_raw" | grep '^rack-id=' | cut -d'=' -f2 || echo 0)
        m=${m:-0}
        total_masters=$((total_masters + m))
        [ "$rack" = "$EFFECTIVE_ACTIVE_RACK" ] && active_rack_masters=$((active_rack_masters + m))
    done
    if [ "$total_masters" -gt 0 ] && [ "$active_rack_masters" -eq "$total_masters" ]; then
        ok "  ASSERT PASS  all ${total_masters} masters on Rack ${EFFECTIVE_ACTIVE_RACK} (active-rack=${EFFECTIVE_ACTIVE_RACK} working)"
        ASSERT_PASS=$((ASSERT_PASS + 1))
    elif [ "$total_masters" -eq 0 ]; then
        warn "  ASSERT WARN  no master objects yet (cluster may still be migrating)"
    else
        fail_msg "  ASSERT FAIL  only ${active_rack_masters}/${total_masters} masters on Rack ${EFFECTIVE_ACTIVE_RACK}"
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
    fi
}

# =============================================================================
# TESTS
# =============================================================================

run_test_BASELINE() {
    begin_test "BASELINE" "Cluster health after fresh start"

    subsection "Verifying 7-node healthy state"
    assert_baseline

    # All 7 containers running and healthy
    subsection "Container health"
    for i in "${!ALL_CONTAINERS[@]}"; do
        local c="${ALL_CONTAINERS[$i]}" id="${ALL_IDS[$i]}"
        local state health
        state=$(container_state "$c")
        health=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "none")
        assert_eq "${id} container state" "$state" "running"
        if [ "$health" != "none" ]; then
            assert_eq "${id} health" "$health" "healthy"
        fi
    done

    end_test
}

run_test_N1() {
    begin_test "N1" "Single data-node failure (B2 -- replica node)"
    # Use a replica node so cluster stays fully operational (no unavailable partitions)

    subsection "Stopping B2 (site2-node2, replica node)"
    stop_nodes "site2-node2"
    sleep 15

    subsection "Assertions after B2 stop"
    wait_for_cluster_size 6 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after single replica stop" "$cs" "6"

    # Cluster must still serve reads/writes (replica node stopped, masters intact)
    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"
    assert_eq "unavailable_partitions" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    subsection "Recovery"
    start_nodes "site2-node2"
    wait_for_cluster_size 7 60 || true
    revive_all
    do_recluster || true
    sleep 10

    assert_eq "cluster_size after recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_N2() {
    begin_test "N2" "Tiebreaker (C1 quorum-node) failure"

    subsection "Stopping C1 (quorum-node -- quiesced, 0 partitions)"
    stop_nodes "$QUORUM_CONTAINER"
    sleep 12

    subsection "Assertions after C1 stop"
    # 6 data nodes should still form a healthy cluster (>= min-cluster-size=${EFFECTIVE_MCS})
    wait_for_cluster_size 6 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after C1 stop" "$cs" "6"

    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"

    # C1 held 0 partitions → no data impact
    assert_eq "unavailable_partitions (C1 was quiesced)" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    subsection "Recovery"
    start_nodes "$QUORUM_CONTAINER"
    wait_for_cluster_size 7 60 || true
    sleep 5
    ensure_quorum_quiesced || warn "C1 quiesce pending"
    sleep 5

    assert_eq "cluster_size after C1 return" "$(seed_cluster_size)" "7"
    assert_eq "C1 re-quiesced" \
        "$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")" "true"

    end_test
}

run_test_N3() {
    begin_test "N3" "Site1 single node failure -- partition impact depends on active-rack"

    subsection "Stopping A1 (site1-node1)"
    stop_nodes "site1-node1"
    # Aerospike SC: failed master partitions become unavailable -- no auto-promotion
    sleep 20

    subsection "Assertions after A1 stop"
    wait_for_cluster_size 6 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after A1 stop" "$cs" "6"

    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"
    local unavail
    unavail=$(get_ns_stat "$sc" "$si" "unavailable_partitions")

    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # A1 is on the active-rack -- it held ~1365 master partitions; they become unavailable
        assert_gt "unavailable_partitions > 0 (A1 holds masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
    else
        # A1 is a replica node; masters are on Rack ${EFFECTIVE_ACTIVE_RACK} and still running
        assert_eq "unavailable_partitions = 0 (A1 is replica, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
    fi

    subsection "Recovery"
    start_nodes "site1-node1"
    wait_for_cluster_size 7 60 || true
    revive_all
    do_recluster || true
    sleep 15  # allow partition migrations to settle

    assert_eq "cluster_size after A1 return" "$(seed_cluster_size)" "7"

    local seed_info2
    seed_info2=$(find_running_seed)
    sc="${seed_info2%%|*}"; si="${seed_info2##*|}"
    assert_eq "unavailable_partitions back to 0 after A1 return" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    end_test
}

run_test_S1() {
    begin_test "S1" "Site 1 failure (A1-A3 stopped)"

    subsection "Stopping A1, A2, A3 (all Site1 nodes)"
    stop_nodes "${SITE1_CONTAINERS[@]}"
    sleep 20  # cluster detects 3-node loss and re-forms

    subsection "Assertions after Site1 failure"
    # Remaining: B1,B2,B3 + C1 = 4 nodes
    wait_for_cluster_size 4 90 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after Site1 loss (Site2+C1 = 4)" "$cs" "4"

    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"

    local unavail
    unavail=$(get_ns_stat "$sc" "$si" "unavailable_partitions")

    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # Site1 = active-rack: all 4096 masters were on Site1 -- all gone
        assert_eq "unavailable_partitions = 4096 (Site1 held all masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-?}" "4096"
    else
        # Site1 = replica rack: masters are on Rack ${EFFECTIVE_ACTIVE_RACK} (Site2), still running
        assert_eq "unavailable_partitions = 0 (Site1 is replica, masters on Rack ${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-?}" "0"
    fi

    # SC never auto-promotes replicas to masters on node loss (only on roster change)
    info "cluster_integrity=$(get_stat "$sc" "$si" "cluster_integrity") (informational)"

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after S1 recovery" "$(seed_cluster_size)" "7"

    local seed_info2
    seed_info2=$(find_running_seed)
    sc="${seed_info2%%|*}"; si="${seed_info2##*|}"
    assert_eq "unavailable_partitions after recovery" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    end_test
}

run_test_S2() {
    begin_test "S2" "Site 2 failure (B1-B3 stopped)"

    subsection "Stopping B1, B2, B3 (all Site2 nodes)"
    stop_nodes "${SITE2_CONTAINERS[@]}"
    sleep 20

    subsection "Assertions after Site2 failure"
    # Remaining: Site1(3) + C1(1) = 4 nodes
    wait_for_cluster_size 4 90 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after Site2 loss (Site1+C1 = 4)" "$cs" "4"

    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"

    local unavail
    unavail=$(get_ns_stat "$sc" "$si" "unavailable_partitions")

    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # Site2 = replica rack: masters are on Site1 (still running) -- no impact
        assert_eq "unavailable_partitions = 0 (Site2 is replica, masters on Rack 1)" \
            "${unavail:-?}" "0"
        local site1_masters=0
        for i in 0 1 2; do
            local m
            m=$(get_ns_stat "${SITE1_CONTAINERS[$i]}" "${SITE1_IPS[$i]}" "master_objects")
            site1_masters=$((site1_masters + ${m:-0}))
        done
        assert_gt "Site1 still holds all masters after Site2 loss" "$site1_masters" "0"
    else
        # Site2 = active-rack: all masters were on Site2 -- all 4096 unavailable
        assert_eq "unavailable_partitions = 4096 (Site2 held all masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-?}" "4096"
    fi

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after S2 recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_S3() {
    begin_test "S3" "DC1 failure (Site1 + C1) -- cluster drops to Site2-only (3 nodes)"
    # Site1(3) + C1(1) = 4 nodes gone; only Site2(3) remains.
    # If mcs > 3: cluster halts entirely.
    # If mcs <= 3: Site2 may still form a 3-node sub-cluster but with no masters (if ar=1).

    subsection "Stopping A1, A2, A3 + C1 (all DC1 nodes)"
    stop_nodes "${SITE1_CONTAINERS[@]}" "$QUORUM_CONTAINER"
    sleep 20

    subsection "Assertions after DC1 failure"
    # Only B1,B2,B3 remain = 3 nodes
    local cs
    cs=$(seed_cluster_size)
    info "cluster_size on surviving Site2 nodes: $cs (expected <= 3, min-cluster-size=${EFFECTIVE_MCS})"
    assert_le "cluster_size <= 3 (Site2 alone = 3 nodes)" "${cs:-0}" "3"

    local site2_cs
    site2_cs=$(get_cluster_size "site2-node1" "172.28.0.21")
    info "Site2 internal cluster_size=$site2_cs  (stop_writes if mcs=${EFFECTIVE_MCS} > 3)"

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after DC1 recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_P2() {
    begin_test "P2" "Network partition: isolate Site2 (majority stays live)"

    subsection "Applying iptables: Site2 isolated from Site1+Quorum"
    local s2c s2i othersc othersi
    s2c=$(IFS=','; echo "${SITE2_CONTAINERS[*]}")
    s2i=$(IFS=','; echo "${SITE2_IPS[*]}")
    othersc=$(IFS=','; echo "${SITE1_CONTAINERS[*]},$QUORUM_CONTAINER")
    othersi=$(IFS=','; echo "${SITE1_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s2c" "$s2i" "$othersc" "$othersi"
    info "iptables DROP rules applied bidirectionally between Site2 and Site1+Quorum"
    sleep 20

    subsection "Assertions on majority side (Site1 + C1 = 4 nodes)"
    # Majority: A1,A2,A3,C1 = 4 nodes >= min-cluster-size -- stays live
    # Minority: B1,B2,B3 = 3 nodes (may halt if mcs > 3)
    local site1_cs
    site1_cs=$(get_cluster_size "site1-node1" "172.28.0.11")
    assert_eq "majority cluster_size (Site1+C1 = 4)" "${site1_cs}" "4"

    local unavail
    unavail=$(get_ns_stat "site1-node1" "172.28.0.11" "unavailable_partitions")
    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # Site1 is active-rack -- masters still intact on majority side
        assert_eq "unavailable_partitions on majority side = 0 (masters intact on Rack 1)" \
            "${unavail:-?}" "0"
    else
        # Site2 is active-rack -- but Site2 is the isolated minority; masters unreachable
        assert_eq "unavailable_partitions = 4096 (masters on isolated Site2, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-?}" "4096"
    fi

    subsection "Assertions on minority side (Site2)"
    local site2_cs
    site2_cs=$(get_cluster_size "site2-node1" "172.28.0.21")
    info "Site2 cluster_size=${site2_cs} (should be <= 3; halts if mcs=${EFFECTIVE_MCS} > 3)"
    assert_le "minority cluster_size <= 3 (Site2 alone = 3 nodes)" "${site2_cs:-0}" "3"

    subsection "Recovery: heal network partition"
    flush_all_iptables
    info "iptables flushed -- waiting for cluster to re-merge"
    wait_for_cluster_size 7 90 || true
    revive_all
    do_recluster || true
    sleep 5
    ensure_quorum_quiesced || true
    sleep 10

    assert_eq "cluster_size after P2 heal" "$(seed_cluster_size)" "7"

    end_test
}

run_test_P3() {
    begin_test "P3" "Network partition: isolate Quorum node C1"

    subsection "Applying iptables: C1 isolated from all data nodes"
    local alldata alldataips
    alldata=$(IFS=','; echo "${SITE1_CONTAINERS[*]},${SITE2_CONTAINERS[*]}")
    alldataips=$(IFS=','; echo "${SITE1_IPS[*]},${SITE2_IPS[*]}")
    isolate_bidirectional "$QUORUM_CONTAINER" "$QUORUM_IP" "$alldata" "$alldataips"
    info "C1 isolated from all 6 data nodes"
    sleep 20

    subsection "Assertions on data cluster (6 nodes)"
    # 6 data nodes (well above min-cluster-size=${EFFECTIVE_MCS}) should stay alive
    local data_cs
    data_cs=$(get_cluster_size "site1-node1" "172.28.0.11")
    assert_eq "6-node data cluster_size after C1 isolation" "${data_cs}" "6"

    # C1 held 0 partitions -- no data impact on data cluster
    local unavail
    unavail=$(get_ns_stat "site1-node1" "172.28.0.11" "unavailable_partitions")
    assert_eq "unavailable_partitions = 0 (C1 was quiesced)" "${unavail:-?}" "0"

    subsection "Recovery: heal C1 isolation"
    flush_all_iptables
    wait_for_cluster_size 7 60 || true
    sleep 5
    ensure_quorum_quiesced || true
    sleep 5

    assert_eq "cluster_size after P3 heal" "$(seed_cluster_size)" "7"
    assert_eq "C1 re-quiesced after re-join" \
        "$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")" "true"

    end_test
}

run_test_P1() {
    begin_test "P1" "Network partition: isolate Site1"
    # Minority: Site1 (3 nodes) -- stops if mcs > 3
    # Majority: Site2+C1 (4 nodes) -- if active-rack=1, masters are stranded on Site1 → IO-dead
    #                               -- if active-rack=2, masters are on Site2 → stays operational

    subsection "Applying iptables: Site1 isolated from Site2+Quorum"
    local s1c s1i othersc othersi
    s1c=$(IFS=','; echo "${SITE1_CONTAINERS[*]}")
    s1i=$(IFS=','; echo "${SITE1_IPS[*]}")
    othersc=$(IFS=','; echo "${SITE2_CONTAINERS[*]},$QUORUM_CONTAINER")
    othersi=$(IFS=','; echo "${SITE2_IPS[*]},$QUORUM_IP")
    isolate_bidirectional "$s1c" "$s1i" "$othersc" "$othersi"
    info "Site1 fully isolated (bidirectional DROP)"
    sleep 20

    subsection "Assertions on majority side (Site2+C1 = 4 nodes)"
    local majority_cs
    majority_cs=$(get_cluster_size "site2-node1" "172.28.0.21")
    assert_eq "majority forms 4-node cluster (Site2+C1)" "${majority_cs}" "4"

    local unavail_majority
    unavail_majority=$(get_ns_stat "site2-node1" "172.28.0.21" "unavailable_partitions")
    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # Masters are on isolated Site1 (minority) → all 4096 unreachable on majority side
        assert_eq "unavailable_partitions = 4096 on majority (masters stranded on Site1)" \
            "${unavail_majority:-?}" "4096"
    else
        # Site2 is active-rack -- majority has all masters → operational
        assert_eq "unavailable_partitions = 0 on majority (Site2 holds masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail_majority:-?}" "0"
    fi

    subsection "Assertions on minority side (Site1)"
    local site1_cs
    site1_cs=$(get_cluster_size "site1-node1" "172.28.0.11")
    info "Site1 cluster_size=${site1_cs} (should be <= 3; halts if mcs=${EFFECTIVE_MCS} > 3)"
    assert_le "Site1 minority cluster_size <= 3" "${site1_cs:-0}" "3"

    subsection "Recovery: heal partition"
    flush_all_iptables
    info "Healing partition -- both sides should re-merge"
    wait_for_cluster_size 7 90 || true
    revive_all
    do_recluster || true
    sleep 5
    ensure_quorum_quiesced || true
    sleep 10

    assert_eq "cluster_size after P1 heal" "$(seed_cluster_size)" "7"

    wait_for_ns_stat "unavailable_partitions" "0" 60 || true
    local seed_info
    seed_info=$(find_running_seed)
    local sc="${seed_info%%|*}" si="${seed_info##*|}"
    assert_eq "unavailable_partitions = 0 after heal" \
        "$(get_ns_stat "$sc" "$si" "unavailable_partitions")" "0"

    end_test
}

run_test_D1() {
    begin_test "D1" "Site1 degraded -- 2 of 3 Site1 nodes down (A1+A2 stopped)"

    subsection "Stopping A1 and A2 (keeping A3 as lone Site1 survivor)"
    stop_nodes "site1-node1" "site1-node2"
    sleep 20

    subsection "Assertions after degraded Site1"
    # 1 Site1 + 3 Site2 + C1 = 5 nodes (>= min-cluster-size=${EFFECTIVE_MCS})
    wait_for_cluster_size 5 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size with Site1 degraded (5 nodes)" "$cs" "5"

    local unavail
    unavail=$(get_ns_stat "site1-node3" "172.28.0.13" "unavailable_partitions")

    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # A1+A2 held ~2731 masters -- they are now unavailable
        assert_gt "unavailable_partitions > 0 (A1+A2 held masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
        # A3 (Rack 1) still holds its remaining ~1365 masters
        local a3_masters
        a3_masters=$(get_ns_stat "site1-node3" "172.28.0.13" "master_objects")
        assert_gt "A3 still holds some masters (active-rack=${EFFECTIVE_ACTIVE_RACK})" "${a3_masters:-0}" "0"
    else
        # A1+A2 are replica nodes; masters are on Rack ${EFFECTIVE_ACTIVE_RACK} (Site2), still running
        assert_eq "unavailable_partitions = 0 (A1+A2 are replicas, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
    fi

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after D1 recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_D3() {
    begin_test "D3" "Quorum + one data node failure (C1 + A3 stopped)"

    subsection "Stopping C1 and A3 (quorum + one Site1 node)"
    stop_nodes "$QUORUM_CONTAINER" "site1-node3"
    sleep 15

    subsection "Assertions after C1 + A3 failure"
    # 2 Site1 + 3 Site2 = 5 nodes (>= min-cluster-size=${EFFECTIVE_MCS})
    wait_for_cluster_size 5 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after C1+A3 stop (5 nodes)" "$cs" "5"

    local unavail
    unavail=$(get_ns_stat "site1-node1" "172.28.0.11" "unavailable_partitions")

    if [ "$EFFECTIVE_ACTIVE_RACK" = "1" ]; then
        # A3 held ~1365 masters on Rack 1 → unavailable
        assert_gt "unavailable_partitions > 0 (A3 held masters, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
    else
        # A3 is a replica; masters are on Rack ${EFFECTIVE_ACTIVE_RACK} and still running
        assert_eq "unavailable_partitions = 0 (A3 is replica, active-rack=${EFFECTIVE_ACTIVE_RACK})" \
            "${unavail:-0}" "0"
    fi

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after D3 recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_D4() {
    begin_test "D4" "Cascading failure: C1 down then full Site2 (4 nodes = min-cluster-size)"

    subsection "Step 1: Stop C1 (quorum node)"
    stop_nodes "$QUORUM_CONTAINER"
    sleep 12
    wait_for_cluster_size 6 60 || true
    local cs
    cs=$(seed_cluster_size)
    assert_eq "cluster_size after C1 stop = 6" "$cs" "6"

    subsection "Step 2: Stop Site2 (cascade to 3 nodes)"
    stop_nodes "${SITE2_CONTAINERS[@]}"
    sleep 20

    subsection "Assertions after cascade"
    # A1,A2,A3 = 3 nodes alone (halts if mcs=${EFFECTIVE_MCS} > 3)
    cs=$(seed_cluster_size)
    info "cluster_size after cascade: $cs (expected <= 3; halts if mcs=${EFFECTIVE_MCS} > 3)"
    assert_le "cluster_size <= 3 (Site1 alone = 3 nodes)" "${cs:-0}" "3"

    subsection "Recovery"
    full_recovery

    assert_eq "cluster_size after D4 recovery" "$(seed_cluster_size)" "7"

    end_test
}

run_test_O2() {
    begin_test "O2" "Quiesce verify: C1 is effective_is_quiesced after re-quiesce"

    subsection "Current quiesce state of C1"
    local q_before
    q_before=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    info "C1 effective_is_quiesced before test: $q_before"

    subsection "Un-quiesce C1 (remove quiesce), then re-quiesce it"
    docker exec "$QUORUM_CONTAINER" asadm --enable \
        -e "manage undo quiesce with ${QUORUM_IP}:3000" 2>/dev/null >/dev/null || \
    docker exec "$QUORUM_CONTAINER" asinfo \
        -v "quiesce-undo:" -h "$QUORUM_IP" -p 3000 -t "$ASINFO_TIMEOUT" 2>/dev/null || true
    do_recluster || true
    sleep 8

    local q_unquiesced
    q_unquiesced=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    info "C1 effective_is_quiesced after un-quiesce: $q_unquiesced"
    assert_eq "C1 un-quiesced (should be false)" "$q_unquiesced" "false"

    subsection "Re-quiesce C1"
    docker exec "$QUORUM_CONTAINER" asadm --enable \
        -e "manage quiesce with ${QUORUM_IP}:3000" 2>/dev/null >/dev/null || true
    do_recluster || true
    sleep 8

    local q_after
    q_after=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "effective_is_quiesced")
    assert_eq "C1 re-quiesced (should be true)" "$q_after" "true"

    local c1_masters
    c1_masters=$(get_ns_stat "$QUORUM_CONTAINER" "$QUORUM_IP" "master_objects")
    assert_eq "C1 holds 0 master_objects (quiesced)" "${c1_masters:-0}" "0"

    end_test
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    section "VALIDATION SUMMARY"

    printf "  %-10s  %-8s  %s\n" "TEST" "RESULT" "NOTES"
    printf "  %-10s  %-8s  %s\n" "----------" "--------" "-----"
    for t in $ALL_TEST_IDS; do
        local result notes color
        result=$(get_result "$t")
        result="${result:-SKIP}"
        notes=$(get_note "$t")
        notes="${notes:-not run}"
        color="$NC"
        case "$result" in
            PASS) color="$GREEN" ;;
            FAIL) color="$RED"   ;;
            SKIP) color="$DIM"   ;;
        esac
        printf "  %-10s  " "$t"
        echo -e "${color}${result}${NC}  ${notes}"
    done

    echo ""
    echo -e "${BOLD}  Results:  ${GREEN}${PASS_COUNT} PASS${NC}  ${RED}${FAIL_COUNT} FAIL${NC}  ${DIM}${SKIP_COUNT} SKIP${NC}${NC}"
    echo ""

    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}  ALL TESTS PASSED${NC}"
    else
        echo -e "${RED}${BOLD}  ${FAIL_COUNT} TEST(S) FAILED${NC}"
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo -e "${BOLD}=== Aerospike Multi-Site SC Cluster -- Scenario Validation ===${NC}"
echo -e "${DIM}  7 nodes | RF=4 | 3 racks | SC mode${NC}"
echo ""

# ── Step 0: Optionally start the cluster ──────────────────────────────────────
if ! $SKIP_START; then
    section "Starting cluster from scratch"
    info "Running: ${SCRIPT_DIR}/run.sh"
    if ! bash "${SCRIPT_DIR}/run.sh"; then
        echo -e "${RED}${BOLD}run.sh failed -- cannot proceed with validation${NC}"
        exit 1
    fi
    echo ""
    info "Giving cluster 10s to fully stabilize after run.sh..."
    sleep 10
else
    info "Skipping cluster start (--skip-start)"
    # Brief check that at least one node is up
    if [ -z "$(find_running_seed)" ]; then
        echo -e "${RED}No running nodes found and --skip-start was set. Start the cluster first.${NC}"
        exit 1
    fi
fi

# Detect active-rack and min-cluster-size from the live cluster.
# This makes all subsequent assertions config-aware.
detect_cluster_config
echo -e "${DIM}  active-rack=${EFFECTIVE_ACTIVE_RACK}  min-cluster-size=${EFFECTIVE_MCS}${NC}"
echo ""

# ── Step 1: Run selected tests ────────────────────────────────────────────────

for TEST_ID in $ALL_TEST_IDS; do
    if ! should_run "$TEST_ID"; then
        skip_test "$TEST_ID" "not in --test list"
        continue
    fi

    # Run the test
    if ! declare -f "run_test_${TEST_ID}" >/dev/null 2>&1; then
        skip_test "$TEST_ID" "no test function defined"
        continue
    fi

    # Run and capture failure without aborting the whole suite
    if "run_test_${TEST_ID}" 2>&1; then
        true
    else
        # If the test function itself errored (bash -e), record it
        if [ -n "$CURRENT_TEST" ]; then
            fail_msg "TEST ${CURRENT_TEST} aborted with bash error"
            set_result "$CURRENT_TEST" "FAIL"
            set_note   "$CURRENT_TEST" "bash error during test"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            CURRENT_TEST=""
        fi
    fi

    # Ensure clean state between tests (even if test didn't explicitly recover)
    if [ "$CURRENT_TEST" != "" ]; then
        # end_test was not called -- force it
        end_test
    fi

    # Safety recovery between tests
    echo ""
    info "--- Post-test safety recovery ---"
    full_recovery
done

# ── Final summary ─────────────────────────────────────────────────────────────
print_summary

[ "$FAIL_COUNT" -eq 0 ]

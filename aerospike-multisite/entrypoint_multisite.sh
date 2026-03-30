#!/bin/bash
# =============================================================================
# Aerospike Multi-Site Cluster - Entrypoint
# =============================================================================
# 1. Validates required environment variables
# 2. Builds MESH_SEED_LIST from comma-separated MESH_SEEDS env var
# 3. Runs envsubst to render aerospike.conf from the template
# 4. Execs asd in the foreground
#
# AUTO_QUIESCE mode (set AUTO_QUIESCE=true on the quorum/tie-breaker node):
#   Instead of exec'ing asd, runs it as a background process and starts a
#   quiesce-keeper alongside it. The keeper quiesces this node the moment the
#   cluster forms, before Aerospike's automatic recluster can assign any
#   partitions to it. It also monitors and re-applies quiesce if it is ever
#   removed at runtime. This avoids all partition migration on every restart.
# =============================================================================
set -euo pipefail

TEMPLATE="/etc/aerospike/config/aerospike.conf.template"
CONFIG="/etc/aerospike/config/aerospike.conf"

# ---- Validate required environment variables ----
missing_vars=()
for var in NODE_ID RACK_ID SERVICE_ADDRESS; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo "ERROR: Required environment variables are not set: ${missing_vars[*]}"
    echo "Each node requires NODE_ID, RACK_ID, and SERVICE_ADDRESS."
    exit 1
fi

# ---- Build mesh-seed-address-port lines from MESH_SEEDS ----
# MESH_SEEDS format: "ip1:port1,ip2:port2,..."
# Note: Including this node's own address is harmless; Aerospike ignores self-seeds.
MESH_SEED_LIST=""
if [ -n "${MESH_SEEDS:-}" ]; then
    IFS=',' read -ra SEEDS <<< "$MESH_SEEDS"
    for seed in "${SEEDS[@]}"; do
        # Trim whitespace (MESH_SEEDS may be multi-line via YAML >- folding)
        seed=$(echo "$seed" | xargs)
        [ -z "$seed" ] && continue
        host="${seed%%:*}"
        port="${seed##*:}"
        MESH_SEED_LIST="${MESH_SEED_LIST}        mesh-seed-address-port ${host} ${port}"$'\n'
    done
else
    echo "WARNING: MESH_SEEDS is empty. This node will not discover peers."
fi
export MESH_SEED_LIST

# ---- Render the config ----
envsubst '${NODE_ID} ${RACK_ID} ${SERVICE_ADDRESS} ${MESH_SEED_LIST}' \
    < "$TEMPLATE" > "$CONFIG"

echo "============================================================"
echo " Aerospike Multi-Site Cluster Node"
echo "============================================================"
echo "  NODE_ID          : ${NODE_ID}"
echo "  RACK_ID          : ${RACK_ID}"
echo "  SERVICE_ADDRESS  : ${SERVICE_ADDRESS}"
echo "  MESH_SEEDS       : ${MESH_SEEDS:-<unset>}"
echo "============================================================"
echo ""
echo "--- Generated aerospike.conf ---"
cat "$CONFIG"
echo "--- End of aerospike.conf ---"
echo ""

# =============================================================================
# Quiesce-keeper (used when AUTO_QUIESCE=true)
# =============================================================================
# Runs as a background process alongside asd.  Quiesces this node as soon as
# the cluster has at least 2 members, then monitors and re-applies quiesce if
# it is ever removed at runtime (e.g., by an operator un-quiesce command).
#
# Why this works:
#   Aerospike triggers its first recluster a few seconds after a node joins.
#   The keeper quiesces + reclusters BEFORE that automatic recluster fires.
#   The combined recluster sees the node as quiesced, so it assigns 0
#   partitions to it — no migration ever starts.
# =============================================================================
_quiesce_keeper() {
    local ip="${SERVICE_ADDRESS}"
    local port=3000
    local ns="${AEROSPIKE_NAMESPACE:-mynamespace}"

    echo "[quiesce-keeper] Waiting for asd to respond on ${ip}:${port}..."
    until asinfo -v "status" -h "$ip" -p "$port" -t 1000 2>/dev/null | grep -q "^ok"; do
        sleep 1
    done
    echo "[quiesce-keeper] asd ready. Waiting for at least one peer (cluster_size >= 2)..."

    local cs=0
    while [ "${cs:-0}" -lt 2 ] 2>/dev/null; do
        cs=$(asinfo -v "statistics" -h "$ip" -p "$port" -t 2000 2>/dev/null \
            | tr ';' '\n' | grep '^cluster_size=' | cut -d'=' -f2 || echo 0)
        sleep 1
    done
    echo "[quiesce-keeper] Cluster visible (size=${cs}). Quiescing this node immediately..."

    # Quiesce self, then trigger recluster so the quiesce is baked into the
    # very first recluster after this node joined — no partition assignment.
    asadm --enable -e "manage quiesce with ${ip}:${port}" 2>&1 \
        | sed 's/^/[quiesce-keeper] /' || true
    asadm --enable -e "manage recluster" 2>&1 \
        | sed 's/^/[quiesce-keeper] /' || true

    echo "[quiesce-keeper] Quiesce+recluster issued. Monitoring every 30s..."

    # Monitoring loop: if quiesce is removed at runtime (e.g. by O2 in
    # simulate-failures.sh), re-apply it automatically so the node never
    # accumulates partitions unexpectedly.
    while true; do
        sleep 30
        local q
        q=$(asinfo -v "namespace/${ns}" -h "$ip" -p "$port" -t 2000 2>/dev/null \
            | tr ';' '\n' | grep '^effective_is_quiesced=' | cut -d'=' -f2 || echo "unknown")
        if [ "$q" != "true" ]; then
            echo "[quiesce-keeper] Node is not quiesced (effective_is_quiesced=${q}). Re-applying..."
            asadm --enable -e "manage quiesce with ${ip}:${port}" 2>&1 \
                | sed 's/^/[quiesce-keeper] /' || true
            asadm --enable -e "manage recluster" 2>&1 \
                | sed 's/^/[quiesce-keeper] /' || true
        fi
    done
}

# ---- Launch Aerospike ----
if [ "${1:-}" = "asd" ]; then
    shift
    if [ "${AUTO_QUIESCE:-false}" = "true" ]; then
        echo "[entrypoint] AUTO_QUIESCE=true: starting asd in background + quiesce-keeper"

        # Start asd as a background process (cannot exec since we need the keeper)
        asd --config-file "$CONFIG" --foreground "$@" &
        ASD_PID=$!

        # Forward stop signals from Docker to asd so 'docker stop' is clean
        trap 'echo "[entrypoint] Caught signal -- stopping asd (pid=$ASD_PID)"; kill -TERM "$ASD_PID" 2>/dev/null' TERM INT

        # Start the keeper in background (it loops forever alongside asd)
        _quiesce_keeper &

        # Block until asd exits (container lifetime = asd lifetime)
        wait "$ASD_PID" || true
    else
        exec asd --config-file "$CONFIG" --foreground "$@"
    fi
fi

exec "$@"

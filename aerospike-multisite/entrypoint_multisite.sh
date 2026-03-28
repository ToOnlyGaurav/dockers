#!/bin/bash
# =============================================================================
# Aerospike Multi-Site Cluster - Entrypoint
# =============================================================================
# 1. Validates required environment variables
# 2. Builds MESH_SEED_LIST from comma-separated MESH_SEEDS env var
# 3. Runs envsubst to render aerospike.conf from the template
# 4. Execs asd in the foreground
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

# ---- Launch Aerospike ----
if [ "${1:-}" = "asd" ]; then
    shift
    exec asd --config-file "$CONFIG" --foreground "$@"
fi

exec "$@"

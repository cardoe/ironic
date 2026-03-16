#!/bin/bash
# 03-enroll-nodes.sh - Enroll pre-created bare metal VMs in Ironic
#
# In the spine-leaf topology, each BM node connects to a specific leaf switch:
#   - Even-indexed nodes (0, 2, ...) -> leaf01
#   - Odd-indexed nodes (1, 3, ...) -> leaf02
#
# The local_link_connection info must reference the correct leaf switch and port.
#
# Run this ON the DevStack VM after stack.sh and post-configuration are done.
#
# Usage:
#   bash scripts/03-enroll-nodes.sh <terraform_output_json>
#
# The argument should be the JSON output from:
#   terraform output -json baremetal_nodes
#
# Example:
#   terraform output -json baremetal_nodes > /tmp/nodes.json
#   scp /tmp/nodes.json ubuntu@<devstack-ip>:/tmp/
#   ssh ubuntu@<devstack-ip> bash scripts/03-enroll-nodes.sh /tmp/nodes.json

set -euo pipefail

REDFISH_PORT="${REDFISH_PORT:-9132}"

info() { echo "[INFO] $1"; }
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; }

export OS_CLOUD=devstack-system-admin

echo "=============================================="
echo "Ironic Bare Metal Node Enrollment"
echo "  (Spine-Leaf Topology)"
echo "=============================================="
echo ""

# =============================================================================
# Parse node information
# =============================================================================

NODES_JSON="${1:-}"

if [[ -n "$NODES_JSON" && -f "$NODES_JSON" ]]; then
    info "Reading node info from $NODES_JSON"
    NODE_COUNT=$(jq 'length' "$NODES_JSON")
else
    NODE_COUNT="${NODE_COUNT:-2}"
    info "No terraform output provided. Using manual configuration."
    info "Set NODE_<N>_UUID, NODE_<N>_MAC, NODE_<N>_SWITCH_PORT, NODE_<N>_SWITCH_INFO"
    echo ""
fi

for i in $(seq 0 $((NODE_COUNT - 1))); do
    echo "--- Enrolling node $i ---"

    if [[ -n "$NODES_JSON" && -f "$NODES_JSON" ]]; then
        NODE_UUID=$(jq -r ".[$i].uuid" "$NODES_JSON")
        NODE_MAC=$(jq -r ".[$i].mac_address" "$NODES_JSON")
        SWITCH_PORT=$(jq -r ".[$i].switch_port" "$NODES_JSON")
        NODE_NAME=$(jq -r ".[$i].name" "$NODES_JSON")
        SWITCH_INFO=$(jq -r ".[$i].leaf_switch" "$NODES_JSON")
    else
        uuid_var="NODE_${i}_UUID"
        mac_var="NODE_${i}_MAC"
        port_var="NODE_${i}_SWITCH_PORT"
        name_var="NODE_${i}_NAME"
        switch_var="NODE_${i}_SWITCH_INFO"
        NODE_UUID="${!uuid_var:?Set $uuid_var}"
        NODE_MAC="${!mac_var:?Set $mac_var}"
        # Default port mapping: leaf01 starts at Eth1/4, leaf02 at Eth1/3
        if (( i % 2 == 0 )); then
            SWITCH_PORT="${!port_var:-Ethernet1/$((4 + i / 2))}"
            SWITCH_INFO="${!switch_var:-leaf01}"
        else
            SWITCH_PORT="${!port_var:-Ethernet1/$((3 + i / 2))}"
            SWITCH_INFO="${!switch_var:-leaf02}"
        fi
        NODE_NAME="${!name_var:-bm-node-$i}"
    fi

    info "  Name:        $NODE_NAME"
    info "  Nova UUID:   $NODE_UUID"
    info "  MAC:         $NODE_MAC"
    info "  Leaf switch: $SWITCH_INFO"
    info "  Switch port: $SWITCH_PORT"

    # Create the Ironic node
    NODE_IRONIC_UUID=$(openstack baremetal node create \
        --driver redfish \
        --name "$NODE_NAME" \
        --driver-info redfish_address="http://localhost:${REDFISH_PORT}" \
        --driver-info redfish_system_id="/redfish/v1/Systems/${NODE_UUID}" \
        --driver-info redfish_username="" \
        --driver-info redfish_password="" \
        --deploy-interface direct \
        --boot-interface redfish-virtual-media \
        --management-interface redfish \
        --power-interface redfish \
        --network-interface neutron \
        --resource-class baremetal \
        -f value -c uuid 2>/dev/null) || {
        NODE_IRONIC_UUID=$(openstack baremetal node show "$NODE_NAME" -f value -c uuid 2>/dev/null || echo "")
        if [[ -z "$NODE_IRONIC_UUID" ]]; then
            fail "Failed to create or find node $NODE_NAME"
            continue
        fi
        info "  Node already exists: $NODE_IRONIC_UUID"
    }

    pass "  Ironic node created: $NODE_IRONIC_UUID"

    # Create the port with local link connection info
    # switch_info must match the [genericswitch:NAME] section in NGS config
    openstack baremetal port create \
        --node "$NODE_IRONIC_UUID" \
        --local-link-connection switch_info="$SWITCH_INFO" \
        --local-link-connection port_id="$SWITCH_PORT" \
        --local-link-connection switch_id="$SWITCH_INFO" \
        "$NODE_MAC" 2>/dev/null || {
        info "  Port may already exist for MAC $NODE_MAC"
    }

    pass "  Port created with local link connection ($SWITCH_INFO:$SWITCH_PORT)"

    # Move node through the state machine: enroll -> manageable -> available
    openstack baremetal node manage "$NODE_IRONIC_UUID" 2>/dev/null || true
    info "  Waiting for node to become manageable..."
    sleep 5

    openstack baremetal node provide "$NODE_IRONIC_UUID" 2>/dev/null || true
    info "  Node set to provide (will become available after cleaning)"

    echo ""
done

# =============================================================================
# Summary
# =============================================================================

echo "=============================================="
info "Enrolled $NODE_COUNT nodes. Current state:"
echo ""
openstack baremetal node list
echo ""
info "Nodes may take a few minutes to reach 'available' state (cleaning)."
info "Monitor with: watch openstack baremetal node list"
echo "=============================================="

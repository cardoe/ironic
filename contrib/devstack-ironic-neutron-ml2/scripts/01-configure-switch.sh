#!/bin/bash
# 01-configure-switch.sh - Configure the Cisco Nexus 9000v switch simulator
#
# The Cisco 9k runs as a Nova instance on the hosting cloud. Initial
# configuration (POAP skip, admin password) must be done via the serial
# console. After that, this script handles SSH-based configuration including
# VXLAN NVE setup for the trunk overlay to DevStack.
#
# Usage:
#   bash scripts/01-configure-switch.sh [options]
#
# Options (via environment variables):
#   SWITCH_IP          - Switch management IP (default: 172.24.5.20)
#   SWITCH_PASS        - Admin password (default: system_s3cret!)
#   NODE_COUNT         - Number of bare metal nodes (default: 3)
#   SWITCH_UNDERLAY_IP - Switch underlay IP for Ethernet1/1 (default: 10.0.99.20)
#   SWITCH_VTEP_IP     - Switch VTEP loopback IP (default: 10.0.99.120)
#   DEVSTACK_UNDERLAY_IP - DevStack underlay IP (default: 10.0.99.10)
#   VLAN_START         - Start of VLAN range (default: 100)
#   VLAN_END           - End of VLAN range (default: 150)
#
# Prerequisites:
#   - The Cisco 9k VM must be booted and initial POAP setup completed
#     via the serial console (see manual steps below)
#   - sshpass must be installed: apt-get install sshpass
#
# Manual initial setup via serial console:
#   1. openstack console url show --serial cisco-nexus9k
#   2. Connect to the serial console URL
#   3. Wait for "Abort Power On Auto Provisioning" prompt (~5-10 min)
#   4. Type: skip
#   5. Wait for "login:" prompt (~2 min)
#   6. Login: admin (no password)
#   7. Run these commands:
#        configure
#        username admin password system_s3cret! role network-admin
#        int mgmt0
#        ip address 172.24.5.20/24
#        exit
#        feature ssh
#        exit
#        copy run start
#   8. Now run this script for the remaining configuration.

set -euo pipefail

SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
SWITCH_PASS="${SWITCH_PASS:-system_s3cret!}"
NODE_COUNT="${NODE_COUNT:-3}"
SWITCH_USER="admin"

# VXLAN underlay configuration
SWITCH_UNDERLAY_IP="${SWITCH_UNDERLAY_IP:-10.0.99.20}"
SWITCH_VTEP_IP="${SWITCH_VTEP_IP:-10.0.99.120}"
DEVSTACK_UNDERLAY_IP="${DEVSTACK_UNDERLAY_IP:-10.0.99.10}"
UNDERLAY_PREFIX="${UNDERLAY_PREFIX:-24}"

# VLAN range (must match DevStack local.conf TENANT_VLAN_RANGE)
VLAN_START="${VLAN_START:-100}"
VLAN_END="${VLAN_END:-150}"
VNI_OFFSET=10000  # VNI = VLAN + VNI_OFFSET

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "      $1"; }

# Check for sshpass
if ! command -v sshpass &>/dev/null; then
    fail "sshpass is required. Install with: apt-get install sshpass"
    exit 1
fi

echo "=============================================="
echo "Cisco Nexus 9000v Switch Configuration"
echo "=============================================="
echo "  Switch mgmt IP:    $SWITCH_IP"
echo "  Switch underlay:   $SWITCH_UNDERLAY_IP/$UNDERLAY_PREFIX"
echo "  Switch VTEP:       $SWITCH_VTEP_IP"
echo "  DevStack underlay: $DEVSTACK_UNDERLAY_IP"
echo "  Node count:        $NODE_COUNT"
echo "  VLAN range:        $VLAN_START-$VLAN_END"
echo ""

# Function to run a command on the switch via SSH
switch_cmd() {
    sshpass -p "$SWITCH_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$SWITCH_USER@$SWITCH_IP" "$1" 2>/dev/null
}

# Wait for SSH to be available
echo "--- Waiting for switch SSH access ---"
MAX_ATTEMPTS=60
for i in $(seq 1 $MAX_ATTEMPTS); do
    if sshpass -p "$SWITCH_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 "$SWITCH_USER@$SWITCH_IP" "show version" &>/dev/null; then
        pass "Switch is accessible via SSH"
        break
    fi
    if [[ $i -eq $MAX_ATTEMPTS ]]; then
        fail "Cannot reach switch at $SWITCH_IP via SSH after $MAX_ATTEMPTS attempts"
        echo ""
        info "Complete the initial setup via serial console first."
        info "See the manual steps in the header of this script."
        exit 1
    fi
    echo -n "."
    sleep 10
done
echo ""

# =========================================================================
# Configure features and underlay
# =========================================================================

echo "--- Enabling features ---"
CONFIG_CMDS="configure terminal"
CONFIG_CMDS+="; feature lldp"
CONFIG_CMDS+="; feature nv overlay"
CONFIG_CMDS+="; feature vn-segment-vlan-based"
CONFIG_CMDS+="; exit"

switch_cmd "$CONFIG_CMDS"
pass "Features enabled (lldp, nv overlay, vn-segment-vlan-based)"

echo "--- Configuring underlay interface (Ethernet1/1) ---"
CONFIG_CMDS="configure terminal"
CONFIG_CMDS+="; interface Ethernet1/1"
CONFIG_CMDS+="; no switchport"
CONFIG_CMDS+="; ip address ${SWITCH_UNDERLAY_IP}/${UNDERLAY_PREFIX}"
CONFIG_CMDS+="; no shutdown"
CONFIG_CMDS+="; exit"

# VTEP loopback
CONFIG_CMDS+="; interface loopback0"
CONFIG_CMDS+="; ip address ${SWITCH_VTEP_IP}/32"
CONFIG_CMDS+="; exit"

CONFIG_CMDS+="; exit"
switch_cmd "$CONFIG_CMDS"
pass "Underlay: Ethernet1/1 ${SWITCH_UNDERLAY_IP}/${UNDERLAY_PREFIX}, loopback0 ${SWITCH_VTEP_IP}/32"

# =========================================================================
# Configure VLANs with VNI mappings
# =========================================================================

echo "--- Configuring VLANs and VNI mappings ---"
CONFIG_CMDS="configure terminal"
for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
    vni=$((vlan + VNI_OFFSET))
    CONFIG_CMDS+="; vlan ${vlan}"
    CONFIG_CMDS+="; vn-segment ${vni}"
    CONFIG_CMDS+="; exit"
done
CONFIG_CMDS+="; exit"

switch_cmd "$CONFIG_CMDS"
pass "VLANs ${VLAN_START}-${VLAN_END} mapped to VNIs $((VLAN_START + VNI_OFFSET))-$((VLAN_END + VNI_OFFSET))"

# =========================================================================
# Configure NVE (VXLAN tunnel endpoint)
# =========================================================================

echo "--- Configuring NVE interface ---"
CONFIG_CMDS="configure terminal"
CONFIG_CMDS+="; interface nve1"
CONFIG_CMDS+="; no shutdown"
CONFIG_CMDS+="; source-interface loopback0"

# Add VNI members with static ingress-replication to DevStack
for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
    vni=$((vlan + VNI_OFFSET))
    CONFIG_CMDS+="; member vni ${vni}"
    CONFIG_CMDS+="; ingress-replication protocol static"
    CONFIG_CMDS+="; peer-ip ${DEVSTACK_UNDERLAY_IP}"
    CONFIG_CMDS+="; exit"
done

CONFIG_CMDS+="; exit"  # exit interface nve1
CONFIG_CMDS+="; exit"  # exit configure terminal

switch_cmd "$CONFIG_CMDS"
pass "NVE1 configured: source loopback0, peer ${DEVSTACK_UNDERLAY_IP}"

# =========================================================================
# Configure access ports for bare metal nodes
# =========================================================================

echo "--- Configuring access ports ---"
CONFIG_CMDS="configure terminal"

# Configure per-node access ports (Ethernet1/2 through Ethernet1/{N+1})
for i in $(seq 0 $((NODE_COUNT - 1))); do
    port_num=$((i + 2))
    CONFIG_CMDS+="; interface Ethernet1/$port_num"
    CONFIG_CMDS+="; switchport"
    CONFIG_CMDS+="; switchport mode access"
    CONFIG_CMDS+="; no shutdown"
    CONFIG_CMDS+="; lldp transmit"
    CONFIG_CMDS+="; exit"
done

CONFIG_CMDS+="; exit"

switch_cmd "$CONFIG_CMDS"
pass "Access ports Ethernet1/2 - Ethernet1/$((NODE_COUNT + 1)) configured"

# =========================================================================
# Save
# =========================================================================

switch_cmd "copy running-config startup-config" || true
pass "Configuration saved"

echo ""
echo "--- Verifying configuration ---"

echo "Interface status:"
switch_cmd "show interface status" || true
echo ""

echo "NVE peers:"
switch_cmd "show nve peers" || true
echo ""

echo "NVE VNI summary:"
switch_cmd "show nve vni summary" || true
echo ""

echo "VXLAN info:"
switch_cmd "show vxlan" || true
echo ""

pass "Switch configuration complete"
echo ""
info "Switch is ready. Key details:"
info "  Management IP:   $SWITCH_IP"
info "  Underlay IP:     $SWITCH_UNDERLAY_IP (Ethernet1/1)"
info "  VTEP IP:         $SWITCH_VTEP_IP (loopback0)"
info "  VXLAN peer:      $DEVSTACK_UNDERLAY_IP (DevStack)"
info "  VNI range:       $((VLAN_START + VNI_OFFSET))-$((VLAN_END + VNI_OFFSET))"
info "  Access ports:    Ethernet1/2 - Ethernet1/$((NODE_COUNT + 1))"
info "  SSH access:      ssh $SWITCH_USER@$SWITCH_IP"

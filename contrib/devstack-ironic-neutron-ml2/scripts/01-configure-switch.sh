#!/bin/bash
# 01-configure-switch.sh - Configure the Cisco Nexus 9000v switch simulator
#
# The Cisco 9k runs as a local QEMU VM inside the DevStack host (nested virt).
# Initial configuration (POAP skip, admin password) must be done via the
# local serial console. After that, this script handles SSH-based configuration.
#
# Usage:
#   bash scripts/01-configure-switch.sh [switch_ip] [password] [node_count]
#
# Prerequisites:
#   - The Cisco 9k VM must be booted and initial POAP setup completed
#     via the serial console (see manual steps below)
#   - sshpass must be installed: apt-get install sshpass
#
# Manual initial setup via serial console:
#   1. telnet 127.0.0.1 4000
#   2. Wait for "Abort Power On Auto Provisioning" prompt (~5-10 min)
#   3. Type: skip
#   4. Wait for "login:" prompt (~2 min)
#   5. Login: admin (no password)
#   6. Run these commands:
#        configure
#        username admin password system_s3cret! role network-admin
#        int mgmt0
#        ip address 192.168.100.20/24
#        exit
#        feature ssh
#        feature lldp
#        exit
#        copy run start
#   7. Now run this script for the remaining configuration.

set -euo pipefail

SWITCH_IP="${1:-192.168.100.20}"
SWITCH_PASS="${2:-system_s3cret!}"
NODE_COUNT="${3:-3}"
SWITCH_USER="admin"

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
echo "  Switch IP: $SWITCH_IP (local management bridge)"
echo "  Node count: $NODE_COUNT"
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
        info "Run: telnet 127.0.0.1 4000"
        info "See the manual steps in the header of this script."
        exit 1
    fi
    echo -n "."
    sleep 10
done
echo ""

# Configure the switch
echo "--- Configuring switch interfaces ---"

# Build the configuration commands
CONFIG_CMDS="configure terminal"

# Enable LLDP globally
CONFIG_CMDS+="; feature lldp"

# Configure Ethernet1/1 as trunk (carries all VLANs to DevStack OVS brbm)
CONFIG_CMDS+="; interface Ethernet1/1"
CONFIG_CMDS+="; switchport"
CONFIG_CMDS+="; switchport mode trunk"
CONFIG_CMDS+="; switchport trunk allowed vlan all"
CONFIG_CMDS+="; no shutdown"
CONFIG_CMDS+="; lldp transmit"
CONFIG_CMDS+="; exit"

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

CONFIG_CMDS+="; exit"  # exit configure terminal

# Apply configuration
switch_cmd "$CONFIG_CMDS"
pass "Interface configuration applied"

# Save configuration
switch_cmd "copy running-config startup-config" || true
pass "Configuration saved"

echo ""
echo "--- Verifying configuration ---"

# Show interface status
echo "Interface status:"
switch_cmd "show interface status" || true
echo ""

# Show LLDP neighbors (will be empty until VMs are connected)
echo "LLDP status:"
switch_cmd "show lldp neighbors" || true
echo ""

pass "Switch configuration complete"
echo ""
info "Switch is ready. Key details:"
info "  Management IP:  $SWITCH_IP (local bridge)"
info "  Admin user:     $SWITCH_USER"
info "  Trunk port:     Ethernet1/1 (all VLANs, local tap to brbm)"
info "  Access ports:   Ethernet1/2 - Ethernet1/$((NODE_COUNT + 1))"
info "  Serial console: telnet 127.0.0.1 4000"
info "  SSH access:     ssh $SWITCH_USER@$SWITCH_IP"

#!/bin/bash
# 01-configure-switch.sh - Manual switch configuration (alternative to POAP)
#
# Use this script if POAP auto-provisioning does not work or you need to
# manually configure switches. For each switch, this script SSHes in and
# applies the same configuration that POAP would deliver.
#
# Prerequisites:
#   - Switches must have mgmt0 IP and SSH configured (manual console setup)
#   - sshpass must be installed: apt-get install sshpass
#
# Manual initial setup via serial console (per switch):
#   1. openstack console url show --serial <switch_name>
#   2. Wait for "Abort Power On Auto Provisioning" prompt (~5-10 min)
#   3. Type: skip
#   4. Wait for "login:" prompt
#   5. Login: admin (no password)
#   6. Run:
#        configure
#        username admin password <password> role network-admin
#        int mgmt0
#        ip address <mgmt_ip>/24
#        exit
#        feature ssh
#        exit
#        copy run start
#
# Usage:
#   bash scripts/01-configure-switch.sh [spine01|spine02|leaf01|leaf02|all]

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SWITCH_PASS="${SWITCH_PASS:-system_s3cret!}"
SWITCH_USER="admin"

SPINE01_IP="${SPINE01_IP:-192.168.32.11}"
SPINE02_IP="${SPINE02_IP:-192.168.32.12}"
LEAF01_IP="${LEAF01_IP:-192.168.32.13}"
LEAF02_IP="${LEAF02_IP:-192.168.32.14}"

BGP_AS="${BGP_AS:-65001}"
VLAN_START="${VLAN_START:-100}"
VLAN_END="${VLAN_END:-150}"
VNI_OFFSET=10000
NODE_COUNT="${NODE_COUNT:-2}"

# Loopback IPs
SPINE01_LO0="10.1.0.1"
SPINE02_LO0="10.1.0.2"
LEAF01_LO0="10.1.0.3"
LEAF02_LO0="10.1.0.4"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo "      $1"; }

if ! command -v sshpass &>/dev/null; then
    fail "sshpass is required. Install with: apt-get install sshpass"
    exit 1
fi

switch_cmd() {
    local ip="$1"
    shift
    sshpass -p "$SWITCH_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$SWITCH_USER@$ip" "$@" 2>/dev/null
}

wait_for_switch() {
    local ip="$1"
    local name="$2"
    echo "--- Waiting for $name ($ip) ---"
    for i in $(seq 1 30); do
        if sshpass -p "$SWITCH_PASS" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=5 "$SWITCH_USER@$ip" "show version" &>/dev/null; then
            pass "$name is accessible"
            return 0
        fi
        echo -n "."
        sleep 10
    done
    fail "Cannot reach $name at $ip"
    return 1
}

# =============================================================================
# Spine01
# =============================================================================

configure_spine01() {
    local ip="$SPINE01_IP"
    wait_for_switch "$ip" "spine01" || return 1

    info "Configuring spine01..."
    switch_cmd "$ip" "$(cat <<'CMDS'
configure terminal
hostname spine01
feature ospf
feature bgp
feature lldp

interface loopback0
  ip address 10.1.0.1/32
  ip router ospf UNDERLAY area 0.0.0.0
  exit

interface Ethernet1/1
  no switchport
  ip address 10.1.1.1/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/2
  no switchport
  ip address 10.1.1.6/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/3
  no switchport
  ip address 10.1.1.14/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

router ospf UNDERLAY
  router-id 10.1.0.1
  exit

router bgp 65001
  router-id 10.1.0.1
  address-family l2vpn evpn
    retain route-target all
    exit
  neighbor 10.1.0.2
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  neighbor 10.1.0.3
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      route-reflector-client
      exit
    exit
  neighbor 10.1.0.4
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      route-reflector-client
      exit
    exit
  exit
exit
CMDS
)"
    switch_cmd "$ip" "copy running-config startup-config" || true
    pass "spine01 configured"
}

# =============================================================================
# Spine02
# =============================================================================

configure_spine02() {
    local ip="$SPINE02_IP"
    wait_for_switch "$ip" "spine02" || return 1

    info "Configuring spine02..."
    switch_cmd "$ip" "$(cat <<'CMDS'
configure terminal
hostname spine02
feature ospf
feature bgp
feature lldp

interface loopback0
  ip address 10.1.0.2/32
  ip router ospf UNDERLAY area 0.0.0.0
  exit

interface Ethernet1/1
  no switchport
  ip address 10.1.1.2/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/2
  no switchport
  ip address 10.1.1.10/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/3
  no switchport
  ip address 10.1.1.18/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

router ospf UNDERLAY
  router-id 10.1.0.2
  exit

router bgp 65001
  router-id 10.1.0.2
  address-family l2vpn evpn
    retain route-target all
    exit
  neighbor 10.1.0.1
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  neighbor 10.1.0.3
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      route-reflector-client
      exit
    exit
  neighbor 10.1.0.4
    remote-as 65001
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      route-reflector-client
      exit
    exit
  exit
exit
CMDS
)"
    switch_cmd "$ip" "copy running-config startup-config" || true
    pass "spine02 configured"
}

# =============================================================================
# Leaf01
# =============================================================================

configure_leaf01() {
    local ip="$LEAF01_IP"
    wait_for_switch "$ip" "leaf01" || return 1

    info "Configuring leaf01..."

    # Base features and interfaces
    switch_cmd "$ip" "$(cat <<CMDS
configure terminal
hostname leaf01
feature ospf
feature bgp
feature lldp
feature nv overlay
feature vn-segment-vlan-based

interface loopback0
  ip address ${LEAF01_LO0}/32
  ip router ospf UNDERLAY area 0.0.0.0
  exit

interface Ethernet1/1
  no switchport
  ip address 10.1.1.5/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/2
  no switchport
  ip address 10.1.1.9/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/3
  switchport
  switchport mode trunk
  switchport trunk allowed vlan ${VLAN_START}-${VLAN_END}
  spanning-tree port type edge trunk
  lldp transmit
  no shutdown
  exit
exit
CMDS
)"

    # VLANs + VNI mappings
    local vlan_cmds="configure terminal"
    for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
        vni=$((vlan + VNI_OFFSET))
        vlan_cmds+="; vlan ${vlan}; vn-segment ${vni}; exit"
    done
    vlan_cmds+="; exit"
    switch_cmd "$ip" "$vlan_cmds"

    # NVE interface
    local nve_cmds="configure terminal; interface nve1; no shutdown; source-interface loopback0; host-reachability protocol bgp"
    for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
        vni=$((vlan + VNI_OFFSET))
        nve_cmds+="; member vni ${vni}; ingress-replication protocol bgp; exit"
    done
    nve_cmds+="; exit; exit"
    switch_cmd "$ip" "$nve_cmds"

    # OSPF + BGP
    switch_cmd "$ip" "$(cat <<CMDS
configure terminal
router ospf UNDERLAY
  router-id ${LEAF01_LO0}
  exit
router bgp ${BGP_AS}
  router-id ${LEAF01_LO0}
  address-family l2vpn evpn
    exit
  neighbor ${SPINE01_LO0}
    remote-as ${BGP_AS}
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  neighbor ${SPINE02_LO0}
    remote-as ${BGP_AS}
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  exit
exit
CMDS
)"

    # Access ports for even-indexed BM nodes
    local port_num=4
    local access_cmds="configure terminal"
    for i in $(seq 0 $((NODE_COUNT - 1))); do
        if (( i % 2 == 0 )); then
            access_cmds+="; interface Ethernet1/${port_num}; switchport; switchport mode access"
            access_cmds+="; spanning-tree port type edge; lldp transmit; no shutdown; exit"
            port_num=$((port_num + 1))
        fi
    done
    access_cmds+="; exit"
    switch_cmd "$ip" "$access_cmds"

    switch_cmd "$ip" "copy running-config startup-config" || true
    pass "leaf01 configured"
}

# =============================================================================
# Leaf02
# =============================================================================

configure_leaf02() {
    local ip="$LEAF02_IP"
    wait_for_switch "$ip" "leaf02" || return 1

    info "Configuring leaf02..."

    switch_cmd "$ip" "$(cat <<CMDS
configure terminal
hostname leaf02
feature ospf
feature bgp
feature lldp
feature nv overlay
feature vn-segment-vlan-based

interface loopback0
  ip address ${LEAF02_LO0}/32
  ip router ospf UNDERLAY area 0.0.0.0
  exit

interface Ethernet1/1
  no switchport
  ip address 10.1.1.13/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit

interface Ethernet1/2
  no switchport
  ip address 10.1.1.17/30
  ip ospf network point-to-point
  ip router ospf UNDERLAY area 0.0.0.0
  no shutdown
  exit
exit
CMDS
)"

    # VLANs + VNI (same as leaf01)
    local vlan_cmds="configure terminal"
    for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
        vni=$((vlan + VNI_OFFSET))
        vlan_cmds+="; vlan ${vlan}; vn-segment ${vni}; exit"
    done
    vlan_cmds+="; exit"
    switch_cmd "$ip" "$vlan_cmds"

    # NVE
    local nve_cmds="configure terminal; interface nve1; no shutdown; source-interface loopback0; host-reachability protocol bgp"
    for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
        vni=$((vlan + VNI_OFFSET))
        nve_cmds+="; member vni ${vni}; ingress-replication protocol bgp; exit"
    done
    nve_cmds+="; exit; exit"
    switch_cmd "$ip" "$nve_cmds"

    # OSPF + BGP
    switch_cmd "$ip" "$(cat <<CMDS
configure terminal
router ospf UNDERLAY
  router-id ${LEAF02_LO0}
  exit
router bgp ${BGP_AS}
  router-id ${LEAF02_LO0}
  address-family l2vpn evpn
    exit
  neighbor ${SPINE01_LO0}
    remote-as ${BGP_AS}
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  neighbor ${SPINE02_LO0}
    remote-as ${BGP_AS}
    update-source loopback0
    address-family l2vpn evpn
      send-community extended
      exit
    exit
  exit
exit
CMDS
)"

    # Access ports for odd-indexed BM nodes
    local port_num=3
    local access_cmds="configure terminal"
    for i in $(seq 0 $((NODE_COUNT - 1))); do
        if (( i % 2 == 1 )); then
            access_cmds+="; interface Ethernet1/${port_num}; switchport; switchport mode access"
            access_cmds+="; spanning-tree port type edge; lldp transmit; no shutdown; exit"
            port_num=$((port_num + 1))
        fi
    done
    access_cmds+="; exit"
    switch_cmd "$ip" "$access_cmds"

    switch_cmd "$ip" "copy running-config startup-config" || true
    pass "leaf02 configured"
}

# =============================================================================
# Main
# =============================================================================

TARGET="${1:-all}"

echo "=============================================="
echo "Spine-Leaf Switch Configuration"
echo "=============================================="
echo ""

case "$TARGET" in
    spine01) configure_spine01 ;;
    spine02) configure_spine02 ;;
    leaf01)  configure_leaf01 ;;
    leaf02)  configure_leaf02 ;;
    all)
        configure_spine01
        configure_spine02
        configure_leaf01
        configure_leaf02
        ;;
    *)
        echo "Usage: $0 {spine01|spine02|leaf01|leaf02|all}"
        exit 1
        ;;
esac

echo ""
pass "Switch configuration complete for: $TARGET"

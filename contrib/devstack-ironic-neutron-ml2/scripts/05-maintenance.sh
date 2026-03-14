#!/bin/bash
# 05-maintenance.sh - Maintenance operations for the DevStack environment
#
# Usage:
#   bash scripts/05-maintenance.sh <command>
#
# Commands:
#   status    - Show status of all services and components
#   restart   - Restart all DevStack services
#   logs      - Tail key service logs (Ctrl+C to stop)
#   reconnect - Re-bridge trunk tap and BM interfaces (after reboot)
#   redeploy  - Undeploy all instances and reset nodes to available

set -uo pipefail

SWITCH_IP="${SWITCH_IP:-192.168.100.20}"
REDFISH_PORT="${REDFISH_PORT:-9132}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

SERVICES=(
    "devstack@ir-api"
    "devstack@ir-cond"
    "devstack@neutron-api"
    "devstack@q-agt"
    "devstack@q-dhcp"
    "devstack@q-l3"
    "devstack@q-meta"
    "devstack@n-api"
    "devstack@n-cpu"
    "devstack@n-cond"
    "devstack@n-sch"
    "devstack@g-api"
    "devstack@s-proxy"
    "devstack@redfish-emulator"
    "devstack@key"
)

cmd_status() {
    echo "=============================================="
    echo "Service Status"
    echo "=============================================="
    for svc in "${SERVICES[@]}"; do
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        case "$state" in
            active)   pass "$svc" ;;
            inactive) warn "$svc (inactive)" ;;
            failed)   fail "$svc (FAILED)" ;;
        esac
    done

    echo ""
    echo "--- Cisco 9k (local VM) ---"
    if [[ -f /tmp/cisco9k.pid ]] && kill -0 "$(cat /tmp/cisco9k.pid)" 2>/dev/null; then
        pass "Cisco 9k running (PID $(cat /tmp/cisco9k.pid))"
    else
        warn "Cisco 9k not running"
    fi
    ping -c 1 -W 2 "$SWITCH_IP" &>/dev/null && pass "Switch at $SWITCH_IP" || warn "Switch unreachable"

    echo ""
    echo "--- OVS brbm ports ---"
    sudo ovs-vsctl list-ports brbm 2>/dev/null || warn "brbm not found"

    echo ""
    echo "--- Per-node bridges ---"
    for br in $(ip -o link show type bridge | awk -F': ' '{print $2}' | grep '^br-bm-'); do
        members=$(bridge link show master "$br" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
        echo "  $br: ${members:-<no members>}"
    done

    echo ""
    echo "--- Redfish API ---"
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$REDFISH_PORT/redfish/v1/" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]] && pass "Redfish API (port $REDFISH_PORT)" || warn "Redfish API not responding"
}

cmd_restart() {
    info "Restarting DevStack services..."
    for svc in "${SERVICES[@]}"; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            sudo systemctl restart "$svc" 2>/dev/null
            systemctl is-active --quiet "$svc" 2>/dev/null && pass "$svc" || fail "$svc"
        fi
    done
}

cmd_logs() {
    sudo journalctl -f \
        -u devstack@ir-api \
        -u devstack@ir-cond \
        -u devstack@neutron-api \
        -u devstack@n-cpu \
        -u devstack@redfish-emulator
}

cmd_reconnect() {
    # After a VM reboot, bridges and trunk tap may be lost.
    # Re-create them.

    info "Re-creating trunk tap..."
    sudo ip tuntap add dev tap-sw-trunk mode tap 2>/dev/null || true
    sudo ip link set tap-sw-trunk up
    sudo ovs-vsctl --may-exist add-port brbm tap-sw-trunk
    pass "Trunk tap bridged to brbm"

    info "Re-creating management bridge..."
    sudo ip link add br-sw-mgmt type bridge 2>/dev/null || true
    sudo ip addr add 192.168.100.1/24 dev br-sw-mgmt 2>/dev/null || true
    sudo ip link set br-sw-mgmt up

    info "Detecting and re-bridging BM interfaces..."
    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)

    local idx=0
    while IFS= read -r iface; do
        if [[ $idx -gt 0 ]]; then
            local bm_idx=$((idx - 1))
            local br_name="br-bm-${bm_idx}"
            sudo ip link add "$br_name" type bridge 2>/dev/null || true
            sudo ip link set "$iface" master "$br_name" 2>/dev/null || true
            sudo ip link set "$iface" up
            sudo ip link set "$br_name" up
            pass "$br_name with $iface"
        fi
        idx=$((idx + 1))
    done <<< "$interfaces"
}

cmd_redeploy() {
    export OS_CLOUD=devstack-system-admin

    info "Checking for active deployments..."
    active_nodes=$(openstack baremetal node list -f json 2>/dev/null | \
        python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('Provisioning State') == 'active':
        print(n['UUID'])
" 2>/dev/null)

    if [[ -n "$active_nodes" ]]; then
        while IFS= read -r uuid; do
            info "Undeploying $uuid..."
            openstack baremetal node undeploy "$uuid" 2>/dev/null || warn "Failed to undeploy $uuid"
        done <<< "$active_nodes"

        info "Waiting for nodes to finish undeploying..."
        for _ in $(seq 1 30); do
            still=$(openstack baremetal node list -f json 2>/dev/null | \
                python3 -c "
import sys, json
nodes = json.load(sys.stdin)
active = [n for n in nodes if n.get('Provisioning State') not in ('available', 'enroll', 'manageable')]
print(len(active))
" 2>/dev/null || echo "0")
            [[ "$still" -eq 0 ]] && break
            sleep 10
        done
    fi

    # Move nodes to available
    for uuid in $(openstack baremetal node list -f value -c UUID 2>/dev/null); do
        state=$(openstack baremetal node show "$uuid" -f value -c provision_state 2>/dev/null)
        case "$state" in
            manageable) openstack baremetal node provide "$uuid" 2>/dev/null ;;
            enroll)     openstack baremetal node manage "$uuid" 2>/dev/null && sleep 2 && openstack baremetal node provide "$uuid" 2>/dev/null ;;
            available)  pass "$uuid already available" ;;
        esac
    done

    echo ""
    openstack baremetal node list
}

case "${1:-}" in
    status)    cmd_status ;;
    restart)   cmd_restart ;;
    logs)      cmd_logs ;;
    reconnect) cmd_reconnect ;;
    redeploy)  cmd_redeploy ;;
    *)
        echo "Usage: $0 {status|restart|logs|reconnect|redeploy}"
        exit 1 ;;
esac

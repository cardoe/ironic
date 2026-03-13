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
#   reconnect - Re-bridge the trunk interface to OVS (after reboot)
#   redeploy  - Undeploy all instances and reset nodes to available

set -uo pipefail

SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
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
    echo "--- OVS brbm ports ---"
    sudo ovs-vsctl list-ports brbm 2>/dev/null || warn "brbm not found"

    echo ""
    echo "--- Switch connectivity ---"
    ping -c 1 -W 2 "$SWITCH_IP" &>/dev/null && pass "Switch at $SWITCH_IP" || warn "Switch unreachable"

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
    # After a VM reboot, the trunk interface bridge may be lost.
    # Re-detect and re-bridge it.
    info "Detecting trunk interface..."
    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)
    local trunk_if
    trunk_if=$(echo "$interfaces" | sed -n '2p')

    if [[ -z "$trunk_if" ]]; then
        fail "Cannot detect trunk interface"
        return 1
    fi

    info "Trunk interface: $trunk_if"
    sudo ovs-vsctl --may-exist add-port brbm "$trunk_if"
    sudo ip link set dev "$trunk_if" up
    pass "Trunk interface $trunk_if bridged to brbm"
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

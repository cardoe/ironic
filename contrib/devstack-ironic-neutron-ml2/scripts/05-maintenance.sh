#!/bin/bash
# 05-maintenance.sh - Maintenance operations for the spine-leaf DevStack environment
#
# Usage:
#   bash scripts/05-maintenance.sh <command>
#
# Commands:
#   status    - Show status of all services and switch connectivity
#   restart   - Restart all DevStack services
#   logs      - Tail key service logs (Ctrl+C to stop)
#   reconnect - Re-add trunk interface to brbm (after reboot)
#   redeploy  - Undeploy all instances and reset nodes to available

set -uo pipefail

LEAF01_IP="${LEAF01_IP:-192.168.32.13}"
LEAF02_IP="${LEAF02_IP:-192.168.32.14}"
SPINE01_IP="${SPINE01_IP:-192.168.32.11}"
SPINE02_IP="${SPINE02_IP:-192.168.32.12}"
TRUNK_INTERFACE="${TRUNK_INTERFACE:-}"
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

detect_trunk_interface() {
    if [[ -n "$TRUNK_INTERFACE" ]]; then
        return
    fi
    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)
    TRUNK_INTERFACE=$(echo "$interfaces" | sed -n '2p')
}

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
    echo "--- Switch connectivity ---"
    for entry in \
        "${SPINE01_IP}:spine01" \
        "${SPINE02_IP}:spine02" \
        "${LEAF01_IP}:leaf01" \
        "${LEAF02_IP}:leaf02"
    do
        ip="${entry%%:*}"
        name="${entry#*:}"
        ping -c 1 -W 2 "$ip" &>/dev/null && pass "$name at $ip" || warn "$name unreachable"
    done

    echo ""
    echo "--- OVS brbm ports ---"
    sudo ovs-vsctl list-ports brbm 2>/dev/null || warn "brbm not found"

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
    # After a VM reboot, the trunk interface may need to be re-added to brbm.

    detect_trunk_interface

    if [[ -z "$TRUNK_INTERFACE" ]]; then
        fail "Cannot detect trunk interface. Set TRUNK_INTERFACE."
        return 1
    fi

    info "Trunk interface: $TRUNK_INTERFACE"
    sudo ip link set "$TRUNK_INTERFACE" up
    sudo ovs-vsctl --may-exist add-port brbm "$TRUNK_INTERFACE"
    pass "Trunk interface $TRUNK_INTERFACE re-added to brbm"
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

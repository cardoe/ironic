#!/bin/bash
# 04-maintenance.sh - Maintenance and lifecycle operations for the DevStack
#                     Ironic + Neutron ML2 development environment.
#
# Usage:
#   bash 04-maintenance.sh <command>
#
# Commands:
#   status    - Show status of all DevStack services and components
#   restart   - Restart all DevStack services
#   logs      - Tail logs from key services (Ctrl+C to stop)
#   switch    - Connect to the switch simulator serial console
#   cleanup   - Clean up all resources (run after unstack.sh/clean.sh)
#   redeploy  - Undeploy all instances and reset nodes to available

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

DEVSTACK_SERVICES=(
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
    "devstack@s-object"
    "devstack@s-container"
    "devstack@s-account"
    "devstack@redfish-emulator"
    "devstack@virtualbmc"
    "devstack@ir-sw-sim"
    "devstack@key"
)

cmd_status() {
    echo "=============================================="
    echo "DevStack Service Status"
    echo "=============================================="
    echo ""

    for svc in "${DEVSTACK_SERVICES[@]}"; do
        if systemctl list-unit-files "$svc.service" &>/dev/null; then
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
            case "$state" in
                active)
                    pass "$svc"
                    ;;
                inactive)
                    warn "$svc (inactive)"
                    ;;
                failed)
                    fail "$svc (FAILED)"
                    ;;
                *)
                    # Service unit doesn't exist, skip silently
                    ;;
            esac
        fi
    done

    echo ""
    echo "--- Libvirt VMs ---"
    sudo virsh list --all 2>/dev/null || warn "Cannot list VMs (libvirtd running?)"

    echo ""
    echo "--- OVS Bridges ---"
    sudo ovs-vsctl show 2>/dev/null | head -30 || warn "Cannot query OVS"

    echo ""
    echo "--- Switch Simulator ---"
    SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
    if ping -c 1 -W 1 "$SWITCH_IP" &>/dev/null; then
        pass "Switch reachable at $SWITCH_IP"
    else
        warn "Switch not reachable at $SWITCH_IP"
    fi

    echo ""
    echo "--- Redfish Emulator ---"
    REDFISH_PORT="${IRONIC_REDFISH_EMULATOR_PORT:-9132}"
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$REDFISH_PORT/redfish/v1/" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        pass "Redfish emulator responding on port $REDFISH_PORT"
    else
        warn "Redfish emulator not responding (code: $code)"
    fi
}

cmd_restart() {
    echo "Restarting DevStack services..."
    echo ""

    for svc in "${DEVSTACK_SERVICES[@]}"; do
        if systemctl list-unit-files "$svc.service" &>/dev/null 2>&1; then
            if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                info "Restarting $svc..."
                sudo systemctl restart "$svc" 2>/dev/null
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    pass "$svc restarted"
                else
                    fail "$svc failed to restart"
                fi
            fi
        fi
    done

    echo ""
    info "Service restart complete."
    info "Run 'bash 04-maintenance.sh status' to verify."
}

cmd_logs() {
    echo "Tailing key service logs (Ctrl+C to stop)..."
    echo "=============================================="
    echo ""

    # Use journalctl to follow multiple services
    sudo journalctl -f \
        -u devstack@ir-api \
        -u devstack@ir-cond \
        -u devstack@neutron-api \
        -u devstack@n-cpu \
        -u devstack@redfish-emulator \
        -u devstack@ir-sw-sim \
        2>/dev/null
}

cmd_switch() {
    SWITCH_CONSOLE_PORT="${SWITCH_CONSOLE_PORT:-55001}"
    echo "Connecting to switch simulator serial console..."
    echo "  Host: localhost"
    echo "  Port: $SWITCH_CONSOLE_PORT"
    echo ""
    echo "Press Ctrl+] to disconnect from telnet."
    echo "=============================================="
    telnet localhost "$SWITCH_CONSOLE_PORT"
}

cmd_cleanup() {
    echo "=============================================="
    echo "Cleaning up DevStack environment"
    echo "=============================================="
    echo ""
    echo "This will remove:"
    echo "  - Switch simulator VM disk copies"
    echo "  - Linux bridges created for switch-to-VM connectivity"
    echo "  - OVS ports for switch simulator"
    echo ""
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    info "Removing switch simulator artifacts..."
    rm -f /opt/stack/nexus_disk_image.qcow2
    rm -f /opt/stack/OVMF-edk2-stable202305.fd
    rm -f /opt/stack/OVMF-edk2-stable202305.fd.zip

    info "Removing Linux bridges (swbr-*)..."
    for br in $(ip link show type bridge 2>/dev/null | grep "swbr-" | awk -F: '{print $2}' | tr -d ' '); do
        sudo ip link set dev "$br" down 2>/dev/null || true
        sudo ip link del dev "$br" 2>/dev/null || true
        info "  Removed $br"
    done

    info "Removing switch tap interfaces..."
    for tap in $(ip link show 2>/dev/null | grep -oP '(sim|sw)-\S+' | cut -d: -f1 | sort -u); do
        sudo ip link del dev "$tap" 2>/dev/null || true
        info "  Removed $tap"
    done

    info "Removing OVS ports for simulator..."
    for port in sim-trunk sim-mgmt; do
        sudo ovs-vsctl --if-exists del-port "$port" 2>/dev/null || true
    done

    echo ""
    pass "Cleanup complete."
    info "Run 'sudo bash 01-prereqs.sh' to prepare for a fresh deployment."
}

cmd_redeploy() {
    echo "=============================================="
    echo "Resetting Bare Metal Nodes"
    echo "=============================================="
    echo ""

    export OS_CLOUD=devstack-system-admin

    info "Checking for active instances..."
    active_nodes=$(openstack baremetal node list -f json 2>/dev/null | jq -r '.[] | select(.["Provisioning State"] == "active") | .UUID' 2>/dev/null)

    if [[ -n "$active_nodes" ]]; then
        echo "$active_nodes" | while read -r uuid; do
            info "Undeploying node $uuid..."
            openstack baremetal node undeploy "$uuid" 2>/dev/null || \
                warn "Failed to undeploy $uuid"
        done

        info "Waiting for nodes to finish undeploying..."
        sleep 10

        for i in $(seq 1 30); do
            still_active=$(openstack baremetal node list -f json 2>/dev/null | jq '[.[] | select(.["Provisioning State"] != "available" and .["Provisioning State"] != "enroll")] | length' 2>/dev/null || echo "0")
            if [[ "$still_active" -eq 0 ]]; then
                break
            fi
            info "  $still_active node(s) still transitioning... (attempt $i/30)"
            sleep 10
        done
    else
        info "No active deployments found."
    fi

    # Make all nodes available
    for uuid in $(openstack baremetal node list -f json 2>/dev/null | jq -r '.[].UUID' 2>/dev/null); do
        state=$(openstack baremetal node show "$uuid" -f json 2>/dev/null | jq -r '.provision_state' 2>/dev/null)
        case "$state" in
            manageable)
                info "Setting $uuid to available..."
                openstack baremetal node provide "$uuid" 2>/dev/null || true
                ;;
            enroll)
                info "Managing and providing $uuid..."
                openstack baremetal node manage "$uuid" 2>/dev/null || true
                sleep 2
                openstack baremetal node provide "$uuid" 2>/dev/null || true
                ;;
            available)
                pass "$uuid already available"
                ;;
            *)
                warn "$uuid in state '$state' - manual intervention may be needed"
                ;;
        esac
    done

    echo ""
    info "Node states:"
    openstack baremetal node list
}

# ---- Main ----
case "${1:-}" in
    status)
        cmd_status
        ;;
    restart)
        cmd_restart
        ;;
    logs)
        cmd_logs
        ;;
    switch)
        cmd_switch
        ;;
    cleanup)
        cmd_cleanup
        ;;
    redeploy)
        cmd_redeploy
        ;;
    *)
        echo "Usage: bash $0 <command>"
        echo ""
        echo "Commands:"
        echo "  status    Show status of all services and components"
        echo "  restart   Restart all DevStack services"
        echo "  logs      Tail logs from key services"
        echo "  switch    Connect to switch simulator console"
        echo "  cleanup   Clean up all simulator resources"
        echo "  redeploy  Reset all nodes to available state"
        exit 1
        ;;
esac

#!/bin/bash
# 03-verify.sh - Post-deployment verification for Ironic + Neutron ML2 DevStack
#
# Run as the stack user after stack.sh completes:
#   bash 03-verify.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "      $1"; }

ERRORS=0
WARNINGS=0

echo "=============================================="
echo "DevStack Post-Deployment Verification"
echo "=============================================="
echo ""

# ---- Check DevStack Services ----
echo "--- Checking DevStack Services ---"

SERVICES=(
    "devstack@ir-api:Ironic API"
    "devstack@ir-cond:Ironic Conductor"
    "devstack@neutron-api:Neutron API"
    "devstack@q-agt:Neutron OVS Agent"
    "devstack@q-dhcp:Neutron DHCP Agent"
    "devstack@q-l3:Neutron L3 Agent"
    "devstack@q-meta:Neutron Metadata Agent"
    "devstack@n-api:Nova API"
    "devstack@n-cpu:Nova Compute"
    "devstack@n-cond:Nova Conductor"
    "devstack@n-sch:Nova Scheduler"
    "devstack@g-api:Glance API"
    "devstack@s-proxy:Swift Proxy"
)

for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    desc="${entry#*:}"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "$desc ($svc)"
    else
        fail "$desc ($svc) is not running"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check sushy-tools / redfish emulator
if systemctl is-active --quiet "devstack@redfish-emulator" 2>/dev/null; then
    pass "sushy-tools Redfish emulator"
elif systemctl is-active --quiet "devstack@virtualbmc" 2>/dev/null; then
    pass "VirtualBMC (IPMI emulator)"
else
    warn "Neither Redfish emulator nor VirtualBMC is running"
    WARNINGS=$((WARNINGS + 1))
fi

# Check switch simulator
if systemctl is-active --quiet "devstack@ir-sw-sim" 2>/dev/null; then
    pass "Network switch simulator (ir-sw-sim)"
else
    warn "Network switch simulator is not running (may be using OVS-only)"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Check Ironic ----
echo "--- Checking Ironic ---"
export OS_CLOUD=devstack-system-admin

node_count=$(openstack baremetal node list -f json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [[ "$node_count" -gt 0 ]]; then
    pass "Ironic has $node_count enrolled node(s)"
else
    fail "No Ironic nodes found"
    ERRORS=$((ERRORS + 1))
fi

# Check node states
if [[ "$node_count" -gt 0 ]]; then
    available=$(openstack baremetal node list -f json 2>/dev/null | jq '[.[] | select(.["Provisioning State"] == "available")] | length' 2>/dev/null || echo "0")
    if [[ "$available" -gt 0 ]]; then
        pass "$available node(s) in 'available' state"
    else
        warn "No nodes in 'available' state yet"
        info "Nodes may still be cleaning. Check: openstack baremetal node list"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check ports have link local info
    has_llc=$(openstack baremetal port list --long -f json 2>/dev/null | jq '[.[] | select(.["Local Link Connection"] != null and .["Local Link Connection"] != {})] | length' 2>/dev/null || echo "0")
    if [[ "$has_llc" -gt 0 ]]; then
        pass "$has_llc port(s) have local link connection info"
    else
        warn "No ports found with local link connection info"
        WARNINGS=$((WARNINGS + 1))
    fi
fi
echo ""

# ---- Check sushy-tools / Redfish ----
echo "--- Checking BMC Emulator ---"
REDFISH_PORT="${IRONIC_REDFISH_EMULATOR_PORT:-9132}"
redfish_response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$REDFISH_PORT/redfish/v1/" 2>/dev/null || echo "000")
if [[ "$redfish_response" == "200" ]]; then
    pass "Redfish emulator responding on port $REDFISH_PORT"
    systems=$(curl -s "http://localhost:$REDFISH_PORT/redfish/v1/Systems/" 2>/dev/null | jq '.Members | length' 2>/dev/null || echo "0")
    if [[ "$systems" -gt 0 ]]; then
        pass "Redfish reports $systems system(s)"
    else
        warn "Redfish reports no systems"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warn "Redfish emulator not responding on port $REDFISH_PORT (code: $redfish_response)"
    info "This is expected if using IPMI/VirtualBMC instead of Redfish."
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Check Cisco Nexus 9000v ----
echo "--- Checking Network Switch Simulator ---"
SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
SWITCH_CONSOLE_PORT="${SWITCH_CONSOLE_PORT:-55001}"

if ping -c 1 -W 2 "$SWITCH_IP" &>/dev/null; then
    pass "Switch simulator reachable at $SWITCH_IP"
else
    warn "Switch simulator not reachable at $SWITCH_IP"
    info "If using OVS-only networking, this is expected."
    info "If using a switch simulator, it may still be booting."
    WARNINGS=$((WARNINGS + 1))
fi

# Check SSH
if timeout 5 bash -c "echo '' | nc -w2 $SWITCH_IP 22" &>/dev/null; then
    pass "Switch SSH port is open ($SWITCH_IP:22)"
else
    warn "Switch SSH port not reachable ($SWITCH_IP:22)"
    WARNINGS=$((WARNINGS + 1))
fi

# Check serial console
if timeout 5 bash -c "echo '' | nc -w2 localhost $SWITCH_CONSOLE_PORT" &>/dev/null; then
    pass "Switch serial console available (localhost:$SWITCH_CONSOLE_PORT)"
else
    warn "Switch serial console not available (localhost:$SWITCH_CONSOLE_PORT)"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Check Neutron ML2 ----
echo "--- Checking Neutron ML2 Configuration ---"
export OS_CLOUD=devstack-admin

# Check ML2 config for genericswitch
NGS_CONF_FILES=(
    "/etc/neutron/plugins/ml2/ml2_conf.ini"
    "/etc/neutron/plugins/ml2/ml2_conf_genericswitch.ini"
)

ngs_configured=false
for conf in "${NGS_CONF_FILES[@]}"; do
    if [[ -f "$conf" ]]; then
        if grep -q "genericswitch" "$conf" 2>/dev/null; then
            ngs_configured=true
            pass "networking-generic-switch config found in $conf"
            # Show switch config summary
            switch_sections=$(grep -c '^\[genericswitch:' "$conf" 2>/dev/null || echo "0")
            if [[ "$switch_sections" -gt 0 ]]; then
                info "  $switch_sections switch section(s) configured"
            fi
        fi
    fi
done

if [[ "$ngs_configured" != "true" ]]; then
    warn "networking-generic-switch configuration not found in ML2 config"
    info "This is expected if using OVS-only networking."
    WARNINGS=$((WARNINGS + 1))
fi

# Check that neutron has the ML2 plugin loaded
ml2_type=$(openstack network list -f json 2>/dev/null | jq 'length' 2>/dev/null)
if [[ -n "$ml2_type" ]]; then
    pass "Neutron API is responding"
else
    fail "Neutron API not responding"
    ERRORS=$((ERRORS + 1))
fi

# Check provisioning network
prov_net=$(openstack network list -f json 2>/dev/null | jq -r '.[] | select(.Name == "ironic-provision") | .Name' 2>/dev/null || echo "")
if [[ -n "$prov_net" ]]; then
    pass "Provisioning network 'ironic-provision' exists"
else
    warn "Provisioning network 'ironic-provision' not found"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Check libvirt VMs ----
echo "--- Checking Libvirt VMs ---"
vm_total=$(sudo virsh list --all --name 2>/dev/null | grep -c "node-" || echo "0")
if [[ "$vm_total" -gt 0 ]]; then
    pass "$vm_total bare metal VM(s) defined in libvirt"
    vm_running=$(sudo virsh list --name 2>/dev/null | grep -c "node-" || echo "0")
    vm_off=$((vm_total - vm_running))
    info "  Running: $vm_running, Shut off: $vm_off"
else
    fail "No bare metal VMs found in libvirt"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- Check Nova ----
echo "--- Checking Nova ---"
export OS_CLOUD=devstack-admin-demo
flavors=$(openstack flavor list -f json 2>/dev/null | jq '[.[] | select(.Name == "baremetal")] | length' 2>/dev/null || echo "0")
if [[ "$flavors" -gt 0 ]]; then
    pass "Baremetal flavor exists"
else
    warn "Baremetal flavor not found"
    WARNINGS=$((WARNINGS + 1))
fi

hypervisors=$(openstack hypervisor list -f json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [[ "$hypervisors" -gt 0 ]]; then
    pass "Nova reports $hypervisors hypervisor(s) (Ironic nodes)"
else
    warn "No hypervisors found in Nova"
    info "Ironic nodes may not have synced to Nova yet."
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- OVS Bridge Check ----
echo "--- Checking OVS Bridges ---"
for bridge in br-int brbm br-infra; do
    if sudo ovs-vsctl br-exists "$bridge" 2>/dev/null; then
        pass "OVS bridge '$bridge' exists"
    else
        if [[ "$bridge" == "br-infra" ]]; then
            warn "OVS bridge '$bridge' not found (may not be needed)"
            WARNINGS=$((WARNINGS + 1))
        else
            fail "OVS bridge '$bridge' not found"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done
echo ""

# ---- Summary ----
echo "=============================================="
if [[ $ERRORS -gt 0 ]]; then
    fail "Verification completed with $ERRORS error(s) and $WARNINGS warning(s)"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    warn "Verification completed with $WARNINGS warning(s) (no errors)"
    info "Warnings may be expected depending on your configuration."
else
    pass "All checks passed!"
fi
echo ""
info "Useful commands:"
info "  export OS_CLOUD=devstack-admin-demo"
info "  openstack server create --flavor baremetal \\"
info "    --nic net-id=\$(openstack network list | awk '/private/ {print \$2}') \\"
info "    --image \$(openstack image list | grep -- '-disk' | awk '{print \$2}') \\"
info "    --key-name default testing"
echo "=============================================="

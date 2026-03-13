#!/bin/bash
# 04-verify.sh - Verify the Ironic + Neutron ML2 DevStack deployment
#
# Run on the DevStack VM after setup and enrollment are complete.

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

SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
REDFISH_PORT="${REDFISH_PORT:-9132}"

echo "=============================================="
echo "Deployment Verification"
echo "=============================================="
echo ""

# ---- DevStack Services ----
echo "--- DevStack Services ---"
for entry in \
    "devstack@ir-api:Ironic API" \
    "devstack@ir-cond:Ironic Conductor" \
    "devstack@neutron-api:Neutron API" \
    "devstack@q-agt:Neutron OVS Agent" \
    "devstack@q-dhcp:Neutron DHCP Agent" \
    "devstack@n-api:Nova API" \
    "devstack@n-cpu:Nova Compute" \
    "devstack@g-api:Glance API" \
    "devstack@redfish-emulator:sushy-tools (Redfish)"
do
    svc="${entry%%:*}"
    desc="${entry#*:}"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc ($svc) not running"
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# ---- sushy-tools Nova driver ----
echo "--- sushy-tools Configuration ---"
REDFISH_CONF="/etc/ironic/redfish/emulator.conf"
if [[ -f "$REDFISH_CONF" ]]; then
    if sudo grep -q "nova" "$REDFISH_CONF" 2>/dev/null; then
        pass "sushy-tools configured for Nova driver"
    else
        fail "sushy-tools not configured for Nova driver"
        info "Expected SUSHY_EMULATOR_DRIVER = 'nova' in $REDFISH_CONF"
        ERRORS=$((ERRORS + 1))
    fi
fi

code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$REDFISH_PORT/redfish/v1/" 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
    pass "Redfish API responding on port $REDFISH_PORT"
    systems=$(curl -s "http://localhost:$REDFISH_PORT/redfish/v1/Systems/" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Members',[])))" 2>/dev/null || echo "0")
    if [[ "$systems" -gt 0 ]]; then
        pass "Redfish reports $systems system(s) (Nova instances on hosting cloud)"
    else
        warn "Redfish reports 0 systems - check hosting cloud credentials"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    fail "Redfish API not responding (HTTP $code)"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- Cisco 9k Switch ----
echo "--- Cisco Nexus 9000v Switch ---"
if ping -c 1 -W 2 "$SWITCH_IP" &>/dev/null; then
    pass "Switch reachable at $SWITCH_IP"
else
    fail "Switch not reachable at $SWITCH_IP"
    ERRORS=$((ERRORS + 1))
fi

if timeout 5 bash -c "echo '' | nc -w2 $SWITCH_IP 22" &>/dev/null; then
    pass "Switch SSH port open"
else
    warn "Switch SSH not reachable"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- OVS Trunk Bridge ----
echo "--- OVS Trunk Configuration ---"
if sudo ovs-vsctl br-exists brbm 2>/dev/null; then
    pass "OVS bridge 'brbm' exists"
    trunk_ports=$(sudo ovs-vsctl list-ports brbm 2>/dev/null)
    if [[ -n "$trunk_ports" ]]; then
        pass "brbm has ports: $trunk_ports"
    else
        warn "brbm has no ports - trunk interface may not be bridged"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    fail "OVS bridge 'brbm' not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- NGS Configuration ----
echo "--- networking-generic-switch ---"
NGS_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"
if [[ -f "$NGS_CONF" ]] && sudo grep -q "genericswitch:cisco_nexus9k" "$NGS_CONF" 2>/dev/null; then
    pass "NGS switch section found in ML2 config"
    configured_ip=$(sudo grep -A5 "genericswitch:cisco_nexus9k" "$NGS_CONF" | grep "ip" | head -1 | awk '{print $NF}')
    info "  Configured switch IP: $configured_ip"
else
    fail "NGS switch configuration not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- Ironic Nodes ----
echo "--- Ironic Bare Metal Nodes ---"
export OS_CLOUD=devstack-system-admin
node_count=$(openstack baremetal node list -f json 2>/dev/null | \
    python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$node_count" -gt 0 ]]; then
    pass "$node_count node(s) enrolled"
    openstack baremetal node list 2>/dev/null
else
    warn "No nodes enrolled. Run scripts/03-enroll-nodes.sh"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Neutron Networks ----
echo "--- Neutron Networks ---"
export OS_CLOUD=devstack-admin
prov_net=$(openstack network list -f json 2>/dev/null | \
    python3 -c "import sys,json; nets=[n for n in json.load(sys.stdin) if 'provision' in n.get('Name','')]; print(nets[0]['Name'] if nets else '')" 2>/dev/null || echo "")
if [[ -n "$prov_net" ]]; then
    pass "Provisioning network exists: $prov_net"
else
    warn "Provisioning network not found"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ---- Summary ----
echo "=============================================="
if [[ $ERRORS -gt 0 ]]; then
    fail "Verification: $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    warn "Verification: $WARNINGS warning(s), no errors"
else
    pass "All checks passed!"
fi
echo ""
info "To test a deployment:"
info "  export OS_CLOUD=devstack-admin-demo"
info "  openstack server create --flavor baremetal \\"
info "    --nic net-id=\$(openstack network list | awk '/private/ {print \$2}') \\"
info "    --image \$(openstack image list | grep -- '-disk' | awk '{print \$2}') \\"
info "    --key-name default testing"
echo "=============================================="

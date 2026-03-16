#!/bin/bash
# 04-verify.sh - Verify the Ironic + Neutron ML2 spine-leaf deployment
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

LEAF01_IP="${LEAF01_IP:-192.168.32.13}"
LEAF02_IP="${LEAF02_IP:-192.168.32.14}"
SPINE01_IP="${SPINE01_IP:-192.168.32.11}"
SPINE02_IP="${SPINE02_IP:-192.168.32.12}"
REDFISH_PORT="${REDFISH_PORT:-9132}"

echo "=============================================="
echo "Spine-Leaf Deployment Verification"
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
        ERRORS=$((ERRORS + 1))
    fi
fi

code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$REDFISH_PORT/redfish/v1/" 2>/dev/null || echo "000")
if [[ "$code" == "200" ]]; then
    pass "Redfish API responding on port $REDFISH_PORT"
    systems=$(curl -s "http://localhost:$REDFISH_PORT/redfish/v1/Systems/" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Members',[])))" 2>/dev/null || echo "0")
    if [[ "$systems" -gt 0 ]]; then
        pass "Redfish reports $systems system(s)"
    else
        warn "Redfish reports 0 systems - check hosting cloud credentials"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    fail "Redfish API not responding (HTTP $code)"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- Switch connectivity ----
echo "--- Spine-Leaf Switches ---"
for entry in \
    "${SPINE01_IP}:spine01" \
    "${SPINE02_IP}:spine02" \
    "${LEAF01_IP}:leaf01" \
    "${LEAF02_IP}:leaf02"
do
    ip="${entry%%:*}"
    name="${entry#*:}"
    if ping -c 1 -W 2 "$ip" &>/dev/null; then
        pass "$name reachable at $ip"
    else
        fail "$name not reachable at $ip"
        ERRORS=$((ERRORS + 1))
    fi
    if timeout 5 bash -c "echo '' | nc -w2 $ip 22" &>/dev/null; then
        pass "$name SSH port open"
    else
        warn "$name SSH not reachable"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# ---- OVS Bridge ----
echo "--- OVS Configuration ---"
if sudo ovs-vsctl br-exists brbm 2>/dev/null; then
    pass "OVS bridge 'brbm' exists"
    ports=$(sudo ovs-vsctl list-ports brbm 2>/dev/null)
    # Check for trunk interface
    trunk_if=$(echo "$ports" | grep -v -E '^(phy-|int-|patch-)' | grep -v "^$" | head -1)
    if [[ -n "$trunk_if" ]]; then
        pass "Trunk interface '$trunk_if' on brbm"
    else
        warn "No trunk interface detected on brbm"
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
for switch in leaf01 leaf02; do
    if [[ -f "$NGS_CONF" ]] && sudo grep -q "genericswitch:$switch" "$NGS_CONF" 2>/dev/null; then
        pass "NGS section found for $switch"
    else
        fail "NGS section missing for $switch"
        ERRORS=$((ERRORS + 1))
    fi
done
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

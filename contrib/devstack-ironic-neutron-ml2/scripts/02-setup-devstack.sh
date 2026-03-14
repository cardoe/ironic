#!/bin/bash
# 02-setup-devstack.sh - Set up DevStack with Ironic + Neutron ML2 on the
#                         DevStack VM, using sushy-tools Nova driver.
#
# Trunk traffic between DevStack and the Cisco 9k flows over VXLAN tunnels
# on the underlay network. OVS brbm gets per-VLAN VXLAN ports that map
# VLANs to VNIs matching the switch's NVE configuration.
#
# Run this ON the DevStack VM as the stack user (or it will create one).
#
# Usage:
#   bash scripts/02-setup-devstack.sh

set -euo pipefail

# =============================================================================
# Configuration - adjust these to match your terraform outputs
# =============================================================================

# Hosting cloud credentials (for sushy-tools Nova driver)
HOSTING_CLOUD_NAME="${HOSTING_CLOUD_NAME:-hosting-cloud}"
HOSTING_CLOUD_AUTH_URL="${HOSTING_CLOUD_AUTH_URL:?Set HOSTING_CLOUD_AUTH_URL}"
HOSTING_CLOUD_PROJECT="${HOSTING_CLOUD_PROJECT:?Set HOSTING_CLOUD_PROJECT}"
HOSTING_CLOUD_USERNAME="${HOSTING_CLOUD_USERNAME:?Set HOSTING_CLOUD_USERNAME}"
HOSTING_CLOUD_PASSWORD="${HOSTING_CLOUD_PASSWORD:?Set HOSTING_CLOUD_PASSWORD}"
HOSTING_CLOUD_USER_DOMAIN="${HOSTING_CLOUD_USER_DOMAIN:-Default}"
HOSTING_CLOUD_PROJECT_DOMAIN="${HOSTING_CLOUD_PROJECT_DOMAIN:-Default}"

# Switch configuration
SWITCH_IP="${SWITCH_IP:-172.24.5.20}"
SWITCH_USER="${SWITCH_USER:-admin}"
SWITCH_PASS="${SWITCH_PASS:-system_s3cret!}"

# VXLAN underlay configuration
SWITCH_VTEP_IP="${SWITCH_VTEP_IP:-10.0.99.120}"
SWITCH_UNDERLAY_IP="${SWITCH_UNDERLAY_IP:-10.0.99.20}"
SWITCH_UNDERLAY_MAC="${SWITCH_UNDERLAY_MAC:-}"  # Set if NX-OS doesn't ARP for VTEP IP
DEVSTACK_UNDERLAY_IP="${DEVSTACK_UNDERLAY_IP:-10.0.99.10}"
UNDERLAY_PREFIX="${UNDERLAY_PREFIX:-24}"

# VLAN/VNI range (must match switch config and DevStack local.conf)
VLAN_START="${VLAN_START:-100}"
VLAN_END="${VLAN_END:-150}"
VNI_OFFSET=10000

# Underlay interface name inside the DevStack VM (second NIC)
UNDERLAY_INTERFACE="${UNDERLAY_INTERFACE:-}"

# DevStack configuration
ADMIN_PASS="${ADMIN_PASSWORD:-password}"
IRONIC_REPO_URL="${IRONIC_REPO:-https://opendev.org/openstack/ironic}"
IRONIC_BRANCH="${IRONIC_BRANCH:-master}"
NODE_COUNT="${NODE_COUNT:-3}"

DEVSTACK_DIR="/opt/stack/devstack"

# =============================================================================
# Helper functions
# =============================================================================

info() { echo "[INFO] $1"; }
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

detect_underlay_interface() {
    # The underlay interface is the second NIC (index 1).
    if [[ -n "$UNDERLAY_INTERFACE" ]]; then
        return
    fi

    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)

    UNDERLAY_INTERFACE=$(echo "$interfaces" | sed -n '2p')

    if [[ -z "$UNDERLAY_INTERFACE" ]]; then
        fail "Cannot auto-detect underlay interface. Set UNDERLAY_INTERFACE manually."
    fi
    info "Auto-detected underlay interface: $UNDERLAY_INTERFACE"
}

# =============================================================================
# Step 1: Prerequisites
# =============================================================================

info "Installing prerequisites..."
sudo apt-get update -qq
sudo apt-get install -y -qq git python3 python3-pip sshpass net-tools >/dev/null 2>&1

# =============================================================================
# Step 2: Stack user
# =============================================================================

if [[ "$(whoami)" != "stack" ]]; then
    if ! id "stack" &>/dev/null; then
        info "Creating stack user..."
        sudo useradd -s /bin/bash -d /opt/stack -m stack
        sudo chmod +x /opt/stack
        echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/50_stack_sh >/dev/null
        sudo chmod 0440 /etc/sudoers.d/50_stack_sh
    fi
    info "Re-running as stack user..."
    sudo -u stack -H bash "$0" "$@"
    exit $?
fi

# =============================================================================
# Step 3: Clone DevStack
# =============================================================================

if [[ ! -d "$DEVSTACK_DIR" ]]; then
    info "Cloning DevStack..."
    git clone https://opendev.org/openstack/devstack.git "$DEVSTACK_DIR"
else
    info "DevStack already cloned at $DEVSTACK_DIR"
fi

# =============================================================================
# Step 4: Set up hosting cloud credentials for sushy-tools
# =============================================================================

info "Writing hosting cloud credentials to clouds.yaml..."
mkdir -p ~/.config/openstack
cat > ~/.config/openstack/clouds.yaml <<CLOUDSEOF
clouds:
  ${HOSTING_CLOUD_NAME}:
    auth:
      auth_url: "${HOSTING_CLOUD_AUTH_URL}"
      project_name: "${HOSTING_CLOUD_PROJECT}"
      username: "${HOSTING_CLOUD_USERNAME}"
      password: "${HOSTING_CLOUD_PASSWORD}"
      user_domain_name: "${HOSTING_CLOUD_USER_DOMAIN}"
      project_domain_name: "${HOSTING_CLOUD_PROJECT_DOMAIN}"
    region_name: "RegionOne"
    identity_api_version: 3
CLOUDSEOF
chmod 600 ~/.config/openstack/clouds.yaml

# =============================================================================
# Step 5: Configure underlay interface
# =============================================================================

detect_underlay_interface

info "Configuring underlay interface $UNDERLAY_INTERFACE..."
sudo ip addr add "${DEVSTACK_UNDERLAY_IP}/${UNDERLAY_PREFIX}" dev "$UNDERLAY_INTERFACE" 2>/dev/null || true
sudo ip link set "$UNDERLAY_INTERFACE" up

# If the switch VTEP IP differs from its underlay IP, add a static ARP
# entry so DevStack can reach it. NX-OS may or may not respond to ARP
# for loopback0's IP on the physical interface.
if [[ "$SWITCH_VTEP_IP" != "$SWITCH_UNDERLAY_IP" ]]; then
    if [[ -n "$SWITCH_UNDERLAY_MAC" ]]; then
        info "Adding static ARP for switch VTEP IP $SWITCH_VTEP_IP..."
        sudo ip neigh replace "$SWITCH_VTEP_IP" lladdr "$SWITCH_UNDERLAY_MAC" \
            dev "$UNDERLAY_INTERFACE" nud permanent
        pass "Static ARP entry added for VTEP"
    else
        info "SWITCH_UNDERLAY_MAC not set. Assuming NX-OS will ARP for VTEP IP."
        info "If VXLAN tunnels don't come up, set SWITCH_UNDERLAY_MAC and re-run."
    fi
fi

pass "Underlay interface configured: $UNDERLAY_INTERFACE = $DEVSTACK_UNDERLAY_IP/$UNDERLAY_PREFIX"

# =============================================================================
# Step 6: Generate local.conf
# =============================================================================

info "Generating DevStack local.conf..."
cat > "$DEVSTACK_DIR/local.conf" <<CONFEOF
[[local|localrc]]

# =============================================================================
# Ironic + Neutron ML2 DevStack (sushy-tools Nova driver)
#
# Architecture:
#   - sushy-tools uses the Nova driver to manage bare metal VMs on the
#     hosting OpenStack cloud
#   - Cisco Nexus 9000v switch (Nova instance) handles VLAN switching
#   - Trunk traffic flows over VXLAN tunnels on the underlay network
#   - OVS brbm gets per-VLAN VXLAN ports mapped to NVE VNIs on the switch
# =============================================================================

# ---- Ironic Plugin ----
enable_plugin ironic ${IRONIC_REPO_URL} ${IRONIC_BRANCH}

# Install networking-generic-switch Neutron ML2 driver
enable_plugin networking-generic-switch https://opendev.org/openstack/networking-generic-switch

# ---- Credentials ----
ADMIN_PASSWORD=${ADMIN_PASS}
DATABASE_PASSWORD=${ADMIN_PASS}
RABBIT_PASSWORD=${ADMIN_PASS}
SERVICE_PASSWORD=${ADMIN_PASS}
SERVICE_TOKEN=${ADMIN_PASS}
SWIFT_HASH=${ADMIN_PASS}
SWIFT_TEMPURL_KEY=${ADMIN_PASS}

# ---- Service Configuration ----
enable_service ironic ir-api ir-cond
disable_service n-novnc
enable_service s-proxy s-object s-container s-account
SWIFT_ENABLE_TEMPURLS=True
disable_service horizon
disable_service cinder c-sch c-api c-vol
disable_service tempest

# ---- Neutron Networking ----
disable_service ovn-controller
disable_service ovn-northd
disable_service neutron-ovn-metadata-agent

enable_service neutron-agent q-agt
enable_service neutron-dhcp q-dhcp
enable_service neutron-l3 q-l3
enable_service neutron-metadata-agent q-meta
enable_service neutron-api q-svc

Q_AGENT=openvswitch
Q_ML2_PLUGIN_MECHANISM_DRIVERS="openvswitch"
Q_USE_SECGROUP=False

# ---- ML2 VLAN Configuration ----
Q_PLUGIN=ml2
ENABLE_TENANT_VLANS=True
Q_ML2_TENANT_NETWORK_TYPE=vlan
TENANT_VLAN_RANGE=${VLAN_START}:${VLAN_END}

# ---- Ironic Networking ----
IRONIC_USE_LINK_LOCAL=True
IRONIC_ENABLED_NETWORK_INTERFACES=flat,neutron
IRONIC_NETWORK_INTERFACE=neutron

OVS_PHYSICAL_BRIDGE=brbm
PHYSICAL_NETWORK=mynetwork
IRONIC_PROVISION_NETWORK_NAME=ironic-provision
IRONIC_PROVISION_SUBNET_PREFIX=10.0.5.0/24
IRONIC_PROVISION_SUBNET_GATEWAY=10.0.5.1

# ---- Ironic Driver Configuration ----
# Use Redfish via sushy-tools (will be reconfigured for Nova driver post-stack)
IRONIC_DEPLOY_DRIVER=redfish
IRONIC_ENABLED_HARDWARE_TYPES=redfish
IRONIC_ENABLED_MANAGEMENT_INTERFACES=redfish,fake
IRONIC_ENABLED_POWER_INTERFACES=redfish,fake
IRONIC_ENABLED_BOOT_INTERFACES=redfish-virtual-media,fake

# ---- Hardware Mode ----
# Bare metal VMs are pre-created on the hosting cloud, not local libvirt VMs.
# This tells DevStack not to create local VMs.
IRONIC_IS_HARDWARE=True
IRONIC_BAREMETAL_BASIC_OPS=False

# ---- Nova ----
VIRT_DRIVER=ironic
GLANCE_LIMIT_IMAGE_SIZE_TOTAL=5000

# ---- Network Addressing ----
IP_VERSION=4
NETWORK_GATEWAY=10.1.0.1
FIXED_RANGE=10.1.0.0/20
IPV4_ADDRS_SAFE_TO_USE=10.1.0.0/20

# ---- Logging ----
LOGFILE=\$HOME/devstack.log
LOGDIR=\$HOME/logs
IRONIC_VM_LOG_DIR=\$HOME/ironic-bm-logs
CONFEOF

pass "local.conf written to $DEVSTACK_DIR/local.conf"

# =============================================================================
# Step 7: Run stack.sh
# =============================================================================

info "Running stack.sh (this will take 20-40 minutes)..."
cd "$DEVSTACK_DIR"
./stack.sh

pass "stack.sh completed"

# =============================================================================
# Step 8: Post-stack configuration
# =============================================================================

info "Applying post-stack configuration..."

# 8a. Create VXLAN tunnel ports on OVS brbm
#
# Each VLAN gets a VXLAN port with:
#   - tag=<vlan>: OVS treats it as an access port in that VLAN
#   - key=<vni>: VXLAN encapsulation uses this VNI
#   - remote_ip=<switch_vtep>: tunnel endpoint on the Cisco 9k
#
# Traffic flow:
#   Neutron sends VLAN-tagged frame on brbm -> OVS matches VLAN tag to
#   access port -> strips VLAN, encapsulates in VXLAN with VNI -> sends UDP
#   to switch VTEP -> NX-OS decapsulates, maps VNI to VLAN -> switches to
#   access port -> BM node receives untagged frame.

info "Creating VXLAN tunnel ports on brbm (VLAN ${VLAN_START}-${VLAN_END})..."
for vlan in $(seq "$VLAN_START" "$VLAN_END"); do
    vni=$((vlan + VNI_OFFSET))
    sudo ovs-vsctl --may-exist add-port brbm "vxlan_${vlan}" \
        tag="${vlan}" \
        -- set interface "vxlan_${vlan}" type=vxlan \
        options:remote_ip="${SWITCH_VTEP_IP}" \
        options:key="${vni}"
done
pass "VXLAN ports created on brbm ($(( VLAN_END - VLAN_START + 1 )) tunnels to ${SWITCH_VTEP_IP})"

# 8b. Reconfigure sushy-tools for the Nova driver
REDFISH_CONF="/etc/ironic/redfish/emulator.conf"
if [[ -f "$REDFISH_CONF" ]]; then
    info "Reconfiguring sushy-tools for Nova driver..."
    # Back up the original config
    sudo cp "$REDFISH_CONF" "${REDFISH_CONF}.orig"

    # Update the driver to Nova
    if sudo grep -q "SUSHY_EMULATOR_DRIVER" "$REDFISH_CONF"; then
        sudo sed -i "s|SUSHY_EMULATOR_DRIVER.*|SUSHY_EMULATOR_DRIVER = 'nova'|" "$REDFISH_CONF"
    else
        echo "SUSHY_EMULATOR_DRIVER = 'nova'" | sudo tee -a "$REDFISH_CONF" >/dev/null
    fi

    # Point sushy-tools at the hosting cloud
    if sudo grep -q "SUSHY_EMULATOR_OS_CLOUD" "$REDFISH_CONF"; then
        sudo sed -i "s|SUSHY_EMULATOR_OS_CLOUD.*|SUSHY_EMULATOR_OS_CLOUD = '${HOSTING_CLOUD_NAME}'|" "$REDFISH_CONF"
    else
        echo "SUSHY_EMULATOR_OS_CLOUD = '${HOSTING_CLOUD_NAME}'" | sudo tee -a "$REDFISH_CONF" >/dev/null
    fi

    # Copy clouds.yaml to a location sushy-tools can read as root
    sudo mkdir -p /etc/openstack
    sudo cp ~/.config/openstack/clouds.yaml /etc/openstack/clouds.yaml

    # Restart sushy-tools
    sudo systemctl restart devstack@redfish-emulator
    pass "sushy-tools reconfigured for Nova driver"
else
    fail "sushy-tools config not found at $REDFISH_CONF"
fi

# 8c. Configure networking-generic-switch for the Cisco 9k
info "Configuring networking-generic-switch..."
NGS_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

# Add the switch configuration
if ! sudo grep -q "genericswitch:cisco_nexus9k" "$NGS_CONF" 2>/dev/null; then
    sudo tee -a "$NGS_CONF" >/dev/null <<NGSEOF

[genericswitch:cisco_nexus9k]
device_type = netmiko_cisco_nxos
ip = ${SWITCH_IP}
username = ${SWITCH_USER}
password = ${SWITCH_PASS}
ngs_port_default_vlan = 1
NGSEOF
    pass "NGS switch configuration added"
else
    info "NGS switch configuration already present"
fi

# Restart Neutron to load NGS config
sudo systemctl restart devstack@neutron-api
sudo systemctl restart devstack@q-agt
sleep 5
pass "Neutron restarted with NGS configuration"

# =============================================================================
# Done
# =============================================================================

echo ""
echo "=============================================="
pass "DevStack setup complete!"
echo ""
echo "Next steps:"
echo "  1. Enroll bare metal nodes: bash scripts/03-enroll-nodes.sh"
echo "  2. Verify the deployment:   bash scripts/04-verify.sh"
echo ""
echo "VXLAN tunnel details:"
echo "  DevStack underlay: $DEVSTACK_UNDERLAY_IP ($(sudo ovs-vsctl list-ports brbm | grep -c vxlan_) VXLAN ports on brbm)"
echo "  Switch VTEP:       $SWITCH_VTEP_IP"
echo "  VNI range:         $((VLAN_START + VNI_OFFSET))-$((VLAN_END + VNI_OFFSET))"
echo "=============================================="

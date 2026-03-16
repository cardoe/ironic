#!/bin/bash
# 02-setup-devstack.sh - Set up DevStack with Ironic + Neutron ML2 on the
#                         DevStack VM, using sushy-tools Nova driver.
#
# The DevStack VM connects to leaf01 via a Neutron trunk port. The hosting
# cloud's trunk port feature handles 802.1Q tagging transparently - DevStack
# sees tagged VLAN frames on its trunk NIC (eth1). OVS brbm bridges the
# trunk NIC directly.
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

# Leaf switch IPs (for networking-generic-switch)
LEAF01_IP="${LEAF01_IP:-192.168.32.13}"
LEAF02_IP="${LEAF02_IP:-192.168.32.14}"
SWITCH_USER="${SWITCH_USER:-admin}"
SWITCH_PASS="${SWITCH_PASS:-system_s3cret!}"

# VLAN range (must match switch config and local.conf)
VLAN_START="${VLAN_START:-100}"
VLAN_END="${VLAN_END:-150}"

# Trunk interface name inside the DevStack VM (second NIC)
TRUNK_INTERFACE="${TRUNK_INTERFACE:-}"

# DevStack configuration
ADMIN_PASS="${ADMIN_PASSWORD:-password}"
IRONIC_REPO_URL="${IRONIC_REPO:-https://opendev.org/openstack/ironic}"
IRONIC_BRANCH="${IRONIC_BRANCH:-master}"

DEVSTACK_DIR="/opt/stack/devstack"

# =============================================================================
# Helper functions
# =============================================================================

info() { echo "[INFO] $1"; }
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

detect_trunk_interface() {
    # The trunk interface is the second NIC (index 1).
    if [[ -n "$TRUNK_INTERFACE" ]]; then
        return
    fi

    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)

    TRUNK_INTERFACE=$(echo "$interfaces" | sed -n '2p')

    if [[ -z "$TRUNK_INTERFACE" ]]; then
        fail "Cannot auto-detect trunk interface. Set TRUNK_INTERFACE manually."
    fi
    info "Auto-detected trunk interface: $TRUNK_INTERFACE"
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
# Step 5: Bring up trunk interface
# =============================================================================

detect_trunk_interface

info "Bringing up trunk interface $TRUNK_INTERFACE..."
sudo ip link set "$TRUNK_INTERFACE" up
pass "Trunk interface $TRUNK_INTERFACE is up"

# =============================================================================
# Step 6: Generate local.conf
# =============================================================================

info "Generating DevStack local.conf..."
cat > "$DEVSTACK_DIR/local.conf" <<CONFEOF
[[local|localrc]]

# =============================================================================
# Ironic + Neutron ML2 DevStack (spine-leaf topology)
#
# Architecture:
#   - sushy-tools uses the Nova driver to manage bare metal VMs on the
#     hosting OpenStack cloud
#   - Spine-leaf fabric (2 spines + 2 leafs) with OSPF underlay, BGP EVPN
#   - DevStack connects to leaf01 via Neutron trunk port (802.1Q tagged)
#   - OVS brbm bridges the trunk NIC for VLAN-tagged tenant traffic
#   - networking-generic-switch manages VLAN assignments on leaf switches
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
IRONIC_DEPLOY_DRIVER=redfish
IRONIC_ENABLED_HARDWARE_TYPES=redfish
IRONIC_ENABLED_MANAGEMENT_INTERFACES=redfish,fake
IRONIC_ENABLED_POWER_INTERFACES=redfish,fake
IRONIC_ENABLED_BOOT_INTERFACES=redfish-virtual-media,fake

# ---- Hardware Mode ----
# Bare metal VMs are pre-created on the hosting cloud, not local libvirt VMs.
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

# 8a. Add trunk interface to OVS brbm
#
# The trunk interface carries 802.1Q tagged frames from the Neutron trunk port.
# Adding it to brbm lets OVS handle the VLAN-tagged traffic directly.
# No VXLAN tunnels needed - the hosting cloud's trunk port handles tagging,
# and the spine-leaf fabric handles inter-leaf VXLAN/EVPN internally.

info "Adding trunk interface $TRUNK_INTERFACE to OVS bridge brbm..."
sudo ovs-vsctl --may-exist add-port brbm "$TRUNK_INTERFACE"
pass "Trunk interface $TRUNK_INTERFACE added to brbm"

# 8b. Reconfigure sushy-tools for the Nova driver
REDFISH_CONF="/etc/ironic/redfish/emulator.conf"
if [[ -f "$REDFISH_CONF" ]]; then
    info "Reconfiguring sushy-tools for Nova driver..."
    sudo cp "$REDFISH_CONF" "${REDFISH_CONF}.orig"

    if sudo grep -q "SUSHY_EMULATOR_DRIVER" "$REDFISH_CONF"; then
        sudo sed -i "s|SUSHY_EMULATOR_DRIVER.*|SUSHY_EMULATOR_DRIVER = 'nova'|" "$REDFISH_CONF"
    else
        echo "SUSHY_EMULATOR_DRIVER = 'nova'" | sudo tee -a "$REDFISH_CONF" >/dev/null
    fi

    if sudo grep -q "SUSHY_EMULATOR_OS_CLOUD" "$REDFISH_CONF"; then
        sudo sed -i "s|SUSHY_EMULATOR_OS_CLOUD.*|SUSHY_EMULATOR_OS_CLOUD = '${HOSTING_CLOUD_NAME}'|" "$REDFISH_CONF"
    else
        echo "SUSHY_EMULATOR_OS_CLOUD = '${HOSTING_CLOUD_NAME}'" | sudo tee -a "$REDFISH_CONF" >/dev/null
    fi

    sudo mkdir -p /etc/openstack
    sudo cp ~/.config/openstack/clouds.yaml /etc/openstack/clouds.yaml

    sudo systemctl restart devstack@redfish-emulator
    pass "sushy-tools reconfigured for Nova driver"
else
    fail "sushy-tools config not found at $REDFISH_CONF"
fi

# 8c. Configure networking-generic-switch for both leaf switches
info "Configuring networking-generic-switch..."
NGS_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

if ! sudo grep -q "genericswitch:leaf01" "$NGS_CONF" 2>/dev/null; then
    sudo tee -a "$NGS_CONF" >/dev/null <<NGSEOF

[genericswitch:leaf01]
device_type = netmiko_cisco_nxos
ip = ${LEAF01_IP}
username = ${SWITCH_USER}
password = ${SWITCH_PASS}
ngs_port_default_vlan = 1

[genericswitch:leaf02]
device_type = netmiko_cisco_nxos
ip = ${LEAF02_IP}
username = ${SWITCH_USER}
password = ${SWITCH_PASS}
ngs_port_default_vlan = 1
NGSEOF
    pass "NGS configuration added for leaf01 and leaf02"
else
    info "NGS switch configuration already present"
fi

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
echo "Trunk port details:"
echo "  Trunk interface: $TRUNK_INTERFACE (on OVS brbm)"
echo "  VLAN range:      $VLAN_START-$VLAN_END"
echo "  Leaf switches:   leaf01=$LEAF01_IP, leaf02=$LEAF02_IP"
echo "=============================================="

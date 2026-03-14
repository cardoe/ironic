#!/bin/bash
# 02-setup-devstack.sh - Set up DevStack with Ironic + Neutron ML2 on the
#                         DevStack VM, using sushy-tools Nova driver.
#
# The Cisco Nexus 9000v runs locally inside this VM (nested virtualization).
# Each bare metal network NIC is bridged to the corresponding 9k access port.
# The trunk between the 9k and OVS brbm is a local tap.
#
# Run this ON the DevStack VM as the stack user (or it will create one).
#
# Usage:
#   bash scripts/02-setup-devstack.sh
#
# Prerequisites:
#   - The Cisco 9k QCOW2 must be SCP'd to the VM (default: /tmp/nexus9300v.qcow2)
#   - The hosting cloud must support nested virtualization (or the 9k must be
#     able to run under QEMU TCG, which is very slow)

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

# Local Cisco 9k switch configuration
SWITCH_IMAGE="${SWITCH_IMAGE:-/tmp/nexus9300v.qcow2}"
SWITCH_LOCAL_IP="${SWITCH_LOCAL_IP:-192.168.100.20}"
SWITCH_LOCAL_GW="${SWITCH_LOCAL_GW:-192.168.100.1}"
SWITCH_LOCAL_CIDR="${SWITCH_LOCAL_CIDR:-192.168.100.0/24}"
SWITCH_USER="${SWITCH_USER:-admin}"
SWITCH_PASS="${SWITCH_PASS:-system_s3cret!}"

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

detect_bm_interfaces() {
    # Detect bare metal network interfaces (all NICs after the first one).
    # The first NIC is mgmt; the rest are BM links (one per node).
    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -v -E '^(lo|docker|veth|br-|ovs|virbr|tap)' | sort)

    # Skip the first (mgmt) interface
    BM_INTERFACES=()
    local idx=0
    while IFS= read -r iface; do
        if [[ $idx -gt 0 ]]; then
            BM_INTERFACES+=("$iface")
        fi
        idx=$((idx + 1))
    done <<< "$interfaces"

    if [[ ${#BM_INTERFACES[@]} -eq 0 ]]; then
        fail "No bare metal network interfaces detected. Expected N NICs after mgmt."
    fi
    info "Detected ${#BM_INTERFACES[@]} BM interface(s): ${BM_INTERFACES[*]}"
}

# =============================================================================
# Step 1: Prerequisites
# =============================================================================

info "Installing prerequisites..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    git python3 python3-pip sshpass net-tools \
    qemu-kvm qemu-utils libvirt-daemon-system bridge-utils \
    >/dev/null 2>&1

# Verify nested virt or KVM is available
if [[ -e /dev/kvm ]]; then
    pass "KVM available (nested virtualization supported)"
else
    info "KVM not available -- Cisco 9k will run under QEMU TCG (slow)"
fi

# Verify the 9k image exists
if [[ ! -f "$SWITCH_IMAGE" ]]; then
    fail "Cisco 9k QCOW2 not found at $SWITCH_IMAGE. SCP it to the VM first."
fi

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
# Step 5: Detect bare metal interfaces and set up local bridges
# =============================================================================

detect_bm_interfaces

info "Creating local management bridge for Cisco 9k..."
sudo ip link add br-sw-mgmt type bridge 2>/dev/null || true
sudo ip addr add "${SWITCH_LOCAL_GW}/24" dev br-sw-mgmt 2>/dev/null || true
sudo ip link set br-sw-mgmt up

info "Creating per-node bridges (BM NIC <-> 9k access port)..."
for i in $(seq 0 $((${#BM_INTERFACES[@]} - 1))); do
    br_name="br-bm-${i}"
    bm_if="${BM_INTERFACES[$i]}"

    sudo ip link add "$br_name" type bridge 2>/dev/null || true
    sudo ip link set "$bm_if" master "$br_name" 2>/dev/null || true
    sudo ip link set "$bm_if" up
    sudo ip link set "$br_name" up

    pass "Bridge $br_name with $bm_if"
done

# =============================================================================
# Step 6: Launch Cisco 9k locally (nested QEMU/KVM)
# =============================================================================

info "Preparing Cisco 9k disk image..."
SWITCH_DISK="/var/lib/libvirt/images/nexus9300v.qcow2"
sudo mkdir -p /var/lib/libvirt/images
if [[ ! -f "$SWITCH_DISK" ]]; then
    sudo cp "$SWITCH_IMAGE" "$SWITCH_DISK"
fi

# Build QEMU command with correct NIC ordering:
#   NIC 0 = mgmt0 (br-sw-mgmt)
#   NIC 1 = Ethernet1/1 (trunk -- connected to OVS brbm, set up post-stack)
#   NIC 2..N = Ethernet1/2..N (access ports -- connected to br-bm-{0..N})

QEMU_CMD="sudo qemu-system-x86_64 -name cisco-9k -daemonize"
QEMU_CMD+=" -m 8192 -smp 2"
QEMU_CMD+=" -drive file=${SWITCH_DISK},if=virtio,format=qcow2"
QEMU_CMD+=" -bios /usr/share/OVMF/OVMF_CODE.fd"
QEMU_CMD+=" -serial telnet:127.0.0.1:4000,server,nowait"
QEMU_CMD+=" -monitor unix:/tmp/cisco9k-monitor.sock,server,nowait"
QEMU_CMD+=" -pidfile /tmp/cisco9k.pid"

# Enable KVM if available
if [[ -e /dev/kvm ]]; then
    QEMU_CMD+=" -enable-kvm -cpu host"
fi

# NIC 0: mgmt0 -> br-sw-mgmt
QEMU_CMD+=" -netdev bridge,id=mgmt,br=br-sw-mgmt"
QEMU_CMD+=" -device virtio-net-pci,netdev=mgmt,mac=52:54:00:9k:00:00"

# NIC 1: Ethernet1/1 (trunk) -> tap device (added to brbm post-stack)
# Create a persistent tap for the trunk
sudo ip tuntap add dev tap-sw-trunk mode tap 2>/dev/null || true
sudo ip link set tap-sw-trunk up
QEMU_CMD+=" -netdev tap,id=trunk,ifname=tap-sw-trunk,script=no,downscript=no"
QEMU_CMD+=" -device virtio-net-pci,netdev=trunk,mac=52:54:00:9k:01:00"

# NIC 2+: Ethernet1/2+ (access ports) -> per-node bridges
for i in $(seq 0 $((${#BM_INTERFACES[@]} - 1))); do
    br_name="br-bm-${i}"
    nic_idx=$((i + 2))
    mac_suffix=$(printf "%02x" "$i")
    QEMU_CMD+=" -netdev bridge,id=bm${i},br=${br_name}"
    QEMU_CMD+=" -device virtio-net-pci,netdev=bm${i},mac=52:54:00:9k:${mac_suffix}:02"
done

# Check if 9k is already running
if [[ -f /tmp/cisco9k.pid ]] && kill -0 "$(cat /tmp/cisco9k.pid)" 2>/dev/null; then
    info "Cisco 9k already running (PID $(cat /tmp/cisco9k.pid))"
else
    info "Launching Cisco 9k VM (this takes 5-10 minutes to boot)..."
    eval "$QEMU_CMD"
    pass "Cisco 9k launched (serial console: telnet 127.0.0.1 4000)"
fi

info "The switch needs initial POAP setup via serial console."
info "Run: telnet 127.0.0.1 4000"
info "Then see scripts/01-configure-switch.sh for setup instructions."

# =============================================================================
# Step 7: Generate local.conf
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
#   - Cisco Nexus 9000v switch simulator runs locally (nested KVM)
#   - DevStack's OVS connects to the local switch trunk port
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
TENANT_VLAN_RANGE=100:150

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
# Step 8: Run stack.sh
# =============================================================================

info "Running stack.sh (this will take 20-40 minutes)..."
cd "$DEVSTACK_DIR"
./stack.sh

pass "stack.sh completed"

# =============================================================================
# Step 9: Post-stack configuration
# =============================================================================

info "Applying post-stack configuration..."

# 9a. Bridge the trunk tap to OVS brbm
info "Adding trunk tap to OVS bridge brbm..."
sudo ovs-vsctl --may-exist add-port brbm tap-sw-trunk
pass "Trunk tap bridged to brbm"

# 9b. Reconfigure sushy-tools for the Nova driver
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

# 9c. Configure networking-generic-switch for the Cisco 9k
info "Configuring networking-generic-switch..."
NGS_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

# Add the switch configuration (uses local management IP)
if ! sudo grep -q "genericswitch:cisco_nexus9k" "$NGS_CONF" 2>/dev/null; then
    sudo tee -a "$NGS_CONF" >/dev/null <<NGSEOF

[genericswitch:cisco_nexus9k]
device_type = netmiko_cisco_nxos
ip = ${SWITCH_LOCAL_IP}
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
echo "  1. If not done already, configure the Cisco 9k switch:"
echo "     telnet 127.0.0.1 4000   (serial console for POAP skip)"
echo "     bash scripts/01-configure-switch.sh ${SWITCH_LOCAL_IP} '${SWITCH_PASS}' ${NODE_COUNT}"
echo "  2. Enroll bare metal nodes: bash scripts/03-enroll-nodes.sh"
echo "  3. Verify the deployment:   bash scripts/04-verify.sh"
echo "=============================================="

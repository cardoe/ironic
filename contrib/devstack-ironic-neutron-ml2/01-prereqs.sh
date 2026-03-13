#!/bin/bash
# 01-prereqs.sh - Check and install prerequisites for Ironic + Neutron ML2
#                 DevStack with sushy-tools and Cisco Nexus 9000v simulator.
#
# Run as root: sudo bash 01-prereqs.sh
#
# This script:
#   1. Verifies nested virtualization is available
#   2. Installs required system packages
#   3. Creates the stack user
#   4. Enables and starts required services
#   5. Checks for the Cisco Nexus 9000v image

set -euo pipefail

CISCO_NEXUS_IMAGE="${CISCO_NEXUS_IMAGE:-/opt/stack/nexus9300v64.10.3.7.M.qcow2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "      $1"; }

ERRORS=0

echo "=============================================="
echo "Ironic + Neutron ML2 DevStack Prerequisites"
echo "=============================================="
echo ""

# ---- Must be root ----
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (sudo bash $0)"
    exit 1
fi

# ---- Check OS ----
echo "--- Checking Operating System ---"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        pass "Ubuntu detected: $PRETTY_NAME"
        if [[ "$VERSION_ID" != "24.04" ]]; then
            warn "Ubuntu 24.04 (Noble) is recommended. You have $VERSION_ID."
        fi
    else
        warn "Ubuntu is recommended. Detected: $PRETTY_NAME"
        info "Other distributions may work but are not tested."
    fi
else
    warn "Cannot determine OS. Ubuntu 24.04 is recommended."
fi
echo ""

# ---- Check CPU / Nested Virtualization ----
echo "--- Checking Virtualization Support ---"
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    pass "Hardware virtualization extensions found"
else
    fail "No hardware virtualization (vmx/svm) detected in /proc/cpuinfo"
    info "If running in a VM, enable nested virtualization on the hypervisor."
    ERRORS=$((ERRORS + 1))
fi

if [[ -e /dev/kvm ]]; then
    pass "KVM device /dev/kvm is available"
else
    warn "/dev/kvm not found. Loading kvm modules..."
    modprobe kvm || true
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
    if [[ -e /dev/kvm ]]; then
        pass "KVM device now available after module load"
    else
        fail "Cannot enable KVM. Nested virtualization may not be supported."
        info "DevStack can fall back to QEMU software emulation (much slower)."
        info "Set IRONIC_VM_ENGINE=qemu in local.conf if needed."
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check nested virt
for mod in kvm_intel kvm_amd; do
    nested_file="/sys/module/$mod/parameters/nested"
    if [[ -f "$nested_file" ]]; then
        nested_val=$(cat "$nested_file")
        if [[ "$nested_val" == "Y" || "$nested_val" == "1" ]]; then
            pass "Nested virtualization is enabled ($mod)"
        else
            warn "Nested virtualization is disabled for $mod"
            info "Enable with: echo 1 > $nested_file"
            info "Or add 'options $mod nested=1' to /etc/modprobe.d/kvm.conf"
        fi
    fi
done
echo ""

# ---- Check Resources ----
echo "--- Checking System Resources ---"
total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_gb=$((total_ram_kb / 1024 / 1024))
if [[ $total_ram_gb -ge 32 ]]; then
    pass "RAM: ${total_ram_gb} GB (minimum 32 GB)"
elif [[ $total_ram_gb -ge 24 ]]; then
    warn "RAM: ${total_ram_gb} GB (32 GB recommended, may work with reduced VM count)"
else
    fail "RAM: ${total_ram_gb} GB (minimum 32 GB required)"
    ERRORS=$((ERRORS + 1))
fi

num_cpus=$(nproc)
if [[ $num_cpus -ge 8 ]]; then
    pass "CPUs: $num_cpus (minimum 8)"
elif [[ $num_cpus -ge 4 ]]; then
    warn "CPUs: $num_cpus (8 recommended, may be slow)"
else
    fail "CPUs: $num_cpus (minimum 4, 8 recommended)"
    ERRORS=$((ERRORS + 1))
fi

avail_disk_gb=$(df /opt --output=avail 2>/dev/null | tail -1 | awk '{printf "%d", $1/1024/1024}')
if [[ $avail_disk_gb -ge 100 ]]; then
    pass "Available disk on /opt: ${avail_disk_gb} GB"
elif [[ $avail_disk_gb -ge 60 ]]; then
    warn "Available disk on /opt: ${avail_disk_gb} GB (100 GB recommended)"
else
    fail "Available disk on /opt: ${avail_disk_gb} GB (need at least 60 GB)"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ---- Install packages ----
echo "--- Installing System Packages ---"
apt-get update -qq

PACKAGES=(
    git
    python3
    python3-pip
    python3-venv
    libvirt-daemon-system
    libvirt-clients
    qemu-kvm
    qemu-utils
    openvswitch-switch
    bridge-utils
    net-tools
    iproute2
    ipmitool
    telnet
    netcat-openbsd
    curl
    wget
    jq
    unzip
    lsb-release
    sudo
    # For building IPA ramdisk if needed
    squashfs-tools
    genisoimage
)

apt-get install -y -qq "${PACKAGES[@]}" 2>&1 | tail -1
pass "System packages installed"
echo ""

# ---- Create stack user ----
echo "--- Setting Up Stack User ---"
if id "stack" &>/dev/null; then
    pass "User 'stack' already exists"
else
    if [[ -f /opt/stack/devstack/tools/create-stack-user.sh ]]; then
        /opt/stack/devstack/tools/create-stack-user.sh
    else
        useradd -s /bin/bash -d /opt/stack -m stack
        chmod +x /opt/stack
    fi
    pass "User 'stack' created"
fi

# Ensure stack can sudo without password
if ! grep -q "^stack ALL" /etc/sudoers.d/50_stack_sh 2>/dev/null; then
    echo "stack ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/50_stack_sh
    chmod 0440 /etc/sudoers.d/50_stack_sh
    pass "Passwordless sudo configured for 'stack'"
else
    pass "Passwordless sudo already configured for 'stack'"
fi
echo ""

# ---- Enable services ----
echo "--- Enabling Services ---"
for svc in libvirtd openvswitch-switch; do
    systemctl enable "$svc" 2>/dev/null || true
    systemctl start "$svc" 2>/dev/null || true
    if systemctl is-active --quiet "$svc"; then
        pass "Service $svc is running"
    else
        fail "Service $svc failed to start"
        ERRORS=$((ERRORS + 1))
    fi
done

# Add stack user to libvirt group
usermod -aG libvirt stack 2>/dev/null || true
pass "User 'stack' added to libvirt group"
echo ""

# ---- Check Cisco Nexus 9000v image ----
echo "--- Checking Cisco Nexus 9000v Image ---"
if [[ -f "$CISCO_NEXUS_IMAGE" ]]; then
    image_size=$(du -h "$CISCO_NEXUS_IMAGE" | awk '{print $1}')
    pass "Cisco Nexus 9000v image found: $CISCO_NEXUS_IMAGE ($image_size)"
    # Verify it's a valid qcow2
    if qemu-img info "$CISCO_NEXUS_IMAGE" &>/dev/null; then
        pass "Image is a valid QCOW2 file"
    else
        fail "Image does not appear to be a valid QCOW2 file"
        ERRORS=$((ERRORS + 1))
    fi
else
    warn "Cisco Nexus 9000v image not found at: $CISCO_NEXUS_IMAGE"
    info ""
    info "To use the Cisco Nexus 9000v switch simulator, you must:"
    info "  1. Download the NX-OSv 9000 QCOW2 image from https://software.cisco.com"
    info "  2. Place it at: $CISCO_NEXUS_IMAGE"
    info ""
    info "If you want to use a different image path, set CISCO_NEXUS_IMAGE before"
    info "running the generate-local-conf script."
    info ""
    info "Without this image, DevStack will use OVS-only networking (no switch sim)."
fi
echo ""

# ---- Ensure /opt/stack ownership ----
mkdir -p /opt/stack
chown -R stack:stack /opt/stack

# ---- Summary ----
echo "=============================================="
if [[ $ERRORS -gt 0 ]]; then
    fail "Prerequisite check completed with $ERRORS error(s)."
    info "Please resolve the issues above before proceeding."
    exit 1
else
    pass "All prerequisites satisfied!"
    echo ""
    info "Next steps:"
    info "  1. Place the Cisco Nexus 9000v image at $CISCO_NEXUS_IMAGE"
    info "     (if not already done)"
    info "  2. Switch to the stack user: sudo su - stack"
    info "  3. Clone devstack: git clone https://opendev.org/openstack/devstack.git"
    info "  4. Run: bash 02-generate-local-conf.sh"
    info "  5. Run: cd devstack && ./stack.sh"
fi
echo "=============================================="

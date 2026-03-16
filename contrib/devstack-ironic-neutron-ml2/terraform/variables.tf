variable "cloud_name" {
  description = "Name of the cloud entry in clouds.yaml for the hosting OpenStack"
  type        = string
}

variable "external_network_name" {
  description = "Name of the external/provider network for floating IPs"
  type        = string
}

variable "cisco_9k_image_path" {
  description = "Local filesystem path to the Cisco Nexus 9000v QCOW2 image"
  type        = string
}

variable "devstack_image_name" {
  description = "Name of an existing Ubuntu 24.04 image in the hosting cloud's Glance"
  type        = string
  default     = "Ubuntu-24.04"
}

variable "devstack_flavor" {
  description = "Flavor for the DevStack VM (needs 8+ vCPU, 32+ GB RAM, 100+ GB disk)"
  type        = string
}

variable "cisco_9k_flavor" {
  description = "Flavor for the Cisco 9k simulator VMs (needs 2 vCPU, 8+ GB RAM)"
  type        = string
}

variable "baremetal_flavor" {
  description = "Flavor for bare metal node VMs (size that Ironic will 'see' as bare metal)"
  type        = string
}

variable "controller_flavor" {
  description = "Flavor for the controller node (DNS, DHCP, TFTP for POAP)"
  type        = string
  default     = ""
}

variable "baremetal_node_count" {
  description = <<-EOT
    Number of virtual bare metal nodes to create.
    Nodes are distributed across leaf switches:
      - Even-indexed nodes (0, 2, ...) attach to leaf01
      - Odd-indexed nodes (1, 3, ...) attach to leaf02
  EOT
  type        = number
  default     = 2
}

variable "key_pair_name" {
  description = "Name of an existing SSH key pair in the hosting cloud"
  type        = string
}

variable "dns_nameservers" {
  description = "DNS nameservers for the management network"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

# =============================================================================
# Management network
# =============================================================================

variable "mgmt_subnet_cidr" {
  description = "CIDR for the management network"
  type        = string
  default     = "192.168.32.0/24"
}

variable "controller_mgmt_ip" {
  description = "Controller node IP on the management network"
  type        = string
  default     = "192.168.32.254"
}

variable "spine01_mgmt_ip" {
  description = "Spine01 IP on the management network"
  type        = string
  default     = "192.168.32.11"
}

variable "spine02_mgmt_ip" {
  description = "Spine02 IP on the management network"
  type        = string
  default     = "192.168.32.12"
}

variable "leaf01_mgmt_ip" {
  description = "Leaf01 IP on the management network"
  type        = string
  default     = "192.168.32.13"
}

variable "leaf02_mgmt_ip" {
  description = "Leaf02 IP on the management network"
  type        = string
  default     = "192.168.32.14"
}

variable "devstack_mgmt_ip" {
  description = "DevStack VM IP on the management network"
  type        = string
  default     = "192.168.32.20"
}

# =============================================================================
# VLAN range
# =============================================================================

variable "vlan_range_start" {
  description = "Start of the VLAN range for tenant networks (must match DevStack local.conf)"
  type        = number
  default     = 100
}

variable "vlan_range_end" {
  description = "End of the VLAN range for tenant networks (must match DevStack local.conf)"
  type        = number
  default     = 150
}

# =============================================================================
# Switch credentials
# =============================================================================

variable "switch_password" {
  description = "Admin password to configure on all Cisco 9k switches"
  type        = string
  default     = "system_s3cret!"
  sensitive   = true
}

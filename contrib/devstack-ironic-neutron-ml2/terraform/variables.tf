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
  description = "Flavor for the Cisco 9k simulator VM (needs 2 vCPU, 8+ GB RAM)"
  type        = string
}

variable "baremetal_flavor" {
  description = "Flavor for bare metal node VMs (size that Ironic will 'see' as bare metal)"
  type        = string
}

variable "baremetal_node_count" {
  description = "Number of virtual bare metal nodes to create"
  type        = number
  default     = 3
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

variable "mgmt_subnet_cidr" {
  description = "CIDR for the management network"
  type        = string
  default     = "172.24.5.0/24"
}

variable "underlay_subnet_cidr" {
  description = "CIDR for the VXLAN underlay network between DevStack and switches"
  type        = string
  default     = "10.0.99.0/24"
}

variable "switch_mgmt_ip" {
  description = "Fixed IP for the Cisco 9k switch on the management network"
  type        = string
  default     = "172.24.5.20"
}

variable "devstack_mgmt_ip" {
  description = "Fixed IP for the DevStack VM on the management network"
  type        = string
  default     = "172.24.5.10"
}

variable "switch_underlay_ip" {
  description = "Fixed IP for the Cisco 9k on the underlay network (Ethernet1/1)"
  type        = string
  default     = "10.0.99.20"
}

variable "switch_vtep_ip" {
  description = <<-EOT
    VTEP IP for the Cisco 9k (loopback0, NVE source-interface).
    Must be in the underlay subnet so DevStack can reach it via the
    underlay network without routing.
  EOT
  type        = string
  default     = "10.0.99.120"
}

variable "devstack_underlay_ip" {
  description = "Fixed IP for the DevStack VM on the underlay network"
  type        = string
  default     = "10.0.99.10"
}

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

variable "switch_password" {
  description = "Admin password to configure on the Cisco 9k switch"
  type        = string
  default     = "system_s3cret!"
  sensitive   = true
}

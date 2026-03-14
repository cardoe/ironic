variable "cloud_name" {
  description = "Name of the cloud entry in clouds.yaml for the hosting OpenStack"
  type        = string
}

variable "external_network_name" {
  description = "Name of the external/provider network for floating IPs"
  type        = string
}

variable "cisco_9k_image_path" {
  description = <<-EOT
    Local filesystem path to the Cisco Nexus 9000v QCOW2 image.
    This image is SCP'd to the DevStack VM (not uploaded to Glance).
    The 9k runs as a local QEMU VM inside the DevStack host (nested virt).
  EOT
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

variable "devstack_mgmt_ip" {
  description = "Fixed IP for the DevStack VM on the management network"
  type        = string
  default     = "172.24.5.10"
}

variable "switch_local_mgmt_ip" {
  description = <<-EOT
    IP address for the Cisco 9k switch on the local management bridge
    inside the DevStack VM. Used by NGS to SSH to the switch.
  EOT
  type        = string
  default     = "192.168.100.20"
}

variable "switch_password" {
  description = "Admin password to configure on the Cisco 9k switch"
  type        = string
  default     = "system_s3cret!"
  sensitive   = true
}

terraform {
  required_version = ">= 1.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

provider "openstack" {
  cloud = var.cloud_name
}

data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

data "openstack_images_image_v2" "devstack" {
  name        = var.devstack_image_name
  most_recent = true
}

variable "node_vpc_id" {
  description = "The ID of the VPC the Kata nodes run in"
  type        = string
}

variable "node_subnets" {
  description = "Name tags of the subnets the Kata nodes run in"
  type        = set(string)
}

variable "node_security_group_id" {
  description = "The security group shared by all cluster nodes"
  type        = string
}

variable "node_instance_profile" {
  description = "The instance profile shared by all cluster nodes"
  type        = string
}

variable "runtime_class_name" {
  description = "The RuntimeClass that pods set as runtimeClassName to run in a Kata VM"
  type        = string
  default     = "kata"
}

variable "node_pool" {
  description = "Karpenter NodePool for Kata nodes (AL2023, nested virtualization)"
  type = object({
    ami_alias           = optional(string, "al2023@v20261012")
    instance_families   = optional(list(string), ["c8i", "m8i", "r8i"]) # nested virtualization is 8th-gen Intel only
    capacity_types      = optional(list(string), ["spot", "on-demand"])
    root_volume_size_gb = optional(number, 100)
    cpu_limit           = optional(number, 64)
  })
  default = {}
}

variable "kata_deploy" {
  description = "kata-deploy Helm release that installs the Kata runtime on Kata nodes"
  type = object({
    helm_version = optional(string, "4.2.0")
    shim         = optional(string, "qemu-runtime-rs")
  })
  default = {}
}

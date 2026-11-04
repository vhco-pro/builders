# -- image --
variable "ubuntu_version" {
  type        = string
  default     = "noble"
  description = "Ubuntu codename (noble = 24.04, jammy = 22.04)."
}

variable "arch" {
  type        = string
  default     = "amd64"
  description = "Target architecture for QEMU. amd64 is verified; arm64/HVF needs separate runtime validation."
}

variable "qemu_accelerator" {
  type        = string
  default     = "kvm"
  description = "QEMU accelerator. Linux/KVM: kvm. macOS same-arch: hvf. Software emulation: tcg (slow)."
}

variable "output_raw" {
  type        = bool
  default     = false
  description = "Also export a raw disk after the portable qcow2 build."
}

# -- proxmox api (proxmox-clone builder) --
# Override connection placeholders in an untracked *.auto.pkrvars.hcl.
# Validation also requires a nonempty token; make check supplies a dummy value.
# NEVER commit a real token.
variable "proxmox_url" {
  type        = string
  default     = "https://proxmox.example.com:8006/api2/json"
  description = "Proxmox API endpoint."
}

variable "proxmox_api_token_id" {
  type        = string
  default     = "packer@pve!packer"
  description = "Proxmox API token id, e.g. user@realm!tokenname."
}

variable "proxmox_api_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Proxmox API token secret. Supply via PKR_VAR_proxmox_api_token or an untracked vars file. NEVER commit."
}

variable "proxmox_node" {
  type        = string
  default     = "pve"
  description = "Proxmox node to build on."
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Explicitly skip certificate verification for an isolated test host. Prefer a trusted certificate."
}

variable "proxmox_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool for the final cloud-init drive. The cloned OS disk inherits the base template storage."
}

variable "proxmox_cpu_type" {
  type        = string
  default     = "host"
  description = "Native Proxmox CPU model. host exposes the node CPU features; choose a shared supported model when live migration between different CPUs is required."

  validation {
    condition     = length(trimspace(var.proxmox_cpu_type)) > 0 && trimspace(var.proxmox_cpu_type) == var.proxmox_cpu_type
    error_message = "The Proxmox CPU type must be a non-empty model name without surrounding whitespace, supported by the target node."
  }
}

variable "proxmox_task_timeout" {
  type        = string
  default     = "10m"
  description = "Maximum wait for asynchronous Proxmox operations such as a full clone. Increase for larger disks or slower storage."
}

variable "base_template_name" {
  type        = string
  default     = "ubuntu-noble-cloudimg"
  description = "Name of the Stage-0 base cloud-init template to clone (see scripts/create-base-template.sh)."
}

# -- resulting proxmox template --
variable "template_name" {
  type        = string
  default     = "ubuntu-2404-base"
  description = "Name of the golden template produced on Proxmox."
}

variable "template_vmid" {
  type        = number
  default     = 0
  description = "Output VM ID. Zero lets Proxmox allocate a new ID; set an unused ID explicitly for reserved test ranges."
}

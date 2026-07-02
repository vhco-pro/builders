# -- image --
variable "ubuntu_version" {
  type        = string
  default     = "noble"
  description = "Ubuntu codename (noble = 24.04, jammy = 22.04)."
}

variable "arch" {
  type        = string
  default     = "amd64"
  description = "Target arch for the qemu build (amd64 or arm64). Override to arm64 for a fast HVF build on Apple Silicon."
}

variable "qemu_accelerator" {
  type        = string
  default     = "kvm"
  description = "QEMU accelerator. Linux/KVM: kvm. macOS same-arch: hvf. Cross-arch emulation: none (slow TCG)."
}

variable "user_password" {
  type        = string
  default     = "changeme"
  description = "Password set on the default 'ubuntu' user during cleanup (build-time only)."
}

# -- proxmox api (proxmox-clone builder) --
# Placeholder defaults keep `packer validate` green; override real values in an
# untracked *.auto.pkrvars.hcl. NEVER commit the token.
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
  default     = true
  description = "Skip TLS verify (true for self-signed homelab certs)."
}

variable "proxmox_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool for the VM disk and the cloud-init drive."
}

variable "base_template_name" {
  type        = string
  default     = "ubuntu-2404-cloudimg"
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
  default     = 9200
  description = "VM id for the golden template."
}

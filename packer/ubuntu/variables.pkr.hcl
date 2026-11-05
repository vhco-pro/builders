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

# -- shared PDS provisioning --
variable "provisioning_recipe" {
  type        = string
  default     = "recipes/default.sh"
  description = "Trusted Bash recipe selecting PDS functions. Native settings and sealing always run."
  validation {
    condition     = fileexists(var.provisioning_recipe)
    error_message = "Select an existing readable Bash recipe before starting a build."
  }
}

variable "pds_version" {
  type        = string
  default     = "0.20.0"
  description = "Exact PDS Debian version. The default published release includes the shared image recipe helpers; explicit candidates remain available for development."
  validation {
    condition     = can(regex("^[0-9][A-Za-z0-9.+:~_-]*$", var.pds_version))
    error_message = "Set an exact Debian package version."
  }
}

variable "pds_input_directory" {
  type        = string
  default     = "pds"
  description = "Public signing key input directory, optionally containing candidate.deb for explicit pre-release validation."
  validation {
    condition     = fileexists("${var.pds_input_directory}/repository-key.asc")
    error_message = "The PDS input directory must contain repository-key.asc."
  }
}

variable "pds_repository" {
  type        = string
  default     = "https://michielvha.github.io/PDS/apt/"
  description = "Signed PDS APT repository retained for updates after deployment."
  validation {
    condition     = can(regex("^https://[^[:space:]]+/$", var.pds_repository))
    error_message = "Use an HTTPS repository URL ending in a slash."
  }
}

variable "pds_key_fingerprint" {
  type        = string
  default     = "37C7D029C0FE4DB0E66E5F72AFA1101D94CBF301"
  description = "Expected primary fingerprint of the public PDS repository signing key."
  validation {
    condition     = can(regex("^[A-F0-9]{40}$", var.pds_key_fingerprint))
    error_message = "Supply a full uppercase OpenPGP primary fingerprint."
  }
}

variable "pds_candidate_sha256" {
  type        = string
  default     = ""
  description = "Explicit candidate.deb SHA-256. Empty selects the signed repository; no candidate fallback is allowed."
  validation {
    condition     = var.pds_candidate_sha256 == "" || can(regex("^[a-f0-9]{64}$", var.pds_candidate_sha256))
    error_message = "Supply the candidate package's lowercase SHA-256, or leave empty for the repository route."
  }
}

variable "motd_preset" {
  type        = string
  default     = "vhco"
  description = "MOTD selection exported to recipes as BUILD_MOTD_PRESET; default recipe accepts packaged PDS presets."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]*$", var.motd_preset))
    error_message = "Use a PDS preset name such as vhco, stackweaver or edgeforge."
  }
}

variable "kubectl_channel" {
  type        = string
  default     = "1.37"
  description = "Kubernetes minor APT channel exported as BUILD_KUBECTL_CHANNEL. Custom recipes decide whether to use it."
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubectl_channel))
    error_message = "Use a Kubernetes minor channel such as 1.37."
  }
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

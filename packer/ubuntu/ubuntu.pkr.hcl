packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# qemu builder -> portable local qcow2 artifact.
# Also the fast local test path: build arm64 with HVF on Apple Silicon via
#   packer build -only='qemu.ubuntu' -var 'arch=arm64' -var 'qemu_accelerator=hvf' .
# ---------------------------------------------------------------------------
source "qemu" "ubuntu" {
  accelerator      = var.qemu_accelerator
  cd_files         = ["./cloud-init/*"]
  cd_label         = "cidata"
  disk_compression = true
  disk_image       = true
  disk_size        = "10G"
  headless         = true
  iso_checksum     = "file:https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/SHA256SUMS"
  iso_url          = "https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/${var.ubuntu_version}-server-cloudimg-${var.arch}.img"
  output_directory = "output-${var.ubuntu_version}-${var.arch}"
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  ssh_password     = "ubuntu"
  ssh_username     = "ubuntu"
  ssh_timeout      = "20m"
  vm_name          = "ubuntu-${var.ubuntu_version}-${var.arch}.qcow2"
  qemuargs = [
    ["-m", "2048M"],
    ["-smp", "2"],
    ["-serial", "mon:stdio"],
  ]
}

# ---------------------------------------------------------------------------
# proxmox-clone builder -> native Proxmox template.
# Clones the Stage-0 base cloud-init template (see scripts/create-base-template.sh),
# customizes it, and seals it as a generic golden template with an empty cloud-init
# drive for clone-time init. Build with:
#   packer build -only='proxmox-clone.ubuntu' -var-file=proxmox.auto.pkrvars.hcl .
# ---------------------------------------------------------------------------
source "proxmox-clone" "ubuntu" {
  # -- Proxmox API connection --
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.proxmox_insecure

  # -- base to clone (Stage 0) --
  clone_vm        = var.base_template_name
  full_clone      = true
  scsi_controller = "virtio-scsi-pci"
  qemu_agent      = true
  os              = "l26"

  # -- resulting golden template --
  vm_id                = var.template_vmid
  template_name        = var.template_name
  template_description = "Generic Ubuntu ${var.ubuntu_version} golden image. Built by Packer. No baked identity."

  # -- empty clone-time cloud-init drive (filled per-VM by the consumer) --
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage_pool

  # Packer generates a temporary SSH key and injects it via cloud-init for the build.
  ssh_username = "ubuntu"
  ssh_timeout  = "20m"
}

build {
  sources = [
    "source.qemu.ubuntu",
    "source.proxmox-clone.ubuntu",
  ]

  # Generic, non-identity provisioning shared by both builders.
  #
  # Identity (hostname, users, SSH keys, static IP) is intentionally NOT set here.
  # It is injected at CLONE time via cloud-init (spec 0001 / issue #1).
  #
  # Tooling (kubectl, zsh, hardening, MOTD) moves to the PDS package in spec 0003 /
  # issue #3 and is intentionally omitted here so the image stays generic and builds
  # green. install.sh only waits for cloud-init; cleanup.sh seals the image.
  provisioner "shell" {
    execute_command = "echo 'packer' | sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "scripts/install.sh",
      "scripts/cleanup.sh",
    ]
    environment_vars = [
      "USER_PASSWORD=${var.user_password}",
    ]
  }
}

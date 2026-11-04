packer {
  required_plugins {
    proxmox = {
      version = "= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
    qemu = {
      version = "= 1.1.8"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# qemu builder -> portable local qcow2 artifact.
# Unvalidated arm64/HVF example; firmware and QEMU settings need separate verification:
#   packer build -only='qemu.ubuntu' -var 'arch=arm64' -var 'qemu_accelerator=hvf' .
# ---------------------------------------------------------------------------
source "qemu" "ubuntu" {
  accelerator      = var.qemu_accelerator
  cd_files         = ["./cloud-init/user-data", "./cloud-init/meta-data"]
  cd_label         = "cidata"
  disk_compression = true
  disk_image       = true
  disk_size        = "10G"
  headless         = true
  iso_checksum     = "file:https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/SHA256SUMS"
  iso_url          = "https://cloud-images.ubuntu.com/${var.ubuntu_version}/current/${var.ubuntu_version}-server-cloudimg-${var.arch}.img"
  output_directory = "output-${var.ubuntu_version}-${var.arch}"
  shutdown_command = "sudo -n shutdown -P now"
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
  task_timeout             = var.proxmox_task_timeout

  # -- base to clone (Stage 0) --
  clone_vm        = var.base_template_name
  full_clone      = true
  cpu_type        = var.proxmox_cpu_type
  scsi_controller = "virtio-scsi-pci"
  qemu_agent      = true
  os              = "l26"
  memory          = 2048
  cores           = 2

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

  # Native OS configuration is applied through cloud-init for both outputs.
  # PDS tooling remains a separate, pinned-package integration.
  provisioner "file" {
    source      = "cloud-init/build-config.yaml"
    destination = "/tmp/build-config.yaml"
  }

  provisioner "shell" {
    timeout         = "20m"
    execute_command = "sudo -n bash '{{ .Path }}'"
    script          = "scripts/wait-cloud-init.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -n bash '{{ .Path }}' /tmp/build-config.yaml"
    script          = "scripts/install.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -n bash '{{ .Path }}' --image-build"
    script          = "scripts/seal-image.sh"
  }

  post-processor "shell-local" {
    only = ["qemu.ubuntu"]
    environment_vars = [
      "BUILD_QEMU_IMAGE=output-${var.ubuntu_version}-${var.arch}/ubuntu-${var.ubuntu_version}-${var.arch}.qcow2",
      "BUILD_OUTPUT_RAW=${var.output_raw}",
    ]
    script = "scripts/export-raw.sh"
  }
}

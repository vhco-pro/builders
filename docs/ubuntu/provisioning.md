# Select the Ubuntu image recipe

Builders applies native Ubuntu settings, installs an exact PDS package, runs the selected Bash
recipe and seals the image. Both QEMU and native Proxmox use this sequence. PDS remains usable
on an ordinary host independently of builders.

This branch is a candidate integration. The last published PDS release, 0.19.0, lacks the new image
helpers. Until the dependent PDS change is reviewed and separately released, use the explicit
[candidate-package route](../../packer/ubuntu/pds/readme.md). A missing selected function stops
the build. A candidate build does not establish that the future signed release works.

## Default selections

The [default recipe](../../packer/ubuntu/recipes/default.sh) calls the shared functions directly:

```bash
install_zi
configure_zsh
setup_motd_preset "$BUILD_MOTD_PRESET"
install_gh
install_kubectl "$BUILD_KUBECTL_CHANNEL" --system
update_system_cron_entry
restricted_ssh_security_profile
```

This selects the existing Zi/Powerlevel10k configuration, a VHCO MOTD, GitHub CLI, kubectl and its
Krew plugins, nightly APT upgrades and key-only SSH with root login disabled. SSH policy is last so
package installers can finish any service operations first. The helper validates configuration
without reloading SSH; builders checks service state and the journal through sealing.

Zi downloads each user's existing plugin set at first shell startup. That first startup needs
internet access; upstream plugin revisions can differ between users or builds. There is no new
image plugin cache to maintain. Krew, neat, view-secret and stern are installed during the build
into `/usr/local/share/pds/krew`, owned by root and available to new users without downloading
another copy. Updating that shared Krew tree requires an administrator.

The nightly job runs at 00:00 in the image's configured timezone. It upgrades APT-managed packages,
including PDS/GitHub CLI and kubectl within its chosen minor channel. It preserves modified
conffiles and waits up to five minutes for package locks. It does not configure automatic reboots
or remove Ubuntu's APT timers. Build-time version records do not freeze a running machine at
those versions, and a PDS package update does not regenerate copied shell configuration.

## Choose a different recipe

The [custom example](../../packer/ubuntu/recipes/custom.example.sh) selects Zi, shared shell
configuration and the MOTD. It omits the PDS nightly-update and SSH-policy calls. Select it from
`packer/ubuntu`, adding the package inputs appropriate to your candidate or released package:

```bash
packer build -only='qemu.ubuntu' \
  -var 'provisioning_recipe=recipes/custom.example.sh' .
```

Copy that example to create your own recipe. Recipes are trusted Bash code running as root in the
disposable build guest. Selected calls must report failures. Native settings, package identity
checks and sealing always run. Omitting a policy call leaves any Ubuntu/vendor policy in place;
it does not enable password login or undo a previous configuration.

The sealer treats `/root` and `/home/ubuntu` as build workspaces. It keeps standard shell startup
files and the shared PDS preset, discarding other contents, including client configuration and
histories. Put shared tooling in system paths and future users' shell assets in `/etc/skel`.

`motd_preset` defaults to `vhco`; packaged alternatives are `stackweaver` and the preserved legacy
`edgeforge`. `kubectl_channel` defaults to `1.37`; choose a minor channel appropriate for your
cluster. Builders exports these as `BUILD_MOTD_PRESET` and `BUILD_KUBECTL_CHANNEL`. The default
recipe uses them, while a custom recipe decides whether to use or override them. PDS also keeps
`setup_motd <banner-file>` for an operator's own text banner.

## Supply the deployed identity

Real users, public keys, shell, sudo policy, hostname and networking belong to deployment inputs.
The temporary build account is locked and loses its keys during sealing. For a Zsh admin user,
use a complete cloud-config, replacing the example key:

```yaml
#cloud-config
hostname: my-service
ssh_pwauth: false
disable_root: true
users:
  - name: operator
    groups: [sudo]
    shell: /usr/bin/zsh
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY
```

For Proxmox, store the complete user-data on snippet-capable storage and select it with the
clone's `cicustom` user input. Storage must already permit snippets and the operator needs access
to that storage; builders does not enable the capability automatically. For a portable disk,
supply the same configuration through a NoCloud seed. Each instance needs its own identity.

See [SSH and debugging](ssh-and-debugging.md) for connection commands and
[development checks](../development.md) for local, artifact and fresh-instance validation.

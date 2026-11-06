# Validate Ubuntu images with disposable deployments

Run this procedure for default and custom recipes, for both native and portable outputs. Use two
new instances per output/recipe pair. The [local checks](../development.md) do not run these steps.
Record the source commit, Packer/plugin versions, PDS version and package digest with the results.
Keep failed attempts separate from completed runs.

## Reserve resources and record the baseline

Use a management machine with Packer, OpenSSH, jq, qemu-img, libguestfs and a NoCloud ISO builder.
Portable builds need KVM or an explicitly selected emulator. A disposable nested-KVM runner can
provide that environment; record and remove that runner with the other owned test resources.
Packer and libguestfs stay off the hypervisor.

Before creating anything, read the cluster inventory and storage configuration:

```bash
ssh "$PVE_HOST" pvesh get /cluster/resources --output-format json
ssh "$PVE_HOST" pvesh get /storage --output-format json
```

Save the original guest IDs, node/type, power states and SHA256 of each configuration after removing
its volatile `digest` field and sorting JSON keys. Use `pvesh get /nodes/NODE/qemu/ID/config` for VMs
and the corresponding `lxc` path for containers. Record storage configuration hashes too; normalize
comma ordering in `content` before comparing. Save these baselines privately outside the repository.
A later comparison must use the original ID list, so a missing guest fails the audit.

Choose unused IDs and unique names for the base, native outputs, optional runner and eight test
instances. Check both the guest inventory and storage contents for those IDs. An orphan volume is
an occupied resource even when no guest configuration exists. Keep an ownership record with each
new resource's exact name, ID, configuration and associated disks/seed paths. Refuse an occupied ID;
do not stop or delete a pre-existing guest to make room.

Use existing snippet-capable storage for native user-data, or explicitly authorize and record a
temporary snippet-only store. Do not enable snippets on an unrelated storage configuration as part
of a test. Scope the Packer token to the selected base/output IDs, storage and bridge; record its
expiry and remove it after testing. Never retain its secret in logs or committed inputs.

## Build and inspect before booting

Follow the [native build](proxmox.md) and [portable build](local-build.md) procedures with explicit
unused IDs/output directories. Select `recipes/default.sh`, then repeat from a clean base with
`recipes/custom.example.sh`. Do not reuse an already provisioned default image as the custom base.
Keep full build logs and the recipe hash. For native outputs, retain `qm config OUTPUT_ID` showing
`template: 1`, cloud-init media, `cpu: host` when using the default, and no temporary `ciuser`,
`cipassword` or `sshkeys`.

Inspect each stopped, unbooted output with `make check-image` before making writable deployments.
Use a read-only export of an owned native disk; record its volume/export checksum and restore its
prior activation state. For portable output, compare both formats:

```bash
qemu-img compare -f qcow2 -F raw image.qcow2 image.raw
```

Require exit 0 and identical contents. Keep exported disks unchanged for later inspection. Cross-check
`/var/lib/builders/pds.json` against the actual dpkg database, retained APT source and public-key
fingerprint inside every disk. A provenance JSON file alone does not establish installed identity.
The offline checker rejects generated netplan, cloud-init instance state, host keys and build access.

## Create two independently initialized instances

Generate separate SSH keys, user names, hostnames and cloud-init instance IDs. Use the complete
[deployment user-data](provisioning.md#supply-the-deployed-identity), setting each user's Zsh shell
and sudo policy explicitly. Keep private test keys and passwords out of logs; discard them afterward.

For native output, full-clone the owned template to each reserved ID, then select the complete user-data
with `qm set ID --cicustom user=STORE:snippets/FILE.yaml --ipconfig0 ip=dhcp` before starting it.
Record the exact snippet path and contents for ownership checks. Inspect both clones' CPU settings
and expected AES/AVX features when validating the single-node `host` default.

For portable output, copy the inspected qcow2 into a new writable disk for each instance. Give each
NoCloud seed its own `user-data` and `meta-data`; the latter contains a unique `instance-id` and the
matching `local-hostname`. Build the seed with:

```bash
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

Attach that seed to the new instance before first boot. When using Proxmox to boot the portable disk,
create a new owned VM, import only its disk, attach it as `scsi0`, set `boot: order=scsi0`, attach its
seed ISO and enable the guest agent. Record the imported volume and ISO checksum. These are deployment
test imports; the native Packer build must have no per-build import/upload step.

Require completed cloud-init without errors; the known generator deprecation alone is accepted as
[documented](proxmox.md). Log in using each supplied non-root key and run `id -un`, retaining the exit
code and returned user. Copy `check-instance.sh` and `check-user-shell.zsh` into the same directory
and run the former as that user with `default` or `custom`. Both Zsh startups must pass. Keep the
actual downloaded Zi/plugin commit IDs, shell, sudo, MOTD and tool results. The first startup needs
network access. Each user must reject the other instance's private key at authentication.

Record each instance's `/etc/machine-id`, SSH host-key fingerprints, hostname and DHCP client ID
(`CLIENTID` in `/run/systemd/netif/leases/` for the tested Ubuntu/networkd images). Require eight
distinct values in the final matrix. Absence of a client ID is a failed observation.

For at least one default instance per output, record `/proc/sys/kernel/random/boot_id`, reboot only
that owned instance, then wait for a different boot ID and completed cloud-init. Require the same
machine ID, DHCP client ID and every host-key fingerprint, successful non-root key login and the
expected SSH settings afterward. Record each key type separately before and after:

```bash
for key in /etc/ssh/ssh_host_*_key.pub; do
  printf '%s ' "${key##*/}"
  ssh-keygen -lf "$key"
done
```

Retain `systemd-machine-id-commit.service` result/state. An inactive unit with `Result=success` only
records no failure; its conditions may have skipped execution. Distinct first-boot IDs
do not establish that those IDs survive reboot.

## Exercise the exact update job

Inside each default instance, use sudo to run the following as root and retain its full output and
process exit status. Run it only on these owned disposable guests; it performs real upgrades.

```bash
set -euo pipefail
job=$(awk '$1=="0" && $2=="0" && $6=="root" {
  $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print
}' /etc/cron.d/pds-update)
test -n "$job"
printf 'EXACT_CRON_COMMAND=%s\n' "$job"
set +e
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root SHELL=/bin/sh LOGNAME=root \
  /bin/sh -c "$job" </dev/null
update_status=$?
set -e
printf 'UPDATE_EXIT_CODE=%s\n' "$update_status"
test "$update_status" -eq 0
systemctl is-active cron
systemctl is-enabled cron
```

Require `UPDATE_EXIT_CODE=0`, an active/enabled scheduler and exactly one midnight PDS job. The
installed command redirects upgrade output to its log; retain that log separately if diagnosing a
failure. Custom instances must lack both the PDS job and `00-pds-security.conf`.

## Prove SSH authentication, including a permissive control

Use the first default instance of each output as an authentication fixture. Set `ssh_pwauth: true`
and `disable_root: false` in its deployment user-data. Provide a temporary known non-root password
and a separate temporary root public key. If provisioning credentials after boot through the owned
guest agent, record that timing; it does not prove cloud-init password injection. The other instance
uses the normal key-only user-data.

Create `10-builders-test-permissive.conf` inside the fixture with `PasswordAuthentication yes`,
`KbdInteractiveAuthentication yes`, `PubkeyAuthentication yes` and `PermitRootLogin yes`.
Keep the baked `00-pds-security.conf` in place first and check `sshd -T`: its restrictions must win.
Temporarily hold only that PDS file outside the included `*.conf` glob, run `sshd -t` and
reload SSH inside the owned fixture. Require these positive controls to authenticate:

- Non-root password: disable public-key and keyboard-interactive fallback in the client.
- Non-root keyboard-interactive: disable password and public-key fallback.
- Root key: use only the temporary root key and require `id -u` to return `0`.

Restore the unchanged PDS file, validate and reload the fixture, then repeat. Non-root supplied-key
login must succeed; password, keyboard-interactive and root-key authentication must fail. The server
must offer only `publickey`. Retain the attempted method/user, actual authentication result, offered
methods and command exit/refusal status. A root forced-command banner is not authentication denial.
A summary boolean or `sshd -T` alone is insufficient. Use an SSH library's explicit authentication
methods or client options that disable fallback; never log the temporary password or private key.

Finally remove the permissive file/root test key, lock the test passwords, validate configuration
and reload the owned fixture. Keep this restoration in the failure path too. These fixture reloads
occur after deployment. The no-reload requirement concerns build-time policy selection through
sealing: retain the build observer's PID, activation/start timestamps and journal interval for that
separate proof. Missing observer evidence when a recipe changes the policy must fail the build.

## Audit and remove owned resources

Compare every original guest's configuration hash and power state with the baseline after each phase.
Before stopping or deleting a test guest, compare its current configuration to its ownership record;
require the expected name and verify that all volumes for its ID are recorded. Stop if ownership or
configuration changed, an unknown volume exists, or a protected guest differs. Do not use a wildcard
name match or a broad ID range as deletion authority.

After each pair, remove only its verified guests, exact matching snippets/ISOs and upload directory.
Compare transferred archive checksums on both machines before removing an owned runner. Remove the
verified test templates/base, temporary API identity and approved empty snippet-only storage last.
Confirm the original storage configurations are unchanged and no owned guest, volume, seed, export
or API account remains. Retain the observed post-cleanup guest hashes and power states and normalized
storage hashes beside the preflight values, then derive the summary from those comparisons. A boolean
written after an assertion is not a substitute for the observed values. Record the observation time;
matching endpoints do not attribute unrelated activity between snapshots. Retain command exits,
ownership records and the comparison inputs/results.
A failed build or interrupted controller requires inspection of its recorded partial resources;
it does not authorize deleting unrelated guests.

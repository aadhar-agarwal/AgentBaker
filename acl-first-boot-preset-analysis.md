# ACL First Boot Preset Analysis

**Date:** April 16, 2026
**Reference node:** `aks-nodepool1-17090824-vmss000000` (ACL 3.0.20260304, kernel 6.6.126.1-1.azl3, containerd 2.0.0)

## Background

Removing `/etc/machine-id` triggers systemd first-boot detection which runs `preset-all` on every unit with `[Install]`. ACL builds systemd with `-Dfirst-boot-full-preset=true`, so both `enable` and `disable` rules apply. The `disable *` catch-all in `99-default-disable.preset` will actively disable every unit not explicitly listed with `enable` in any preset file.

## Preset Processing Order

Presets are sorted by filename across `/etc/systemd/system-preset/` and `/usr/lib/systemd/system-preset/`. `/etc/` files override same-named `/usr/lib/` files. **First match for a unit wins.**

```
50-acl-coreos-metadata.preset
50-acl-ntp.preset
50-acl-rsyncd.preset
50-acl-sshd.preset        (enables sshd.socket, disables sshd.service)
50-conntrackd.preset
50-etcd-member.preset
50-flannel.preset
50-lvm2.preset
50-nfs-server.preset
50-ntpd.preset
50-rpcbind.preset
50-saslauthd.preset
90-default.preset          (enables many OS services; also DISABLES systemd-oomd, systemd-boot-update, systemd-timesyncd)
90-systemd.preset          (enables core systemd services)
99-default-disable.preset  (disable *)
```

## Current `99-default-disable.preset` Allowlist

```
enable aks-node-controller.service
enable disk_queue.service
enable ci-syslog-watcher.path
enable ci-syslog-watcher.service
enable update_certs.path
enable aks-log-collector.timer
enable sync-container-logs.service
enable cgroup-memory-telemetry.timer
enable cgroup-pressure-telemetry.timer
enable resolv-uplink-override.service
enable snapshot-update.timer
enable measure-tls-bootstrapping-latency.service
enable systemd-sysext.service
enable ensure-sysext.service
disable *
```

## Services Enabled on Prod (preset=disabled) NOT in the Allowlist

These 38 services are currently enabled on the prod node with `preset=disabled`, meaning they were explicitly enabled during VHD build or CSE and are **not covered by any OS preset**. On first boot with `disable *`, they would all be disabled.

### AKS-Critical Services

| Service | Purpose | Notes |
|---------|---------|-------|
| `containerd.service` | Container runtime | Typically enabled by CSE, but needs to survive first-boot |
| `kubelet.service` | Kubernetes node agent | Typically enabled by CSE |
| `node-exporter.service` | Prometheus metrics exporter | |
| `node-problem-detector.service` | Node health monitoring | |
| `secure-tls-bootstrap.service` | TLS bootstrapping for kubelet | |

### SSH / Connectivity (needed BEFORE CSE can run)

| Service | Purpose | Notes |
|---------|---------|-------|
| `sshd-keygen.service` | Generate SSH host keys | **Critical** — without host keys, SSH won't work |
| `sshkeys.service` | SSH key management | |
| `ssh-key-proc-cmdline.service` | SSH keys from kernel cmdline | |
| `update-ssh-keys-after-ignition.service` | SSH key setup post-ignition | |

> **Note:** `sshd.socket` is already enabled via `50-acl-sshd.preset`, but the key generation services are not covered.

### Cloud-Init / Azure Boot Infrastructure

| Service | Purpose | Notes |
|---------|---------|-------|
| `oem-cloudinit.service` | OEM cloud-init processing | **Critical** — needed for initial node config |
| `enable-oem-cloudinit.service` | Enables OEM cloud-init | |
| `azure-ephemeral-disk-setup.service` | Azure ephemeral disk setup | |
| `network-cleanup.service` | Network cleanup | |
| `packet-phone-home.service` | Phone home service | |
| `audit-rules.service` | Load audit rules | |

### systemd Infrastructure

| Service | Purpose | Notes |
|---------|---------|-------|
| `systemd-sysext.socket` | Companion to systemd-sysext.service | `.service` is in preset but `.socket` is not |
| `systemd-confext.service` | Configuration extensions | |
| `systemd-networkd.socket` | networkd socket activation | |
| `systemd-homed-activate.service` | Home directory activation | |
| `systemd-pcrextend.socket` | TPM PCR extend socket | |
| `systemd-pcrlock-file-system.service` | PCR lock — file system | |
| `systemd-pcrlock-firmware-code.service` | PCR lock — firmware code | |
| `systemd-pcrlock-firmware-config.service` | PCR lock — firmware config | |
| `systemd-pcrlock-machine-id.service` | PCR lock — machine-id | |
| `systemd-pcrlock-make-policy.service` | PCR lock — make policy | |
| `systemd-pcrlock-secureboot-authority.service` | PCR lock — secureboot authority | |
| `systemd-pcrlock-secureboot-policy.service` | PCR lock — secureboot policy | |
| `systemd-sysupdate.timer` | System updates timer | |
| `systemd-sysupdate-reboot.timer` | System update reboot timer | |
| `remote-veritysetup.target` | DM-verity target | |

### Storage / Hardware

| Service | Purpose | Notes |
|---------|---------|-------|
| `blk-availability.service` | LVM block device availability | |
| `nvmefc-boot-connections.service` | NVMe-FC boot connections | |
| `nvmf-autoconnect.service` | NVMe fabric autoconnect | |
| `mdcheck_continue.timer` | RAID md check continue | |
| `mdcheck_start.timer` | RAID md check start | |

## Services Explicitly Disabled by Higher-Priority Presets

These services are enabled on the prod node but are explicitly **disabled** in `90-default.preset` (which has higher priority than `99-*`). Adding them to the `99-default-disable.preset` **will not help** — the `disable` rule in `90-default.preset` matches first.

| Service | Disabled by | Notes |
|---------|-------------|-------|
| `systemd-oomd.service` | `90-default.preset` | Enabled on prod via explicit `systemctl enable` during VHD build |
| `systemd-oomd.socket` | (companion to above) | |
| `systemd-boot-update.service` | `90-default.preset` | Enabled on prod via explicit `systemctl enable` during VHD build |

**Workaround:** If these need to survive first boot, create a separate preset file at a higher priority, e.g.:

```
/etc/systemd/system-preset/50-aks-overrides.preset
```

```ini
enable systemd-oomd.service
enable systemd-oomd.socket
enable systemd-boot-update.service
```

## Priority / Risk Assessment

### Must-add (node will not boot correctly or be reachable without these)

1. **SSH key services** — `sshd-keygen.service`, `sshkeys.service`, `ssh-key-proc-cmdline.service`, `update-ssh-keys-after-ignition.service`
2. **Cloud-init services** — `oem-cloudinit.service`, `enable-oem-cloudinit.service`
3. **Azure ephemeral disk** — `azure-ephemeral-disk-setup.service`
4. **sysext socket** — `systemd-sysext.socket` (companion to already-listed `.service`)

### Should-add (AKS workloads will fail without these)

5. **Container runtime + kubelet** — `containerd.service`, `kubelet.service`
6. **Node monitoring** — `node-exporter.service`, `node-problem-detector.service`
7. **TLS bootstrap** — `secure-tls-bootstrap.service`
8. **Network/audit** — `network-cleanup.service`, `audit-rules.service`

### Nice-to-have (infrastructure services that are enabled on prod)

9. **systemd-oomd** — requires higher-priority preset (see above)
10. **PCR lock services** — security/TPM services
11. **Storage services** — `blk-availability.service`, NVMe, md RAID timers
12. **systemd-confext**, `systemd-homed-activate`, `systemd-networkd.socket`, etc.
13. **`packet-phone-home.service`**, `systemd-sysupdate.timer`, `systemd-sysupdate-reboot.timer`

## Full Diff: Prod Enabled (preset=disabled) vs Current Allowlist

```diff
  # Already in 99-default-disable.preset:
  enable aks-node-controller.service
  enable disk_queue.service
  enable ci-syslog-watcher.path
  enable ci-syslog-watcher.service
  enable update_certs.path
  enable aks-log-collector.timer
  enable sync-container-logs.service
  enable cgroup-memory-telemetry.timer
  enable cgroup-pressure-telemetry.timer
  enable resolv-uplink-override.service
  enable measure-tls-bootstrapping-latency.service
  enable systemd-sysext.service
  enable ensure-sysext.service

+ # SSH / connectivity
+ enable sshd-keygen.service
+ enable sshkeys.service
+ enable ssh-key-proc-cmdline.service
+ enable update-ssh-keys-after-ignition.service
+
+ # Cloud-init / Azure boot
+ enable oem-cloudinit.service
+ enable enable-oem-cloudinit.service
+ enable azure-ephemeral-disk-setup.service
+ enable network-cleanup.service
+ enable packet-phone-home.service
+ enable audit-rules.service
+
+ # AKS workload services
+ enable containerd.service
+ enable kubelet.service
+ enable node-exporter.service
+ enable node-problem-detector.service
+ enable secure-tls-bootstrap.service
+
+ # systemd infrastructure
+ enable systemd-sysext.socket
+ enable systemd-confext.service
+ enable systemd-networkd.socket
+ enable systemd-homed-activate.service
+ enable systemd-pcrextend.socket
+ enable systemd-pcrlock-file-system.service
+ enable systemd-pcrlock-firmware-code.service
+ enable systemd-pcrlock-firmware-config.service
+ enable systemd-pcrlock-machine-id.service
+ enable systemd-pcrlock-make-policy.service
+ enable systemd-pcrlock-secureboot-authority.service
+ enable systemd-pcrlock-secureboot-policy.service
+ enable systemd-sysupdate.timer
+ enable systemd-sysupdate-reboot.timer
+ enable remote-veritysetup.target
+
+ # Storage / hardware
+ enable blk-availability.service
+ enable nvmefc-boot-connections.service
+ enable nvmf-autoconnect.service
+ enable mdcheck_continue.timer
+ enable mdcheck_start.timer

- # snapshot-update.timer — in allowlist but NOT enabled on prod (verify if needed)

  disable *
```

### Note on `snapshot-update.timer`

This unit is in the current `99-default-disable.preset` but was **not** enabled on the prod node. Verify whether it is expected to be present on newer builds or can be removed from the preset.


root@aks-nodepool1-17090824-vmss000000 [ / ]# systemctl list-unit-files --state=enabled --no-pager
UNIT FILE                                    STATE   PRESET
ci-syslog-watcher.path                       enabled disabled
update_certs.path                            enabled disabled
aks-node-controller.service                  enabled disabled
audit-rules.service                          enabled disabled
azure-ephemeral-disk-setup.service           enabled disabled
blk-availability.service                     enabled disabled
chronyd.service                              enabled enabled
ci-syslog-watcher.service                    enabled disabled
containerd.service                           enabled disabled
disk_queue.service                           enabled disabled
enable-oem-cloudinit.service                 enabled disabled
ensure-sysext.service                        enabled disabled
getty@.service                               enabled enabled
iscsi-onboot.service                         enabled enabled
iscsi-starter.service                        enabled enabled
kubelet.service                              enabled disabled
mdmonitor.service                            enabled enabled
measure-tls-bootstrapping-latency.service    enabled disabled
network-cleanup.service                      enabled disabled
node-exporter.service                        enabled disabled
node-problem-detector.service                enabled disabled
nvmefc-boot-connections.service              enabled disabled
nvmf-autoconnect.service                     enabled disabled
oem-cloudinit.service                        enabled disabled
packet-phone-home.service                    enabled disabled
resolv-uplink-override.service               enabled disabled
secure-tls-bootstrap.service                 enabled disabled
selinux-autorelabel-mark.service             enabled enabled
ssh-key-proc-cmdline.service                 enabled disabled
sshd-keygen.service                          enabled disabled
sshkeys.service                              enabled disabled
sync-container-logs.service                  enabled disabled
systemd-boot-update.service                  enabled disabled
systemd-confext.service                      enabled disabled
systemd-homed-activate.service               enabled disabled
systemd-homed.service                        enabled enabled
systemd-network-generator.service            enabled enabled
systemd-networkd-wait-online.service         enabled enabled
systemd-networkd.service                     enabled enabled
systemd-oomd.service                         enabled disabled
systemd-pcrlock-file-system.service          enabled disabled
systemd-pcrlock-firmware-code.service        enabled disabled
systemd-pcrlock-firmware-config.service      enabled disabled
systemd-pcrlock-machine-id.service           enabled disabled
systemd-pcrlock-make-policy.service          enabled disabled
systemd-pcrlock-secureboot-authority.service enabled disabled
systemd-pcrlock-secureboot-policy.service    enabled disabled
systemd-pstore.service                       enabled enabled
systemd-resolved.service                     enabled enabled
systemd-sysext.service                       enabled disabled
update-ssh-keys-after-ignition.service       enabled disabled
dm-event.socket                              enabled enabled
sshd.socket                                  enabled enabled
systemd-journald-audit.socket                enabled enabled
systemd-networkd.socket                      enabled disabled
systemd-oomd.socket                          enabled disabled
systemd-pcrextend.socket                     enabled disabled
systemd-sysext.socket                        enabled disabled
systemd-userdbd.socket                       enabled enabled
nfs-client.target                            enabled enabled
reboot.target                                enabled enabled
remote-cryptsetup.target                     enabled enabled
remote-fs.target                             enabled enabled
remote-veritysetup.target                    enabled disabled
aks-log-collector.timer                      enabled disabled
cgroup-memory-telemetry.timer                enabled disabled
cgroup-pressure-telemetry.timer              enabled disabled
logrotate.timer                              enabled enabled
mdcheck_continue.timer                       enabled disabled
mdcheck_start.timer                          enabled disabled
raid-check.timer                             enabled enabled
systemd-sysupdate-reboot.timer               enabled disabled
systemd-sysupdate.timer                      enabled disabled

73 unit files listed.
root@aks-nodepool1-17090824-vmss000000 [ / ]#

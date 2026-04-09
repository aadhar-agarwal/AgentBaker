# ACL SELinux Enforcing — Missing `spc_t` Permissions

## The Error

`systemctl stop` and `systemctl reload` fail with "Access denied" when run from the `spc_t` context (the context used by the Azure VM agent for provisioning scripts and `az vm run-command`):

```
system_u:system_r:spc_t:s0       ← process context
Enforcing                         ← SELinux mode
stop: FAILED                      ← Access denied
reload: FAILED                    ← Access denied
restart: OK                       ← allowed (systemd checks 'start' for restarts)
sshd: active                      ← still running after failed stop
```

**AgentBaker pipeline failure**: https://msazure.visualstudio.com/CloudNativeCompute/CloudNativeCompute%20Team/_build/results?buildId=157925567&view=logs&j=c7a068aa-0008-5656-5cb7-beef58e331c1&t=cad60b1e-234f-503a-17d4-960acd1fcf47&l=948

## Reproduce It

Create a VM from the ACL image and run this (it runs as `spc_t`):

```bash
# Create the VM
az vm create --resource-group <rg> --name <vm-name> \
    --image "/subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel/images/acldevel/versions/0.20260319.1073003" \
    --location westus2 --size Standard_D2ds_v5 --generate-ssh-keys \
    --security-type TrustedLaunch --enable-vtpm true --public-ip-sku Standard

# Reproduce the bug
az vm run-command invoke --resource-group <rg> --name <vm-name> \
    --command-id RunShellScript --scripts '
id -Z; getenforce
systemctl stop sshd 2>&1 && echo "stop: OK" || echo "stop: FAILED"
systemctl reload sshd 2>&1 && echo "reload: OK" || echo "reload: FAILED"
systemctl restart sshd 2>&1 && echo "restart: OK" || echo "restart: FAILED"
systemctl is-active sshd'
```

Note: `sudo systemctl stop sshd` via SSH works fine because SSH sessions run as `unconfined_t`, not `spc_t`. You can only reproduce this via `az vm run-command`.

**AgentBaker VHD VM** (ACL image after AKS provisioning scripts applied — has additional systemd units, binaries, etc.):
```bash
az vm create --resource-group <rg> --name <vm-name> \
    --image /subscriptions/c4c3550e-a965-4993-a50c-628fd38cd3e1/resourceGroups/aksvhdtestbuildrg/providers/Microsoft.Compute/galleries/PackerSigGalleryEastUS/images/aclgen2TL/versions/1.1773956902.23067 \
    --generate-ssh-keys --size Standard_D2ds_v5 --security-type TrustedLaunch \
    --enable-secure-boot true --enable-vtpm true --location westus3
```
Same `az vm run-command` reproduces the bug on this VM too. Compare SELinux labels between the two with `ls -Z /etc/systemd/system/*.service`.

## The issue

In `rpm_configure_selinux()` (`build_library/rpm/rpm_install.sh`), line ~757:
```
(allow spc_t unlabeled_t (service (start status)))
```

This is missing **`stop`** and **`reload`**. systemd checks different SELinux permissions per operation:

| `systemctl` command | SELinux permission | Result |
|--------------------|--------------------|--------|
| `restart` | `start` | Allowed |
| `stop` | `stop` | **Denied** |
| `reload` | `reload` | **Denied** |

## Possibe Fix

```diff
- (allow spc_t unlabeled_t (service (start status)))
+ (allow spc_t unlabeled_t (service (start status stop reload)))
```

## Questions

- **`/var/lib/selinux/` missing at runtime**: `/var/lib/selinux/` does not exist on the running VM (Flatcar reinitializes `/var` on boot). The kernel loads `policy.33` from `/etc/` which persists, and `start`/`status` work — so the hotfix rules are baked into the binary. But `semodule` management commands (`semodule -l`, `semodule -i`) fail at runtime. Is this a problem?
- **File labeling**: The following systemd units are labeled `unlabeled_t` instead of `systemd_unit_file_t`:

  **On the base ACL VM** (from the OS image itself):
  - `/usr/lib/systemd/system/sshd.service`
  - `/usr/lib/systemd/system/containerd.service`

  **On the AgentBaker VHD VM** (all of the above, plus units added by packer build):
  - `aks-node-controller.service`, `aks-check-network.service`, `aks-log-collector.service`
  - `kubelet.service`, `bind-mount.service`, `kms.service`
  - `cgroup-memory-telemetry.service`, `cgroup-pressure-telemetry.service`
  - `ci-syslog-watcher.service`, `dhcpv6.service`, `disk_queue.service`
  - `ensure-no-dup.service`, `iptables.service`, `ipv6_nftables.service`
  - `localdns.service`, `measure-tls-bootstrapping-latency.service`
  - `mig-partition.service`, `nfs-server.service`, `resolv-uplink-override.service`
  - `secure-tls-bootstrap.service`, `snapshot-update.service`
  - `sync-container-logs.service`, `systemd-timesyncd.service`
  - `teleportd.service`, `update_certs.service`
  - `chronyd.service.d/10-chrony-restarts.conf`
  - `containerd.service.d/50-default-config.conf`
  - `dracut-cmdline.service`, `dracut-initqueue.service`, `dracut-mount.service`, `dracut-pre-mount.service`, `dracut-pre-pivot.service`, `dracut-pre-trigger.service`, `dracut-pre-udev.service`, `dracut-shutdown.service`, `dracut-shutdown-onfailure.service` (9 files — these were `systemd_unit_t` on the base image but flipped to `unlabeled_t` after packer overwrote them)

  The hotfix grants permissions on `unlabeled_t` so things work, but is this the intended labeling?

---

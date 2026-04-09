# Investigation: E2E Failures on `aadagarwal/remove-machine-id`

**Build**: `aadagarebld159764244`
**Branch**: `aadagarwal/remove-machine-id`
**Date**: April 8, 2026
**ASI Link**: https://asi.azure.ms/services/AKS%20E2E%20Infra/pages/E2E%20Builds?buildID=aadagarebld159764244

## Summary

All ~60+ `Scenario_AzureContainerLinux_*` E2E tests fail. Kubelet gets permanently stuck in `activating` state on every node, preventing node registration and causing cluster creation to time out.

## Timeline (Cluster `e2eaks-PKL`, Scenario `Azure_CNI`)

| Time (UTC) | Event | Status |
|---|---|---|
| 21:49:49 | Cluster PUT sent to RP | OK |
| 21:49:54 | RP returns 201 Created, async op `37070e2c` starts | OK |
| 21:50:00 | VMSS `aks-agentpool0-16343636-vmss` does not exist yet (expected) | OK |
| 21:51:00 | VMSS creation begins, control plane components in `NotReady` | OK |
| 21:51:42 | Kernel start on all 3 VMSS instances | OK |
| 21:52:23-33 | CSE starts on all 3 nodes (5-7s after kernel) | OK |
| 21:52:28-40 | **CSE exits code 0 on all 3 nodes — kubelet in `activating`** | **Problem** |
| 21:53:00 | RP sees CSE success but `ValidateAgentpoolNodeReadiness` fails | Stuck |
| 22:06-22:21 | All pods still have `node.kubernetes.io/not-ready` tolerations | Stuck |
| 23:17+ | `SystemAddons.Validate: 0 of 4 pods Running` (repeated every minute) | Stuck |
| 22:49 (v2) / 23:49 (v3) | Test times out with `context deadline exceeded` | Failed |

## Root Cause (Confirmed via Live VM Investigation)

### What the branch does

1. **VHD build** (`vhdbuilder/packer/vhd-image-builder-acl.json`): Adds `sudo rm -f /etc/machine-id` at the end of packer provisioning
2. **VHD build** (`vhdbuilder/packer/install-dependencies.sh`): Calls `deferFirstBootPresetServices()` which moves 4 service unit files out of systemd's path
3. **CSE** (`parts/linux/cloud-init/artifacts/cse_main.sh`): Restores the deferred units and runs `systemctl daemon-reload`

### Why it breaks (confirmed on live VM `test-acl-vm-48-2`)

Removing `/etc/machine-id` triggers systemd's **first-boot detection**. On boot, systemd logs:
```
Detected first boot.
Initializing machine ID from random generator.
Populated /etc with preset unit settings.
```

This `preset-all` applies ACL's preset policies to **every** unit file in `/etc/systemd/system/`. The `deferFirstBootPresetServices()` only defers 4 services, but `preset-all` enables **many more** that should not be enabled at boot.

### Services enabled by `preset-all` that should NOT be (confirmed)

Symlinks created at boot time (`Apr 9 00:24`) in `/etc/systemd/system/multi-user.target.wants/`:

| Service | Impact |
|---|---|
| **`kubelet.service`** | Kubelet starts on boot before CSE configures it — no kubeconfig, no certs, hangs forever in `ExecStartPre` |
| **`docker.socket`** | Re-enabled despite being explicitly masked during VHD build |
| **`snapshot-update.timer`** | Starts update timer that may interfere with provisioning |
| **`measure-tls-bootstrapping-latency.service`** | Starts without proper config |
| **`bind-mount.service`** | |
| **`dhcpv6.service`** | |
| **`ipv6_nftables.service`** | |

Additionally, `preset-all` created:
- `/etc/systemd/system/kubelet.service.requires/resolv-uplink-override.service` — adds a **Requires dependency** to kubelet
- `/etc/systemd/system/nfs-server.service` — NFS server enabled
- `/etc/systemd/system/iptables.service` — iptables re-enabled

### The kubelet death mechanism

On a real AKS node (where `/opt/bin/kubelet` exists on the VHD):
1. Boot with empty `/etc/machine-id` → systemd detects first boot
2. `preset-all` enables `kubelet.service` via `WantedBy=multi-user.target`
3. Systemd starts kubelet automatically during boot — **before CSE runs**
4. Kubelet's `ExecStartPre` scripts run without config (`/etc/default/kubelet` not populated, no kubeconfig, no certs)
5. `ExecStartPre=/bin/sh -c 'until [ -S /run/containerd/containerd.sock ]; do sleep 0.1; done'` — polls forever if containerd isn't ready or is in a bad state
6. CSE runs, tries to `systemctl restart kubelet`, but kubelet is stuck in the first `ExecStartPre` attempt
7. CSE's non-blocking restart returns "success" but kubelet never becomes `active`
8. Node never registers → pods Pending → cluster timeout

On the test VM (no `/opt/bin/kubelet`), kubelet was skipped due to `ConditionPathExists=/opt/bin/kubelet`. But the preset symlinks are still visible, confirming the mechanism.

### The preset file that causes this

ACL's preset files at `/usr/lib/systemd/system-preset/` end with a **catch-all rule**:
```
disable *
```

But earlier rules like `enable docker.socket`, `enable fstrim.timer`, etc. match AKS-installed units because the preset uses glob patterns. The key entry is:
```
enable docker.socket
```
This **overrides** the `systemctl mask docker.socket` done during VHD build, because `preset-all` removes the mask symlink and creates a new enable symlink.

### Kubelet `activating` death spiral

The CSE output from all 3 nodes shows identical behavior:

```
+ systemctl show -p ActiveState --value kubelet
+ local state=activating
+ '[' activating = active ']'
+ '[' activating = activating ']'
+ echo 'kubelet is still activating, continuing anyway...'
```

Kubelet is started with `systemctlEnableAndStartNoBlock` (non-blocking). CSE's `checkServiceHealth kubelet` sees `activating` and returns success (by design — kubelet is expected to take time). But kubelet **never** transitions to `active`, meaning one of its `ExecStartPre` steps is hanging forever.

Kubelet's `ExecStartPre` chain in `kubelet.service`:
```
ExecStartPre=/bin/bash /opt/azure/containers/kubelet.sh
ExecStartPre=/bin/bash /opt/azure/containers/ensure_imds_restriction.sh
ExecStartPre=/bin/bash /opt/azure/containers/validate-kubelet-credentials.sh
ExecStartPre=/bin/sh -c 'until [ -S /run/containerd/containerd.sock ]; do sleep 0.1; done'
```

The last `ExecStartPre` polls for the containerd socket. If containerd is dead or stuck, kubelet loops here forever.

### What localdns is NOT

Initially suspected `localdns.service` (which has `Before=containerd.service` and `Type=notify`) as the blocker. However, `SHOULD_ENABLE_LOCALDNS` is **not set** for these test scenarios — localdns is never started. This rules it out.

## Evidence

### Kusto Queries Used

**Build session list:**
```kql
V3_ASI_Build_SessionList(datetime(2026-04-01), datetime(2026-04-09), "aadagarebld159764244")
| project testScenario, sessionId, testResult, SessionDuration
| order by testResult asc
```

**Async operation errors (operationID from PUT response):**
```kql
AsyncContextActivity
| where TIMESTAMP between (datetime(2026-04-08T21:40:00) .. datetime(2026-04-09T01:00:00))
| where operationID == "37070e2c-a441-402f-8513-f294f1d65e00"
| where level in ("error", "warn") or msg has "error" or msg has "fail"
| project TIMESTAMP, level, msg, suboperationName
```

**CSE exit codes and kubelet status:**
```kql
AsyncContextActivity
| where TIMESTAMP between (datetime(2026-04-08T21:52:00) .. datetime(2026-04-09T01:00:00))
| where operationID == "37070e2c-a441-402f-8513-f294f1d65e00"
| where msg has "ExitCode" or msg has "Perf log" or msg has "vmssCSE"
| project TIMESTAMP, level, msg
| order by TIMESTAMP asc
```

### Key Data Points

- **Agent pool distro**: `CustomizedImageLinuxGuard` (ACL with trusted launch)
- **VHD image**: `aclgen2TL` from `PackerSigGalleryEastUS`, version `1.1775603314.16815`
- **Configuration version**: `v0.20260407.aadagarwal0`
- **Service build**: `Version: aadagarebld159764244 - Branch: refs/heads/aadagarwal/remove-machine-id-4-7`
- **CSE duration**: 5-7 seconds (very fast, no errors)
- **Boot time**: ~38s total (kernel 1.2s + initrd 22s + userspace 15s)
- **Kubelet state at CSE exit**: `activating` — never transitions to `active`
- **Nodes registered**: 0 of 3

### Failure Patterns

| Pattern | Count | Duration | Error |
|---|---|---|---|
| V2 tests (1hr timeout) | ~25 | 01:00:xx | `context deadline exceeded` during cluster create poll |
| V3 tests (30min timeout) | ~30 | 00:30:xx | `PutManagedClusterFailure: context deadline exceeded` |
| Autoupgrader (fast reject) | 3 | 00:03:16 | `400: Autoupgrade does not support custom node image` |

The Autoupgrader failures are **expected** — RP correctly rejects autoupgrade for custom images.

## Live AKS BYOI Node Investigation (Cluster `acl-byoi-fboot`)

Investigated a real AKS BYOI node (`aks-nodepool1-38134348-vmss000000`, k8s 1.33.7) using the same VHD image.

### First-boot confirmed

Kernel command line includes `flatcar.first_boot=detected`. Ignition ran and set presets for its own services.

### Complete list of symlinks created by first-boot/ignition at boot time

From `find /etc/systemd/system -type l -newer chronyd.service`:

| Symlink | Target | Created by |
|---|---|---|
| `multi-user.target.wants/kubelet.service` | `/etc/systemd/system/kubelet.service` | preset-all |
| `multi-user.target.wants/measure-tls-bootstrapping-latency.service` | `/etc/systemd/system/...` | preset-all |
| `multi-user.target.wants/snapshot-update.timer` | `/etc/systemd/system/...` | preset-all |
| `multi-user.target.wants/bind-mount.service` | `/etc/systemd/system/...` | preset-all |
| `multi-user.target.wants/dhcpv6.service` | `/etc/systemd/system/...` | preset-all |
| `multi-user.target.wants/ipv6_nftables.service` | `/etc/systemd/system/...` | preset-all |
| `multi-user.target.wants/containerd.service` | `/usr/lib/systemd/system/...` | CSE (00:40:31) |
| `sysinit.target.wants/ignition-bootcmds.service` | `/etc/systemd/system/...` | ignition |
| `sysinit.target.wants/ignition-file-extract.service` | `/etc/systemd/system/...` | ignition |

### Why this BYOI node survived

The node **worked** because of a timing accident:

| Time | Event |
|---|---|
| 00:40:00 | First-boot `preset-all` enables `kubelet.service` |
| 00:40:17 | Systemd tries to start kubelet → **skipped** (`ConditionPathExists=/opt/bin/kubelet` — binary not yet installed) |
| 00:40:26 | CSE starts |
| 00:40:28 | CSE installs kubelet binary to `/opt/bin/kubelet` |
| 00:40:31 | CSE starts containerd |
| 00:40:37 | CSE starts kubelet (binary now exists, containerd socket available) |
| 00:40:38 | Kubelet active and running, node registers |

The key protection is `ConditionPathExists=/opt/bin/kubelet` — since the kubelet binary is installed by CSE (not pre-cached on the VHD for this k8s version), the preset-enabled kubelet was harmlessly skipped.

### Why E2E tests fail but BYOI works

The E2E environment uses a **newer code path** or VHD build where kubelet binary may already exist on the VHD, or where CSE runs differently. If `/opt/bin/kubelet` exists at boot time, the `ConditionPathExists` check passes and systemd starts kubelet immediately — before CSE configures it.

### docker.socket on the BYOI node

`docker.socket` is **masked** (`-> /dev/null`) on this node. The mask symlink was created at VHD build time (`Apr 7 23:11`). The `preset-all` did NOT override the mask in this case — contradicting what we saw on the plain VM. This may depend on the systemd version or the specific `preset-all` mode used during first-boot.

### CSE did NOT restore deferred units

The deferred-units restore block in `cse_main.sh` **never ran** on this node because the production CSE (from the RP) doesn't contain the branch's changes. The deferred units remain in `/opt/azure/containers/deferred-units/`:
- `kms.service` — still deferred
- `localdns.service` — still deferred
- `mig-partition.service` — still deferred (separate copy dropped by CSE at `/etc/systemd/system/`)
- `secure-tls-bootstrap.service` — still deferred (separate copy dropped by CSE at `/etc/systemd/system/`)

### Failed service

`snapshot-update.service` is in **failed** state — it was enabled by `preset-all` and then also enabled by CSE via `ensureSnapshotUpdate`, but the service itself fails.

## Next Steps

### Fix options (in order of recommendation)

**Option 1: Defer ALL unit files with `WantedBy=` in `/etc/systemd/system/` (most robust)**

Instead of just 4 services, move **all** custom unit files out of the systemd search path before removing machine-id. This prevents `preset-all` from touching any AKS units:

```bash
deferFirstBootPresetServices() {
    systemctl stop docker.socket || true
    systemctl mask docker.socket || true

    local defer_dir="/opt/azure/containers/deferred-units"
    mkdir -p "${defer_dir}"
    # Move ALL custom units that have [Install] sections to prevent preset-all
    for svc in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do
        [ -f "$svc" ] || continue
        if grep -q '^\[Install\]' "$svc"; then
            mv "$svc" "${defer_dir}/$(basename $svc)"
        fi
    done
}
```

**Option 2: Add a no-op preset file to block preset-all**

Create `/etc/systemd/system-preset/00-aks-no-preset.preset` during VHD build:
```bash
echo 'disable *' > /etc/systemd/system-preset/00-aks-no-preset.preset
```
This file takes priority (sorted first) and prevents `preset-all` from enabling anything.

**Option 3: Mask first-boot targets during VHD build**

```bash
systemctl mask systemd-firstboot.service first-boot-complete.target
```
This prevents the first-boot mechanism entirely. The machine-id will still be regenerated, but `preset-all` won't run.

**Option 4: Truncate instead of delete machine-id**

```bash
# Instead of: sudo rm -f /etc/machine-id
sudo truncate -s 0 /etc/machine-id
```
An empty (but existing) file may trigger machine-id regeneration without triggering full first-boot detection. Behavior depends on systemd version — needs testing on ACL.

### Verification

After applying the fix, rebuild the VHD and verify on a booted VM:
```bash
# No services should be newly enabled at boot time
sudo find /etc/systemd/system -type l -newermt "$(date -d '5 minutes ago' '+%Y-%m-%d %H:%M')" 2>&1
# kubelet should NOT be in multi-user.target.wants
ls -la /etc/systemd/system/multi-user.target.wants/kubelet.service 2>&1
# docker.socket should remain masked
systemctl is-enabled docker.socket
```

## Files Changed in This Branch

| File | Change |
|---|---|
| `vhdbuilder/packer/vhd-image-builder-acl.json` | Added `sudo rm -f /etc/machine-id` |
| `vhdbuilder/packer/vhd-image-builder-acl-arm64.json` | Added `sudo rm -f /etc/machine-id` |
| `vhdbuilder/packer/install-dependencies.sh` | Calls `deferFirstBootPresetServices` for ACL |
| `vhdbuilder/scripts/linux/acl/tool_installs_acl.sh` | Added `deferFirstBootPresetServices()` |
| `parts/linux/cloud-init/artifacts/cse_main.sh` | Added deferred-units restore block + snapshot-update.timer disable |
| `parts/linux/cloud-init/artifacts/cse_helpers.sh` | Error code renumbering (unrelated) |
| `parts/linux/cloud-init/artifacts/cse_config.sh` | Added `time` to artifact streaming commands (unrelated) |

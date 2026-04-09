# ACL E2E Test Failures — Machine-ID and First-Boot Preset Issues

## Background

**ACL (Azure Container Linux)** is an AKS node OS based on Flatcar Linux, using Azure Linux 3 RPMs. It uses Ignition for first-boot provisioning and systemd sysexts for runtime components.

Systemd's **first-boot detection** is critical: on first boot, systemd runs `manager_preset_all()` to enable/disable services according to preset files. It detects first boot by checking `/etc/machine-id` — the file must be **absent** or contain `"uninitialized"`. An empty file is treated as "already initialized" → no first boot → no presets applied.

---

## Four-Cluster Comparison (April 1, 2026)

Verified on fresh AKS clusters using four different VHD images:

| | **Flatcar** (systemd 258) | **AzureLinux V3** (systemd 255) | **AzL3 + machine-id removed** (systemd 255) | **ACL Current** (systemd 255) | **ACL + machine-id fix** (systemd 255) |
|---|---|---|---|---|---|
| OS | Flatcar 4628.0.0 | AzureLinux 3.0.20260304 | AzureLinux 3.0.20260304 | ACL 3.0.20260304 | ACL 3.0.20260330 |
| First boot detected | **Yes** | **No** | **Yes** (inferred) | **No** | **Yes** |
| kms/mig/localdns enabled | **disabled** | disabled | unknown (node dead) | disabled | **enabled** |
| Failed units | **0** | **0** | **node unrecoverable** | **0** | **5** |
| Kubelet status | Running | Running | **Dead** | Running | Running |
| Guest agent status | Running | Running | **Dead** | Running | Running |
| `disable *` preset present | Yes | Yes | Yes | Yes | Yes |
| `/etc/systemd/system-preset/` | exists | **does not exist** | **does not exist** | exists | exists |

**Key finding**: Flatcar detects first boot AND runs `manager_preset_all()`, yet services stay **disabled** because `disable *` is respected (systemd 258 uses FULL mode). ACL with machine-id fix also detects first boot, but services get **enabled** because `disable *` is ignored (systemd 255 uses ENABLE_ONLY mode). AzureLinux V3 and ACL Current don't detect first boot at all (empty `/etc/machine-id`), so the issue is dormant.

### AzureLinux V3 First-Boot Test (April 1, 2026)

**Experiment**: On a running AzL3 AKS node (systemd 255, no first-boot detected, all healthy), we removed `/etc/machine-id` and rebooted to force first-boot detection.

**Result**: The node became **completely unrecoverable**:
- Kubelet stopped posting status → node went `NotReady` within ~3 minutes
- Azure guest agent became unresponsive → `az vmss run-command invoke` returns `Conflict: execution in progress`
- Managed run-commands (`az vmss run-command create`) stuck in `Creating` state indefinitely
- `kubectl-node_shell` and `kubectl debug node` both time out — no pods can schedule
- VMSS restart did not recover the node
- Only `az vmss reimage` (full reimage) restored the node

**Conclusion**: AzureLinux V3 is **confirmed vulnerable** to the same systemd 255 `ENABLE_ONLY` first-boot preset bug as ACL. The impact is even more severe — the node becomes completely unmanageable (no SSH, no run-command, no kubelet). This is because AzL3 has more services with `[Install] WantedBy=` sections that get auto-enabled, and the cascading failures from conflicting services take down the guest agent and kubelet.

**Implication**: If the machine-id removal fix were applied to AzureLinux V3 VHDs (via `vhd-image-builder-mariner.json`), it would break all AzL3 nodes. The systemd 255 ENABLE_ONLY bug must be fixed at the OS level before any machine-id changes can be safely applied to any OS using systemd 255.

---

## Issue 1: Systemd Doesn't Detect First Boot on ACL

### Problem

The ACL VHD ships with an **empty** `/etc/machine-id` file (see "ACL Current" column above). No first boot → no presets applied.

### Why

During VHD build, `cleanup-vhd.sh` runs `rm -f /etc/machine-id && touch /etc/machine-id`, creating an **empty file**. Then `waagent -deprovision+user` runs, which on some OSes would clean this up — but not on ACL.

**walinuxagent OS detection**: waagent selects a deprovision handler based on `/etc/os-release`. ACL's `os-release` has `ID=azurelinux`, so waagent uses `MarinerOSUtil` (Azure Linux handler). This handler's `del_account()` method does **not** touch `/etc/machine-id` — it only removes user accounts, sudoers entries, and similar.

On Flatcar, `os-release` has `ID=flatcar`, so waagent uses `CoreOSDeprovisionHandler`. This handler explicitly calls:
```python
# From WALinuxAgent CoreOSDeprovisionHandler:
fileutil.rm_files("/etc/machine-id")
```

This is why Flatcar's VHD ships without `/etc/machine-id` (triggering first boot correctly), while ACL's VHD retains the empty file from `cleanup-vhd.sh`.

**Note**: Standard AzureLinux V3 (non-ACL) images also use `MarinerOSUtil` and the same `cleanup-vhd.sh`, so they also ship with an empty `/etc/machine-id`. First boot is NOT detected on those images either. This is currently harmless because cloud-init handles service configuration on those distros. However, if `/etc/machine-id` were removed from AzureLinux V3 images, they would face the **exact same Issue 3** since they use the same `systemd 255-26.azl3` binary with `ENABLE_ONLY` first-boot preset mode.

### Fix

Remove `/etc/machine-id` in the ACL packer config:
```
sudo rm -f /etc/machine-id
```
Added to `vhd-image-builder-acl.json` and `vhd-image-builder-acl-arm64.json`.

---

## Issue 2: Docker Auto-Starts After Machine-ID Fix

### Problem

Fixing Issue 1 causes Docker to start automatically, creating iptables rules incompatible with Cilium eBPF host routing.

### Root Cause

1. Machine-ID fix → first boot detected → `manager_preset_all()` runs
2. Azure Linux 3's `90-default.preset` contains `enable docker.socket`
3. Docker starts via socket activation → creates iptables rules
4. `ValidateIPTablesCompatibleWithCiliumEBPF` fails

### Fix

Add a higher-priority preset file to the ACL VHD:

**`/etc/systemd/system-preset/10-disable-docker.preset`**:
```
disable docker.socket
disable docker.service
```

**Important caveat**: This fix relies on `disable` rules being processed. See Issue 3 — on systemd 255, first-boot preset runs in `ENABLE_ONLY` mode which ignores `disable` rules. This fix only works for Docker because Docker is explicitly listed as `enable docker.socket` in `90-default.preset`, so it IS matched by the higher-priority `disable` rule. For services NOT listed in any `enable` rule (like kms, mig-partition), `disable` rules are simply never evaluated in `ENABLE_ONLY` mode.

---

## Issue 3: Services Auto-Enabled Due to systemd 255 `ENABLE_ONLY` First-Boot Preset Mode

### Problem

Services placed on the VHD during packer build (kms, mig-partition, localdns) get **auto-enabled** on ACL with the machine-id fix, but remain **disabled** on Flatcar.

### Root Cause

**systemd 255** (ACL) runs first-boot `manager_preset_all()` in **`ENABLE_ONLY` mode**, which ignores all `disable` rules — including the `disable *` catch-all. **systemd 258** (Flatcar) runs it in **`FULL` mode**, which correctly processes `disable *`.

From systemd v255 source (`manager.c`):
```c
static void manager_preset_all(Manager *m) {
        UnitFilePresetMode mode =
                ENABLE_FIRST_BOOT_FULL_PRESET ? UNIT_FILE_PRESET_FULL :
                UNIT_FILE_PRESET_ENABLE_ONLY;
        ...
}
```

The meson option `first-boot-full-preset` defaults to `false` in v255:
```
option('first-boot-full-preset', type: 'boolean', value: false,
       description : 'during first boot, do full preset-all
                      (default will be changed to true later)')
```

In `ENABLE_ONLY` mode, any service with `[Install] WantedBy=` that isn't matched by an explicit `enable` rule gets **enabled by default**. The `disable *` catch-all is completely ignored.

### Why Flatcar Works

Flatcar uses **systemd 258**, which processes `disable *` correctly during first-boot preset. Both Flatcar and ACL detect first boot, both have `disable *` in their presets, but only Flatcar's systemd version respects it.

### Why This Only Appears After the Machine-ID Fix

Before the fix, ACL had an empty `/etc/machine-id` → no first boot detected → `manager_preset_all()` never ran → services stayed disabled. After the fix, first boot IS detected → preset-all runs in `ENABLE_ONLY` mode → services with `WantedBy=` get auto-enabled.

### Proof

**On ACL with machine-id fix (systemd 255):**
```bash
$ systemctl is-enabled kms.service mig-partition.service localdns.service
enabled    # ← auto-enabled by first-boot preset
enabled
enabled

# Manual preset-all with explicit FULL mode correctly disables them:
$ systemctl preset-all --preset-mode=full --no-reload
$ systemctl is-enabled kms.service mig-partition.service localdns.service
disabled   # ← disable * now applied
disabled
disabled
```

**On Flatcar (systemd 258):**
```bash
$ journalctl -b | grep "Detected first boot"
Apr 01 16:02:23 ... systemd[1]: Detected first boot.

$ systemctl is-enabled kms.service mig-partition.service
disabled   # ← disable * correctly applied in FULL mode
disabled
```

### Affected Services

Installed to `/etc/systemd/system/` by `packer_source.sh::copyPackerFiles()` — all have `WantedBy=multi-user.target`:
- `kms.service` — legacy, no CSE enable handler
- `mig-partition.service` — CSE enables only when `MIG_NODE=true`
- `localdns.service` — CSE enables only when local DNS is configured

### Fix Options

1. **OS-level (root cause)**: Build ACL's systemd with `-Dfirst-boot-full-preset=true` so first-boot preset uses FULL mode and respects `disable *`. The Azure Linux RPM spec already has this flag, but the ACL systemd binary demonstrably does not have it compiled in.

2. **AgentBaker-level (workaround — remove [Install] section)**: Strip `[Install]` from services during VHD build. Without `WantedBy=`, `manager_preset_all()` won't touch them:
   ```bash
   sed -i '/^\[Install\]/,$d' /etc/systemd/system/kms.service
   sed -i '/^\[Install\]/,$d' /etc/systemd/system/mig-partition.service
   sed -i '/^\[Install\]/,$d' /etc/systemd/system/localdns.service
   ```

3. **AgentBaker-level (workaround — mask)**: Mask services during VHD build. CSE would unmask before enabling.

### Open Question

The Azure Linux RPM spec has `-Dfirst-boot-full-preset=true` since the initial v255 import (Feb 2024). Why the binary on ACL doesn't reflect this is unclear — it may be related to how ACL builds systemd (potentially from Flatcar's portage/Gentoo build system rather than directly from the RPM, despite the `azl3` version suffix).

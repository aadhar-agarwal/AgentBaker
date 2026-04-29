# ACL BYOI Investigation — acl-byoi-413 (April 13, 2026)

## Cluster Creation Command

```bash
az aks create \
  --resource-group aadagarwal --name acl-byoi-413 --location westcentralus \
  --generate-ssh-keys --node-vm-size Standard_D2ads_v6 \
  --enable-secure-boot --enable-vtpm \
  --aks-custom-headers \
    AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
    OSImageSubscriptionID=c4c3550e-a965-4993-a50c-628fd38cd3e1,\
    OSImageResourceGroup=aksvhdtestbuildrg,\
    OSImageGallery=PackerSigGalleryEastUS,\
    OSImageName=aclgen2TL,\
    OSImageVersion=1.1775872585.14420,\
    OSSKU=Flatcar,\
    OSDistro=CustomizedImageLinuxGuard \
  --nodepool-tags AzSecPackAutoConfigReady=true \
  --node-os-upgrade-channel None --node-count 1
```

**VHD image**: `1.1775872585.14420` (built from branch `aadagarwal/remove-machine-id`)

## Symptom

Kubelet crash-loops with `Exec format error`. The kubelet binary at `/opt/bin/kubelet` is **0 bytes**.

```
kubelet.service: Failed to execute /opt/bin/kubelet: Exec format error
kubelet.service: Main process exited, code=exited, status=203/EXEC
```

773+ restart cycles observed on the node.

## Root Cause: First-boot triggers ignition tar extraction, overwriting VHD files

### Why it worked before (without machine-id removal)

The previous VHD (without `rm -f /etc/machine-id`) had `/etc/machine-id` as an **empty file**
(from `cleanup-vhd.sh`: `rm; touch; chmod 644`). systemd treats an empty machine-id as
"uninitialized" — it regenerates the ID but does **NOT** trigger first-boot. Without first-boot,
`preset-all` does not run, and `ignition-file-extract.service` stays **disabled** (even though
its preset says `enabled`). The ignition tar is never extracted, so the VHD's correct ACL
`provision_installs_distro.sh` (with `mergeSysexts`) is preserved.

### What changed

The new VHD removes `/etc/machine-id` entirely (`sudo rm -f /etc/machine-id` in packer final step).
systemd sees a missing machine-id → **first-boot detected** → runs `preset-all` with
`-Dfirst-boot-full-preset=true`.

### Chain of Failure

1. **First-boot preset-all enables `ignition-file-extract.service`**: The service has
   `preset: enabled` (from the Ignition/Flatcar base config). With `disable *` in the custom
   preset at priority 99, services with no explicit entry in higher-priority presets get disabled.
   But `ignition-file-extract.service` has a built-in preset of `enabled` from Ignition's own
   preset file, so it gets enabled by `preset-all`.

2. **Ignition tar is extracted**: `ignition-file-extract.service` runs, extracting
   `/var/lib/ignition/ignition-files.tar`. This tar contains ALL the customData files generated
   by the AKS RP's AgentBaker service, including `provision_installs_distro.sh`.

3. **VHD file overwritten with wrong version**: The customData is generated based on
   `CustomizedImageLinuxGuard` → `IsAzlOSGuard = true` (in `baker.go`), so the tar contains
   the **Azure Linux OSGuard** version of `provision_installs_distro.sh` (with
   `installRPMPackageFromFile` / `rpm2cpio`), NOT the ACL version (with `mergeSysexts`).
   This overwrites the VHD's correct ACL copy.

4. **rpm2cpio on a sysext .raw file**: The OSGuard `installRPMPackageFromFile` runs `rpm2cpio`
   on `kubelet-v1.34.4-1-azlinux3-x86-64.raw`, which is a sysext raw image, not an RPM.
   `rpm2cpio` fails with `argument is not an RPM package`.

5. **0-byte kubelet via broken pipe**: The `rpm2cpio | cpio | install /dev/stdin` pipeline
   breaks — `install` reads empty stdin and creates a 0-byte `/opt/bin/kubelet`.

6. **Crash loop**: `kubelet.service` tries to execute 0-byte binary → `Exec format error` →
   restarts every 2s.

### Distro Classification Mismatch (underlying issue)

`OSDistro=CustomizedImageLinuxGuard` maps to `IsAzlOSGuard = true`, NOT `IsACL = true`:

```go
// baker.go lines 714-716
"IsAzlOSGuard": func() bool {
    return profile.Distro.IsAzureLinuxOSGuardDistro() ||
        profile.Distro == datamodel.CustomizedImageLinuxGuard
},
```

ACL distros are only `AKSACLGen2TL` and `AKSACLArm64Gen2TL` (in `sig_config.go`).
There is no BYOI distro type that maps to ACL.

### Evidence: old vs new cluster comparison

| | Old cluster (acl-byoi-49) | New cluster (acl-byoi-413) |
|---|---|---|
| `/etc/machine-id` | Empty file (pre-existing) | Missing → regenerated at boot |
| First boot? | **No** | **Yes** |
| preset-all ran? | No | Yes |
| `ignition-file-extract` | `disabled`, never ran | `enabled`, ran successfully |
| Tar extracted? | **No** — VHD files preserved | **Yes** — VHD files overwritten |
| `provision_installs_distro.sh` | ACL version (from VHD, `mergeSysexts`) | OSGuard version (from customData, `rpm2cpio`) |
| `/opt/bin/kubelet` | symlink → `/usr/bin/kubelet` (sysext) | 0-byte regular file |
| Result | ✅ Working | ❌ Crash loop |

### Key Log Evidence (from node)

```
+ installRPMPackageFromFile kubelet 1.34.4
+ rpm2cpio /opt/kubelet/downloads/kubelet-v1.34.4-1-azlinux3-x86-64.raw
+ cpio -i --to-stdout ./usr/bin/kubelet ./usr/local/bin/kubelet
+ install -m0755 /dev/stdin /opt/bin/kubelet
argument is not an RPM package
cpio: premature end of archive
```

## Other Findings

### First-boot preset changes are working correctly

- containerd: `enabled`, `active` ✅
- kubelet: `enabled` (CSE ran `systemctl enable kubelet` successfully), but failing due to 0-byte binary
- waagent: `disabled` (presets), but `active` ✅ (started via `Upholds=` from `multi-user.target.d/10-waagent-sysext.conf`)
- `/etc/machine-id`: populated with new ID at boot ✅
- Preset file at `/etc/systemd/system-preset/99-default-disable.preset`: present and correct ✅
- `systemd-sysext`: merged `aks-sysext`, `containerd-flatcar`, `docker-flatcar`, `oem-azure` ✅

### kubectl worked via binary fallback

kubectl had no sysext download, so `fallbackToKubeBinaryInstall` kicked in and successfully moved the cached `/opt/bin/kubectl-1.34.4` → `/opt/bin/kubectl` (60MB real binary).

## Fix Options

1. **Disable ignition-file-extract in the first-boot preset** — add `disable ignition-file-extract.service` and `disable ignition-bootcmds.service` to `99-default-disable.preset` ABOVE the `disable *` line. This prevents the tar from being extracted on first boot, preserving VHD files.

2. **Create a new `CustomizedImageACL` distro constant** — add mappings in `baker.go`, `types.go`, `nodecustomdata.yml` so ACL BYOI gets the correct `cse_install_acl.sh` in customData. Then the ignition tar extraction is harmless (it writes the correct version).

3. **Use production ACL flow** — `--os-sku AzureContainerLinux` (no BYOI) which uses the correct `AKSACLGen2TL` distro mapping. Available in `eastus2euap` with aks-preview extension v20.0.0b1+.

4. **Short-term workaround** — manually SSH to node and install kubelet from the cached binary:
   ```bash
   cp /opt/bin/kubelet-1.34.4 /opt/bin/kubelet && chmod +x /opt/bin/kubelet
   systemctl restart kubelet
   ```

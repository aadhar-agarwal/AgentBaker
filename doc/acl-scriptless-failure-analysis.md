# ACL Scriptless Provisioning — Failure Analysis

## TL;DR

ACL clusters fail to create when **scriptless** provisioning is on. CSE
(`aks-node-controller provision-wait`) waits for
`/opt/azure/containers/provision.complete`, which never appears, and
times out after ~16 minutes.

**Root cause:** the VHD release pipeline's prefetch-optimization step
boots the ACL VHD before sealing it. That single boot lets Ignition run
once, process empty CustomData, and delete
`/boot/flatcar/first_boot`. The published VHD is in a "post-firstboot"
state, so on the real node Ignition is skipped, the scriptless config
files are never written, and `aks-node-controller` exits without
provisioning.

**Fix:** skip prefetch for `OS_SKU=AzureContainerLinux` in the release
pipeline ([PR #8436](https://github.com/Azure/AgentBaker/pull/8436)).

Legacy CSE is unaffected — it carries all provisioning logic in the CSE
command and doesn't depend on Ignition.

## How scriptless works

Logic split:

- **Brains** — the `aks-node-controller` Go binary, baked into the VHD.
- **Data** — CustomData written by Ignition on first boot:
  `aks-node-controller-nbc-cmd.sh` and `nodecustomdata.yml` under
  `/opt/azure/containers/`.
- **CSE command** — just `"aks-node-controller provision-wait"`.

Boot:

1. ARM creates the VM with CustomData + the tiny CSE command.
2. **Ignition reads CustomData and writes the config files.**
3. `aks-node-controller.service` runs `provision`, which produces
   `provision.complete` when done.
4. CSE's `provision-wait` polls for that file and reports success to
   ARM.

If step 2 doesn't happen, the wrapper hits its `else exit 0` branch,
`provision.complete` is never written, and `provision-wait` hangs until
CSE timeout.

### Why Ignition needs the marker

On a Flatcar/ACL VHD, "first boot" is signalled by
`/boot/flatcar/first_boot`. GRUB sees it, adds
`flatcar.first_boot=detected` to the kernel cmdline, and Ignition runs
once — then deletes the marker so subsequent boots skip Ignition.

On the failing prod ACL VHD the marker is gone before the customer ever
boots:

```
$ cat /proc/cmdline
... flatcar.oem.id=azure ignition.platform.id=azure   # no flatcar.first_boot
$ ls /boot/flatcar/
grub  initramfs-a.img  vmlinuz-a                       # no first_boot file
$ journalctl -u ignition-fetch
-- No entries --
```

## Where the marker is consumed

Packer correctly creates the marker
([vhd-image-builder-acl.json](../vhdbuilder/packer/vhd-image-builder-acl.json)):

```bash
sudo touch /boot/flatcar/first_boot
```

Then the release pipeline runs an Azure VM Image Builder step
([optimize.json](../vhdbuilder/prefetch/templates/optimize.json)) with
`optimize.vmBoot.state = "Enabled"`. AIB **boots the VM** to trace
hot disk blocks and reorder the layout — and on a Flatcar disk that
means GRUB → Ignition → marker deleted. The post-firstboot disk is then
published to the AKS gallery.

E2E and earlier BYOI builds were fine because they used the
pre-prefetch Packer SIG image directly.

## The fix

[PR #8436](https://github.com/Azure/AgentBaker/pull/8436) adds an
`OS_SKU` short-circuit to the `Determine Prefetch Optimization
compatibility` step in
[.builder-release-template.yaml](../.pipelines/templates/.builder-release-template.yaml):

```yaml
if [ "${OS_SKU}" = "AzureContainerLinux" ]; then
  echo "##vso[task.setvariable variable=PREFETCH_COMPATIBLE]False"
  exit 0
fi
```

Trade-off: ACL nodes lose AIB's boot-time IO optimization (a few
seconds on first boot, no steady-state impact). In exchange, ACL nodes
provision at all.

### Recommended follow-ups

1. **Cover `OS_SKU=Flatcar` in the same gate** — same Packer flow, same
   marker, same Ignition dependency. PR #8436 doesn't.
2. **Add an image-version gate to `ShouldUseScriptlessMode`** —
   currently the `EnableSelfContainedVHD` + `CustomizedImage` path in
   [scriptless_utils.go](../resourceprovider/sharedlib/agentbaker/scriptless_utils.go)
   enables scriptless on any image. The newer `ShouldUseScriptlessCSECmdMode`
   has a version check (`>= 202602.13.0`); mirroring it would prevent
   a repeat.
3. **Better long-term: restore the marker after capture.** Either
   (a) re-`touch /boot/flatcar/first_boot` on the post-prefetch VHD
   before publishing, or (b) ship a Flatcar systemd unit that recreates
   the marker on shutdown. Both protect against any future "something
   booted my disk before sealing" regression — including the prod-SIG
   republishing pipeline.

## Repro and debugging

Failing scriptless cluster:

```bash
./aksdev cluster create test-acl-repro \
  --os-sku AzureContainerLinux \
  --azureconfig ./azureconfig.yaml \
  --subscription-features AzureContainerLinuxPreview \
  --vm-size Standard_D2ads_v5 --wait
```

Same cluster on legacy CSE (succeeds — confirms Ignition isn't the
issue for the legacy flow):

```bash
./aksdev cluster create test-acl-legacy \
  --os-sku AzureContainerLinux \
  --azureconfig ./azureconfig.yaml \
  --subscription-features AzureContainerLinuxPreview \
  --http-headers AKSHTTPCustomFeatures=Microsoft.ContainerService/DisableSelfContainedVHD \
  --vm-size Standard_D2ads_v5 --wait
```

> `DisableSelfContainedVHD` must go via `--http-headers`, not
> `--subscription-features` — the RP reads it from
> `AKSHTTPCustomFeatures`.

For SSH access to inspect a failing node:

```bash
aksdev cluster create test-acl-debug \
  --os-sku AzureContainerLinux \
  --azureconfig "$AZURECONFIG" --location "$LOC" \
  --subscription-features AzureContainerLinuxPreview \
  --vm-size Standard_D2pds_v6 --network-plugin kubenet \
  --enable-node-public-ip --ssh-key ~/.ssh/id_rsa_build.pub \
  --managedclustersubscription 8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8
```

On the node:

```bash
grep -o flatcar.first_boot=detected /proc/cmdline || echo "marker missing"
ls /boot/flatcar/first_boot 2>/dev/null || echo "marker file missing"
journalctl -u ignition-fetch --no-pager | head
```

If the marker is missing, audit anything that boots the disk between
`sudo touch /boot/flatcar/first_boot` in Packer and image capture.

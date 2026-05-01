# ACL + ImageCustomizer + COSI: feasibility

## Can ACL use ImageCustomizer?

**Yes — but in a limited way.** IC was built for Azure Linux (Mariner-style); ACL is Flatcar-style (read-only verity-protected `/usr`, sysext extensions, Ignition first-boot). Most IC features still apply, a few do not.

**ACL can use IC for:**
- Copying files into the image (`os.additionalFiles`, `additionalDirs`)
- Enabling/disabling services (`os.services`)
- Configuring kernel modules and users
- Reshaping partitions and converting image formats (vhd, raw, qcow2, split-partitions)
- Chroot scripts that touch writable paths (`/etc`, `/opt`, `/var`)

**ACL cannot use IC for:**
- Installing/removing packages (`os.packages.*`) — IC uses `tdnf`; ACL has no package manager. Use sysexts instead.
- Writing anything under `/usr` — read-only and verity-protected; boot will fail.
- SELinux config (`os.selinux.mode`) — requires `selinux-policy` rpm that ACL doesn't ship.
- Resetting the bootloader (`os.resetBootLoaderType: hard-reset`) — breaks Flatcar's `USR-A`/`USR-B` update mechanism.
- IC's verity feature — only supports verity on `/`; ACL's verity is on `/usr`.

In short: IC works on ACL as a **file-copy and format-conversion tool**, not a full distro builder. That's enough for AgentBaker's current ACL build, which is essentially file copies plus shell scripts.

**One unknown**: it has not been tested whether IC's mount layer correctly handles ACL's Flatcar GPT layout and squashfs `/usr`. A 30-minute no-op smoke test resolves this:

```bash
imagecustomizer \
  --image-file <existing-acl.vhd> \
  --config-file noop.yml \
  --output-image-format raw \
  --output-image-file out.raw
```

---

## Can IC produce COSI?

**Not directly.** IC has no `cosi` output format. The closest is `--output-split-partitions-format raw-zst`, which writes each partition as a zstd-compressed file plus a metadata JSON.

Three paths:

| Option | Effort | Risk |
|---|---|---|
| **A.** Post-process IC's split-partition output into COSI ourselves | Medium | Depends on COSI spec |
| **B.** Ask Azure Linux team to add native COSI output to IC | Low for us, external timeline | Low |
| **C.** Use IC for customization + a separate tool for COSI conversion | Medium-High | More moving parts |

Option A is fastest if the COSI spec is close to "split partitions + manifest".

---

## What would change in AgentBaker

1. New IC config: `vhdbuilder/packer/imagecustomizer/acl/acl.yml` — modeled on `azlosguard.yml`, but strip `os.packages`, `os.selinux`, `resetBootLoaderType`, verity.
2. New pipeline job in `.pipelines/.vsts-vhd-builder-release.yaml` (set `BUILDER=imagecustomizer`).
3. Reuse OSGuard build script; new publish logic for COSI artifacts.
4. New `make` target in `packer.mk` (e.g. `build-acl-cosi`).
5. Possibly a new distro constant in `pkg/agent/datamodel/types.go`.

---

## Open questions for the ACL team

1. What is the exact **COSI format** — file layout, manifest, signing?
2. Does the **ACL base image ship via ORAS** (like OSGuard) or only via SIG? IC needs a local file.
3. Replace the current ACL Packer build with IC, or add COSI as a separate step?

---

## Background (for reviewers)

- **ACL** (Azure Container Linux) — Flatcar-derived node OS for AKS. Read-only verity-protected `/usr`, sysext for extensions, Ignition for first-boot config.
- **ImageCustomizer (IC)** — Microsoft tool that mounts a disk image, edits it via chroot, writes a new image. Currently used in AgentBaker to build the **OSGuard** Azure Linux image.
- **COSI** — "Composite OS Image", a packaged image format. Spec not yet public; confirm with the ACL team.

## References

| File | Purpose |
|---|---|
| [vhdbuilder/packer/imagecustomizer/azlosguard/azlosguard.yml](vhdbuilder/packer/imagecustomizer/azlosguard/azlosguard.yml) | Existing OSGuard IC config — template for ACL |
| [vhdbuilder/packer/imagecustomizer/scripts/build-imagecustomizer-image.sh](vhdbuilder/packer/imagecustomizer/scripts/build-imagecustomizer-image.sh) | IC build invocation |
| [vhdbuilder/packer/vhd-image-builder-acl.json](vhdbuilder/packer/vhd-image-builder-acl.json) | Current ACL Packer build |
| [vhdbuilder/packer/acl-customdata.yaml](vhdbuilder/packer/acl-customdata.yaml) | ACL Ignition (Butane) config |
| [.pipelines/.vsts-vhd-builder-release.yaml](.pipelines/.vsts-vhd-builder-release.yaml) | Where the new job would go |

External: [IC docs](https://github.com/microsoft/azurelinux/tree/3.0/toolkit/tools/imagecustomizer/docs) · [partition metadata JSON](https://github.com/microsoft/azurelinux/blob/3.0/toolkit/tools/imagecustomizer/docs/partitionmetadatajson.md)

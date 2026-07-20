# Azure Container Linux node bootstrap

## Mental model

An Azure Container Linux (ACL) node image contains the operating system and
common AKS software, but it does not know which cluster it should join.
Bootstrap supplies the cluster-specific configuration:

```text
Prebuilt ACL image + cluster-specific bootstrap data = working AKS node
```

The bootstrap data includes the API server, credentials, networking settings,
kubelet configuration, labels, taints, and optional GPU settings.

## End-to-end flow

```text
AgentBaker configuration
  -> standard path: shared files -> Butane -> Ignition
  -> scriptless path: controller inputs -> minimal Ignition
  -> Azure VM custom data
  -> aks-node-controller
  -> kubelet registers the node
```

AgentBaker supports both paths. Sections 2 through 6 first explain the
standard path because it shows the complete Butane-to-Ignition process. The
current production default is the smaller scriptless path, described
[below](#standard-versus-scriptless-paths).

### 1. AgentBaker receives the node configuration

AKS constructs a
[`NodeBootstrappingConfiguration`](../pkg/agent/datamodel/types.go#L1734-L1812)
for the new VM. The provisioning layer selects an ACL image and sets
`OSSKU=AzureContainerLinux` or an
[ACL distro](../pkg/agent/datamodel/types.go#L200-L203).

AgentBaker then [detects ACL](../pkg/agent/datamodel/types.go#L1830-L1832) and
selects the ACL bootstrap path.

### 2. Standard path: AgentBaker renders the shared AKS node configuration

AgentBaker renders [`nodecustomdata.yml`](../parts/linux/cloud-init/nodecustomdata.yml).
This shared template describes the files and boot commands required by an AKS
Linux node.

For ACL, AgentBaker converts those files and commands into a tar archive. The
archive contains items such as configuration files, certificates, scripts,
and `/etc/ignition-bootcmds.sh`. AgentBaker compresses the archive and embeds
it in the first-boot configuration as:

```text
/var/lib/ignition/ignition-files.tar
```

The conversion is implemented by
[`cloudInitToButane`](../pkg/agent/baker.go#L332-L369).

### 3. Standard path: AgentBaker adds the ACL Butane template

AgentBaker loads [`acl.yml`](../parts/linux/cloud-init/acl.yml), which defines
two early-boot systemd services:

| Service | Purpose |
| --- | --- |
| `ignition-file-extract.service` | Extracts `ignition-files.tar` into the root filesystem and reloads systemd. |
| `ignition-bootcmds.service` | Runs `/etc/ignition-bootcmds.sh` after the files have been extracted. |

The template also creates explicit links under `sysinit.target.wants`. ACL
images ship with an `/etc/machine-id` that exists but is empty. Systemd treats
a boot as the first boot only when that file is absent, so the units' normal
first-boot enablement would not run. The explicit links wire both services
into `sysinit.target.wants` so they start regardless.

### 4. Standard path: Butane is converted into Ignition

**Butane** is the human-readable YAML source format. It describes files,
links, and systemd units, but ACL does not execute Butane directly.

AgentBaker validates and converts the completed Butane configuration into
Ignition 3.4 JSON using
[`ToIgn3_4`](../pkg/agent/baker.go#L395-L405).

The conversion happens in these steps:

1. AgentBaker reads `acl.yml` and parses the YAML into a Butane
   `flatcar1_1.Config` object.
2. AgentBaker adds the generated `ignition-files.tar` entry to
   `storage.files`. At this point the object contains both the static ACL
   systemd units and the dynamic cluster-specific payload.
3. `ToIgn3_4` validates the Butane fields and translates them into the
   equivalent Ignition 3.4 structures.
4. Butane expands readable values into the lower-level representation
   Ignition expects. For example, inline file contents become `data:` URLs,
   permissions become numeric modes, and systemd units become JSON objects.
5. AgentBaker checks the translation report. Any conversion error or warning
   stops generation so AKS does not create a VM with questionable bootstrap
   data.
6. AgentBaker serializes the translated Ignition object into JSON with
   `json.Marshal`.

For example, a readable Butane file:

```yaml
storage:
  files:
    - path: /etc/example
      mode: 0600
      contents:
        inline: hello
```

becomes an Ignition structure similar to:

```json
{
  "storage": {
    "files": [
      {
        "path": "/etc/example",
        "mode": 384,
        "contents": {
          "source": "data:,hello"
        }
      }
    ]
  }
}
```

This conversion runs inside AgentBaker before VM creation. Butane itself is
not sent to or installed on the node; only the resulting Ignition JSON is
placed in Azure VM custom data.

```text
Butane YAML = human-readable source
Ignition JSON = machine-readable first-boot configuration
```

This is closer to compiling source code than simply renaming YAML fields as
JSON.

### 5. Ignition becomes Azure VM custom data

Azure VM **custom data** is an opaque first-boot payload included in the VM
creation request. Azure does not execute it; the guest operating system
decides how to process it.

- Ubuntu and Azure Linux normally give custom data to cloud-init.
- ACL gives custom data to Ignition.

AgentBaker serializes the Ignition document and base64-encodes it for the
Azure VM custom-data field. A simplified Ignition document looks like:

```json
{
  "ignition": {
    "version": "3.4.0"
  },
  "storage": {
    "files": [
      {
        "path": "/var/lib/ignition/ignition-files.tar",
        "mode": 384,
        "overwrite": true,
        "contents": {
          "compression": "gzip",
          "source": "data:;base64,H4sI..."
        }
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "ignition-file-extract.service",
        "enabled": true,
        "contents": "[Unit]\n...\n[Service]\nExecStart=tar -xvf ..."
      },
      {
        "name": "ignition-bootcmds.service",
        "enabled": true,
        "contents": "[Unit]\n...\n[Service]\nExecStart=-/etc/ignition-bootcmds.sh"
      }
    ]
  }
}
```

The actual document is larger because the `data:;base64,...` value contains
the compressed AKS file payload. The JSON `mode` value `384` is decimal for
the file permission `0600`.

### 6. ACL applies Ignition during early boot

When the VM starts, Ignition runs before normal system services. It creates
the tar file, systemd units, and links described by the JSON.

Systemd then:

1. Runs `ignition-file-extract.service` to extract the AKS files.
2. Runs `ignition-bootcmds.service` to execute the early boot commands.
3. Starts `aks-node-controller` or the configured CSE phase.

### 7. The node finishes configuring and joins AKS

`aks-node-controller` configures the live node, including:

- containerd and its registry/runtime settings;
- networking;
- cluster credentials and certificates;
- kubelet settings, labels, and taints;
- system extensions required by the node, including NVIDIA components when
  applicable.

Kubelet then starts, authenticates with the AKS API server, and registers the
VM as a Kubernetes `Node`. After networking and required services are healthy,
the node becomes `Ready` and can run pods.

## Standard versus scriptless paths

The standard and scriptless paths both send Ignition to ACL, but they generate
different Ignition documents:

| Area | Standard path | Scriptless path |
| --- | --- | --- |
| Generation | Loads `acl.yml` and calls `ToIgn3_4` | Uses the built-in [`flatcarTemplate`](../pkg/agent/baker.go#L71-L79) |
| Payload | Compressed `ignition-files.tar` plus early-boot services | A few controller input files written directly to their target paths |
| Butane | Yes | No |
| Bootstrap services | Defined by `acl.yml` custom data | `aks-node-controller.service` and scripts are already baked into the VHD |

The scriptless path:

1. Sets `DisableCustomData=true` so the node controller uses VHD-baked
   provisioning scripts.
2. Generates the node-controller command and node configuration.
3. Compresses and base64-encodes each input.
4. Adds those inputs as file entries in a minimal Ignition document.
5. Base64-encodes that Ignition JSON as Azure VM custom data.

This logic is in
[`getScriptlessNBCCustomData`](../pkg/agent/baker.go#L113-L163). It does not
use `acl.yml`, `ignition-files.tar`, `ignition-file-extract.service`, or
`ignition-bootcmds.service`.

The important common behavior is:

```text
Standard ACL bootstrap:   Butane-generated Ignition
Scriptless ACL bootstrap: directly generated Ignition
```

## What is ACL-specific?

| Area | Ubuntu/Azure Linux | ACL |
| --- | --- | --- |
| First-boot format | cloud-init/boothook | Ignition; Butane-generated on the standard path |
| Root filesystem | package-managed | immutable `/usr` |
| Extra components | packages/files | systemd sysexts |
| Security | image-dependent | Gen2 Trusted Launch, Secure Boot, and vTPM |

ACL-specific installation logic lives in
[`cse_install_acl.sh`](../parts/linux/cloud-init/artifacts/acl/cse_install_acl.sh).

## Why the bootstrap format matters

The image and custom-data formats must match:

```text
ACL image + Ignition       = expected
ACL image + cloud-init     = node is not correctly configured
```

Selecting an ACL image is therefore not sufficient by itself. The
provisioning path must identify ACL so AgentBaker generates Ignition rather
than the cloud-init payload used by other Linux images.

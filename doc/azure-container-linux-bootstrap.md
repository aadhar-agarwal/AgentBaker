# Azure Container Linux node bootstrap

## Bootstrap flow

1. The provisioning layer selects an ACL node image and sets
   `OSSKU=AzureContainerLinux` or an [ACL distro](../pkg/agent/datamodel/types.go#L200-L203).
2. AgentBaker [detects ACL](../pkg/agent/datamodel/types.go#L1830-L1832).
3. AgentBaker renders the shared AKS node files from
   [`nodecustomdata.yml`](../parts/linux/cloud-init/nodecustomdata.yml).
4. For ACL, it selects [`acl.yml`](../parts/linux/cloud-init/acl.yml) and
   [converts the Butane configuration to Ignition](../pkg/agent/baker.go#L370-L405).
5. ACL reads the Ignition document during early boot and writes the required
   files and systemd units.
6. `aks-node-controller` or CSE configures containerd, networking, credentials,
   and kubelet; kubelet then registers the node with AKS.

Both the standard and scriptless paths explicitly route ACL through the
Flatcar-style Ignition flow
([standard](../pkg/agent/baker.go#L95-L110),
[scriptless](../pkg/agent/baker.go#L113-L163)).

## Butane and Ignition

- **Butane:** Human-readable YAML that AgentBaker renders and converts into Ignition.
- **Ignition:** Machine-readable JSON that ACL consumes during early boot to create files and configure systemd.

## What is ACL-specific?

| Area | Ubuntu/Azure Linux | ACL |
| --- | --- | --- |
| First-boot format | cloud-init/boothook | Butane-generated Ignition |
| Root filesystem | package-managed | immutable `/usr` |
| Extra components | packages/files | systemd sysexts |
| Security | image-dependent | Gen2 Trusted Launch, Secure Boot, and vTPM |

ACL-specific installation logic lives in
[`cse_install_acl.sh`](../parts/linux/cloud-init/artifacts/acl/cse_install_acl.sh).

# Azure Container Linux support in AKS Node Auto-Provisioning

This page describes the cross-component requirements for supporting Azure
Container Linux (ACL) in AKS Node Auto-Provisioning (NAP). For the node-side
flow, see [Azure Container Linux node bootstrap](azure-container-linux-bootstrap.md).

## End-to-end flow

```text
Pending pod
  -> Karpenter selects a NodePool and AKSNodeClass
  -> Karpenter creates a NodeClaim
  -> Azure provider creates an AKS Machine request
  -> AKS uses AgentBaker to generate ACL Ignition
  -> the VM boots and registers as a Kubernetes node
```

Managed NAP does not require Karpenter to generate Butane or Ignition.
Karpenter describes the requested node; AKS and AgentBaker generate its
ACL-specific bootstrap payload.

## Current state

Status checked against public sources on July 22, 2026.

| Component | State |
| --- | --- |
| AgentBaker | Recognizes `OSSKU=AzureContainerLinux` or an ACL image distro and generates ACL-compatible Ignition on both the standard and scriptless paths. |
| AKS documentation | Is inconsistent. The [ACL overview](https://learn.microsoft.com/azure/aks/azure-container-linux-overview) says ACL supports NAP, while the [AKSNodeClass supported-family list](https://learn.microsoft.com/azure/aks/node-auto-provisioning-aksnodeclass#supported-image-families) only documents Ubuntu and Azure Linux. |
| Public Azure Karpenter provider | Release [`v1.14.0`](https://github.com/Azure/karpenter-provider-azure/releases/tag/v1.14.0) and [main at `01522c8`](https://github.com/Azure/karpenter-provider-azure/tree/01522c8b6c724ec89d31b50aabeaca448ef4c44f) contain no `AzureContainerLinux` API value, image family, OSSKU mapping, or ACL GPU entry. |
| Machine API SDK | Added the `OSSKUAzureContainerLinux` enum in [`armcontainerservice` 9.2.0](https://github.com/Azure/azure-sdk-for-go/blob/870565769baf65b57bd8ac200cfe36d93dc06678/sdk/resourcemanager/containerservice/armcontainerservice/CHANGELOG.md#920-2026-05-09), but an SDK enum does not establish service-side support. |

The AKSNodeClass documentation briefly added `AzureContainerLinux` on
[July 15, 2026](https://github.com/MicrosoftDocs/azure-aks-docs/commit/0eb120b6a65ca7469fbc607506674e070b9b7b74)
and deliberately removed the supported-family entry and standalone example on
[July 17, 2026](https://github.com/MicrosoftDocs/azure-aks-docs/commit/a088fa1dc0a73a514c9fb613882df83dc34a85f7).
The same live page still has a
[stale comprehensive YAML example](https://learn.microsoft.com/azure/aks/node-auto-provisioning-aksnodeclass#comprehensive-aksnodeclass-configuration-example)
that lists `AzureContainerLinux` as valid.

The public evidence therefore proves AgentBaker bootstrap readiness and SDK
vocabulary, but not that customers can select ACL through managed NAP. Managed
NAP can deploy a controller build that differs from the public provider
release, so the NAP owners must confirm the deployed CRD, provider version,
image rollout, and supported regions before ACL is treated as available.

## Required provider and Machine API support

| Area | Requirement |
| --- | --- |
| API | Add `AzureContainerLinux` to `AKSNodeClass.imageFamily`, constants, labels, served API versions, and generated CRDs. |
| Images | Add a dedicated ACL image family using `aclgen2TL`, `aclgen2arm64TL`, and confirmed FIPS variants. ACL must not alias Azure Linux. |
| Machine request | Send `OSSKU=AzureContainerLinux`, a supported ACL `NodeImageVersion`, GPU settings when requested, and the required security configuration. |
| VM compatibility | Require Kubernetes 1.34+, Generation 2, and Trusted Launch-capable SKUs. ACL Arm64 must use compatible Cobalt v6 SKUs. |
| Features | Reject unsupported combinations such as Artifact Streaming. |
| Provisioning modes | Initially allow ACL only in managed AKS Machine API modes; fail closed in direct-VM modes. |

Artifact Streaming is the exposed incompatible setting that needs an
ACL-specific guard. The provider already excludes Confidential VM SKUs, and
Pod Sandboxing is not currently exposed by `AKSNodeClass`.

Relevant provider code:

- [`AKSNodeClass` API](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/apis/v1beta1/aksnodeclass.go)
- [image-family resolver](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/providers/imagefamily/resolver.go)
- [AKS Machine request construction](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/providers/instance/aksmachineinstancehelpers.go)
- [instance-type filtering](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/providers/instancetype/instancetypes.go)

## Contracts to confirm

Before considering ACL supported, the NAP and Machine API owners must confirm:

1. **Image version format:** the provider's generic conversion would produce
   `AKSAzureLinux-aclgen2TL-<version>`, while AKS documentation shows
   `AKSAzureContainerLinux-<version>`.
2. **Trusted Launch ownership:** Machine requests currently leave Secure Boot
   and vTPM unset. Machine API must default both for ACL or the provider must
   set them explicitly.
3. **Image availability:** ACL image definitions must be returned by the Node
   Image Versions API in every supported region and cloud.
4. **Feature matrix:** FIPS and optional `AKSNodeClass` settings must be
   validated against ACL rather than inherited from Azure Linux.

## GPU support

Updating
[`supported-gpus.yaml`](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/utils/supported-gpus.yaml)
is necessary but insufficient. The provider must also add ACL handling to
`isInstanceTypeSupportedByImageFamily`; otherwise every ACL GPU SKU is
filtered out.

Start validation with AgentBaker-tested AMD64 NVIDIA SKUs:

- `Standard_NC4as_T4_v3`
- `Standard_NC24ads_A100_v4`
- `Standard_NV6ads_A10_v5`
- `Standard_NC16ads_A10_v4`

Keep RTX PRO 6000 GRID v20 excluded until an ACL-compatible driver exists.
ACL GPU support is AMD64-only.

## Validation

Validate a non-GPU node before GPU:

1. Confirm the selected image and node OS are ACL.
2. Confirm Generation 2, Trusted Launch, Secure Boot, and vTPM.
3. Confirm containerd, networking, kubelet, node readiness, and expected
   labels and taints.
4. Confirm replacement, disruption, consolidation, and image drift behavior.

Then validate GPU:

1. Confirm the NVIDIA driver, kernel modules, and container toolkit.
2. Confirm the device plugin advertises `nvidia.com/gpu`.
3. Run a real GPU workload.
4. Repeat replacement and consolidation with a GPU node.

## Self-hosted Karpenter

Managed NAP support does not automatically provide self-hosted support.
The provider's self-hosted
[`AKSScriptless` mode](https://github.com/Azure/karpenter-provider-azure/blob/38aebe17358bd306c88aef2a319c91948dc554cf/pkg/providers/launchtemplate/launchtemplate.go#L214-L238)
generates cloud-init/CSE custom data and contains no Ignition support. This is
different from AgentBaker's scriptless NBC path, which already emits ACL
Ignition. Self-hosted support requires an AgentBaker bootstrapping-client ACL
contract or another ACL Ignition implementation, plus direct-VM Trusted
Launch, Secure Boot, vTPM, and SKU filtering.

The provider's
[support guidance](https://github.com/Azure/karpenter-provider-azure#node-auto-provisioning-nap-vs-self-hosted-karpenter)
recommends managed NAP for most users. Microsoft support channels cover
managed NAP, while self-hosted Karpenter is supported through GitHub issues on
a best-effort basis.

Until those pieces exist, `imageFamily: AzureContainerLinux` should be
rejected outside managed Machine API modes.

## Suggested delivery order

1. Managed Machine API, AMD64, non-GPU ACL with Generation 2 and Trusted
   Launch enforcement.
2. Arm64/Cobalt v6 and confirmed FIPS behavior.
3. Managed ACL GPU support for validated SKUs.
4. Self-hosted/direct-VM support.

## AgentBaker references

- [ACL detection](../pkg/agent/datamodel/types.go#L1830-L1832)
- [ACL image definitions](../pkg/agent/datamodel/sig_config.go#L799-L827)
- [ACL bootstrap routing](../pkg/agent/baker.go#L95-L163)
- [Butane-to-Ignition conversion](../pkg/agent/baker.go#L370-L405)
- [ACL installation logic](../parts/linux/cloud-init/artifacts/acl/cse_install_acl.sh)
- [ACL GPU scenarios](../e2e/scenario_test.go#L284-L355)

## AKS NAP documentation

The AKS documentation table of contents has the following NAP-specific pages:

- [NAP overview](https://learn.microsoft.com/azure/aks/node-auto-provisioning):
  architecture, prerequisites, limitations, and upgrade behavior.
- [Enable or disable NAP](https://learn.microsoft.com/azure/aks/use-node-auto-provisioning):
  cluster configuration, monitoring, and migration from self-hosted
  Karpenter.
- [Migrate from Cluster Autoscaler to NAP](https://learn.microsoft.com/azure/aks/migrate-from-autoscaler-to-node-auto-provisioning):
  direct and side-by-side migration paths.
- [Use NAP in a custom virtual network](https://learn.microsoft.com/azure/aks/node-auto-provisioning-custom-vnet):
  subnet delegation, managed identity, and load-balancer requirements.
- [Update NAP node images](https://learn.microsoft.com/azure/aks/node-auto-provisioning-upgrade-image):
  image drift and maintenance windows.
- [Configure NAP networking](https://learn.microsoft.com/azure/aks/node-auto-provisioning-networking):
  supported CNI modes, subnet RBAC, and CIDR planning.
- [Configure disruption policies](https://learn.microsoft.com/azure/aks/node-auto-provisioning-disruption):
  expiration, consolidation, drift, and disruption budgets.
- [Configure NodePool resources](https://learn.microsoft.com/azure/aks/node-auto-provisioning-node-pools):
  VM constraints, Spot capacity, limits, and weights.
- [Configure AKSNodeClass resources](https://learn.microsoft.com/azure/aks/node-auto-provisioning-aksnodeclass):
  image families, disks, kubelet settings, GPU mode, and LocalDNS.

Related product guidance:

- [Azure Container Linux for AKS overview](https://learn.microsoft.com/azure/aks/azure-container-linux-overview)
- [AKS-managed GPU nodes](https://learn.microsoft.com/azure/aks/aks-managed-gpu-nodes)
- [NVIDIA GPU Operator on AKS](https://learn.microsoft.com/azure/aks/nvidia-gpu-operator)
- [AKS control-plane metrics](https://learn.microsoft.com/azure/aks/control-plane-metrics-monitor)
- [LocalDNS on AKS](https://learn.microsoft.com/azure/aks/localdns-custom)
- [Azure Karpenter provider README](https://github.com/Azure/karpenter-provider-azure)

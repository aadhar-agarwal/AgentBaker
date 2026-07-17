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

| Component | State |
| --- | --- |
| AgentBaker | Detects `OSSKU=AzureContainerLinux`, selects ACL images, and generates Butane-based Ignition. |
| AKS documentation | Documents `spec.imageFamily: AzureContainerLinux` for managed NAP. |
| Public Azure Karpenter provider | At commit [`6581367`](https://github.com/Azure/karpenter-provider-azure/tree/6581367bf9988484da003d0e3dfcb67032ac7f53), contains no `AzureContainerLinux` API or image-family mapping. |
| Machine API SDK | Defines `OSSKUAzureContainerLinux`; the service-side image and security behavior must still be confirmed. |

The managed NAP deployment might therefore be ahead of, or patched beyond,
the public provider repository.

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

- [`AKSNodeClass` API](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/apis/v1beta1/aksnodeclass.go)
- [image-family resolver](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/providers/imagefamily/resolver.go)
- [AKS Machine request construction](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/providers/instance/aksmachineinstancehelpers.go)
- [instance-type filtering](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/providers/instancetype/instancetypes.go)

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
[`supported-gpus.yaml`](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/utils/supported-gpus.yaml)
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
[`AKSScriptless` mode](https://github.com/Azure/karpenter-provider-azure/blob/6581367bf9988484da003d0e3dfcb67032ac7f53/pkg/providers/launchtemplate/launchtemplate.go#L214-L238)
generates cloud-init/CSE custom data and contains no Ignition support. This is
different from AgentBaker's scriptless NBC path, which already emits ACL
Ignition. Self-hosted support requires an AgentBaker bootstrapping-client ACL
contract or another ACL Ignition implementation, plus direct-VM Trusted
Launch, Secure Boot, vTPM, and SKU filtering.

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

## Product references

- [Configure AKSNodeClass resources](https://learn.microsoft.com/azure/aks/node-auto-provisioning-aksnodeclass)
- [Azure Container Linux for AKS overview](https://learn.microsoft.com/azure/aks/azure-container-linux-overview)

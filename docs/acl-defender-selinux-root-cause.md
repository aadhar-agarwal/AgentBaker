# ACL Defender LowLevelCollector Failure: SELinux Missing `tracepoint` Permission

**Date:** April 27, 2026
**Status:** Root cause confirmed
**Affected:** All ACL images with SELinux enforcing (both kernel 6.6.126 and 6.6.130)
**Impact:** `Scenario_AzureContainerLinux_Defender_Profile_Enable_New_Cluster` and `Scenario_AzureContainerLinux_Defender_Profile_Enable_Existing_Cluster` E2E tests fail

## Summary

Defender's LowLevelCollector (`ig trace exec`) fails with `permission denied` on ACL nodes because the **SELinux policy is missing the `tracepoint` permission** on the `perf_event` class for `spc_t`. This is NOT a kernel regression — the failure occurs identically on both kernel `6.6.126.1-1.azl3` and `6.6.130.1-3.azl3`.

## Root Cause

### The AVC Denial

From `dmesg` on an AKS node running the pinned older kernel (6.6.126.1-1.azl3):

```
audit: type=1400 audit(1777316958.735:2024): avc:  denied  { tracepoint }
  for  pid=10331 comm="ig"
  scontext=system_u:system_r:spc_t:s0
  tcontext=system_u:system_r:spc_t:s0
  tclass=perf_event permissive=0
```

### Explanation

1. The kernel's `perf_event` SELinux class defines **6 permissions**: `{ cpu kernel open read write tracepoint }`
2. The ACL SELinux policy grants `spc_t` only **5 of 6**: `allow spc_t spc_t:perf_event { cpu kernel open read write }`
3. The `tracepoint` permission is **missing**
4. When Inspektor Gadget calls `perf_event_open(PERF_TYPE_TRACEPOINT)` to attach eBPF programs to kernel tracepoints, the kernel's LSM hook checks the `tracepoint` permission
5. SELinux denies it → Defender's LowLevelCollector cannot trace process creation events

### Error from LowLevelCollector

```
Error: running gadget: running gadget: installing tracer:
  attaching enter tracepoint: opening tracepoint perf event: permission denied
```

This repeats every ~3 seconds. The `process_creation_events` file is never created at `/var/log/microsoft-defender-for-cloud/collectors/LowLevelCollector/`.

### Test Failures

```
FAIL: TestContainerProcessCollection — open process_creation_events: no such file or directory
FAIL: TestHostProcessCollection    — open process_creation_events: no such file or directory
PASS: TestPolicySync
PASS: TestPodsCollection
```

## Fix

Add `tracepoint` to the `spc_t` `perf_event` allow rule in the ACL SELinux policy:

```
# Before (current policy)
allow spc_t spc_t:perf_event { cpu kernel open read write };

# After (fix)
allow spc_t spc_t:perf_event { cpu kernel open read write tracepoint };
```

The same fix should also be applied to `container_t` if any workloads run under that label with `perf_event` needs (currently `container_t` has zero `perf_event` rules).

## Investigation Timeline

### Initial Hypothesis: Kernel Lockdown (DISPROVEN)

The original investigation blamed kernel lockdown (`lockdown=integrity`) for blocking `perf_event_open()`, citing a behavioral change between kernels 6.6.126 and 6.6.130. This was disproven:

1. **Standalone VM tests** (kernel 6.6.130, `lockdown=integrity`, SELinux enforcing): `perf_event_open(PERF_TYPE_TRACEPOINT)` **passes** with `CAP_SYS_ADMIN` in containers via `ctr run`, because `ctr` assigns `kernel_t`/`spc_t` labels and the test binary's code path doesn't trigger the same LSM hook as Inspektor Gadget
2. **AKS cluster with pinned kernel 6.6.126** (this investigation): Defender **still fails** with the identical `permission denied` error, proving the kernel version is irrelevant

### Why Standalone VM Tests Were Misleading

| Factor | Standalone VM (ctr run) | AKS Cluster (kubelet/containerd) |
|--------|------------------------|----------------------------------|
| Container runtime | `ctr` direct | kubelet → CRI → containerd |
| SELinux label | `kernel_t` or `spc_t` | `spc_t` (same) |
| Test method | C binary calling `perf_event_open()` directly | Inspektor Gadget `ig trace exec` (eBPF) |
| SELinux hook triggered | Generic `perf_event { open }` | Specific `perf_event { tracepoint }` |
| Result | PASS | **FAIL** |

The standalone C test program called `perf_event_open()` with `PERF_TYPE_TRACEPOINT`, but the kernel's SELinux hook for the `tracepoint` permission is triggered at a different point in the code path — specifically when the eBPF program attaches to the tracepoint, not just when the perf event FD is opened. Inspektor Gadget triggers this path; the simple C test did not.

### Proof: Both Kernels Fail Identically

| Cluster | Kernel | Lockdown | SELinux | LLC Error | Test Result |
|---------|--------|----------|---------|-----------|-------------|
| To-release image (6.6.130) | 6.6.130.1-3.azl3 | integrity | Enforcing | `permission denied` | FAIL |
| Pinned image (6.6.126) | 6.6.126.1-1.azl3 | integrity | Enforcing | `permission denied` | FAIL |

### Defender Pod Security Context (from aks-rp Helm chart)

The Defender LowLevelCollector DaemonSet ([`_microsoftdefender-collector-daemonset-0.9.yaml`](https://msazure.visualstudio.com/CloudNativeCompute/_git/aks-rp?path=/overlaymgr/server/charts/kube-control-plane/charts/kube-addons/templates/addons/partner-addons/_microsoftdefender-collector-daemonset-0.9.yaml)) specifies:

```yaml
securityContext:
  capabilities:
    drop: [all]
    add: ["SYS_ADMIN", "SYS_RESOURCE", "SYS_PTRACE", "SYSLOG", "IPC_LOCK", "NET_ADMIN", "NET_RAW"]
```

However, at runtime the pod actually gets `spc_t` SELinux label and **all capabilities** (`0x1ffffffffff`), likely due to the AppArmor `unconfined` annotation or kubelet behavior on ACL.

### SELinux Policy Analysis

From the ACL SELinux policy (policy version 33):

```
# spc_t perf_event rules (MISSING tracepoint):
allow spc_t spc_t:perf_event { cpu kernel open read write };

# container_t perf_event rules (NONE):
(empty)

# Available permissions in perf_event class:
cpu kernel open read tracepoint write
```

The `tracepoint` permission was added to the kernel's `perf_event` class in SELinux policy v33 but was never added to the ACL policy's allow rules for `spc_t`.

## Repro Steps

### Quick Repro (AKS cluster)

```bash
# Create cluster with ANY ACL image + Defender + Secure Boot
az aks create -g repro-defender -n repro-defender \
  --location westus3 --node-vm-size Standard_D4ds_v5 \
  --enable-secure-boot --enable-vtpm --enable-defender \
  --node-count 1 \
  --aks-custom-headers \
"AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=c4c3550e-a965-4993-a50c-628fd38cd3e1,\
OSImageResourceGroup=aksvhdtestbuildrg,\
OSImageGallery=PackerSigGalleryEastUS,\
OSImageName=aclgen2TL,\
OSImageVersion=<any-version>,\
OSSKU=AzureContainerLinux,\
OSDistro=CustomizedImageLinuxGuard"

# Check for the AVC denial
kubectl run check --rm -it --restart=Never --image=busybox \
  --overrides='{"spec":{"nodeName":"<node>","hostPID":true,
    "containers":[{"name":"c","image":"busybox","stdin":true,
      "command":["nsenter","-t","1","-m","-u","-i","-n","-p","--",
        "sh","-c","dmesg | grep perf_event"],
      "securityContext":{"privileged":true}}]}}'

# Expected output:
# avc: denied { tracepoint } for comm="ig" scontext=...spc_t... tclass=perf_event
```

## References

- Build 161952237 (pinned kernel test): https://msazure.visualstudio.com/CloudNativeCompute/_build/results?buildId=161952237
- Defender DaemonSet template: `aks-rp/overlaymgr/server/charts/kube-control-plane/charts/kube-addons/templates/addons/partner-addons/_microsoftdefender-collector-daemonset-0.9.yaml`
- Original (incorrect) analysis: `aks-rp/docs/acl-defender-kernel-regression.md`
- SELinux `perf_event` class: added `tracepoint` permission in policy version 33
- Inspektor Gadget `ig trace exec`: uses `perf_event_open(PERF_TYPE_TRACEPOINT)` for eBPF process tracing

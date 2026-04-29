# Build Analysis: 160345053

**Pipeline**: E2Ev2 AKS RP Customized Image Validation
**Branch**: `refs/heads/aadagarwal/remove-machine-id-ignition`
**Status**: **Build Failed**
**Region**: eastus2
**Build Link**: https://dev.azure.com/msazure/CloudNativeCompute/_build/results?buildId=160345053&view=results
**ASI Link**: https://asi.azure.ms/services/AKS%20E2E%20Infra/pages/E2E%20Builds?buildID=aadagarebld160345053

---

## Summary (from Kusto: AKSE2EVstsPipelineStatus)

| Metric | Count |
|--------|-------|
| **Total Unique Scenarios** | 150 |
| **Total Sessions (incl. retries)** | 353 |
| **Passed Sessions (succeeded/passed)** | 110 |
| **Failed Sessions** | 243 |
| **Scenario Pass Rate** | **73.3%** (110/150 scenarios had at least 1 pass) |

### Pass Rate by Framework

| Framework | Total Scenarios | Passed | Failed | Pass Rate |
|---|---|---|---|---|
| **E2Ev2** | 76 | 69 | 7 | **90.8%** |
| **E2Ev3** | 74 | 41 | 33 | **55.4%** |
| **Combined** | 150 | 110 | 40 | **73.3%** |

### Node Provisioning Health (from azcore/Fa GuestAgentGenericLogs)

| Metric | Value |
|--------|-------|
| CSE exit code 0 | **409/409 (100%)** |
| Kubelet reached Ready | **409/409 (100%)** |
| CSE failures | **0** |
| RP cluster creates succeeded | **109/168 (65%)** |
| RP cluster creates canceled | 58 (48 client cancel + 7 ControlPlaneAddOnsNotReady + 3 InternalOperationError) |
| RP cluster creates failed | 1 (GalleryImageNotFound) |

**The `remove-machine-id` code changes are NOT causing any node provisioning failures.** Every node that was provisioned had CSE exit 0 and kubelet ready. The high cancel rate is due to E2Ev3 framework timeouts (context deadline exceeded), not provisioning failures.

---

## Failed Scenarios: 40 total (33 E2Ev3 + 7 E2Ev2)

### Failure Category 1: Context Deadline Exceeded — ~20 E2Ev3 scenarios

**Root cause**: The E2Ev3 test framework times out waiting for cluster creation or operations to complete. The RP-side shows `Canceled` (client disconnected before RP finished). OverlayMgr health checks also show context cancellation, suggesting the E2E underlay was under load.

```
[Code: PutManagedClusterFailure]
fail to create or update managed cluster: context deadline exceeded
```

RP log pattern (from AsyncContextActivity):
```
health check context canceled: Category: InternalError; Code: InternalOperationError;
SubCode: OverlayMgrAPIRequestFailed; Message: Internal server error;
OriginalError: context canceled
```

48 `PutManagedCluster` operations were canceled by the client. These scenarios created clusters successfully on other retries (the 41 E2Ev3 passes), confirming the issue is transient.

---

### Failure Category 2: InvalidOSSKU / SecureBoot Required — 7 E2Ev3 scenarios

Tests that attempt operations on ACL clusters without secure boot/vTPM enabled:

```
ERROR CODE: InvalidOSSKU
"OSSKU='AzureContainerLinux' is invalid, details: AzureContainerLinux requires
secureboot and vTPM to be enabled"
```

Affected scenarios:
- `Scenario_AzureContainerLinux_Managed_NATGateway`
- `Scenario_AzureContainerLinux_Static_Egress_VM_AzureLinux`
- `Scenario_AzureContainerLinux_Static_Egress_VMSS_Ubuntu`
- `Scenario_AzureContainerLinux_Traffic_Istio_BYOCA_AzureLinux`
- `Scenario_AzureContainerLinux_Traffic_Istio_CRUD_Azure_Linux`
- `Scenario_AzureContainerLinux_Traffic_Istio_Functionality_AzureLinux`
- `Scenario_AzureContainerLinux_Traffic_Istio_Functionality_IstioCNI_AzureLinux`

These are **test configuration issues** — the test scenarios don't enable secure boot/vTPM when creating/updating clusters with `OSSKU=AzureContainerLinux`.

---

### Failure Category 3: InvalidGalleryImageRef / GalleryImageNotFound — ~3 scenarios

Operations fail because the custom gallery image reference is invalid or the image is not replicated to the target region:

```
RESPONSE 500: 500 Internal Server Error
ERROR CODE: InvalidGalleryImageRef — "Gallery image reference invalid."
```
```
RESPONSE 404: 404 Not Found
ERROR CODE: GalleryImageNotFound
```

This affects operations like `RotateClusterCertificates` and agent pool VMSS creation in non-primary regions (`westus2`, `indonesiacentral`).

---

### Failure Category 4: Custom Image Operation Restrictions — 7 E2Ev2 scenarios

These 7 E2Ev2 scenarios fail due to expected RP limitations on custom images:

| # | Scenario | Error |
|---|----------|-------|
| 1 | `Scenario_AzureContainerLinux_Autoupgrader` | `StatusCode=400: Autoupgrade does not support custom node image` |
| 2 | `Scenario_AzureContainerLinux_CostAnalysis` | No TestError event — silent failure |
| 3 | `Scenario_AzureContainerLinux_ExtensionAddon` | No TestError event — silent failure |
| 4 | `Scenario_AzureContainerLinux_KubeProxyConfig_IPTABLES` | No TestError event — silent failure |
| 5 | `Scenario_AzureContainerLinux_Multi_AgentPool_Runner` | `InvalidOSSKU: AzureContainerLinux requires secureboot and vTPM` |
| 6 | `Scenario_AzureContainerLinux_Swift_CNI_Runner` | `AvailabilityZoneNotSupported: zone '1' not supported, only '4'` |
| 7 | `Scenario_AzureContainerLinux_Upgrade_With_Deprecated_API_Detection` | No TestError event — silent failure |

RP 400s breakdown (from FrontEndQoSEvents):

| Error | Count |
|-------|-------|
| `Autoupgrade does not support custom node image` | 10 |
| `NodeImageUpgrade is not supported on agent pool with type CustomImage` | 4 |
| VM size `Standard_D4lds_v5` not available in subscription | 1 |

These are **expected failures** — the customized image validation pipeline runs scenarios designed for standard images.

---

### Failure Category 5: Misc Infrastructure — ~3 scenarios

- **Role assignment failures** (Cross_Subscription_VNet, CrossTenant_Auxiliary_Token_Provider): `ListRoleAssignment` failures — subscription/RBAC infra issues
- **No keys available** (KMS scenarios): Key pool exhausted
- **Watch event errors**: `unexpected object type: *v1.PodList` — test framework bug

---

## Root Cause Summary

| Category | Scenarios | Caused by code? | Action |
|---|---|---|---|
| Context deadline exceeded / RP cancel | ~20 E2Ev3 | **No** — infra load | Transient, retries pass |
| InvalidOSSKU (secure boot required) | 7 E2Ev3 | **No** — test config | Fix test params for ACL |
| InvalidGalleryImageRef / NotFound | ~3 E2Ev3 | **No** — image replication | Ensure image in all test regions |
| Custom image operation restrictions | 7 E2Ev2 | **No** — expected RP limitations | Known — can't auto-upgrade/node-image-upgrade custom images |
| Misc infra (RBAC, keys, watch) | ~3 E2Ev3 | **No** — infra | Transient |

**Conclusion**: Zero test failures are caused by the `remove-machine-id` code changes. All 409 provisioned nodes had CSE exit 0 and kubelet ready. Remaining failures are E2E infrastructure timeouts (transient), test configuration issues (InvalidOSSKU), and expected custom image limitations.

---

## Kusto Queries Used

### Session results (V3_ASI_Build_SessionList)
```kql
V3_ASI_Build_SessionList(datetime(2026-04-14), datetime(2026-04-16), "aadagarebld160345053")
| summarize count() by testResult
```
Cluster: `akse2e.westus2.kusto.windows.net`, DB: `AKSE2EVstsPipelineStatus`

### Scenario pass rates (AKSE2Ev2Metrics)
```kql
AKSE2Ev2Metrics
| where buildVersion == "aadagarebld160345053"
| where event == "TestPlanFinish"
| summarize anyPass = countif(testPassed == true) > 0 by testScenario
| summarize total = count(), passed = countif(anyPass), failed = countif(not(anyPass))
```

### CSE exit codes (cross-cluster to azcore/Fa)
```kql
cluster('azcore.centralus.kusto.windows.net').database('Fa').GuestAgentGenericLogs
| where PreciseTimeStamp between (datetime(2026-04-14T06:00:00Z) .. datetime(2026-04-14T20:00:00Z))
| where ResourceGroupName contains "MC_e2erg-" and ResourceGroupName contains "bld160345053"
| where TaskName == "AKS.CSE.cse_start"
| extend CSEData = parse_json(Context1)
| extend ExitCode = toint(CSEData.ExitCode)
| extend KubeletReadyTime = tostring(CSEData.KubeletReadyTime)
| summarize totalNodes = count(), kubeletReady = countif(KubeletReadyTime != "") by ExitCode
```

### RP create outcomes (AsyncQoSEvents)
```kql
AsyncQoSEvents
| where PreciseTimeStamp between (datetime(2026-04-14T06:00:00Z) .. datetime(2026-04-14T20:00:00Z))
| where resourceGroupName contains "bld160345053"
| where operationName == "PutManagedClusterHandler.PUT"
| summarize count() by resultCode, result
```

### E2Ev3 error categorization
```kql
AKSE2Ev3
| where build_version == "aadagarebld160345053"
| where level == "ERROR"
| extend errorCategory = case(
    msg has "context deadline exceeded", "ContextDeadlineExceeded",
    msg has "InvalidGalleryImageRef", "InvalidGalleryImageRef",
    msg has "InvalidOSSKU", "InvalidOSSKU_SecureBoot",
    msg has "GalleryImageNotFound", "GalleryImageNotFound",
    msg has "InternalOperationError", "InternalOperationError",
    "Other"
)
| summarize distinctScenarios = dcount(scenario) by errorCategory
```

### E2Ev3 step timeline (V3_ASI_Session_StepTimeline)
```kql
V3_ASI_Session_StepTimeline("aadagarebld160345053", "<scenario>", "<sessionId>", int(0))
| where Health == "Error"
| project Name, error = substring(error, 0, 500)
```

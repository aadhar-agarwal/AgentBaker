#!/bin/bash
# Reproducer for ACL Defender LowLevelCollector kernel lockdown regression
#
# Root Cause: Kernel 6.6.130.1-3.azl3 tightened perf_event_open() enforcement
# under lockdown=integrity, blocking Defender's eBPF-based process tracing
# (Inspektor Gadget ig trace exec). Kernel 6.6.126.1-1.azl3 allows this.
#
# This script creates an AKS cluster with the affected ACL custom image,
# enables Defender, and runs the same integration test job used by the E2E
# pipeline to demonstrate the failure.
#
# Prerequisites:
#   - az cli logged in with appropriate permissions
#   - kubectl installed
#   - The UseCustomizedOSImage feature flag registered on the subscription
#
# Usage:
#   ./repro-defender-lockdown.sh [--cleanup]
#
# A/B Test (proves it's the kernel):
#   Run with the FAILING image (default), then re-run with the PASSING image:
#     OS_IMAGE_VERSION=1.1777053798.6825 CLUSTER_NAME=repro-defender-pass \
#       ./repro-defender-lockdown.sh
#   Compare Step 4b evidence and final test results between the two runs.
#
# Image versions (from the failing/passing E2E pipeline builds):
#   FAILING (to-release): aclgen2TL 1.1776989278.20867 (kernel 6.6.130.1-3.azl3)
#   PASSING (prod):       aclgen2TL 1.1777053798.6825  (kernel 6.6.126.1-1.azl3)

set -euo pipefail

###############################################################################
# Configuration — adjust as needed
###############################################################################
RESOURCE_GROUP="${RESOURCE_GROUP:-repro-defender-lockdown}"
CLUSTER_NAME="${CLUSTER_NAME:-repro-defender-acl}"
LOCATION="${LOCATION:-eastus2}"
VM_SIZE="${VM_SIZE:-Standard_D4ds_v5}"

# Custom image coordinates for the FAILING image (kernel 6.6.130.1-3.azl3)
OS_IMAGE_SUBSCRIPTION="${OS_IMAGE_SUBSCRIPTION:-c4c3550e-a965-4993-a50c-628fd38cd3e1}"
OS_IMAGE_RG="${OS_IMAGE_RG:-aksvhdtestbuildrg}"
OS_IMAGE_GALLERY="${OS_IMAGE_GALLERY:-PackerSigGalleryEastUS}"
OS_IMAGE_NAME="${OS_IMAGE_NAME:-aclgen2TL}"
OS_IMAGE_VERSION="${OS_IMAGE_VERSION:-1.1776989278.20867}"

DEFENDER_TEST_IMAGE="mcr.microsoft.com/azuredefender/stable/integration-tests:2.0.211"
DEFENDER_NS="defender-tests"
JOB_NAME="defender-test-job"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

###############################################################################
# Cleanup mode
###############################################################################
if [[ "${1:-}" == "--cleanup" ]]; then
    log "Cleaning up resource group $RESOURCE_GROUP..."
    az group delete -n "$RESOURCE_GROUP" --yes --no-wait 2>/dev/null || true
    log "Cleanup initiated (async). Resource group will be deleted in the background."
    exit 0
fi

###############################################################################
# Step 1: Create resource group
###############################################################################
log "Step 1: Creating resource group $RESOURCE_GROUP in $LOCATION..."
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none

###############################################################################
# Step 2: Create AKS cluster with custom ACL image + Defender
###############################################################################
log "Step 2: Creating AKS cluster with custom ACL image (version $OS_IMAGE_VERSION)..."
log "  This uses the FAILING image with kernel 6.6.130.1-3.azl3"
log "  Cluster creation takes ~5-10 minutes..."

az aks create \
    -g "$RESOURCE_GROUP" \
    -n "$CLUSTER_NAME" \
    --location "$LOCATION" \
    --node-vm-size "$VM_SIZE" \
    --enable-secure-boot \
    --enable-vtpm \
    --enable-defender \
    --node-count 1 \
    --aks-custom-headers \
"AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=${OS_IMAGE_SUBSCRIPTION},\
OSImageResourceGroup=${OS_IMAGE_RG},\
OSImageGallery=${OS_IMAGE_GALLERY},\
OSImageName=${OS_IMAGE_NAME},\
OSImageVersion=${OS_IMAGE_VERSION},\
OSSKU=AzureContainerLinux,\
OSDistro=CustomizedImageLinuxGuard" \
    -o none

log "  Cluster created successfully"

###############################################################################
# Step 3: Get credentials
###############################################################################
log "Step 3: Getting cluster credentials..."
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing

###############################################################################
# Step 4: Verify kernel version and lockdown state
###############################################################################
log "Step 4: Verifying kernel version and lockdown state..."

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
log "  Node: $NODE_NAME"

KERNEL_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')
log "  Kernel version: $KERNEL_VERSION"

if [[ "$KERNEL_VERSION" == *"6.6.130"* ]]; then
    warn "  Kernel 6.6.130.x detected — this is the AFFECTED kernel"
elif [[ "$KERNEL_VERSION" == *"6.6.126"* ]]; then
    log "  Kernel 6.6.126.x detected — this is the WORKING kernel"
fi

###############################################################################
# Step 4b: Kernel causation — verify lockdown blocks perf_event_open
###############################################################################
log "Step 4b: Verifying kernel lockdown is the cause (direct evidence)..."

# Helper: run a command on the host via a privileged ephemeral pod
host_exec() {
    local cmd="$1"
    local pod_name="host-exec-${RANDOM}"
    kubectl run "$pod_name" \
        --rm -i --restart=Never --quiet \
        --image=busybox \
        --overrides='{
          "spec": {
            "nodeName": "'"$NODE_NAME"'",
            "hostPID": true,
            "containers": [{
              "name": "c",
              "image": "busybox",
              "stdin": true,
              "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c", "'"$cmd"'"],
              "securityContext": {"privileged": true}
            }]
          }
        }' 2>/dev/null || echo ""
}

# Evidence 1: Lockdown state
log "  [Evidence 1] Reading /sys/kernel/security/lockdown..."
LOCKDOWN_STATE=$(host_exec 'cat /sys/kernel/security/lockdown')
log "  Lockdown state: $LOCKDOWN_STATE"

if echo "$LOCKDOWN_STATE" | grep -q '\[integrity\]'; then
    warn "  lockdown=integrity is ACTIVE — restricts perf_event_open()"
elif echo "$LOCKDOWN_STATE" | grep -q '\[none\]'; then
    log "  lockdown=none — perf_event_open() should NOT be restricted"
fi

# Evidence 2: dmesg lockdown/perf denials
log "  [Evidence 2] Checking dmesg for lockdown/perf denials..."
DMESG_DENIALS=$(host_exec 'dmesg 2>/dev/null | grep -iE "Lockdown|perf_event|bpf.*denied" | tail -15')

if [[ -n "$DMESG_DENIALS" ]]; then
    warn "  Lockdown-related kernel messages found:"
    echo "$DMESG_DENIALS" | sed 's/^/    /'
else
    log "  No lockdown denials in dmesg yet (may appear after Defender starts)"
fi

# Evidence 3: perf_event_paranoid sysctl
log "  [Evidence 3] Reading perf_event_paranoid sysctl..."
PARANOID=$(host_exec 'cat /proc/sys/kernel/perf_event_paranoid')
log "  kernel.perf_event_paranoid = $PARANOID"
log "  (Note: under lockdown=integrity the kernel overrides this for tracepoint access)"

# Evidence 4: Attempt perf_event_open syscall via perf tool
log "  [Evidence 4] Testing perf_event_open() syscall directly..."
PERF_TEST=$(host_exec 'perf stat -- ls /dev/null 2>&1; echo EXIT_CODE=$?')

if echo "$PERF_TEST" | grep -qiE 'permission denied|operation not permitted|not supported'; then
    err "  CONFIRMED: perf_event_open() is BLOCKED by kernel lockdown"
    echo "$PERF_TEST" | grep -iE 'denied|not permitted|not supported' | head -3 | sed 's/^/    /'
elif echo "$PERF_TEST" | grep -qi 'EXIT_CODE=0'; then
    log "  perf_event_open() SUCCEEDED — lockdown is NOT blocking perf events"
elif echo "$PERF_TEST" | grep -qi 'not found'; then
    warn "  perf tool not installed on this image; relying on evidence 1-3 and LLC logs"
else
    warn "  Inconclusive perf result:"
    echo "$PERF_TEST" | tail -5 | sed 's/^/    /'
fi

echo ""
log "  --- Causation summary ---"
if echo "$LOCKDOWN_STATE" | grep -q '\[integrity\]'; then
    log "  Kernel lockdown=integrity is active on kernel $KERNEL_VERSION"
    log "  This blocks perf_event_open(PERF_TYPE_TRACEPOINT) which Defender's"
    log "  LowLevelCollector (Inspektor Gadget ig trace exec) requires for eBPF."
    log "  To confirm, re-run with the passing image:"
    log "    OS_IMAGE_VERSION=1.1777053798.6825 CLUSTER_NAME=repro-defender-pass \\\n      $0"
else
    log "  Lockdown is NOT in integrity mode — Defender failure may have a different cause"
fi
echo ""

###############################################################################
# Step 5: Wait for Defender pods to be running
###############################################################################
log "Step 5: Waiting for Defender pods to start (up to 5 minutes)..."

DEFENDER_READY=false
for i in $(seq 1 30); do
    # Check for defender collector daemonset pods (label varies by version)
    DEFENDER_PODS=$(kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep "microsoft-defender-collector-ds" | awk '{print $2}' || echo "")
    if [[ "$DEFENDER_PODS" == *"Running"* ]]; then
        DEFENDER_READY=true
        log "  Defender pods are running"
        break
    fi
    echo -n "."
    sleep 10
done

if [[ "$DEFENDER_READY" != "true" ]]; then
    err "  Defender pods did not start within 5 minutes"
    kubectl get pods -n kube-system -l app=microsoft-defender-collector -o wide
    exit 1
fi

###############################################################################
# Step 6: Check LowLevelCollector logs for permission denied
###############################################################################
log "Step 6: Checking LowLevelCollector for 'permission denied' errors..."

LLC_LOGS=$(kubectl logs -n kube-system \
    $(kubectl get pods -n kube-system -o name 2>/dev/null | grep "microsoft-defender-collector-ds" | head -1) \
    -c microsoft-defender-low-level-collector 2>&1 || echo "")

if echo "$LLC_LOGS" | grep -q "permission denied"; then
    err "  CONFIRMED: LowLevelCollector is hitting 'permission denied' on perf_event_open()"
    echo ""
    echo "--- LowLevelCollector error output (first 10 lines) ---"
    echo "$LLC_LOGS" | grep "permission denied" | head -10
    echo "---"
    echo ""
else
    log "  No 'permission denied' errors detected (test may pass)"
fi

###############################################################################
# Step 7: Deploy RBAC and test job (same as E2E pipeline)
###############################################################################
log "Step 7: Deploying Defender test RBAC and test job..."

kubectl create namespace "$DEFENDER_NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: defender-test-policy-operator
rules:
- apiGroups: ["defender.microsoft.com"]
  resources: ["*"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: defender-test-policy-rb-sa-default
subjects:
- kind: ServiceAccount
  name: default
  namespace: defender-tests
roleRef:
  kind: ClusterRole
  name: defender-test-policy-operator
  apiGroup: rbac.authorization.k8s.io
EOF

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $DEFENDER_NS
  labels:
    app: $DEFENDER_NS
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: $DEFENDER_NS
    spec:
      serviceAccountName: default
      restartPolicy: Never
      initContainers:
      - name: init-container
        image: ubuntu
        command: ["/bin/bash", "-c", "touch ./E2EValidation; cp /bin/echo /bin/echo2; echo2 drift; sleep 1; echo2 again"]
        volumeMounts:
        - name: hostfs
          mountPath: /host
      containers:
      - name: defender-tests
        image: $DEFENDER_TEST_IMAGE
        volumeMounts:
        - name: hostfs
          mountPath: /host
      volumes:
      - name: hostfs
        hostPath:
          path: /
EOF

###############################################################################
# Step 8: Wait for test job and collect results
###############################################################################
log "Step 8: Waiting for test job to complete (up to 3 minutes)..."

JOB_DONE=false
for i in $(seq 1 18); do
    STATUS=$(kubectl get job "$JOB_NAME" -n "$DEFENDER_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status},{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")

    if [[ "$STATUS" == *"True"* ]]; then
        JOB_DONE=true
        break
    fi

    # Check if pod is in a terminal state
    POD_PHASE=$(kubectl get pods -n "$DEFENDER_NS" -l job-name="$JOB_NAME" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$POD_PHASE" == "Failed" || "$POD_PHASE" == "Succeeded" ]]; then
        JOB_DONE=true
        break
    fi

    echo -n "."
    sleep 10
done
echo ""

###############################################################################
# Step 9: Display results
###############################################################################
log "Step 9: Test results"
echo ""
echo "========================================================================"
echo "  JOB STATUS"
echo "========================================================================"
kubectl get job "$JOB_NAME" -n "$DEFENDER_NS" -o wide
echo ""

echo "========================================================================"
echo "  POD LOGS (defender-test-job)"
echo "========================================================================"
kubectl logs -n "$DEFENDER_NS" -l job-name="$JOB_NAME" -c defender-tests 2>&1 || true
echo ""

echo "========================================================================"
echo "  SUMMARY"
echo "========================================================================"

JOB_SUCCEEDED=$(kubectl get job "$JOB_NAME" -n "$DEFENDER_NS" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
JOB_FAILED=$(kubectl get job "$JOB_NAME" -n "$DEFENDER_NS" \
    -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")

if [[ "${JOB_SUCCEEDED:-0}" -gt 0 ]]; then
    log "Test job PASSED — Defender LowLevelCollector is working on this image"
else
    err "Test job FAILED — Defender LowLevelCollector is broken on this image"
    err ""
    err "Root Cause: Kernel $KERNEL_VERSION tightened perf_event_open() enforcement"
    err "under lockdown=integrity, blocking Defender's eBPF process tracing."
    err ""
    err "The file /var/log/microsoft-defender-for-cloud/collectors/LowLevelCollector/"
    err "process_creation_events is never created because the LowLevelCollector cannot"
    err "attach eBPF programs to kernel tracepoints."
    err ""
    err "Workarounds:"
    err "  1. Use a VHD built with lockdown=none (apply the lockdown disable patch)"
    err "  2. Pin kernel to 6.6.126.1-1.azl3 in the ACL image build"
    err "  3. Get the upstream kernel fix for BPF tracepoint access under lockdown=integrity"
fi

echo ""
echo "========================================================================"
echo "  CLEANUP"
echo "========================================================================"
echo "To clean up all resources:"
echo "  $0 --cleanup"
echo "  # or manually:"
echo "  az group delete -n $RESOURCE_GROUP --yes --no-wait"

$Global:ClusterConfiguration = ConvertFrom-Json ((Get-Content "c:\k\kubeclusterconfig.json" -ErrorAction Stop) | out-string)

$global:MasterIP = $Global:ClusterConfiguration.Kubernetes.ControlPlane.IpAddress
$global:KubeDnsSearchPath = "svc.cluster.local"
$global:KubeDnsServiceIp = $Global:ClusterConfiguration.Kubernetes.Network.DnsIp
$global:MasterSubnet = $Global:ClusterConfiguration.Kubernetes.ControlPlane.MasterSubnet
$global:KubeClusterCIDR = $Global:ClusterConfiguration.Kubernetes.Network.ClusterCidr
$global:KubeServiceCIDR = $Global:ClusterConfiguration.Kubernetes.Network.ServiceCidr
$global:KubeBinariesVersion = $Global:ClusterConfiguration.Kubernetes.Source.Release
$global:KubeDir = $Global:ClusterConfiguration.Install.Destination
$global:NetworkMode = "L2Bridge"
$global:ExternalNetwork = "ext"
$global:CNIConfig = "$CNIConfig"
$global:NetworkPlugin = $Global:ClusterConfiguration.Cni.Name
$global:KubeletNodeLabels = $Global:ClusterConfiguration.Kubernetes.Kubelet.NodeLabels
$global:IsSkipCleanupNetwork = [System.Convert]::ToBoolean($Global:ClusterConfiguration.Services.IsSkipCleanupNetwork)

$global:AzureCNIDir = [Io.path]::Combine("$global:KubeDir", "azurecni")
$global:AzureCNIBinDir = [Io.path]::Combine("$global:AzureCNIDir", "bin")
$global:AzureCNIConfDir = [Io.path]::Combine("$global:AzureCNIDir", "netconf")

$global:CNIPath = [Io.path]::Combine("$global:KubeDir", "cni")
$global:CNIConfig = [Io.path]::Combine($global:CNIPath, "config", "$global:NetworkMode.conf")
$global:CNIConfigPath = [Io.path]::Combine("$global:CNIPath", "config")

$global:KubeconfigPath = [Io.path]::Combine("$global:KubeDir", "config")
$global:BootstrapKubeconfigPath = [io.path]::Combine("$global:KubeDir", "bootstrap-config")
$global:EnableSecureTLSBootstrapping = $Global:ClusterConfiguration.Kubernetes.Kubelet.SecureTLSBootstrapArgs.Enabled
$global:SecureTLSBootstrapScriptPath = [Io.path]::Combine("$global:KubeDir", "securetlsbootstrap.ps1")
$global:DefaultSecureTLSBootstrapAADResource = "6dae42f8-4368-4678-94ff-3960e28e3630"

$global:HNSModule = "c:\k\hns.v2.psm1"

ipmo $global:HNSModule

#TODO ksbrmnn refactor to be sensical instead of if if if ...

# Calculate some local paths
$global:VolumePluginDir = [Io.path]::Combine($global:KubeDir, "volumeplugins")
mkdir $global:VolumePluginDir -Force

$KubeletArgList = $Global:ClusterConfiguration.Kubernetes.Kubelet.ConfigArgs # This is the initial list passed in from aks-engine
$KubeletArgList += "--node-labels=$global:KubeletNodeLabels"
# $KubeletArgList += "--hostname-override=$global:AzureHostname" TODO: remove - dead code?
$KubeletArgList += "--volume-plugin-dir=$global:VolumePluginDir"
# If you are thinking about adding another arg here, you should be considering pkg/engine/defaults-kubelet.go first
# Only args that need to be calculated or combined with other ones on the Windows agent should be added here.

# Update args to use ContainerD
$KubeletArgList += @("--container-runtime-endpoint=npipe://./pipe/containerd-containerd")
# Kubelet flag --container-runtime has been removed from k8s 1.27
# Reference: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.27.md#other-cleanup-or-flake
if ($global:KubeBinariesVersion -lt "1.27.0") {
    $KubeletArgList += @("--container-runtime=remote")
}

# Run the secure TLS bootstrap script to generate a kubelet client certificate, if enabled
if ($global:EnableSecureTLSBootstrapping) {
    if (!$env:MasterFQDNPrefix) {
        Write-Host "secure TLS bootstrapping is enabled but master FQDN prefix has not been supplied to the kubelet service"
        exit 1
    }
    $aadResource = $global:DefaultSecureTLSBootstrapAADResource
    if ($env:CustomSecureTLSBootstrapAADResource) {
        $aadResource = $env:CustomSecureTLSBootstrapAADResource
    }
    & "c:\k\securetlsbootstrap.ps1 -KubeDir $global:KubeDir -APIServerFQDN $env:MasterFQDNPrefix -AADResource $aadResource"
}

# If we have a kubeconfig at this point, we know this indicates that either:
# a) secure TLS bootstrapping has succeeded
# b) we don't have a bootstrap token with which to create a bootstrap-
if (Test-Path $global:KubeconfigPath) {
    Remove-Item $global:BootstrapKubeconfigPath
}

# If we don't have a kubeconfig but we do have a bootstrap kubeconfig we can fall back to,
# specify it as a valid bootstrap-kubeconfig in the kubelet arg list
if (!Test-Path $global:KubeconfigPath -and Test-Path $global:BootstrapKubeconfigPath) {
    $KubeletArgList += " --bootstrap-kubeconfig=$global:BootstrapKubeconfigPath"
}

# Used in WinCNI version of kubeletstart.ps1
$KubeletArgListStr = ""
$KubeletArgList | Foreach-Object {
    # Since generating new code to be written to a file, need to escape quotes again
    if ($KubeletArgListStr.length -gt 0) {
        $KubeletArgListStr = $KubeletArgListStr + ", "
    }
    # TODO ksbrmnn figure out what's going on here re tick marks
    $KubeletArgListStr = $KubeletArgListStr + "`"" + $_.Replace("`"`"", "`"`"`"`"") + "`""
}
$KubeletArgListStr = "@($KubeletArgListStr`)"

# Used in Azure-CNI version of kubeletstart.ps1
$KubeletCommandLine = "$global:KubeDir\kubelet.exe " + ($KubeletArgList -join " ")

# Turn off Firewall to enable pods to talk to service endpoints. (Kubelet should eventually do this)
# TODO move this to CSE
netsh advfirewall set allprofiles state off

# Required to clean up the HNS policy lists properly
Write-Host "Stopping kubeproxy service"
Stop-Service kubeproxy

if ($global:NetworkPlugin -eq "azure") {
    Write-Host "NetworkPlugin azure, starting kubelet."

    if ($global:IsSkipCleanupNetwork) {
        Write-Host "Skipping legacy code: kubeletstart.ps1 invokes cleanupnetwork.ps1"
    } else {
        # Legacy codes
        # Find if network created by CNI exists, if yes, remove it
        # This is required to keep the network non-persistent behavior
        # Going forward, this would be done by HNS automatically during restart of the node
        & "c:\k\cleanupnetwork.ps1"
    }

    # Restart Kubeproxy, which would wait, until the network is created
    # This was fixed in 1.15, workaround still needed for 1.14 https://github.com/kubernetes/kubernetes/pull/78612
    Restart-Service Kubeproxy -Force

    # Set env file for Azure Stack
    $env:AZURE_ENVIRONMENT_FILEPATH = "c:\k\azurestackcloud.json"
}

# Start the kubelet
# Use run-process.cs to set process priority class as 'AboveNormal'
# Load a signed version of runprocess.dll if it exists for Azure SysLock compliance
# otherwise load class from cs file (for CI/testing)
if (Test-Path "$global:KubeDir\runprocess.dll") {
    [System.Reflection.Assembly]::LoadFrom("$global:KubeDir\runprocess.dll")
} else {
    Add-Type -Path "$global:KubeDir\run-process.cs"
}
$exe = "$global:KubeDir\kubelet.exe"
$args = ($KubeletArgList -join " ")
[RunProcess.exec]::RunProcess($exe, $args, [System.Diagnostics.ProcessPriorityClass]::AboveNormal)

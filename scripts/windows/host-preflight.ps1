[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VMName,
    [string]$GpuMatch,
    [string]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PropertyValue([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-GpuText([object]$Gpu) {
    $values = foreach ($name in @('Name', 'InstancePath', 'PartitionableGpuName')) {
        [string](Get-PropertyValue $Gpu $name)
    }
    return $values -join ' '
}

if (-not (Test-Administrator)) {
    throw 'Run PowerShell as Administrator.'
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module is not available.'
}
if (-not (Get-Command Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue)) {
    throw 'This Windows/Hyper-V build does not expose Get-VMHostPartitionableGpu.'
}

$vm = Get-VM -Name $VMName
$gpus = @(Get-VMHostPartitionableGpu)
$adapters = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)
$video = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, PNPDeviceID, Status)

if ($GpuMatch) {
    $matchingVideo = @($video | Where-Object Name -like "*$GpuMatch*")
    $pciIds = @($matchingVideo | ForEach-Object {
        if ($_.PNPDeviceID -match '(VEN_[0-9A-F]{4}).*(DEV_[0-9A-F]{4})') { "$($Matches[1]).*$($Matches[2])" }
    })
    $gpus = @($gpus | Where-Object {
        $text = Get-GpuText $_
        $text -like "*$GpuMatch*" -or @($pciIds | Where-Object { $text -match $_ }).Count -gt 0
    })
}

$secureBoot = $null
if ($vm.Generation -eq 2) {
    try { $secureBoot = (Get-VMFirmware -VMName $VMName).SecureBoot } catch { $secureBoot = 'Unknown' }
}

$report = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    WindowsVersion = [Environment]::OSVersion.VersionString
    IsAdministrator = $true
    VM = [ordered]@{
        Name = $vm.Name
        State = [string]$vm.State
        Generation = $vm.Generation
        Version = [string]$vm.Version
        SecureBoot = $secureBoot
        GuestControlledCacheTypes = $vm.GuestControlledCacheTypes
        LowMemoryMappedIoSpace = [uint64]$vm.LowMemoryMappedIoSpace
        HighMemoryMappedIoSpace = [uint64]$vm.HighMemoryMappedIoSpace
    }
    PartitionableGpuCount = $gpus.Count
    PartitionableGpus = @($gpus | ForEach-Object {
        [ordered]@{
            Name = Get-PropertyValue $_ 'Name'
            InstancePath = Get-PropertyValue $_ 'InstancePath'
            PartitionableGpuName = Get-PropertyValue $_ 'PartitionableGpuName'
            ValidPartitionCounts = @(Get-PropertyValue $_ 'ValidPartitionCounts')
        }
    })
    ExistingGpuAdapterCount = $adapters.Count
    ExistingGpuAdapters = @($adapters | Select-Object Name, InstancePath, PartitionId,
        MinPartitionVRAM, MaxPartitionVRAM, OptimalPartitionVRAM,
        MinPartitionEncode, MaxPartitionEncode, OptimalPartitionEncode,
        MinPartitionDecode, MaxPartitionDecode, OptimalPartitionDecode)
    VideoControllers = $video
    Checks = [ordered]@{
        VMExists = $true
        VMIsOffForApply = ($vm.State -eq 'Off')
        ExactlyOneSelectedGpu = ($gpus.Count -eq 1)
        AdapterNotDuplicated = ($adapters.Count -le 1)
        NvidiaPresent = (@($video | Where-Object Name -like '*NVIDIA*').Count -gt 0)
    }
}

$report | ConvertTo-Json -Depth 8
if ($JsonOutput) {
    $parent = Split-Path -Parent $JsonOutput
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -Path $JsonOutput
}

if ($gpus.Count -ne 1) {
    Write-Error "Expected exactly one selected partitionable GPU, found $($gpus.Count). Use -GpuMatch when multiple GPUs exist."
}
if ($adapters.Count -gt 1) {
    Write-Warning 'Duplicate VM GPU-P adapters detected. configure-gpup.ps1 -Action Apply can consolidate them while the VM is off.'
}

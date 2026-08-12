[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VMName,
    [ValidateSet('Status', 'Apply', 'Remove', 'Rollback')]
    [string]$Action = 'Status',
    [string]$GpuMatch,
    [UInt64]$LowMMIO = 1GB,
    [UInt64]$HighMMIO = 32GB,
    [string]$StateFile = ".\state\$VMName-gpup.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }
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

function Get-SelectedGpu {
    $items = @(Get-VMHostPartitionableGpu)
    if ($GpuMatch) {
        $matchingVideo = @(Get-CimInstance Win32_VideoController | Where-Object Name -like "*$GpuMatch*")
        $pciIds = @($matchingVideo | ForEach-Object {
            if ($_.PNPDeviceID -match '(VEN_[0-9A-F]{4}).*(DEV_[0-9A-F]{4})') { "$($Matches[1]).*$($Matches[2])" }
        })
        $items = @($items | Where-Object {
            $text = Get-GpuText $_
            $text -like "*$GpuMatch*" -or @($pciIds | Where-Object { $text -match $_ }).Count -gt 0
        })
    }
    if ($items.Count -ne 1) {
        throw "Expected one partitionable GPU, found $($items.Count). Supply -GpuMatch to disambiguate."
    }
    return $items[0]
}

function Assert-VMOff([object]$VM) {
    if ($VM.State -ne 'Off') {
        throw "VM '$($VM.Name)' must be shut down, current state: $($VM.State)."
    }
}

Assert-Administrator
$vm = Get-VM -Name $VMName
$existing = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)

if ($Action -eq 'Status') {
    [ordered]@{
        VM = $VMName
        State = [string]$vm.State
        GuestControlledCacheTypes = $vm.GuestControlledCacheTypes
        LowMMIO = [uint64]$vm.LowMemoryMappedIoSpace
        HighMMIO = [uint64]$vm.HighMemoryMappedIoSpace
        AdapterCount = $existing.Count
        Adapters = $existing
    } | ConvertTo-Json -Depth 6
    exit 0
}

Assert-VMOff $vm

if ($Action -eq 'Apply') {
    $gpu = Get-SelectedGpu
    $parent = Split-Path -Parent $StateFile
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    if (-not (Test-Path $StateFile)) {
        [ordered]@{
            VMName = $VMName
            CapturedAt = (Get-Date).ToString('o')
            GuestControlledCacheTypes = $vm.GuestControlledCacheTypes
            LowMemoryMappedIoSpace = [uint64]$vm.LowMemoryMappedIoSpace
            HighMemoryMappedIoSpace = [uint64]$vm.HighMemoryMappedIoSpace
            Adapters = @($existing | Select-Object InstancePath, PartitionId,
                MinPartitionVRAM, MaxPartitionVRAM, OptimalPartitionVRAM,
                MinPartitionEncode, MaxPartitionEncode, OptimalPartitionEncode,
                MinPartitionDecode, MaxPartitionDecode, OptimalPartitionDecode,
                MinPartitionCompute, MaxPartitionCompute, OptimalPartitionCompute)
        } | ConvertTo-Json -Depth 7 | Set-Content -Encoding utf8 $StateFile
    }

    if ($PSCmdlet.ShouldProcess($VMName, 'Consolidate GPU-P adapters and configure MMIO')) {
        if ($existing.Count -gt 0) {
            Remove-VMGpuPartitionAdapter -VMName $VMName
        }
        $addCommand = Get-Command Add-VMGpuPartitionAdapter
        $instancePath = Get-PropertyValue $gpu 'InstancePath'
        if (-not $instancePath) { $instancePath = Get-PropertyValue $gpu 'Name' }
        if ($addCommand.Parameters.ContainsKey('InstancePath') -and $instancePath) {
            Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $instancePath | Out-Null
        } else {
            if (@(Get-VMHostPartitionableGpu).Count -ne 1) {
                throw 'This Hyper-V build cannot select an InstancePath and multiple GPUs exist.'
            }
            Add-VMGpuPartitionAdapter -VMName $VMName | Out-Null
        }
        Set-VM -Name $VMName -GuestControlledCacheTypes $true `
            -LowMemoryMappedIoSpace $LowMMIO -HighMemoryMappedIoSpace $HighMMIO
    }
}
elseif ($Action -eq 'Remove') {
    if ($PSCmdlet.ShouldProcess($VMName, 'Remove every GPU-P adapter')) {
        if ($existing.Count -gt 0) { Remove-VMGpuPartitionAdapter -VMName $VMName }
    }
}
elseif ($Action -eq 'Rollback') {
    if (-not (Test-Path $StateFile)) { throw "State file not found: $StateFile" }
    $state = Get-Content -Raw $StateFile | ConvertFrom-Json
    if ($state.VMName -ne $VMName) { throw 'State file belongs to another VM.' }
    if ($PSCmdlet.ShouldProcess($VMName, 'Restore saved MMIO and GPU-P adapter state')) {
        if ($existing.Count -gt 0) { Remove-VMGpuPartitionAdapter -VMName $VMName }
        Set-VM -Name $VMName `
            -GuestControlledCacheTypes ([bool]$state.GuestControlledCacheTypes) `
            -LowMemoryMappedIoSpace ([uint64]$state.LowMemoryMappedIoSpace) `
            -HighMemoryMappedIoSpace ([uint64]$state.HighMemoryMappedIoSpace)
        foreach ($adapter in @($state.Adapters)) {
            $addCommand = Get-Command Add-VMGpuPartitionAdapter
            $instancePath = Get-PropertyValue $adapter 'InstancePath'
            if ($addCommand.Parameters.ContainsKey('InstancePath') -and $instancePath) {
                $restored = Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $instancePath -Passthru
            } else {
                $restored = Add-VMGpuPartitionAdapter -VMName $VMName -Passthru
            }
            $limits = @{}
            foreach ($name in @(
                'MinPartitionVRAM', 'MaxPartitionVRAM', 'OptimalPartitionVRAM',
                'MinPartitionEncode', 'MaxPartitionEncode', 'OptimalPartitionEncode',
                'MinPartitionDecode', 'MaxPartitionDecode', 'OptimalPartitionDecode',
                'MinPartitionCompute', 'MaxPartitionCompute', 'OptimalPartitionCompute'
            )) {
                $value = Get-PropertyValue $adapter $name
                if ($null -ne $value) { $limits[$name] = [uint64]$value }
            }
            if ($limits.Count -gt 0) {
                Set-VMGpuPartitionAdapter -VMGpuPartitionAdapter $restored @limits | Out-Null
            }
        }
    }
}

& "$PSScriptRoot\host-preflight.ps1" -VMName $VMName -GpuMatch $GpuMatch

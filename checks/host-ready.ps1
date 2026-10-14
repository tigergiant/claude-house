param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$processors = @(Get-CimInstance -ClassName Win32_Processor)

$edition = [string]$os.Caption
# Caption is translated on non-English Windows, so decide by SKU and build instead.
$sku = 0
$build = 0
[void][int]::TryParse([string]$os.OperatingSystemSKU, [ref]$sku)
[void][int]::TryParse([string]$os.BuildNumber, [ref]$build)
$editionOk = [bool](Test-HouseHyperVEdition -Sku $sku -Build $build)
# preflight owns the nested-guest blocker. This step keeps its current items and
# still calls the shared helper so the model list lives in one place.
$model = ''
$manufacturer = ''
$modelProp = $computer.PSObject.Properties['Model']
if ($null -ne $modelProp) { $model = [string]$modelProp.Value }
$makerProp = $computer.PSObject.Properties['Manufacturer']
if ($null -ne $makerProp) { $manufacturer = [string]$makerProp.Value }
$nestedGuest = [bool](Test-HouseNestedComputer -Model $model -Manufacturer $manufacturer)
if ($nestedGuest -and -not $editionOk) { $editionOk = $false }
$elevated = [bool](Test-HouseElevation)

$hyperv = $false
if ($elevated) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    $hyperv = $feature.State -eq 'Enabled'
}

$firmware = $false
foreach ($processor in $processors) {
    if ($processor.VirtualizationFirmwareEnabled -eq $true) { $firmware = $true }
}
$hypervisor = $false
if ($computer.HypervisorPresent -eq $true) { $hypervisor = $true }
$virtualization = $firmware -or $hypervisor

$ramBytes = [int64]$computer.TotalPhysicalMemory
$ramOk = $ramBytes -ge 16GB
$ramGB = [math]::Round($ramBytes / 1GB, 2)

$failing = @()
if (-not $editionOk) { $failing += 'edition' }
if (-not $elevated) { $failing += 'elevated' }
if (-not $hyperv) { $failing += 'hyper-v' }
if (-not $virtualization) { $failing += 'virtualization' }
if (-not $ramOk) { $failing += 'ram' }

$detail = 'host ready'
if ($failing.Count -gt 0) { $detail = $failing -join ', ' }

[pscustomobject]@{
    id       = 'host-ready'
    ok       = ($failing.Count -eq 0)
    detail   = [string]$detail
    fix      = 'runbook/00-host-ready.md#if-it-fails'
    evidence = [pscustomobject]@{
        edition        = $edition
        sku            = $sku
        build          = $build
        editionOk      = [bool]$editionOk
        elevated       = [bool]$elevated
        hyperv         = [bool]$hyperv
        virtualization = [bool]$virtualization
        ramGB          = $ramGB
        ramOk          = [bool]$ramOk
    }
}

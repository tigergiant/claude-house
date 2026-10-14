param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/04-vm.md#if-it-fails'

function ConvertTo-VmResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'vm'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-VmEvidence {
    param(
        [bool]$Exists,
        [bool]$Generation,
        [bool]$SecureBoot,
        [bool]$Tpm,
        [bool]$Cpu,
        [bool]$Memory,
        [bool]$StaticMemory,
        [bool]$Disk,
        [bool]$OneAdapter,
        [bool]$Switch,
        [bool]$Checkpoints
    )
    return [pscustomobject]@{
        exists      = $Exists
        generation  = $Generation
        secureboot  = $SecureBoot
        tpm         = $Tpm
        cpu         = $Cpu
        memory       = $Memory
        staticMemory = $StaticMemory
        disk         = $Disk
        oneadapter  = $OneAdapter
        switch      = $Switch
        checkpoints = $Checkpoints
    }
}

function Get-HousePositiveBytes {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    $number = [int64]0
    if (-not [int64]::TryParse([string]$Value, [ref]$number)) { return $null }
    return $number
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-VmResult -Ok $false -Detail 'blueprint not loaded' -Evidence (ConvertTo-VmEvidence -Exists $false -Generation $false -SecureBoot $false -Tpm $false -Cpu $false -Memory $false -StaticMemory $false -Disk $false -OneAdapter $false -Switch $false -Checkpoints $false))
}

$house = $config.House
$network = $config.Network
$name = [string]$house.Name

$vms = @(Get-VM -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$exists = ($vms.Count -eq 1)
$vm = $null
if ($exists) { $vm = $vms[0] }

$generation = $false
$checkpoints = $false
if ($null -ne $vm) {
    $generation = ([string]$vm.Generation -eq '2')
    $checkpoints = ($vm.AutomaticCheckpointsEnabled -eq $false)
}

$firmware = Get-VMFirmware -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
$secureboot = $false
if ($null -ne $firmware) {
    $secureOn = ([string]$firmware.SecureBoot -eq 'On')
    $templateOk = ([string]$firmware.SecureBootTemplate -eq 'MicrosoftWindows')
    $secureboot = $secureOn -and $templateOk
}

$security = Get-VMSecurity -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
$tpm = $false
if ($null -ne $security) {
    $tpm = ($security.TpmEnabled -eq $true) -or ([string]$security.TpmEnabled -eq 'True')
}

$processors = @(Get-VMProcessor -VMName $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$cpu = $false
if ($processors.Count -ge 1) {
    $cpuCount = 0
    $cpuParsed = [int]::TryParse([string]$processors[0].Count, [ref]$cpuCount)
    $cpu = $cpuParsed -and ($cpuCount -eq [int]$house.CpuCount)
}

$memoryInfo = Get-VMMemory -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
$memory = $false
if ($null -ne $memoryInfo) {
    $dynamic = $false
    if ($memoryInfo.DynamicMemoryEnabled -eq $true -or [string]$memoryInfo.DynamicMemoryEnabled -eq 'True') { $dynamic = $true }
    $actual = $null
    if ($dynamic) { $actual = Get-HousePositiveBytes -Value $memoryInfo.Maximum }
    else { $actual = Get-HousePositiveBytes -Value $memoryInfo.Startup }
    $expectedMemory = [int64]$house.MemoryGB * [int64]1GB
    $memory = ($null -ne $actual -and $actual -eq $expectedMemory)
}

$staticMemory = $false
if ($null -ne $vm) {
    $dynamicProp = $vm.PSObject.Properties['DynamicMemoryEnabled']
    $startupProp = $vm.PSObject.Properties['MemoryStartup']
    $dynamicOff = $false
    if ($null -ne $dynamicProp) {
        $dynamicValue = $dynamicProp.Value
        if ($null -ne $dynamicValue) {
            $dynamicOff = ($dynamicValue -eq $false) -or ([string]$dynamicValue -eq 'False')
        }
    }
    $startupBytes = $null
    if ($null -ne $startupProp) { $startupBytes = Get-HousePositiveBytes -Value $startupProp.Value }
    $expectedStatic = [int64]$house.MemoryGB * [int64]1GB
    $staticMemory = $dynamicOff -and ($null -ne $startupBytes) -and ($startupBytes -eq $expectedStatic)
}

$expectedDisk = [int64]$house.DiskGB * [int64]1GB
$drives = @(Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$disk = $false
foreach ($drive in $drives) {
    if ([string]::IsNullOrEmpty([string]$drive.Path)) { continue }
    $vhd = Get-VHD -Path $drive.Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $vhd) { continue }
    $size = Get-HousePositiveBytes -Value $vhd.Size
    if ($null -ne $size -and $size -ge $expectedDisk) { $disk = $true }
}

$adapters = @(Get-VMNetworkAdapter -VMName $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$oneadapter = ($adapters.Count -eq 1)
$switch = $false
if ($oneadapter) {
    $switch = ([string]$adapters[0].SwitchName -eq [string]$network.SwitchName)
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $exists) { $failing.Add('exists') }
if (-not $generation) { $failing.Add('generation') }
if (-not $secureboot) { $failing.Add('secureboot') }
if (-not $tpm) { $failing.Add('tpm') }
if (-not $cpu) { $failing.Add('cpu') }
if (-not $memory) { $failing.Add('memory') }
if (-not $staticMemory) { $failing.Add('staticMemory') }
if (-not $disk) { $failing.Add('disk') }
if (-not $oneadapter) { $failing.Add('oneadapter') }
if (-not $switch) { $failing.Add('switch') }
if (-not $checkpoints) { $failing.Add('checkpoints') }

$detail = 'vm ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }

return (ConvertTo-VmResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-VmEvidence -Exists $exists -Generation $generation -SecureBoot $secureboot -Tpm $tpm -Cpu $cpu -Memory $memory -StaticMemory $staticMemory -Disk $disk -OneAdapter $oneadapter -Switch $switch -Checkpoints $checkpoints))

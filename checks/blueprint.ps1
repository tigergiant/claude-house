param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/01-blueprint.md#if-it-fails'

function ConvertTo-BlueprintResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'blueprint'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

$config = $null
$configError = $null
if ($Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($Context.ContainsKey('ConfigError')) { $configError = $Context['ConfigError'] }

if ($null -eq $config) {
    $detail = $configError
    if (-not $detail) { $detail = 'house.config.psd1 not found' }
    return (ConvertTo-BlueprintResult -Ok $false -Detail ([string]$detail) -Evidence ([pscustomobject]@{
        config = $false
        iso    = $false
        disk   = $false
        ram    = $false
        subnet = $false
    }))
}

$isoOk = $false
$isoPath = [string]$config.House.IsoPath
if ($isoPath) {
    $isoOk = [bool](Test-Path -LiteralPath $isoPath -PathType Leaf)
}

$diskOk = $false
$freeGB = 0
$diskMedia = ''
$pathText = [string]$config.House.Path
$root = [System.IO.Path]::GetPathRoot($pathText)
$needDisk = ([int64]$config.House.DiskGB + 10) * 1GB
if ($root -match '^([A-Za-z]):\\') {
    $letter = $Matches[1].ToUpper()
    try {
        $drive = Get-PSDrive -Name $letter
        $freeBytes = [int64]$drive.Free
        $freeGB = [math]::Round($freeBytes / 1GB, 2)
        $diskOk = $freeBytes -ge $needDisk
    }
    catch {
        $diskOk = $false
    }
    # A VM on a spinning disk takes minutes to boot and to reach the desktop (seen live: 409 s boot, 56 s desktop).
    $diskMedia = Get-HouseVolumeMediaType -DriveLetter $letter
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$ramBytes = [int64]$computer.TotalPhysicalMemory
$ramGB = [math]::Round($ramBytes / 1GB, 2)
$needRam = ([int64]$config.House.MemoryGB + 4) * 1GB
$ramOk = $ramBytes -ge $needRam

$subnetOk = $true
$overlaps = @()
$subnet = [string]$config.Network.Subnet
$hostIp = [string]$config.Network.HostIP
$switchName = [string]$config.Network.SwitchName
$ownAlias = 'vEthernet (' + $switchName + ')'
$addresses = @(Get-NetIPAddress -AddressFamily IPv4)
foreach ($address in $addresses) {
    $ipText = [string]$address.IPAddress
    $alias = [string]$address.InterfaceAlias
    if ($alias -eq $ownAlias -and $ipText -eq $hostIp) { continue }
    $prefix = [int]$address.PrefixLength
    if (Test-HouseCidrOverlap -LeftCidr $subnet -RightIp $ipText -RightPrefix $prefix) {
        $subnetOk = $false
        $overlaps += ("{0}/{1}" -f $ipText, $prefix)
    }
}

$theme = Get-HouseLookTheme -Config $config
$themeOk = @('light', 'none') -contains $theme

$failing = @()
if (-not $themeOk) { $failing += 'Look.Theme must be light or none' }
if (-not $isoOk) { $failing += 'iso' }
if (-not $diskOk) { $failing += 'disk' }
$ssdOk = $diskMedia -ne 'HDD'
if (-not $ssdOk) { $failing += 'ssd' }
if (-not $ramOk) { $failing += 'ram' }
if (-not $subnetOk) { $failing += 'subnet' }
$detail = 'blueprint ready'
if ($failing.Count -gt 0) { $detail = $failing -join ', ' }

return (ConvertTo-BlueprintResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence ([pscustomobject]@{
    config   = $true
    iso      = [bool]$isoOk
    disk     = [bool]$diskOk
    ram      = [bool]$ramOk
    subnet   = [bool]$subnetOk
    ssd      = [bool]$ssdOk
    freeGB   = $freeGB
    diskMedia = $diskMedia
    ramGB    = $ramGB
    overlaps = @($overlaps)
}))

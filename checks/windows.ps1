param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/05-windows.md#if-it-fails'

function ConvertTo-WindowsResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'windows'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-WindowsEvidence {
    param(
        [bool]$Marker,
        [bool]$Credential,
        [bool]$BootDisk,
        [bool]$VhdSize
    )
    return [pscustomobject]@{
        marker     = $Marker
        credential = $Credential
        bootdisk   = $BootDisk
        vhdsize    = $VhdSize
    }
}

function Test-WindowsMarkerFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        $parsed = $text | ConvertFrom-Json
        return ($null -ne $parsed)
    }
    catch {
        return $false
    }
}

function Test-WindowsHardDiskDevice {
    param($Device)
    if ($null -eq $Device) { return $false }
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add([string]$Device.GetType().FullName)
    $names.Add([string]$Device.GetType().Name)
    if ($null -ne $Device.PSObject) {
        foreach ($typeName in @($Device.PSObject.TypeNames)) { $names.Add([string]$typeName) }
    }
    foreach ($typeName in $names) {
        if ($typeName -match 'HardDiskDrive') { return $true }
    }
    return $false
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-WindowsResult -Ok $false -Detail 'blueprint not loaded' -Evidence (ConvertTo-WindowsEvidence -Marker $false -Credential $false -BootDisk $false -VhdSize $false))
}

$name = [string]$config.House.Name
$stateRoot = Join-Path (Join-Path $env:ProgramData 'claude-house') $name
$markerPath = Join-Path $stateRoot 'windows-applied.json'
$credPath = Join-Path $stateRoot 'vm-user.cred.xml'

$marker = Test-WindowsMarkerFile -Path $markerPath
$credential = Test-Path -LiteralPath $credPath -PathType Leaf

$firmware = Get-VMFirmware -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
$bootdisk = $false
if ($null -ne $firmware) {
    $order = @($firmware.BootOrder | Where-Object { $null -ne $_ })
    if ($order.Count -ge 1) {
        $first = $order[0]
        $bootdisk = Test-WindowsHardDiskDevice -Device $first.Device
        # After the first boot Windows puts its own Boot Manager entry first; that still boots the house disk.
        if (-not $bootdisk -and [string]$first.BootType -eq 'File' -and [string]$first.FirmwarePath -match '(?i)\\EFI\\Microsoft\\Boot\\bootmgfw\.efi$') {
            $bootdisk = $true
        }
    }
}

$sixGb = [int64]6GB
$drives = @(Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$vhdsize = $false
foreach ($drive in $drives) {
    if ([string]::IsNullOrEmpty([string]$drive.Path)) { continue }
    $vhd = Get-VHD -Path $drive.Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $vhd -or $null -eq $vhd.FileSize -or [string]$vhd.FileSize -eq '') { continue }
    $fileSize = [int64]0
    if (-not [int64]::TryParse([string]$vhd.FileSize, [ref]$fileSize)) { continue }
    if ($fileSize -ge $sixGb) { $vhdsize = $true }
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $marker) { $failing.Add('marker') }
if (-not $credential) { $failing.Add('credential') }
if (-not $bootdisk) { $failing.Add('bootdisk') }
if (-not $vhdsize) { $failing.Add('vhdsize') }

$detail = 'windows applied'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }

return (ConvertTo-WindowsResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-WindowsEvidence -Marker $marker -Credential $credential -BootDisk $bootdisk -VhdSize $vhdsize))

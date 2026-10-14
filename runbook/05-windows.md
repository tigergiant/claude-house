---
id: windows
title: Apply Windows to the virtual disk
order: 5
requires: [vm]
runs_on: host
admin: true
reboot: false
human: false
---

## Purpose

Apply the blueprint Windows edition to the VM disk while the VM is Off, and create the local user the house will sign in with. This step's check is circumstantial: it only sees a marker, a credential file, the boot order and the VHD file size. The real proof is step 6.

## Before you start

The VM check must already pass. Open PowerShell as Administrator. Show this script to the human and wait for approval before running it. The VM stays Off. Do not attach the ISO as a DVD.

If the disk is not RAW, stop and ask the human. Never repartition a disk that already has partitions unless the human explicitly approves that disk.

The user is `{{House.ComputerName}}\{{House.UserName}}`, a local administrator. The default password is `123456`. The script stores it as a `PSCredential` at `$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml` for PowerShell Direct, and writes it into `Unattend.xml` on the mounted Windows volume. The human changes it in step 14 with the procedure in `runbook/daily.md`. Never print the password, never write it anywhere else, and never put any password in the repo or the blueprint.

`House.ImageName` and `House.Locale` must match the ISO: a Chinese ISO names its editions in Chinese (for example `Windows 11 专业版`) and ships only `zh-CN`. If you save the script to a file, save it as UTF-8 **with** BOM; Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page and garbles non-ASCII names.

Run this from the repository root as one script. Image index and drive letters are computed inside the script. A failure dismounts the VHD and the ISO.

## Do

```powershell
$ErrorActionPreference = 'Stop'
$houseName = '{{House.Name}}'
$housePath = '{{House.Path}}'
$isoPath = '{{House.IsoPath}}'
$imageNameExpected = '{{House.ImageName}}'
$computerName = '{{House.ComputerName}}'
$userName = '{{House.UserName}}'
$locale = '{{House.Locale}}'
$timeZone = '{{House.TimeZone}}'
$vmRoot = Join-Path $housePath $houseName
$vhdPath = Join-Path $vmRoot ($houseName + '.vhdx')
$stateRoot = Join-Path (Join-Path $env:ProgramData 'claude-house') $houseName
$mountedIso = $false
$mountedVhd = $false
$imageIndex = $null
$applied = $false
try {
    $iso = Mount-DiskImage -ImagePath $isoPath -PassThru
    $mountedIso = $true
    $isoVolume = $iso | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
    if ($null -eq $isoVolume) { throw 'mounted ISO has no drive letter' }
    $isoLetter = [string]$isoVolume.DriveLetter
    $sourceDir = $isoLetter + ':\sources'
    $wimPath = Join-Path $sourceDir 'install.wim'
    $esdPath = Join-Path $sourceDir 'install.esd'
    $imageFile = $null
    if (Test-Path -LiteralPath $wimPath -PathType Leaf) { $imageFile = $wimPath }
    elseif (Test-Path -LiteralPath $esdPath -PathType Leaf) { $imageFile = $esdPath }
    else { throw 'ISO has neither sources\install.wim nor sources\install.esd' }
    # Read edition names as objects: dism text output is decoded with the console code page,
    # so a localized name such as 'Windows 11 专业版' can arrive garbled and never match.
    $images = @(Get-WindowsImage -ImagePath $imageFile)
    $images | ForEach-Object { Write-Output ([string]$_.ImageIndex + ': ' + [string]$_.ImageName) }
    $match = @($images | Where-Object { [string]$_.ImageName -eq $imageNameExpected })
    if ($match.Count -ne 1) { throw "edition not found in the image: $imageNameExpected (set House.ImageName to one of the names above)" }
    $imageIndex = [int]$match[0].ImageIndex
    $mounted = Mount-VHD -Path $vhdPath -PassThru
    $mountedVhd = $true
    $disk = Get-Disk -Number $mounted.DiskNumber
    if ([string]$disk.OperationalStatus -eq 'Offline') {
        Set-Disk -Number $disk.Number -IsOffline $false
        $disk = Get-Disk -Number $disk.Number
    }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    if ([string]$disk.PartitionStyle -ne 'RAW') {
        throw "STOP: disk $($disk.Number) partition style is $($disk.PartitionStyle), not RAW. Ask the human before any repartition."
    }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $efi = Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber
    $efiLetter = [string]$efi.DriveLetter
    if (-not $efiLetter) { throw 'EFI partition has no drive letter' }
    $msr = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    if ($null -eq $msr) { throw 'MSR partition was not created' }
    $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $windows -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $windows = Get-Partition -DiskNumber $disk.Number -PartitionNumber $windows.PartitionNumber
    $winLetter = [string]$windows.DriveLetter
    if (-not $winLetter) { throw 'Windows partition has no drive letter' }
    $applyDir = $winLetter + ':\'
    & dism.exe /English /Apply-Image ('/ImageFile:"' + $imageFile + '"') ('/Index:' + $imageIndex) ('/ApplyDir:' + $applyDir)
    if ($LASTEXITCODE -ne 0) { throw "dism Apply-Image exit $LASTEXITCODE" }
    & bcdboot.exe ($winLetter + ':\Windows') /s ($efiLetter + ':') /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot exit $LASTEXITCODE" }
    $password = '123456' # House default; the human changes it in step 14. secretscan:allow
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential (($computerName + '\' + $userName), $secure)
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $null = $credential | Export-Clixml -LiteralPath (Join-Path $stateRoot 'vm-user.cred.xml')
    $escapedPassword = [System.Security.SecurityElement]::Escape($password)
    $escapedUser = [System.Security.SecurityElement]::Escape($userName)
    $escapedComputer = [System.Security.SecurityElement]::Escape($computerName)
    $escapedLocale = [System.Security.SecurityElement]::Escape($locale)
    $escapedZone = [System.Security.SecurityElement]::Escape($timeZone)
    $setupPass = 'oobeSystem'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$escapedComputer</ComputerName>
      <TimeZone>$escapedZone</TimeZone>
    </component>
  </settings>
  <settings pass="$setupPass">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$escapedLocale</InputLocale>
      <SystemLocale>$escapedLocale</SystemLocale>
      <UILanguage>$escapedLocale</UILanguage>
      <UserLocale>$escapedLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$escapedZone</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$escapedPassword</Value>
              <PlainText>true</PlainText>
            </Password>
            <DisplayName>$escapedUser</DisplayName>
            <Group>Administrators</Group>
            <Name>$escapedUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
    $panther = Join-Path ($winLetter + ':\Windows') 'Panther'
    $sysprep = Join-Path ($winLetter + ':\Windows\System32') 'Sysprep'
    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    New-Item -ItemType Directory -Path $sysprep -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $panther 'Unattend.xml'), $xml, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $sysprep 'Unattend.xml'), $xml, $utf8)
    # SetupComplete.cmd runs as SYSTEM after OOBE and before the first logon screen, so the
    # plaintext password in Unattend.xml never survives the first boot. No autologon is needed:
    # PowerShell Direct does not require a signed-in user.
    $scripts = Join-Path ($winLetter + ':\Windows\Setup') 'Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    # Windows expires local passwords after 42 days by default; an expired password silently
    # breaks PowerShell Direct and every check of a house that runs for months.
    # Hyper-V starts the guest clock from the host's local clock. When the house uses another
    # time zone, only the time service (its Hyper-V provider) moves the clock to the right
    # time, and Windows leaves that service stopped, so set it to start on every boot.
    $cleanup = "@echo off`r`nrem Windows expires local passwords after 42 days by default; an expired password silently breaks PowerShell Direct and every check of a house that runs for months.`r`nnet accounts /maxpwage:unlimited`r`nrem The guest clock starts from the host's local clock; only the time service corrects it to the right time zone, and it is not started on its own.`r`nsc config w32time start= auto`r`nnet start w32time`r`nw32tm /resync /force`r`ndel /f /q C:\Windows\Panther\Unattend.xml`r`ndel /f /q C:\Windows\System32\Sysprep\Unattend.xml`r`ndel /f /q `"%~f0`"`r`n"
    [System.IO.File]::WriteAllText((Join-Path $scripts 'SetupComplete.cmd'), $cleanup, [System.Text.Encoding]::ASCII)
    Remove-Variable password, secure, credential, escapedPassword, xml -ErrorAction SilentlyContinue
    $applied = $true
}
finally {
    if ($mountedVhd) {
        try { Dismount-VHD -Path $vhdPath } catch { Write-Output ("VHD dismount failed: " + $_.Exception.Message) }
    }
    if ($mountedIso) {
        try { Dismount-DiskImage -ImagePath $isoPath } catch { Write-Output ("ISO dismount failed: " + $_.Exception.Message) }
    }
}
if ($applied) {
    $firstDisk = Get-VMHardDiskDrive -VMName $houseName | Select-Object -First 1
    Set-VMFirmware -VMName $houseName -FirstBootDevice $firstDisk
    if ($null -eq $imageIndex) { throw 'image index was not selected' }
    $marker = [ordered]@{
        imageName  = $imageNameExpected
        imageIndex = $imageIndex
        appliedAt  = (Get-Date).ToString('o')
    }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stateRoot 'windows-applied.json'), ($marker | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
    Write-Output 'windows apply finished'
}
```

## Verify

Run:

```powershell
house check windows
```

A pass looks like `PASS windows: windows applied`. That pass does not prove setup finished. Step 6 does.

## If it fails

- **marker:** `$env:ProgramData\claude-house\{{House.Name}}\windows-applied.json` is missing or is not JSON. Run the script in Do again. If it stopped because the disk was not RAW, ask the human before touching partitions.
- **credential:** `vm-user.cred.xml` is missing beside the marker. The check only tests that the file exists. It does not read the password. Run the script in Do again.
- **bootdisk:** The first firmware boot entry is not a hard disk. After a successful apply, the script runs `Set-VMFirmware -FirstBootDevice` on the VM hard disk. The VM must be Off.
- **vhdsize:** `Get-VHD` `FileSize` is under 6 GB, so the image does not look applied. Run the script again only after the human agrees the disk may be rewritten. If the disk is no longer RAW, stop and ask.
- **dism or bcdboot exit code:** The script stops and dismounts both images. Fix the image path or edition name `{{House.ImageName}}`, then run the script again.

---
id: guest-shares
title: Open the shares inside the house
order: 11
requires: [shares]
runs_on: guest
admin: true
reboot: true
human: false
---

## Purpose

Make every blueprint share reachable from the VM user as `\\house-host\<Name>`. Mirrored shares also appear at the original host path. Read-only shares must refuse a write. Nothing in this step maps a drive letter with `net use`.

## Before you start

The shares check must already pass. Open PowerShell as Administrator from the repository root. Show the script in Do to the human and wait for approval before running it.

The first run writes `EnableLinkedConnections` and, for a share whose host path is not on `C:`, a `DOS Devices` entry. Both take effect only after the next VM restart. Restart the VM after the first run, then run the check again. Do not print the share password.

Recursive search from a share root over SMB is slow. Search a narrow subfolder, not `\\house-host\<Name>` itself.

Paths below come from the blueprint. A mirror is refused when its path is inside the VM profile `C:\Users\{{House.UserName}}`, inside `C:\Windows`, or inside `C:\Program Files`.

## Do

1. Remove any DVD drive from the VM so a mirrored letter such as `D:` is free. If a real volume already owns that letter, stop and tell the human. Do not format the disk.

```powershell
$vmName = '{{House.Name}}'
Get-VMDvdDrive -VMName $vmName | ForEach-Object {
    Remove-VMDvdDrive -VMName $vmName -ControllerNumber $_.ControllerNumber -ControllerLocation $_.ControllerLocation
}
```

2. Point the guest at `house-host`, store the share credential, turn on linked connections, and create the UNC symlinks. Blueprint values stay outside the script block and travel in `-ArgumentList`.

```powershell
$vmName = '{{House.Name}}'
$hostIp = '{{Network.HostIP}}'
$vmUser = '{{House.UserName}}'
$shares = {{Shares.Literal}}
$shareUser = $env:COMPUTERNAME + '\house-share'
$credPath = Join-Path $env:ProgramData ('claude-house\' + $vmName + '\share-user.cred.xml')
$shareCred = Import-Clixml -LiteralPath $credPath
$sharePass = $shareCred.GetNetworkCredential().Password
foreach ($share in @($shares)) {
    if ($share.Mirror -ne $true) { continue }
    $full = [System.IO.Path]::GetFullPath([string]$share.HostPath).TrimEnd('\')
    $profile = 'C:\Users\' + $vmUser
    $refused = $false
    if ($full.Equals($profile, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($profile + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $refused = $true }
    if ($full.Equals('C:\Windows', [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith('C:\Windows\', [System.StringComparison]::OrdinalIgnoreCase)) { $refused = $true }
    if ($full.ToLowerInvariant().StartsWith('c:\program files')) { $refused = $true }
    if ($refused) { throw ('mirror refused: ' + $full) }
}
$shareJson = '[]'
if (@($shares).Count -eq 1) {
    $shareJson = '[' + (ConvertTo-Json -InputObject @($shares)[0] -Compress -Depth 4) + ']'
}
elseif (@($shares).Count -gt 1) {
    $shareJson = ConvertTo-Json -InputObject @($shares) -Compress -Depth 4
}
Invoke-Command -VMName $vmName -Credential (Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml") -ScriptBlock {
    param($HostIp, $VmUser, $ShareUser, $SharePass, $ShareJson)
    $ErrorActionPreference = 'Stop'
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $existing = ''
    if (Test-Path -LiteralPath $hostsPath) { $existing = [System.IO.File]::ReadAllText($hostsPath) }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($existing -split "`r?`n", 0)) {
        if ($line -match '# claude-house') { continue }
        $kept.Add($line)
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq '') { $kept.RemoveAt($kept.Count - 1) }
    $kept.Add($HostIp + '  house-host  # claude-house')
    $hostsText = ($kept.ToArray() -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($hostsPath, $hostsText, [System.Text.Encoding]::ASCII)
    & cmdkey.exe /add:house-host /user:$ShareUser /pass:$SharePass | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'cmdkey /add failed' }
    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -LiteralPath $policy)) { New-Item -Path $policy -Force | Out-Null }
    New-ItemProperty -LiteralPath $policy -Name 'EnableLinkedConnections' -PropertyType DWord -Value 1 -Force | Out-Null
    $parsed = ConvertFrom-Json -InputObject $ShareJson
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($parsed)) { if ($null -ne $row) { $rows.Add($row) } }
    $letters = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        if ($row.Mirror -ne $true) { continue }
        $path = [System.IO.Path]::GetFullPath([string]$row.HostPath).TrimEnd('\')
        $profile = 'C:\Users\' + $VmUser
        $lower = $path.ToLowerInvariant()
        $refused = $false
        if ($lower -eq $profile.ToLowerInvariant() -or $lower.StartsWith($profile.ToLowerInvariant() + '\')) { $refused = $true }
        if ($lower -eq 'c:\windows' -or $lower.StartsWith('c:\windows\')) { $refused = $true }
        if ($lower.StartsWith('c:\program files')) { $refused = $true }
        if ($refused) { throw 'mirror path is refused' }
        $root = [System.IO.Path]::GetPathRoot($path)
        $letter = $root.Substring(0, 1).ToUpperInvariant()
        $leafParent = [System.IO.Path]::GetDirectoryName($path)
        $linkPath = $path
        if ($letter -ne 'C') {
            $rest = $path.Substring($root.Length)
            $linkPath = Join-Path (Join-Path 'C:\HouseMirror' $letter) $rest
            $leafParent = [System.IO.Path]::GetDirectoryName($linkPath)
            if (-not $letters.Contains($letter)) { $letters.Add($letter) }
        }
        if (-not (Test-Path -LiteralPath $leafParent)) { New-Item -ItemType Directory -Path $leafParent -Force | Out-Null }
        $want = '\\house-host\' + [string]$row.Name
        if (Test-Path -LiteralPath $linkPath) {
            $currentItem = Get-Item -LiteralPath $linkPath -Force
            $currentTarget = ''
            $targets = @($currentItem.Target)
            if ($targets.Count -gt 0 -and $null -ne $targets[0]) { $currentTarget = [string]$targets[0] }
            $currentTarget = $currentTarget.TrimEnd('\')
            if ($currentItem.LinkType -ne 'SymbolicLink' -or $currentTarget -ne $want) {
                throw 'mirror path exists and is not the house symlink'
            }
        }
        else {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $want | Out-Null
        }
    }
    $dosKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices'
    foreach ($letter in $letters) {
        $valueName = $letter + ':'
        $expected = '\??\C:\HouseMirror\' + $letter
        $current = ''
        $existingValue = Get-ItemProperty -LiteralPath $dosKey -Name $valueName -ErrorAction SilentlyContinue
        if ($null -ne $existingValue) {
            $prop = $existingValue.PSObject.Properties[$valueName]
            if ($null -ne $prop) { $current = [string]$prop.Value }
        }
        $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $letter + ":'")
        if ($volume -and $current -ne $expected) { throw 'drive letter is owned by a volume; tell the human and stop' }
        New-ItemProperty -LiteralPath $dosKey -Name $valueName -PropertyType String -Value $expected -Force | Out-Null
    }
} -ArgumentList $hostIp, $vmUser, $shareUser, $sharePass, $shareJson
Remove-Variable sharePass, shareCred -ErrorAction SilentlyContinue
```

3. Restart the VM so linked connections and `DOS Devices` take effect, then prove the step.

```powershell
Restart-VM -Name '{{House.Name}}' -Type Reboot -Force -Wait -For Heartbeat
$deadline = (Get-Date).AddMinutes(10)
do {
    Start-Sleep -Seconds 20
    & .\house.ps1 check guest-shares --json | Out-Null
} while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
& .\house.ps1 check guest-shares
```

The guest needs several minutes after the restart before PowerShell Direct answers; the loop waits up to 10 minutes (about 6 minutes was measured on a real host).

## Verify

Run:

```powershell
house check guest-shares
```

A pass looks like `PASS guest-shares: guest shares ready`. The check may write and delete one `.house-probe-` marker per writable share. That is the only write any check in this project may do.

## If it fails

- **hostname:** `house-host` does not resolve to `{{Network.HostIP}}` from the guest hosts file. Run Do again. The line must carry the `# claude-house` marker and must be written with `[System.IO.File]::WriteAllText` as ASCII. Do not use `Set-Content` on `hosts`.
- **credential:** `cmdkey /list` has no target for `house-host`. Run Do again. The stored user is `<host computer>\house-share`. Do not print the password.
- **reach:** A share root `\\house-host\<Name>` could not be listed. The detail names the share. Confirm step 10, then run Do again. Do not map a drive letter.
- **mirror:** A mirrored path is missing, is not a symlink to `\\house-host\<Name>`, could not be listed, or a non-`C:` letter is not `\??\C:\HouseMirror\<Letter>`. A target that is a drive letter fails. A mirror inside `C:\Users\{{House.UserName}}`, `C:\Windows`, or `C:\Program Files` is refused. Create the link with `New-Item -ItemType SymbolicLink`, not with `mklink`. If the letter belongs to a real volume, stop and tell the human.
- **readonly:** A read-only share accepted a write, or the write failed for a reason other than access denied. Access denied passes. Success fails, and the marker is deleted. Any other error is a probe error and fails. Do not grant Change to a read-only share.
- **writable:** The two-way marker test failed. The check writes a `.house-probe-` file through the mirrored path, reads it back through `\\house-host\<Name>`, deletes it, then does the reverse. Both directions must match, and `finally` deletes the marker. Run Do again, then restart the VM if this is the first run.
- **linked:** `EnableLinkedConnections` is not 1. Run Do again, then restart the VM. The value does nothing until that restart.

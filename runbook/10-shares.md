---
id: shares
title: Share the host folders into the house
order: 10
requires: [tools]
runs_on: host
admin: true
reboot: false
human: false
---

## Purpose

Create one local account, `house-share`, and one SMB share per blueprint folder. The account is not an administrator. A writable share gets Change on the share and Modify on the folder. Every other share gets Read and Read & execute. One inbound firewall rule allows TCP 445 only from the VM.

## Before you start

The tools check must already pass. Open PowerShell as Administrator from the repository root. Show the script in Do to the human and wait for approval before running it.

The password is generated the same way as step 5: 28 characters, stored only as a `PSCredential` at `$env:ProgramData\claude-house\{{House.Name}}\share-user.cred.xml`. Never print it, never write it anywhere else, and never put it in the repo. The check only tests that the file exists.

The shares below come from the blueprint:

```powershell
$shares = {{Shares.Literal}}
```

## Do

1. Create the account, the shares, the NTFS rights, and the firewall rule.

```powershell
$houseName = '{{House.Name}}'
$vmIp = '{{Network.VmIP}}'
$shares = {{Shares.Literal}}
$stateRoot = Join-Path $env:ProgramData ('claude-house\' + $houseName)
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$credPath = Join-Path $stateRoot 'share-user.cred.xml'
if (Test-Path -LiteralPath $credPath) {
    $credential = Import-Clixml -LiteralPath $credPath
    $plain = $credential.GetNetworkCredential().Password
}
else {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 28
    $rng.GetBytes($buffer)
    $chars = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 28; $i++) {
        [void]$chars.Append($alphabet[[int]$buffer[$i] % $alphabet.Length])
    }
    $plain = $chars.ToString()
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential (($env:COMPUTERNAME + '\house-share'), $secure)
    $null = $credential | Export-Clixml -LiteralPath $credPath
}
$secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
$existingUser = Get-LocalUser -Name 'house-share' -ErrorAction SilentlyContinue
if ($null -eq $existingUser) {
    New-LocalUser -Name 'house-share' -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
}
else {
    Set-LocalUser -Name 'house-share' -Password $secure
}
Enable-LocalUser -Name 'house-share'
$admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue)
foreach ($member in $admins) {
    if ([string]$member.Name -match '(?i)\\house-share$') {
        Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $member.Name
    }
}
foreach ($share in @($shares)) {
    if (-not (Test-Path -LiteralPath $share.HostPath)) {
        New-Item -ItemType Directory -Path $share.HostPath -Force | Out-Null
    }
    $existingShare = Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue
    if ($null -eq $existingShare) {
        New-SmbShare -Name $share.Name -Path $share.HostPath -CachingMode None | Out-Null
    }
    elseif ([string]$existingShare.Path -ne [string]$share.HostPath) {
        throw ('SMB share path does not match the blueprint: ' + $share.Name)
    }
    $aces = @(Get-SmbShareAccess -Name $share.Name)
    foreach ($ace in $aces) {
        $account = [string]$ace.AccountName
        $drop = $false
        if ($account -match '(?i)(^|\\)Everyone$') { $drop = $true }
        if ($account -match '(?i)(^|\\)house-share$') { $drop = $true }
        if ($drop) { Revoke-SmbShareAccess -Name $share.Name -AccountName $account -Force | Out-Null }
    }
    $right = 'Read'
    if ($share.Writable -eq $true) { $right = 'Change' }
    Grant-SmbShareAccess -Name $share.Name -AccountName 'house-share' -AccessRight $right -Force | Out-Null
    $acl = Get-Acl -LiteralPath $share.HostPath
    $identity = $env:COMPUTERNAME + '\house-share'
    $rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    if ($share.Writable -eq $true) { $rights = [System.Security.AccessControl.FileSystemRights]::Modify }
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $rights, $inherit, 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $share.HostPath -AclObject $acl
}
Get-NetFirewallRule -DisplayName "claude-house SMB" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "claude-house SMB" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress $vmIp -Profile Any | Out-Null
Remove-Variable plain, secure, credential -ErrorAction SilentlyContinue
```

## Verify

Run:

```powershell
house check shares
```

A pass looks like `PASS shares: shares ready`. The check does not read the password file.

## If it fails

- **account:** `house-share` is missing, disabled, or a member of Administrators. Run Do again. Do not add the account to Administrators.
- **credential:** `share-user.cred.xml` is missing beside the house state folder. The check only tests that the file exists. Run Do again and do not print the password.
- **shares:** A blueprint share is missing, points at the wrong folder, grants `Everyone` anything, or grants `house-share` the wrong access. Writable needs Change or Full. Read-only needs Read and must not also have Change or Full. The detail names the share. Run Do again.
- **smbfirewall:** No enabled inbound Allow rule named `claude-house SMB` matches TCP port 445 with remote address exactly `{{Network.VmIP}}`. A wider remote address fails. Run the firewall lines in Do again.

---
id: vm-online
title: Start the house and prove it answers
order: 6
requires: [windows]
runs_on: host
admin: true
reboot: true
human: false
---

## Purpose

Start the VM, wait until it answers PowerShell Direct, and prove the computer name, the Windows build, that the unattended password file is gone, that no autologon password is left in the registry, and that the guest clock keeps the right time. Put a shortcut on the public desktop that opens the console. The host does not reboot. `reboot: true` records the VM's first boot.

## Before you start

The windows check must already pass. Open PowerShell as Administrator from the repository root. Show every command in Do to the human and wait for approval before running it.

The first boot and OOBE take 10–30 minutes; about 20 minutes is normal on a fast PC. Until setup finishes, PowerShell Direct answers "The credential is invalid" (or the same message in the host's language). That is progress, not a wrong password. PowerShell Direct uses the credential file from step 5 and does not need a network inside the VM. Do not print that credential.

## Do

1. Start the VM:

```powershell
Start-VM -Name '{{House.Name}}'
```

2. Put the console shortcut on the public desktop (the check below waits for these files, so they come first):

```powershell
Import-Module (Join-Path (Get-Location) 'lib\House.psm1') -Force
$config = Import-HouseConfig -Path (Join-Path (Get-Location) 'house.config.psd1')
New-HouseDesktopShortcut -Config $config
New-HouseConsoleSettings -Config $config
```

The first double-click connects without asking. The console window can be resized. To change the choice later, use the window's own "show options". `New-HouseConsoleSettings` writes the vmconnect settings file for the user running this block when that file does not exist. A choice already saved on disk is left alone.

3. Poll the read-only check for up to 30 minutes:

```powershell
$deadline = (Get-Date).AddMinutes(30)
$passed = $false
do {
    & .\house.ps1 check vm-online --json | Out-Null
    if ($LASTEXITCODE -eq 0) { $passed = $true; break }
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)
if (-not $passed) { throw 'vm-online did not pass within 30 minutes' }
```

Double-click **{{House.Name}}** on the desktop and accept the administrator prompt. If the VM is off, the window offers Start.

## Verify

Run:

```powershell
house check vm-online
```

A pass looks like `PASS vm-online: vm online`.

## If it fails

- **running:** The VM state is not Running. Run `Start-VM -Name '{{House.Name}}'` and wait for the first boot.
- **heartbeat:** `Get-VMIntegrationService -Name Heartbeat` did not report `PrimaryOperationalStatus` = `Ok` (the description text is localized, so the check reads the status code). Integration services are quiet until OOBE finishes. Wait up to 30 minutes and watch the console with `vmconnect.exe localhost {{House.Name}}`. If it stays dark, the offline apply or the boot order from step 5 needs another look.
- **psdirect:** PowerShell Direct did not return. "The credential is invalid" during the first 30 minutes means setup is still running; keep polling. If it persists after that, do not print the password. The file is `$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml` and the user inside it is `{{House.ComputerName}}\{{House.UserName}}`. Ask the human before resetting that account.
- **build:** The guest build is under 22000, so it is not Windows 11. The applied edition was `{{House.ImageName}}`.
- **name:** The guest computer name is not `{{House.ComputerName}}`. That name is `{{House.Name}}` with every character outside letters, digits and hyphen removed, then cut to 15 characters. The unattend file sets it on first boot.
- **unattendGone:** `C:\Windows\Panther\Unattend.xml` or `C:\Windows\System32\Sysprep\Unattend.xml` is still present. The plaintext password file must be gone after the first boot; `SetupComplete.cmd` from step 5 deletes it before the logon screen. Ask the human, then delete both files through PowerShell Direct:

```powershell
Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock {
    Remove-Item -LiteralPath 'C:\Windows\Panther\Unattend.xml', 'C:\Windows\System32\Sysprep\Unattend.xml' -Force -ErrorAction SilentlyContinue
}
```

- **autologonGone:** The guest still has `DefaultPassword` in `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`, or `AutoAdminLogon` is `1`. Step 5 does not configure automatic logon, so either value means something else turned it on and may have left a password in plain text. Ask the human, then clear it through PowerShell Direct:

```powershell
Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Remove-ItemProperty -LiteralPath $key -Name DefaultPassword -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $key -Name AutoAdminLogon -Value '0'
}
```

- **shortcut:** The public desktop shortcut `{{House.Name}}.lnk` is missing, its target does not end with `\vmconnect.exe`, its arguments do not contain the house name, or it is not set to run as administrator. Run Do 2 of step 6 again.
- **consoleSettings:** The vmconnect settings file for this user is missing, or `SavedConfigExists` is not `True`. Run Do 2 of step 6 again as the person who will use the console, not as another admin account.
- **clock:** The guest time service `w32time` does not start on its own, or the guest clock is more than five minutes away from the host's. Hyper-V starts the guest clock from the host's local clock, so a house in another time zone runs hours off until the time service corrects it. A wrong clock breaks sign-in and certificate checks. Step 5 sets the service to start on every boot; a house built before that needs this one PowerShell Direct line: `Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock { Set-Service -Name w32time -StartupType Automatic; Start-Service -Name w32time; w32tm /resync /force }`
- **passwordNoExpiry:** The guest password has an expiry date. An expired password breaks every check. Ask the human first, then run this one PowerShell Direct line: `Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock { net accounts /maxpwage:unlimited }`

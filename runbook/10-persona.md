---
id: persona
title: Set the house persona and mute telemetry
order: 10
requires: [tools]
runs_on: guest
admin: true
reboot: false
human: false
---

## Purpose

Give the guest one coherent persona and turn off Claude's optional reporting. Culture, home region and time zone are aligned to the blueprint here, so what the guest shows agrees with where its traffic leaves. Four documented Claude Code switches are written machine-wide, so every new shell and every Claude session starts with telemetry, error reporting and non-essential traffic off.

## Before you start

The tools check must already pass. Open PowerShell as Administrator from the repository root. Show the script in Do to the human and wait for approval before running it. PowerShell Direct runs as the VM user `{{House.UserName}}`, a local administrator from step 5.

The switches are documented Claude Code settings, read out of the official client itself: `DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` mute optional reporting, `DISABLE_ERROR_REPORTING` turns off crash reporting, and `DO_NOT_TRACK` is the industry-wide opt-out that the client also honours. Machine-level variables apply to new sign-in sessions; the check reads the saved values, so no sign-out is needed to pass. The blueprint's `House.Locale` and `House.TimeZone` already seeded the unattended install in step 5; this step aligns the live user profile with them and keeps the two provable in one place.

## Do

```powershell
$vmName = '{{House.Name}}'
$locale = '{{House.Locale}}'
$timeZone = '{{House.TimeZone}}'
Invoke-Command -VMName $vmName -Credential (Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml") -ScriptBlock {
    param($Locale, $TimeZone)
    $ErrorActionPreference = 'Stop'
    foreach ($name in 'DISABLE_TELEMETRY', 'DISABLE_ERROR_REPORTING', 'DO_NOT_TRACK', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC') {
        [Environment]::SetEnvironmentVariable($name, '1', 'Machine')
    }
    Set-Culture -CultureInfo $Locale
    Set-TimeZone -Id $TimeZone
    $geoId = (New-Object System.Globalization.RegionInfo($Locale)).GeoId
    try { Set-WinHomeLocation -GeoId $geoId } catch { }
} -ArgumentList $locale, $timeZone
```

## Verify

Run:

```powershell
house check persona
```

A pass looks like `PASS persona: persona aligned`. Evidence lists the four saved switches plus the observed culture, home-region id and time zone, each compared against the blueprint.

## If it fails

- **telemetry, errorReporting, doNotTrack or nonessential:** the saved machine variable is not `1`. Re-run Do; the check reads `Machine`-scope values, so a stale terminal does not matter.
- **culture:** `(Get-Culture).Name` is not `{{House.Locale}}`. Re-run Do. The change applies to new processes; a terminal that was already open still shows the old culture.
- **geo:** the home-region id does not match `{{House.Locale}}`. Re-run Do. If the catch in Do swallowed an error, run `Set-WinHomeLocation -GeoId <id>` with the id from `(New-Object System.Globalization.RegionInfo('{{House.Locale}}')).GeoId`.
- **timezone:** `(Get-TimeZone).Id` is not `{{House.TimeZone}}`. Re-run Do. Step 5 also wrote this into the unattended answer file, so a mismatch here means the image was applied from a different blueprint.

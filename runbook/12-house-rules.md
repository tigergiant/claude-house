---
id: house-rules
title: Install the house rules and hooks
order: 12
requires: [guest-shares]
runs_on: guest
admin: false
reboot: false
human: false
---

## Purpose

Install the share address book and house rules into the VM user's `CLAUDE.md`, write the share-root list, and turn on the hooks selected in the blueprint. Text outside the house markers is left as it is. Hook entries that do not belong to the house are left as they are.

## Before you start

The guest-shares check must already pass. Run the script from the repository root. An unknown name in `Rules.Hooks` stops this page before anything is written. Known names are `bounded-search`, `share-delete-guard` and `windows-guard`.

## Do

1. Render the rules on the host, then write them in the VM with one PowerShell Direct call. Blueprint values and file text travel in `-ArgumentList`. The script block stays ASCII.

```powershell
Import-Module (Join-Path (Get-Location) 'lib\House.psm1') -Force
$config = Import-HouseConfig -Path (Join-Path (Get-Location) 'house.config.psd1')
$vmName = '{{House.Name}}'
$vmUser = '{{House.UserName}}'
$selection = Get-HouseHookSelection -Config $config
$unknown = @($selection.Unknown | Where-Object { $_ })
if ($unknown.Count -gt 0) { throw ('unknown hook: ' + ($unknown -join ', ')) }
$block = Format-HouseRulesBlock -Config $config
$roots = Format-HouseRootsJson -Config $config
$rows = New-Object System.Collections.Generic.List[object]
foreach ($name in @($selection.Selected | Where-Object { $_ })) {
    $file = Join-Path (Join-Path (Get-Location) 'rules\hooks') ('house-' + [string]$name + '.ps1')
    if (-not (Test-Path -LiteralPath $file)) { throw ('missing hook script: ' + [string]$name) }
    $rows.Add([pscustomobject]@{ name = [string]$name; text = [System.IO.File]::ReadAllText($file); matcher = (Get-HouseHookMatcher -Name ([string]$name)); timeout = 10 })
}
$hooksJson = '[]'
if ($rows.Count -eq 1) { $hooksJson = '[' + (ConvertTo-Json -InputObject $rows[0] -Compress -Depth 6) + ']' }
elseif ($rows.Count -gt 1) { $hooksJson = ConvertTo-Json -InputObject @($rows.ToArray()) -Compress -Depth 6 }
Invoke-Command -VMName $vmName -Credential (Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml") -ScriptBlock {
    param($Block, $RootsJson, $HooksJson, $UserName)
    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    $hooksDir = Join-Path $claudeDir 'hooks'
    if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $hooksDir 'house-roots.json'), $RootsJson, $utf8)
    $parsed = ConvertFrom-Json -InputObject $HooksJson
    foreach ($row in @($parsed)) {
        if ($null -eq $row) { continue }
        $hookPath = Join-Path $hooksDir ('house-' + [string]$row.name + '.ps1')
        [System.IO.File]::WriteAllText($hookPath, [string]$row.text, $utf8)
    }
    $begin = '<!-- claude-house:begin -->'
    $end = '<!-- claude-house:end -->'
    $claudePath = Join-Path $claudeDir 'CLAUDE.md'
    $existing = ''
    if (Test-Path -LiteralPath $claudePath) { $existing = [System.IO.File]::ReadAllText($claudePath) }
    $start = $existing.IndexOf($begin)
    $stop = -1
    if ($start -ge 0) { $stop = $existing.IndexOf($end, $start + $begin.Length) }
    if ($start -ge 0 -and $stop -lt 0) { throw 'CLAUDE.md house block is not closed' }
    if ($start -ge 0) {
        $head = $existing.Substring(0, $start)
        $tail = $existing.Substring($stop + $end.Length)
        while ($true) {
            $again = $tail.IndexOf($begin)
            if ($again -lt 0) { break }
            $againEnd = $tail.IndexOf($end, $again + $begin.Length)
            if ($againEnd -lt 0) { throw 'CLAUDE.md house block is not closed' }
            $tail = $tail.Substring(0, $again) + $tail.Substring($againEnd + $end.Length)
        }
        $updated = $head + $Block + $tail
    }
    else {
        $updated = $existing
        if ($updated.Length -gt 0 -and -not $updated.EndsWith("`n")) { $updated = $updated + "`r`n" }
        $updated = $updated + $Block
        if (-not $updated.EndsWith("`n")) { $updated = $updated + "`r`n" }
    }
    [System.IO.File]::WriteAllText($claudePath, $updated, $utf8)

    function ConvertTo-HousePlain {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
        if ($Value -is [System.Collections.IDictionary]) {
            $mapped = @{}
            foreach ($key in @($Value.Keys)) { $mapped[[string]$key] = ConvertTo-HousePlain -Value $Value[$key] }
            return $mapped
        }
        if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            $items = New-Object System.Collections.ArrayList
            foreach ($item in $Value) { [void]$items.Add((ConvertTo-HousePlain -Value $item)) }
            return $items.ToArray()
        }
        $mapped = @{}
        foreach ($prop in $Value.PSObject.Properties) { $mapped[[string]$prop.Name] = ConvertTo-HousePlain -Value $prop.Value }
        return $mapped
    }

    $settingsPath = Join-Path $claudeDir 'settings.json'
    $plain = @{}
    if (Test-Path -LiteralPath $settingsPath) {
        $settingsText = [System.IO.File]::ReadAllText($settingsPath)
        if ($settingsText.Trim()) { $plain = ConvertTo-HousePlain -Value (ConvertFrom-Json -InputObject $settingsText) }
    }
    if ($null -eq $plain) { $plain = @{} }
    if (-not $plain.Contains('hooks') -or $null -eq $plain['hooks']) { $plain['hooks'] = @{} }
    $hooksNode = $plain['hooks']
    $pre = @()
    if ($hooksNode.Contains('PreToolUse') -and $null -ne $hooksNode['PreToolUse']) { $pre = @($hooksNode['PreToolUse']) }
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $pre) {
        if ($null -eq $entry) { continue }
        $drop = $false
        $inner = @()
        if (($entry -is [System.Collections.IDictionary]) -and $entry.Contains('hooks') -and $null -ne $entry['hooks']) { $inner = @($entry['hooks']) }
        foreach ($hook in $inner) {
            $cmd = ''
            if (($hook -is [System.Collections.IDictionary]) -and $hook.Contains('command')) { $cmd = [string]$hook['command'] }
            if ($cmd.IndexOf('/.claude/hooks/house-') -ge 0) { $drop = $true }
        }
        if (-not $drop) { $kept.Add($entry) }
    }
    foreach ($row in @($parsed)) {
        if ($null -eq $row) { continue }
        $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/' + $UserName + '/.claude/hooks/house-' + [string]$row.name + '.ps1"'
        $matcher = 'Grep|Glob|Bash|PowerShell'
        if ($null -ne $row.matcher -and [string]$row.matcher) { $matcher = [string]$row.matcher }
        $timeout = 10
        if ($null -ne $row.timeout) { $timeout = [int]$row.timeout }
        $kept.Add(@{ matcher = $matcher; hooks = @(@{ type = 'command'; command = $command; timeout = $timeout }) })
    }
    $hooksNode['PreToolUse'] = $kept.ToArray()
    if (-not $plain.Contains('env') -or $null -eq $plain['env'] -or -not ($plain['env'] -is [System.Collections.IDictionary])) {
        $plain['env'] = @{}
    }
    $plain['env']['PYTHONUTF8'] = '1'
    $plain['env']['PYTHONIOENCODING'] = 'utf-8'
    $plain['env']['CLAUDE_CODE_USE_POWERSHELL_TOOL'] = '1'
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216
    [System.IO.File]::WriteAllText($settingsPath, $serializer.Serialize($plain), $utf8)

    function Find-HouseTool {
        param([string]$Name, [string]$Fallback)
        $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $command -and $command.Source) { return [string]$command.Source }
        if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
        return ''
    }
    $gitFile = Find-HouseTool -Name 'git' -Fallback ''
    if (-not $gitFile) { throw 'git not found' }
    & $gitFile config --global core.longpaths true
    if ($LASTEXITCODE -ne 0) { throw 'git core.longpaths failed' }
    & $gitFile config --global core.quotepath false
    if ($LASTEXITCODE -ne 0) { throw 'git core.quotepath failed' }
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWord -Force | Out-Null
} -ArgumentList $block, $roots, $hooksJson, $vmUser
```

2. Prove the step.

```powershell
house check house-rules
```

## Verify

Run:

```powershell
house check house-rules
```

A pass looks like `PASS house-rules: house rules ready`. The check compares hashes. It does not print the rules or the hook files.

## If it fails

- **claudemd:** `%USERPROFILE%\.claude\CLAUDE.md` is missing, contains more than one house block, or the block hash does not match the host render. Run Do again. Text outside `<!-- claude-house:begin -->` and `<!-- claude-house:end -->` is kept.
- **roots:** `house-roots.json` is missing or its hash does not match the host render. Run Do again. The file is UTF-8 without a BOM.
- **hooks:** A selected hook file hash does not match the repo, `settings.json` does not parse (the detail contains the parse error), a selected hook command is missing, the matcher or timeout does not match (`timeout` is 10; `windows-guard` uses `Bash|PowerShell|Write|Edit` and the other hooks use `Grep|Glob|Bash|PowerShell`), an unselected known hook is still registered, or the blueprint names an unknown hook (the detail contains that name). Known names are `bounded-search`, `share-delete-guard` and `windows-guard`. Fix `settings.json` if it is not JSON, then run Do again. The command form is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/<UserName>/.claude/hooks/house-<name>.ps1"`.
- **winshell:** The detail names the first wrong setting. In the VM, merge these `settings.json` `env` values without removing other keys: `PYTHONUTF8` = `1`, `PYTHONIOENCODING` = `utf-8`, `CLAUDE_CODE_USE_POWERSHELL_TOOL` = `1`. Then run:

```powershell
$gitFile = (Get-Command -Name git -ErrorAction SilentlyContinue).Source
& $gitFile config --global core.longpaths true
& $gitFile config --global core.quotepath false
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWord -Force
```

<#
.SYNOPSIS
    Fails when the repository contains secrets or private markers.

.DESCRIPTION
    Scans every file git would publish: tracked files plus untracked files that are not ignored.
    Generic patterns live here. Project-private markers (names, hosts, addresses) belong in a
    deny-list kept OUTSIDE the repository. Pass its path with -DenyList or set the
    HOUSE_PRIVATE_DENYLIST environment variable. Each non-empty, non-# line is a literal and
    matching ignores case.

    Findings show only file, line and rule. The matched text is never printed.
    A line containing "secretscan:allow" is skipped.

.EXAMPLE
    .\tools\Invoke-SecretScan.ps1
    .\tools\Invoke-SecretScan.ps1 -History     # also scan every commit's patch
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$DenyList = $env:HOUSE_PRIVATE_DENYLIST,
    [switch]$History
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside param defaults.
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$rules = [ordered]@{
    'private-key'      = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'anthropic-key'    = 'sk-ant-[A-Za-z0-9_\-]{20,}'
    'openai-style-key' = '\bsk-[A-Za-z0-9]{32,}\b'
    'github-token'     = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b'
    'aws-access-key'   = '\bAKIA[0-9A-Z]{16}\b'
    'slack-token'      = '\bxox[abpors]-[A-Za-z0-9-]{10,}\b'
    'password-assign'  = '(?i)\b(?!pass\s*=\s*[''"](windowsPE|offlineServicing|generalize|specialize|auditSystem|auditUser|oobeSystem)[''"])(password|passwd|pass|pwd|secret|token|api[_-]?key)\s*[:=]\s*[''"][^''"\s$]{6,}[''"]'
    'private-ipv4'     = '\b(10\.\d{1,3}|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b'
    'cgnat-ipv4'       = '\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b'
    'email'            = '\b[A-Za-z0-9._%+-]+@(?!example\.(com|org|net)\b|[A-Za-z0-9.-]*\.invalid\b|users\.noreply\.github\.com\b|anthropic\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
    'cn-mobile'        = '(?<![\d.])1[3-9]\d{9}(?![\d.])'
    'cn-id-card'       = '(?<![\d.])\d{17}[\dXx](?![\d.])'
}

$private = @()
if ($DenyList) {
    if (-not (Test-Path -LiteralPath $DenyList)) { throw "Deny-list not found: $DenyList" }
    $private = Get-Content -LiteralPath $DenyList -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

$findings = New-Object System.Collections.Generic.List[object]

function Test-Line([string]$Where, [int]$LineNo, [string]$Text) {
    if ($Text -match 'secretscan:allow') { return }
    foreach ($name in $rules.Keys) {
        if ($Text -match $rules[$name]) {
            $findings.Add([pscustomobject]@{ Where = $Where; Line = $LineNo; Rule = $name })
        }
    }
    for ($i = 0; $i -lt $private.Count; $i++) {
        if ($Text.IndexOf($private[$i], [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $findings.Add([pscustomobject]@{ Where = $Where; Line = $LineNo; Rule = "private-denylist#$($i + 1)" })
        }
    }
}

Push-Location $Root
try {
    $files = git -c core.quotepath=off ls-files -co --exclude-standard
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed; run inside the repository.' }
    foreach ($rel in $files) {
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $bytes = [IO.File]::ReadAllBytes($full)
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }   # binary
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $n = 0
        foreach ($line in ($text -split "`r?`n")) { $n++; Test-Line $rel $n $line }
    }
    if ($History) {
        $n = 0
        foreach ($line in (git log -p --all --no-color)) {
            $n++
            if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { Test-Line 'git-history' $n $line }
        }
    }
}
finally { Pop-Location }

$scope = if ($History) { 'working tree + history' } else { 'working tree' }
if ($findings.Count -gt 0) {
    $findings | Sort-Object Where, Line | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "Secret scan FAILED: $($findings.Count) finding(s) in $scope. Private deny-list entries: $($private.Count)."
    exit 1
}
Write-Host "Secret scan passed ($scope). Files: $(@($files).Count). Private deny-list entries: $($private.Count)."
exit 0

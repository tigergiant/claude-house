Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = [Console]::OutputEncoding

Import-Module (Join-Path $PSScriptRoot 'lib\House.psm1') -Force

function Show-HouseUsage {
    @(
        'Usage:',
        '  house.ps1 guide  [--json]',
        '  house.ps1 step   <id> [--json]',
        '  house.ps1 check  <id> [--json] [--config <path>]',
        '  house.ps1 next   [--json] [--config <path>]',
        '  house.ps1 doctor [--json] [--config <path>]',
        '  house.ps1 preflight [--json] [--config <path>]'
    ) | Write-Output
}

function Write-HouseJson {
    param($InputObject)
    ConvertTo-Json -InputObject $InputObject -Depth 6 -Compress | Write-Output
}

function ConvertTo-HousePublicResult {
    param($Result)
    $names = @($Result.PSObject.Properties.Name)
    $public = [ordered]@{
        id     = [string]$Result.id
        ok     = [bool]$Result.ok
        status = [string]$Result.status
        detail = [string]$Result.detail
    }
    if ($names -contains 'fix' -and $Result.fix) { $public.fix = [string]$Result.fix }
    if ($names -contains 'evidence' -and $null -ne $Result.evidence) { $public.evidence = $Result.evidence }
    if ($names -contains 'ms') { $public.ms = [int]$Result.ms }
    return $public
}

function Get-HouseStatusWord {
    param([string]$Status)
    switch ($Status) {
        'pass' { return 'PASS' }
        'fail' { return 'FAIL' }
        'blocked' { return 'BLOCKED' }
        default { return 'FAIL' }
    }
}

$wantJson = $false
$configArg = $null
$positionals = New-Object System.Collections.Generic.List[string]
$badArgs = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    $token = [string]$args[$i]
    if ($token -eq '--json') { $wantJson = $true; continue }
    if ($token -eq '--config') {
        if (($i + 1) -ge $args.Count) { $badArgs = $true; break }
        $i++
        $configArg = [string]$args[$i]
        continue
    }
    if ($token.StartsWith('-')) { $badArgs = $true; break }
    $positionals.Add($token)
}

if ($badArgs -or $positionals.Count -lt 1) {
    Show-HouseUsage
    exit 2
}

$verb = $positionals[0]
$known = @('guide', 'step', 'check', 'next', 'doctor', 'preflight')
if ($known -notcontains $verb) {
    Show-HouseUsage
    exit 2
}
if ($verb -eq 'step' -or $verb -eq 'check') {
    if ($positionals.Count -ne 2) {
        Show-HouseUsage
        exit 2
    }
}
elseif ($positionals.Count -ne 1) {
    Show-HouseUsage
    exit 2
}

$repoRoot = Get-HouseRepoRoot
$steps = @(Get-HouseSteps -RepoRoot $repoRoot)

function Get-HouseStepById {
    param([string]$StepId)
    foreach ($candidate in $steps) {
        if ($candidate.Id -eq $StepId) { return $candidate }
    }
    return $null
}

function Get-HouseRunContext {
    $params = @{ RepoRoot = $repoRoot }
    if ($configArg) { $params['ConfigPath'] = $configArg }
    return New-HouseContext @params
}

if ($verb -eq 'guide') {
    if ($wantJson) {
        $payload = @()
        foreach ($step in $steps) {
            $payload += [ordered]@{
                order    = [int]$step.Order
                id       = [string]$step.Id
                title    = [string]$step.Title
                runs_on  = [string]$step.RunsOn
                admin    = [bool]$step.Admin
                reboot   = [bool]$step.Reboot
                human    = [bool]$step.Human
                requires = @([string[]]$step.Requires)
                page     = [string]$step.PagePath
            }
        }
        Write-HouseJson -InputObject ([ordered]@{
            note  = 'Run preflight first, before step 0.'
            steps = @($payload)
        })
    }
    else {
        Write-Output 'Run preflight first, before step 0.'
        $rows = @()
        foreach ($step in $steps) {
            $rows += [pscustomobject]@{
                '#'       = $step.Order
                id        = $step.Id
                title     = $step.Title
                runs_on   = $step.RunsOn
                admin     = $step.Admin
                human     = $step.Human
                requires  = (@($step.Requires) -join ',')
            }
        }
        $rows | Format-Table -AutoSize | Out-String -Width 4096 | Write-Output
    }
    exit 0
}

if ($verb -eq 'step') {
    $step = Get-HouseStepById -StepId $positionals[1]
    if ($null -eq $step) {
        Show-HouseUsage
        exit 2
    }
    $pageFile = Join-Path $repoRoot (($step.PagePath -replace '/', '\'))
    $content = [System.IO.File]::ReadAllText($pageFile)
    $ctx = Get-HouseRunContext
    $content = Format-HousePage -Content $content -Config $ctx.Config
    if ($wantJson) {
        Write-HouseJson -InputObject ([ordered]@{
            id      = [string]$step.Id
            page    = [string]$step.PagePath
            content = $content
        })
    }
    else {
        Write-Output $content
    }
    exit 0
}

if ($verb -eq 'preflight') {
    $ctx = Get-HouseRunContext
    $scriptPath = Join-Path $repoRoot 'checks\preflight.ps1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = @(& $scriptPath -Context $ctx)
    $sw.Stop()
    $ms = [int]$sw.Elapsed.TotalMilliseconds
    if ($output.Count -ne 1) {
        if ($wantJson) {
            Write-HouseJson -InputObject ([ordered]@{
                id     = 'preflight'
                ok     = $false
                status = 'fail'
                detail = 'invalid check result'
                ms     = $ms
            })
        }
        else {
            Write-Output 'VERDICT not compatible (1 blockers)'
        }
        exit 1
    }
    $result = $output[0]
    $items = @()
    $propNames = @($result.PSObject.Properties.Name)
    if ($propNames -contains 'evidence' -and $null -ne $result.evidence) {
        $evidenceNames = @($result.evidence.PSObject.Properties.Name)
        if ($evidenceNames -contains 'items') { $items = @($result.evidence.items) }
    }
    if ($wantJson) {
        $copy = [ordered]@{
            id     = [string]$result.id
            ok     = [bool]$result.ok
            status = [string]$result.status
            detail = [string]$result.detail
        }
        if ($propNames -contains 'fix' -and $result.fix) { $copy.fix = [string]$result.fix }
        if ($propNames -contains 'evidence' -and $null -ne $result.evidence) { $copy.evidence = $result.evidence }
        $copy.ms = $ms
        Write-HouseJson -InputObject $copy
    }
    else {
        foreach ($item in $items) {
            $label = 'INFO'
            if ([string]$item.level -eq 'blocker') { $label = 'BLOCKER' }
            elseif ([string]$item.level -eq 'fixable' -and [bool]$item.ok) { $label = 'OK' }
            elseif ([string]$item.level -eq 'fixable') { $label = 'FIXABLE' }
            Write-Output ('{0} {1}: {2}' -f $label, [string]$item.name, [string]$item.value)
        }
        $blockerCount = 0
        foreach ($item in $items) {
            if ([string]$item.level -eq 'blocker') { $blockerCount++ }
        }
        if ([bool]$result.ok) { Write-Output 'VERDICT compatible' }
        else { Write-Output ('VERDICT not compatible ({0} blockers)' -f $blockerCount) }
    }
    if ([bool]$result.ok) { exit 0 }
    exit 1
}

$ctx = Get-HouseRunContext
$cache = @{}

if ($verb -eq 'check') {
    $step = Get-HouseStepById -StepId $positionals[1]
    if ($null -eq $step) {
        Show-HouseUsage
        exit 2
    }
    $result = Invoke-HouseStepStatus -Id $step.Id -Context $ctx -Cache $cache
    if ($wantJson) {
        Write-HouseJson -InputObject (ConvertTo-HousePublicResult -Result $result)
    }
    else {
        $word = Get-HouseStatusWord -Status $result.status
        Write-Output ("{0} {1}: {2}" -f $word, $result.id, $result.detail)
        $names = @($result.PSObject.Properties.Name)
        if ($names -contains 'fix' -and $result.fix) {
            Write-Output ("fix: {0}" -f $result.fix)
        }
    }
    if ($result.status -eq 'pass') { exit 0 }
    if ($result.status -eq 'blocked') { exit 3 }
    exit 1
}

if ($verb -eq 'next') {
    $next = $null
    $nextStep = $null
    foreach ($step in $steps) {
        $status = Invoke-HouseStepStatus -Id $step.Id -Context $ctx -Cache $cache
        if ([string]$status.status -ne 'pass') {
            $next = $status
            $nextStep = $step
            break
        }
    }
    if ($null -eq $next) {
        if ($wantJson) { Write-HouseJson -InputObject ([ordered]@{ done = $true }) }
        Write-Output 'ALL DONE'
        exit 0
    }
    if ($wantJson) {
        $body = [ordered]@{
            id     = [string]$nextStep.Id
            title  = [string]$nextStep.Title
            page   = [string]$nextStep.PagePath
            status = [string]$next.status
            detail = [string]$next.detail
        }
        $names = @($next.PSObject.Properties.Name)
        if ($names -contains 'fix' -and $next.fix) { $body.fix = [string]$next.fix }
        Write-HouseJson -InputObject ([ordered]@{ done = $false; next = $body })
    }
    else {
        Write-Output ("NEXT {0} ({1}) -> {2}" -f $nextStep.Id, $nextStep.Title, $nextStep.PagePath)
        Write-Output ([string]$next.detail)
    }
    exit 1
}

$results = @()
foreach ($step in $steps) {
    $results += Invoke-HouseStepStatus -Id $step.Id -Context $ctx -Cache $cache
}

$pass = 0
$fail = 0
$blocked = 0
foreach ($result in $results) {
    if ($result.status -eq 'pass') { $pass++ }
    elseif ($result.status -eq 'blocked') { $blocked++ }
    else { $fail++ }
}
if ($wantJson) {
    $publicResults = @()
    foreach ($result in $results) { $publicResults += ConvertTo-HousePublicResult -Result $result }
    Write-HouseJson -InputObject ([ordered]@{
        results = @($publicResults)
        summary = [ordered]@{ pass = $pass; fail = $fail; blocked = $blocked }
    })
}
else {
    foreach ($result in $results) {
        $word = Get-HouseStatusWord -Status $result.status
        Write-Output ("{0} {1}: {2}" -f $word, $result.id, $result.detail)
    }
    Write-Output ("SUMMARY pass={0} fail={1} blocked={2}" -f $pass, $fail, $blocked)
}
if ($fail -eq 0 -and $blocked -eq 0) { exit 0 }
exit 1

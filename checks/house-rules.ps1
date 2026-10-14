param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/12-house-rules.md#if-it-fails'

function ConvertTo-HouseRulesResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'house-rules'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-HouseRulesEvidence {
    param(
        [bool]$ClaudeMd,
        [bool]$Roots,
        [bool]$Hooks,
        [bool]$Winshell = $false
    )
    return [pscustomobject]@{
        claudemd = $ClaudeMd
        roots    = $Roots
        hooks    = $Hooks
        winshell = $Winshell
    }
}

function Get-HouseRulesProbe {
    $body = @'
param([string]$NamesJson)
$ErrorActionPreference = 'Stop'

function Get-HouseProbeHash {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $normal = $Text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd()
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8.GetBytes($normal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) { [void]$builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hooksDir = Join-Path $claudeDir 'hooks'
$claudePath = Join-Path $claudeDir 'CLAUDE.md'
$exists = Test-Path -LiteralPath $claudePath
$blockCount = 0
$blockHash = ''
if ($exists) {
    $text = [System.IO.File]::ReadAllText($claudePath)
    $begin = '<!-- claude-house:begin -->'
    $end = '<!-- claude-house:end -->'
    $searchFrom = 0
    $first = ''
    while ($searchFrom -lt $text.Length) {
        $at = $text.IndexOf($begin, $searchFrom)
        if ($at -lt 0) { break }
        $stop = $text.IndexOf($end, $at + $begin.Length)
        if ($stop -lt 0) { break }
        $blockCount++
        if ($blockCount -eq 1) { $first = $text.Substring($at, ($stop + $end.Length) - $at) }
        $searchFrom = $stop + $end.Length
    }
    if ($first) { $blockHash = Get-HouseProbeHash -Text $first }
}
$rootsPath = Join-Path $hooksDir 'house-roots.json'
$rootsHash = ''
if (Test-Path -LiteralPath $rootsPath) {
    $rootsHash = Get-HouseProbeHash -Text ([System.IO.File]::ReadAllText($rootsPath))
}
$names = @()
if ($NamesJson) {
    $parsed = ConvertFrom-Json -InputObject $NamesJson
    foreach ($name in @($parsed)) {
        if ($null -ne $name -and [string]$name) { $names += [string]$name }
    }
}
$hookRows = New-Object System.Collections.Generic.List[object]
foreach ($name in $names) {
    $file = Join-Path $hooksDir ('house-' + $name + '.ps1')
    $fileHash = ''
    if (Test-Path -LiteralPath $file) { $fileHash = Get-HouseProbeHash -Text ([System.IO.File]::ReadAllText($file)) }
    $hookRows.Add([pscustomobject]@{ name = $name; hash = $fileHash })
}
$settingsOk = $true
$settingsError = ''
$commands = New-Object System.Collections.Generic.List[string]
$entryRows = New-Object System.Collections.Generic.List[object]
$pythonUtf8 = ''
$pythonIo = ''
$pwshTool = ''
$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $settings = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($settingsPath))
        $pre = $null
        if ($null -ne $settings) {
            $envProp = $settings.PSObject.Properties['env']
            if ($null -ne $envProp -and $null -ne $envProp.Value) {
                $envNode = $envProp.Value
                $utfProp = $envNode.PSObject.Properties['PYTHONUTF8']
                if ($null -ne $utfProp -and $null -ne $utfProp.Value) { $pythonUtf8 = [string]$utfProp.Value }
                $ioProp = $envNode.PSObject.Properties['PYTHONIOENCODING']
                if ($null -ne $ioProp -and $null -ne $ioProp.Value) { $pythonIo = [string]$ioProp.Value }
                $psProp = $envNode.PSObject.Properties['CLAUDE_CODE_USE_POWERSHELL_TOOL']
                if ($null -ne $psProp -and $null -ne $psProp.Value) { $pwshTool = [string]$psProp.Value }
            }
            $hooksProp = $settings.PSObject.Properties['hooks']
            if ($null -ne $hooksProp -and $null -ne $hooksProp.Value) {
                $preProp = $hooksProp.Value.PSObject.Properties['PreToolUse']
                if ($null -ne $preProp) { $pre = $preProp.Value }
            }
        }
        foreach ($entry in @($pre)) {
            if ($null -eq $entry) { continue }
            $matcher = ''
            $matcherProp = $entry.PSObject.Properties['matcher']
            if ($null -ne $matcherProp -and $null -ne $matcherProp.Value) { $matcher = [string]$matcherProp.Value }
            $inner = $null
            $innerProp = $entry.PSObject.Properties['hooks']
            if ($null -ne $innerProp) { $inner = $innerProp.Value }
            foreach ($hook in @($inner)) {
                if ($null -eq $hook) { continue }
                $commandText = ''
                $commandProp = $hook.PSObject.Properties['command']
                if ($null -ne $commandProp -and $null -ne $commandProp.Value) { $commandText = [string]$commandProp.Value }
                if ($commandText) { $commands.Add($commandText) }
                $timeoutText = ''
                $timeoutProp = $hook.PSObject.Properties['timeout']
                if ($null -ne $timeoutProp -and $null -ne $timeoutProp.Value) { $timeoutText = [string]$timeoutProp.Value }
                $entryRows.Add([pscustomobject]@{ matcher = $matcher; command = $commandText; timeout = $timeoutText })
            }
        }
    }
    catch {
        $settingsOk = $false
        $settingsError = [string]$_.Exception.Message
        if (-not $settingsError) { $settingsError = 'settings.json did not parse' }
    }
}
$gitLongpaths = ''
$gitQuotepath = ''
$longPathsEnabled = ''
$gitCommand = Get-Command -Name 'git' -ErrorAction SilentlyContinue
if ($null -ne $gitCommand -and $gitCommand.Source) {
    $gitFile = [string]$gitCommand.Source
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $gitLongpaths = ([string](& $gitFile config --global --get core.longpaths)).Trim() } catch { $gitLongpaths = '' }
    try { $gitQuotepath = ([string](& $gitFile config --global --get core.quotepath)).Trim() } catch { $gitQuotepath = '' }
    $ErrorActionPreference = $savedPreference
}
try {
    $longItem = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop
    $longPathsEnabled = [string]$longItem.LongPathsEnabled
}
catch { $longPathsEnabled = '' }
return [pscustomobject]@{
    claudeExists      = [bool]$exists
    blockCount        = [int]$blockCount
    blockHash         = [string]$blockHash
    rootsHash         = [string]$rootsHash
    hooks             = @($hookRows.ToArray())
    settingsOk        = [bool]$settingsOk
    settingsError     = [string]$settingsError
    commands          = @($commands.ToArray())
    entries           = @($entryRows.ToArray())
    pythonUtf8        = [string]$pythonUtf8
    pythonIo          = [string]$pythonIo
    pwshTool          = [string]$pwshTool
    gitLongpaths      = [string]$gitLongpaths
    gitQuotepath      = [string]$gitQuotepath
    longPathsEnabled  = [string]$longPathsEnabled
    error             = $null
}
'@
    return [scriptblock]::Create($body)
}

function ConvertTo-HouseRulesNameJson {
    param([string[]]$Names)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Names)) {
        if ($name) { $parts.Add('"' + ([string]$name).Replace('\', '\\').Replace('"', '\"') + '"') }
    }
    return '[' + ($parts.ToArray() -join ',') + ']'
}

function Find-HouseRulesHookHash {
    param($Rows, [string]$Name)
    foreach ($row in (ConvertTo-HouseItemList -Value $Rows)) {
        $rowName = [string](Get-HousePropertyValue -Object $row -Name 'name')
        if ($rowName -eq $Name) { return [string](Get-HousePropertyValue -Object $row -Name 'hash') }
    }
    return ''
}

$empty = ConvertTo-HouseRulesEvidence -ClaudeMd $false -Roots $false -Hooks $false
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-HouseRulesResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$repoRoot = ''
if ($Context.ContainsKey('RepoRoot') -and $Context['RepoRoot']) { $repoRoot = [string]$Context['RepoRoot'] }
if (-not $repoRoot) { $repoRoot = Get-HouseRepoRoot }
$house = Get-HousePropertyValue -Object $config -Name 'House'
$userName = [string](Get-HousePropertyValue -Object $house -Name 'UserName')
$selection = Get-HouseHookSelection -Config $config
$selected = @(Get-HousePropertyValue -Object $selection -Name 'Selected')
$unknown = @(Get-HousePropertyValue -Object $selection -Name 'Unknown')
$known = @(Get-HouseKnownHookNames)
$expectedBlock = ConvertTo-HouseRulesHash -Text (Format-HouseRulesBlock -Config $config)
$expectedRoots = ConvertTo-HouseRulesHash -Text (Format-HouseRootsJson -Config $config)
$expectedHooks = @{}
foreach ($name in $selected) {
    if (-not $name) { continue }
    $file = Join-Path (Join-Path $repoRoot 'rules\hooks') ('house-' + [string]$name + '.ps1')
    if (Test-Path -LiteralPath $file) {
        $expectedHooks[[string]$name] = ConvertTo-HouseRulesHash -Text ([System.IO.File]::ReadAllText($file))
    }
    else {
        $expectedHooks[[string]$name] = $null
    }
}

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-HouseRulesProbe
    $namesJson = ConvertTo-HouseRulesNameJson -Names $selected
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @($namesJson)
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add($guestError) }
$claudeOk = $false
$rootsOk = $false
$hooksOk = $false
if ($null -ne $guest) {
    $observed = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observed) { $notes.Add($observed) }
    $existsValue = Get-HousePropertyValue -Object $guest -Name 'claudeExists'
    $exists = ($existsValue -eq $true) -or ([string]$existsValue -eq 'True')
    $countText = [string](Get-HousePropertyValue -Object $guest -Name 'blockCount')
    $blockCount = 0
    if ($countText -match '^\d+$') { $blockCount = [int]$countText }
    $blockHash = [string](Get-HousePropertyValue -Object $guest -Name 'blockHash')
    $claudeOk = $exists -and ($blockCount -eq 1) -and ($blockHash -eq $expectedBlock)
    if (-not $exists) { $notes.Add('claudemd missing') }
    elseif ($blockCount -ne 1) { $notes.Add('claudemd blocks ' + $blockCount) }
    elseif ($blockHash -ne $expectedBlock) { $notes.Add('claudemd hash') }
    $rootsHash = [string](Get-HousePropertyValue -Object $guest -Name 'rootsHash')
    $rootsOk = ($rootsHash -eq $expectedRoots) -and ($rootsHash -ne '')
    if (-not $rootsOk) { $notes.Add('roots hash') }
    $settingsValue = Get-HousePropertyValue -Object $guest -Name 'settingsOk'
    $settingsOk = ($settingsValue -eq $true) -or ([string]$settingsValue -eq 'True')
    $settingsError = [string](Get-HousePropertyValue -Object $guest -Name 'settingsError')
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($command in (ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'commands'))) {
        if ($null -ne $command -and [string]$command) { $commands.Add([string]$command) }
    }
    $guestHooks = Get-HousePropertyValue -Object $guest -Name 'hooks'
    $hookNotes = New-Object System.Collections.Generic.List[string]
    foreach ($name in $unknown) {
        if ($name) { $hookNotes.Add('unknown hook ' + [string]$name) }
    }
    if (-not $settingsOk) {
        if (-not $settingsError) { $settingsError = 'settings.json did not parse' }
        $hookNotes.Add($settingsError)
    }
    else {
        foreach ($name in $selected) {
            if (-not $name) { continue }
            $hookName = [string]$name
            if (-not $expectedHooks.ContainsKey($hookName) -or $null -eq $expectedHooks[$hookName]) {
                $hookNotes.Add('missing hook script ' + $hookName)
            }
            else {
                $actual = Find-HouseRulesHookHash -Rows $guestHooks -Name $hookName
                if ($actual -ne [string]$expectedHooks[$hookName]) { $hookNotes.Add($hookName + ' hash') }
            }
            $want = Get-HouseHookCommandLine -UserName $userName -HookName $hookName
            $wantMatcher = Get-HouseHookMatcher -Name $hookName
            $registered = $false
            $matcherOk = $false
            $timeoutOk = $false
            $entries = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'entries')
            foreach ($entry in $entries) {
                $command = [string](Get-HousePropertyValue -Object $entry -Name 'command')
                if ($command -ne $want) { continue }
                $registered = $true
                $matcher = [string](Get-HousePropertyValue -Object $entry -Name 'matcher')
                if ($matcher -eq $wantMatcher) { $matcherOk = $true }
                $timeoutText = [string](Get-HousePropertyValue -Object $entry -Name 'timeout')
                if ($timeoutText -eq '10') { $timeoutOk = $true }
            }
            if (-not $registered) { $hookNotes.Add($hookName + ' not registered') }
            elseif (-not $matcherOk) { $hookNotes.Add($hookName + ' matcher') }
            elseif (-not $timeoutOk) { $hookNotes.Add($hookName + ' timeout') }
        }
        foreach ($name in $known) {
            $chosen = $false
            foreach ($selectedName in $selected) {
                if ([string]$selectedName -eq [string]$name) { $chosen = $true }
            }
            if ($chosen) { continue }
            $needle = '/.claude/hooks/house-' + [string]$name + '.ps1'
            foreach ($command in $commands) {
                if ($command.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $hookNotes.Add([string]$name + ' still registered')
                }
            }
        }
    }
    $hooksOk = ($hookNotes.Count -eq 0)
    foreach ($note in $hookNotes) { $notes.Add([string]$note) }
}

$winshellOk = $false
$winshellNote = ''
if ($null -ne $guest) {
    $winshellRows = @(
        @{ Name = 'PYTHONUTF8'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'pythonUtf8'); Want = '1'; Loose = $false },
        @{ Name = 'PYTHONIOENCODING'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'pythonIo'); Want = 'utf-8'; Loose = $false },
        @{ Name = 'CLAUDE_CODE_USE_POWERSHELL_TOOL'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'pwshTool'); Want = '1'; Loose = $false },
        @{ Name = 'core.longpaths'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'gitLongpaths'); Want = 'true'; Loose = $true },
        @{ Name = 'core.quotepath'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'gitQuotepath'); Want = 'false'; Loose = $true },
        @{ Name = 'LongPathsEnabled'; Actual = [string](Get-HousePropertyValue -Object $guest -Name 'longPathsEnabled'); Want = '1'; Loose = $false }
    )
    $winshellOk = $true
    foreach ($row in $winshellRows) {
        $same = $false
        if ($row['Loose']) { $same = [string]::Equals([string]$row['Actual'], [string]$row['Want'], [System.StringComparison]::OrdinalIgnoreCase) }
        else { $same = ([string]$row['Actual'] -eq [string]$row['Want']) }
        if (-not $same) {
            $winshellOk = $false
            $winshellNote = [string]$row['Name']
            break
        }
    }
}
if ($winshellNote) { $notes.Add($winshellNote) }

$failing = New-Object System.Collections.Generic.List[string]
if (-not $claudeOk) { $failing.Add('claudemd') }
if (-not $rootsOk) { $failing.Add('roots') }
if (-not $hooksOk) { $failing.Add('hooks') }
if (-not $winshellOk) { $failing.Add('winshell') }
$detail = 'house rules ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
$clean = New-Object System.Collections.Generic.List[string]
foreach ($note in @($notes.ToArray())) {
    if ($note) { $clean.Add([string]$note) }
}
if ($clean.Count -gt 0) {
    $suffix = ($clean.ToArray() -join '; ')
    if ($suffix.Length -gt 1500) { $suffix = $suffix.Substring(0, 1500) }
    if ($failing.Count -eq 0) { $detail = $suffix }
    else { $detail = $detail + '; ' + $suffix }
}
$evidence = ConvertTo-HouseRulesEvidence -ClaudeMd $claudeOk -Roots $rootsOk -Hooks $hooksOk -Winshell $winshellOk
return (ConvertTo-HouseRulesResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence $evidence)

param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/09-tools.md#if-it-fails'

function ConvertTo-ToolsResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'tools'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function Test-ToolsFlag {
    param($Tools, [string]$Name)
    $value = Get-HousePropertyValue -Object $Tools -Name $Name
    if ($value -eq $true) { return $true }
    if ([string]$value -eq 'True') { return $true }
    return $false
}

function Get-ToolsProbe {
    return {
        param([string]$WantPython, [string]$WantNode, [string]$WantClaudeDesktop, [string]$WantGitHubCli, [string]$WantVSCode)
        $ErrorActionPreference = 'Stop'

        function Read-HouseToolVersion {
            param([string]$File)
            $output = ''
            $ok = $false
            $errorText = ''
            try {
                $output = @(& $File '--version' 2>&1 | ForEach-Object { "$_" }) -join "`n"
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                    $errorText = 'exit ' + [string]$LASTEXITCODE
                }
                else {
                    $ok = $true
                }
            }
            catch {
                $errorText = [string]$_.Exception.Message
                $ok = $false
            }
            $version = ''
            $trimmed = $output.Trim()
            if ($trimmed) {
                $version = [string]@($trimmed -split "`r?`n")[0]
            }
            if ($version.Length -gt 200) { $version = $version.Substring(0, 200) }
            if ($ok -and -not $version) {
                $ok = $false
                if (-not $errorText) { $errorText = 'no version' }
            }
            return [pscustomobject]@{ ok = [bool]$ok; version = [string]$version; error = [string]$errorText }
        }

        function Find-HouseTool {
            param([string]$Name, [string]$Fallback)
            $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $command -and $command.Source) { return [string]$command.Source }
            if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
            return ''
        }

        function ConvertTo-HouseToolRow {
            param([string]$File, [string]$Missing)
            if (-not $File) {
                return [pscustomobject]@{ ok = $false; version = ''; error = $Missing }
            }
            return Read-HouseToolVersion -File $File
        }

        $gitFile = Find-HouseTool -Name 'git' -Fallback ''
        $claudeFallback = Join-Path (Join-Path $env:USERPROFILE '.local') 'bin\claude.exe'
        $claudeFile = Find-HouseTool -Name 'claude' -Fallback $claudeFallback
        # The human runs `claude` from a new terminal in step 14, so the install folder must be on the saved PATH, not only findable by its full path.
        $claudeBin = (Split-Path -Parent $claudeFallback).TrimEnd('\')
        $claudeOnPath = $false
        foreach ($scope in 'User', 'Machine') {
            foreach ($entry in @(([string][Environment]::GetEnvironmentVariable('Path', $scope)) -split ';')) {
                if ($entry -and ($entry.Trim().TrimEnd('\') -eq $claudeBin)) { $claudeOnPath = $true }
            }
        }
        $git = ConvertTo-HouseToolRow -File $gitFile -Missing 'git not found'
        $claude = ConvertTo-HouseToolRow -File $claudeFile -Missing 'claude not found'
        $python = $null
        $node = $null
        if ($WantPython -eq 'True') {
            $pythonFile = Find-HouseTool -Name 'python' -Fallback ''
            $python = ConvertTo-HouseToolRow -File $pythonFile -Missing 'python not found'
        }
        if ($WantNode -eq 'True') {
            $nodeFile = Find-HouseTool -Name 'node' -Fallback ''
            $node = ConvertTo-HouseToolRow -File $nodeFile -Missing 'node not found'
        }
        $desktop = $null
        $gh = $null
        $vscode = $null
        if ($WantClaudeDesktop -eq 'True') {
            $desktopPackage = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
            $desktopVersion = ''
            if ($null -ne $desktopPackage) { $desktopVersion = [string]$desktopPackage.Version }
            if ($desktopVersion) {
                $desktop = [pscustomobject]@{ ok = $true; version = $desktopVersion; error = '' }
            }
            else {
                $desktop = [pscustomobject]@{ ok = $false; version = ''; error = 'Claude desktop package not found' }
            }
        }
        if ($WantGitHubCli -eq 'True') {
            $ghFile = Find-HouseTool -Name 'gh' -Fallback ''
            $gh = ConvertTo-HouseToolRow -File $ghFile -Missing 'gh not found'
        }
        if ($WantVSCode -eq 'True') {
            $vscodeFile = Find-HouseTool -Name 'code' -Fallback (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
            $vscode = ConvertTo-HouseToolRow -File $vscodeFile -Missing 'code not found'
        }
        return [pscustomobject]@{
            git    = $git
            claude = $claude
            claudeOnPath = [bool]$claudeOnPath
            python = $python
            node   = $node
            desktop = $desktop
            gh      = $gh
            vscode  = $vscode
            error  = $null
        }
    }.GetNewClosure()
}

$empty = [pscustomobject]@{
    git          = $false
    gitVersion   = ''
    claude       = $false
    claudeVersion = ''
    claudePath   = $false
}
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-ToolsResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$wantPython = Test-ToolsFlag -Tools (Get-HousePropertyValue -Object $config -Name 'Tools') -Name 'Python'
$wantNode = Test-ToolsFlag -Tools (Get-HousePropertyValue -Object $config -Name 'Tools') -Name 'Node'
$wantClaudeDesktop = Test-ToolsFlag -Tools (Get-HousePropertyValue -Object $config -Name 'Tools') -Name 'ClaudeDesktop'
$wantGitHubCli = Test-ToolsFlag -Tools (Get-HousePropertyValue -Object $config -Name 'Tools') -Name 'GitHubCli'
$wantVSCode = Test-ToolsFlag -Tools (Get-HousePropertyValue -Object $config -Name 'Tools') -Name 'VSCode'
$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-ToolsProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @(
        $(if ($wantPython) { 'True' } else { 'False' }),
        $(if ($wantNode) { 'True' } else { 'False' }),
        $(if ($wantClaudeDesktop) { 'True' } else { 'False' }),
        $(if ($wantGitHubCli) { 'True' } else { 'False' }),
        $(if ($wantVSCode) { 'True' } else { 'False' })
    )
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

function ConvertTo-ToolsItem {
    param($Row)
    $ok = $false
    $version = ''
    $errorText = ''
    if ($null -ne $Row) {
        $okValue = Get-HousePropertyValue -Object $Row -Name 'ok'
        $ok = ($okValue -eq $true) -or ([string]$okValue -eq 'True')
        $version = [string](Get-HousePropertyValue -Object $Row -Name 'version')
        $errorText = [string](Get-HousePropertyValue -Object $Row -Name 'error')
        if ($ok -and -not $version) { $ok = $false }
    }
    return [pscustomobject]@{ ok = [bool]$ok; version = $version; error = $errorText }
}

$gitItem = ConvertTo-ToolsItem -Row $null
$claudeItem = ConvertTo-ToolsItem -Row $null
$pythonItem = ConvertTo-ToolsItem -Row $null
$nodeItem = ConvertTo-ToolsItem -Row $null
$desktopItem = ConvertTo-ToolsItem -Row $null
$ghItem = ConvertTo-ToolsItem -Row $null
$vscodeItem = ConvertTo-ToolsItem -Row $null
$claudeOnPath = $false
$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add($guestError) }
if ($null -ne $guest) {
    $observed = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observed) { $notes.Add($observed) }
    $gitItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'git')
    $claudeItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'claude')
    $onPathValue = Get-HousePropertyValue -Object $guest -Name 'claudeOnPath'
    $claudeOnPath = ($onPathValue -eq $true) -or ([string]$onPathValue -eq 'True')
    if ($wantPython) { $pythonItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'python') }
    if ($wantNode) { $nodeItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'node') }
    if ($wantClaudeDesktop) { $desktopItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'desktop') }
    if ($wantGitHubCli) { $ghItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'gh') }
    if ($wantVSCode) { $vscodeItem = ConvertTo-ToolsItem -Row (Get-HousePropertyValue -Object $guest -Name 'vscode') }
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $gitItem.ok) { $failing.Add('git') }
if (-not $claudeItem.ok) { $failing.Add('claude') }
elseif (-not $claudeOnPath) { $failing.Add('claudePath') }
if ($wantPython -and -not $pythonItem.ok) { $failing.Add('python') }
if ($wantNode -and -not $nodeItem.ok) { $failing.Add('node') }
if ($wantClaudeDesktop -and -not $desktopItem.ok) { $failing.Add('desktop') }
if ($wantGitHubCli -and -not $ghItem.ok) { $failing.Add('gh') }
if ($wantVSCode -and -not $vscodeItem.ok) { $failing.Add('vscode') }
foreach ($item in @($gitItem, $claudeItem)) {
    if (-not $item.ok -and $item.error) { $notes.Add($item.error) }
}
if ($wantPython -and -not $pythonItem.ok -and $pythonItem.error) { $notes.Add($pythonItem.error) }
if ($wantNode -and -not $nodeItem.ok -and $nodeItem.error) { $notes.Add($nodeItem.error) }
if ($wantClaudeDesktop -and -not $desktopItem.ok -and $desktopItem.error) { $notes.Add($desktopItem.error) }
if ($wantGitHubCli -and -not $ghItem.ok -and $ghItem.error) { $notes.Add($ghItem.error) }
if ($wantVSCode -and -not $vscodeItem.ok -and $vscodeItem.error) { $notes.Add($vscodeItem.error) }

$evidence = [ordered]@{
    git           = [bool]$gitItem.ok
    gitVersion    = [string]$gitItem.version
    claude        = [bool]$claudeItem.ok
    claudeVersion = [string]$claudeItem.version
    claudePath    = [bool]$claudeOnPath
}
if ($wantPython) {
    $evidence['python'] = [bool]$pythonItem.ok
    $evidence['pythonVersion'] = [string]$pythonItem.version
}
if ($wantNode) {
    $evidence['node'] = [bool]$nodeItem.ok
    $evidence['nodeVersion'] = [string]$nodeItem.version
}
if ($wantClaudeDesktop) {
    $evidence['desktop'] = [bool]$desktopItem.ok
    $evidence['desktopVersion'] = [string]$desktopItem.version
}
if ($wantGitHubCli) {
    $evidence['gh'] = [bool]$ghItem.ok
    $evidence['ghVersion'] = [string]$ghItem.version
}
if ($wantVSCode) {
    $evidence['vscode'] = [bool]$vscodeItem.ok
    $evidence['vscodeVersion'] = [string]$vscodeItem.version
}

$detail = 'tools ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
$clean = New-Object System.Collections.Generic.List[string]
foreach ($note in @($notes.ToArray())) {
    if ($note) { $clean.Add([string]$note) }
}
if ($clean.Count -gt 0) {
    $suffix = ($clean.ToArray() -join '; ')
    if ($failing.Count -eq 0) { $detail = $suffix }
    else { $detail = $detail + '; ' + $suffix }
}
return (ConvertTo-ToolsResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence ([pscustomobject]$evidence))

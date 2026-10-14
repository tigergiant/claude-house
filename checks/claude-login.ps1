param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/14-claude-login.md#if-it-fails'

function ConvertTo-ClaudeLoginResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'claude-login'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-ClaudeLoginEvidence {
    param(
        [bool]$SignedIn,
        [bool]$Credentials,
        [bool]$ApiKey,
        [bool]$AuthToken,
        [bool]$Claude,
        [string]$ClaudeVersion
    )
    return [pscustomobject]@{
        signedin      = $SignedIn
        credentials   = $Credentials
        apiKey        = $ApiKey
        authToken     = $AuthToken
        claude        = $Claude
        claudeVersion = $ClaudeVersion
    }
}

function Get-ClaudeLoginProbe {
    return {
        $ErrorActionPreference = 'Stop'
        $credOk = $false
        $credPath = Join-Path (Join-Path $env:USERPROFILE '.claude') '.credentials.json'
        if (Test-Path -LiteralPath $credPath) {
            $info = Get-Item -LiteralPath $credPath
            if ($info.Length -gt 0) { $credOk = $true }
        }
        $apiOk = $false
        $apiValue = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'User')
        if (-not [string]::IsNullOrEmpty($apiValue)) { $apiOk = $true }
        # Third-party Anthropic-compatible endpoints (for example DeepSeek) use a bearer token instead.
        $tokenOk = $false
        $tokenValue = [Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')
        if (-not [string]::IsNullOrEmpty($tokenValue)) { $tokenOk = $true }
        $apiValue = $null
        $tokenValue = $null

        function Read-HouseClaudeVersion {
            param([string]$File)
            $output = ''
            $ok = $false
            $errorText = ''
            try {
                $output = @(& $File '--version' 2>&1 | ForEach-Object { "$_" }) -join "`n"
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $errorText = 'exit ' + [string]$LASTEXITCODE }
                else { $ok = $true }
            }
            catch {
                $errorText = [string]$_.Exception.Message
                $ok = $false
            }
            $version = ''
            $trimmed = $output.Trim()
            if ($trimmed) { $version = [string]@($trimmed -split "`r?`n")[0] }
            if ($version.Length -gt 200) { $version = $version.Substring(0, 200) }
            if ($ok -and -not $version) {
                $ok = $false
                if (-not $errorText) { $errorText = 'no version' }
            }
            return [pscustomobject]@{ ok = [bool]$ok; version = [string]$version; error = [string]$errorText }
        }

        $claudeFallback = Join-Path (Join-Path $env:USERPROFILE '.local') 'bin\claude.exe'
        $claudeFile = ''
        $command = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
        if ($null -ne $command -and $command.Source) { $claudeFile = [string]$command.Source }
        elseif ($claudeFallback -and (Test-Path -LiteralPath $claudeFallback)) { $claudeFile = $claudeFallback }
        if (-not $claudeFile) {
            $claude = [pscustomobject]@{ ok = $false; version = ''; error = 'claude not found' }
        }
        else {
            $claude = Read-HouseClaudeVersion -File $claudeFile
        }
        return [pscustomobject]@{
            credentials = [bool]$credOk
            apiKey      = [bool]$apiOk
            authToken   = [bool]$tokenOk
            claudeOk    = [bool]$claude.ok
            claudeVersion = [string]$claude.version
            error       = $null
        }
    }.GetNewClosure()
}

function Test-ClaudeLoginFlag {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ([string]$Value -eq 'True') { return $true }
    return $false
}

$empty = ConvertTo-ClaudeLoginEvidence -SignedIn $false -Credentials $false -ApiKey $false -AuthToken $false -Claude $false -ClaudeVersion ''
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-ClaudeLoginResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-ClaudeLoginProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @()
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$credentials = $false
$apiKey = $false
$authToken = $false
$claudeOk = $false
$claudeVersion = ''
$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add('guest probe failed') }
if ($null -ne $guest) {
    $credentials = Test-ClaudeLoginFlag -Value (Get-HousePropertyValue -Object $guest -Name 'credentials')
    $apiKey = Test-ClaudeLoginFlag -Value (Get-HousePropertyValue -Object $guest -Name 'apiKey')
    $authToken = Test-ClaudeLoginFlag -Value (Get-HousePropertyValue -Object $guest -Name 'authToken')
    $claudeOk = Test-ClaudeLoginFlag -Value (Get-HousePropertyValue -Object $guest -Name 'claudeOk')
    if ($claudeOk) { $claudeVersion = [string](Get-HousePropertyValue -Object $guest -Name 'claudeVersion') }
    $versionError = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($versionError -and $versionError -ne 'claude not found') { $notes.Add('guest probe failed') }
}
$signedIn = $credentials -or $apiKey -or $authToken
if (-not $signedIn) { $notes.Add('credentials=' + $credentials.ToString().ToLowerInvariant() + ' apiKey=' + $apiKey.ToString().ToLowerInvariant() + ' authToken=' + $authToken.ToString().ToLowerInvariant()) }
if (-not $claudeOk) { $notes.Add('claude') }
$failing = New-Object System.Collections.Generic.List[string]
if (-not $signedIn) { $failing.Add('signedin') }
if (-not $claudeOk) { $failing.Add('claude') }
$detail = 'claude login ready'
if ($failing.Count -gt 0) {
    $detail = ($failing.ToArray() -join ', ')
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($note in @($notes.ToArray())) {
        if ($note) { $clean.Add([string]$note) }
    }
    if ($clean.Count -gt 0) { $detail = $detail + '; ' + ($clean.ToArray() -join '; ') }
}
$evidence = ConvertTo-ClaudeLoginEvidence -SignedIn $signedIn -Credentials $credentials -ApiKey $apiKey -AuthToken $authToken -Claude $claudeOk -ClaudeVersion $claudeVersion
return (ConvertTo-ClaudeLoginResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence $evidence)

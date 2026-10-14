$ErrorActionPreference = 'Stop'

function Get-HouseHookTokens {
    param([string]$Command)
    $tokens = New-Object System.Collections.Generic.List[string]
    if (-not $Command) { return @() }
    $buf = New-Object System.Text.StringBuilder
    $quote = [char]0
    foreach ($ch in $Command.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 }
            else { [void]$buf.Append($ch) }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($buf.Length -gt 0) { $tokens.Add($buf.ToString()); $buf.Length = 0 }
            continue
        }
        [void]$buf.Append($ch)
    }
    if ($buf.Length -gt 0) { $tokens.Add($buf.ToString()) }
    return @($tokens.ToArray())
}

function ConvertTo-HouseHookPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $text = $Value.Trim()
    if ($text.Length -ge 2) {
        $head = $text[0]
        $tail = $text[$text.Length - 1]
        if (($head -eq '"' -and $tail -eq '"') -or ($head -eq "'" -and $tail -eq "'")) {
            $text = $text.Substring(1, $text.Length - 2).Trim()
        }
    }
    $text = $text.Replace('/', '\')
    while ($text.Length -gt 1 -and $text.EndsWith('\')) { $text = $text.Substring(0, $text.Length - 1) }
    if ($text -match '^[A-Za-z]:$') { $text = $text + '\' }
    return $text
}

function Test-HouseHookSamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HouseHookParentPath {
    param([string]$Candidate, [string]$Root)
    if (-not $Candidate -or -not $Root) { return $false }
    if (Test-HouseHookSamePath -Left $Candidate -Right $Root) { return $false }
    $prefix = $Candidate
    if (-not $prefix.EndsWith('\')) { $prefix = $prefix + '\' }
    return $Root.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-HouseHookRoots {
    $path = Join-Path $PSScriptRoot 'house-roots.json'
    $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    $roots = New-Object System.Collections.Generic.List[string]
    $items = @()
    if ($null -ne $doc) {
        $prop = $doc.PSObject.Properties['roots']
        if ($null -ne $prop) { $items = @($prop.Value) }
    }
    foreach ($item in $items) {
        $normal = ConvertTo-HouseHookPath -Value ([string]$item)
        if ($normal) { $roots.Add($normal) }
    }
    return @($roots.ToArray())
}

function Test-HouseHookPathLike {
    param([string]$Token)
    if (-not $Token) { return $false }
    if ($Token.StartsWith('\\') -or $Token.StartsWith('//')) { return $true }
    if ($Token -match '^[A-Za-z]:') { return $true }
    if ($Token.StartsWith('-') -or $Token.StartsWith('/')) { return $false }
    if ($Token.Contains('\') -or $Token.Contains('/')) { return $true }
    return $false
}

function Test-HouseHookDelete {
    param([string[]]$Tokens)
    $removeItem = 'Remove-' + 'Item'
    $delete = $false
    $recursive = $false
    foreach ($token in $Tokens) {
        if ($token.Contains('\') -or $token.Contains('/')) { continue }
        $base = $token.ToLowerInvariant()
        if ($base -eq 'rm' -or $base -eq 'rm.exe' -or $base -eq 'ri' -or $base -eq 'del' -or $base -eq 'del.exe' -or $base -eq 'rmdir' -or $base -eq 'rmdir.exe' -or $base -eq 'rd' -or $base -eq $removeItem.ToLowerInvariant()) {
            $delete = $true
        }
    }
    if (-not $delete) { return $false }
    foreach ($token in $Tokens) {
        if ($token -match '^(?i)-Recurse$' -or $token -eq '-r' -or $token -eq '-R' -or $token -eq '--recursive') { $recursive = $true }
        if ($token -match '^-[rfvRFV]+$' -and $token -match '[rR]') { $recursive = $true }
        if ($token -match '^(?i)/s($|/)') { $recursive = $true }
    }
    return $recursive
}

function Write-HouseHookDeleteBlock {
    param([string]$Root)
    [Console]::Error.WriteLine('Refusing recursive delete of ' + $Root)
    exit 2
}

try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
    $raw = [Console]::In.ReadToEnd()
    # A sender may prefix a byte order mark; ConvertFrom-Json rejects it.
    $raw = $raw.TrimStart([char]0xFEFF)
    $payload = $raw | ConvertFrom-Json
    if ($null -eq $payload) { throw 'empty payload' }
    $tool = ''
    $toolProp = $payload.PSObject.Properties['tool_name']
    if ($null -ne $toolProp) { $tool = [string]$toolProp.Value }
    $toolKey = $tool.ToLowerInvariant()
    if ($toolKey -ne 'bash' -and $toolKey -ne 'powershell') { exit 0 }
    $cwd = ''
    $cwdProp = $payload.PSObject.Properties['cwd']
    if ($null -ne $cwdProp -and $null -ne $cwdProp.Value) { $cwd = [string]$cwdProp.Value }
    $command = ''
    $inputProp = $payload.PSObject.Properties['tool_input']
    if ($null -ne $inputProp -and $null -ne $inputProp.Value) {
        $commandProp = $inputProp.Value.PSObject.Properties['command']
        if ($null -ne $commandProp -and $null -ne $commandProp.Value) { $command = [string]$commandProp.Value }
    }
    $tokens = @(Get-HouseHookTokens -Command $command)
    if (-not (Test-HouseHookDelete -Tokens $tokens)) { exit 0 }
    $roots = @(Get-HouseHookRoots)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($token in $tokens) {
        if (Test-HouseHookPathLike -Token $token) { $paths.Add($token) }
    }
    if ($paths.Count -eq 0 -and $cwd) { $paths.Add($cwd) }
    foreach ($token in $paths) {
        $normal = ConvertTo-HouseHookPath -Value $token
        foreach ($known in $roots) {
            if ((Test-HouseHookSamePath -Left $normal -Right $known) -or (Test-HouseHookParentPath -Candidate $normal -Root $known)) {
                Write-HouseHookDeleteBlock -Root $normal
            }
        }
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    if (-not $message) { $message = 'hook ignored malformed input' }
    $message = $message -replace '[\r\n]+', ' '
    [Console]::Error.WriteLine($message)
    exit 0
}

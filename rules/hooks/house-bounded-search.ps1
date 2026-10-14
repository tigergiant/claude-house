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

function Test-HouseHookBare {
    param([string]$Token)
    if (-not $Token) { return $false }
    if ($Token.Contains('\') -or $Token.Contains('/')) { return $false }
    return $true
}

function Test-HouseHookSearch {
    param([string[]]$Tokens)
    $search = $false
    $select = $false
    $recurseWord = $false
    $grep = $false
    $cmdList = $false
    $psList = $false
    foreach ($token in $Tokens) {
        if ($token -match '^(?i)-Recurse$' -or $token -eq '-r' -or $token -eq '-R' -or $token -eq '--recursive') { $recurseWord = $true }
        if (-not (Test-HouseHookBare -Token $token)) { continue }
        $base = $token.ToLowerInvariant()
        if ($base -eq 'rg' -or $base -eq 'rg.exe') { $search = $true }
        if ($base -eq 'find' -or $base -eq 'find.exe') { $search = $true }
        if ($base -eq 'grep' -or $base -eq 'grep.exe') { $grep = $true }
        if ($base -eq 'findstr' -or $base -eq 'findstr.exe' -or $base -eq 'dir') { $cmdList = $true }
        if ($base -eq 'dir' -or $base -eq 'gci' -or $base -eq 'ls' -or $base -eq 'get-childitem') { $psList = $true }
        if ($base -eq 'select-string') { $select = $true }
    }
    if ($grep) {
        foreach ($flag in $Tokens) {
            if ($flag -eq '--recursive') { $search = $true }
            if ($flag -match '^-[A-Za-z]{1,4}$' -and $flag -match '[rR]') { $search = $true }
        }
    }
    if ($cmdList) {
        foreach ($flag in $Tokens) {
            if ($flag -match '^(?i)/s($|/)') { $search = $true }
        }
    }
    if ($psList -and $recurseWord) { $search = $true }
    if ($select -and $recurseWord) { $search = $true }
    return $search
}

function Write-HouseHookBlock {
    param([string]$Root)
    $line = 'Search a subfolder, for example: rg <pattern> "' + $Root + '\<subfolder>"'
    [Console]::Error.WriteLine($line)
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
    $cwd = ''
    $cwdProp = $payload.PSObject.Properties['cwd']
    if ($null -ne $cwdProp -and $null -ne $cwdProp.Value) { $cwd = [string]$cwdProp.Value }
    $inputObj = $null
    $inputProp = $payload.PSObject.Properties['tool_input']
    if ($null -ne $inputProp) { $inputObj = $inputProp.Value }
    $roots = @(Get-HouseHookRoots)
    if ($toolKey -eq 'grep' -or $toolKey -eq 'glob') {
        $path = ''
        if ($null -ne $inputObj) {
            $pathProp = $inputObj.PSObject.Properties['path']
            if ($null -ne $pathProp -and $null -ne $pathProp.Value) { $path = [string]$pathProp.Value }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $cwd }
        $normal = ConvertTo-HouseHookPath -Value $path
        foreach ($known in $roots) {
            if (Test-HouseHookSamePath -Left $normal -Right $known) { Write-HouseHookBlock -Root $normal }
        }
        exit 0
    }
    if ($toolKey -eq 'bash' -or $toolKey -eq 'powershell') {
        $command = ''
        if ($null -ne $inputObj) {
            $commandProp = $inputObj.PSObject.Properties['command']
            if ($null -ne $commandProp -and $null -ne $commandProp.Value) { $command = [string]$commandProp.Value }
        }
        $tokens = @(Get-HouseHookTokens -Command $command)
        if (-not (Test-HouseHookSearch -Tokens $tokens)) { exit 0 }
        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($token in $tokens) {
            if (Test-HouseHookPathLike -Token $token) { $paths.Add($token) }
        }
        if ($paths.Count -eq 0) {
            $normal = ConvertTo-HouseHookPath -Value $cwd
            foreach ($known in $roots) {
                if (Test-HouseHookSamePath -Left $normal -Right $known) { Write-HouseHookBlock -Root $normal }
            }
            exit 0
        }
        foreach ($token in $paths) {
            $normal = ConvertTo-HouseHookPath -Value $token
            foreach ($known in $roots) {
                if (Test-HouseHookSamePath -Left $normal -Right $known) { Write-HouseHookBlock -Root $normal }
            }
        }
        exit 0
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

$ErrorActionPreference = 'Stop'

# Each value is the on/off switch for one rule family. Tests flip a single
# '$true' to '$false' to prove the corpus would notice a dead rule.
$script:HouseGuardOn = @{
    'bash-length' = $true
    'bash-backslash' = $true
    'bash-nul' = $true
    'bash-powershell-dollar' = $true
    'bash-winswitch' = $true
    'bash-winpath' = $true
    'bash-cmdism' = $true
    'shell-chcp' = $true
    'ps-syntax' = $true
    'ps-native-stderr' = $true
    'ps-same-file' = $true
    'ps-alias' = $true
    'write-reserved-name' = $true
    'write-ps1-nonascii' = $true
    'delete-junction' = $true
}

function Write-HouseGuardLog {
    param([string]$Rule, [string]$Message)
    try {
        $dir = Join-Path $env:USERPROFILE '.claude\hooks'
        if (-not [System.IO.Directory]::Exists($dir)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        if (-not $Message) { $Message = 'unknown' }
        $clean = $Message.Replace("`r", ' ').Replace("`n", ' ')
        $line = [DateTime]::Now.ToString('o') + ' ' + $Rule + ' ' + $clean + "`r`n"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::AppendAllText((Join-Path $dir 'house-windows-guard.log'), $line, $utf8)
    }
    catch { }
}

function Stop-HouseGuard {
    param([string]$Id, [string]$Message)
    if (-not $script:HouseGuardOn.ContainsKey($Id)) { return }
    if ($script:HouseGuardOn[$Id] -ne $true) { return }
    $line = 'windows-guard ' + $Id + ': ' + $Message + "`n"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8.GetBytes($line)
    $stderr = [Console]::OpenStandardError()
    $stderr.Write($bytes, 0, $bytes.Length)
    $stderr.Flush()
    exit 2
}

function Read-HouseGuardStdin {
    $inputStream = [Console]::OpenStandardInput()
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    while ($true) {
        $read = $inputStream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $memory.Write($buffer, 0, $read)
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = $utf8.GetString($memory.ToArray())
    # A sender writing through a UTF-8 console writer adds its own byte order mark, so more than one can arrive.
    $text = $text.TrimStart([char]0xFEFF)
    return $text
}

function Get-HouseGuardField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-HouseGuardBackslashRun {
    param([string]$Command)
    $i = 0
    $n = $Command.Length
    while ($i -lt $n) {
        if ($Command[$i] -ne '\') { $i++; continue }
        $start = $i
        while ($i -lt $n -and $Command[$i] -eq '\') { $i++ }
        if (($i - $start) -ge 2) {
            $followed = ($i -lt $n -and $Command[$i] -eq '"')
            if (-not $followed) { return $true }
        }
    }
    return $false
}

function Test-HouseGuardDigits {
    param([string]$Text)
    if (-not $Text) { return $false }
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -lt '0' -or $ch -gt '9') { return $false }
    }
    return $true
}

function Get-HouseGuardBashCommands {
    param([string]$Command)
    $st = @{
        Command  = $Command
        N        = $Command.Length
        I        = 0
        Commands = (New-Object System.Collections.Generic.List[object])
        Words    = (New-Object System.Collections.Generic.List[object])
        Buf      = (New-Object System.Text.StringBuilder)
        InWord   = $false
        Unq      = $false
        Single   = $false
        Double   = $false
        Mode     = 0
        Expect   = $false
        Op       = ''
        Heredocs = (New-Object System.Collections.Generic.List[object])
    }

    function Reset-HouseGuardWord {
        $st.Buf.Length = 0
        $st.InWord = $false
        $st.Unq = $false
        $st.Single = $false
        $st.Double = $false
    }

    function Flush-HouseGuardWord {
        if (-not $st.InWord) { return }
        $kinds = 0
        if ($st.Unq) { $kinds++ }
        if ($st.Single) { $kinds++ }
        if ($st.Double) { $kinds++ }
        $quote = 'unquoted'
        if ($kinds -gt 1) { $quote = 'mixed' }
        elseif ($st.Single) { $quote = 'single' }
        elseif ($st.Double) { $quote = 'double' }
        $st.Words.Add([pscustomobject]@{
            Text   = $st.Buf.ToString()
            Quote  = $quote
            Target = [bool]$st.Expect
            Op     = [string]$st.Op
        })
        if ($st.Expect) { $st.Expect = $false; $st.Op = '' }
        Reset-HouseGuardWord
    }

    function Save-HouseGuardCommand {
        Flush-HouseGuardWord
        if ($st.Words.Count -gt 0) {
            $copy = New-Object System.Collections.Generic.List[object]
            foreach ($word in $st.Words) { $copy.Add($word) }
            $st.Commands.Add($copy)
        }
        $st.Words = New-Object System.Collections.Generic.List[object]
        $st.Expect = $false
        $st.Op = ''
    }

    function Skip-HouseGuardHeredocs {
        while ($st.Heredocs.Count -gt 0) {
            $item = $st.Heredocs[0]
            $st.Heredocs.RemoveAt(0)
            $delim = [string]$item.Delim
            $strip = [bool]$item.Strip
            while ($st.I -lt $st.N) {
                $start = $st.I
                while ($st.I -lt $st.N) {
                    $ch = $st.Command[$st.I]
                    if ($ch -eq "`n" -or $ch -eq "`r") { break }
                    $st.I++
                }
                $line = $st.Command.Substring($start, $st.I - $start)
                if ($st.I -lt $st.N -and $st.Command[$st.I] -eq "`r") { $st.I++ }
                if ($st.I -lt $st.N -and $st.Command[$st.I] -eq "`n") { $st.I++ }
                if ($strip) { $line = $line.TrimStart([char]9) }
                if ($line -eq $delim) { break }
            }
        }
    }

    while ($st.I -lt $st.N) {
        $ch = $st.Command[$st.I]
        if ($st.Mode -eq 1) {
            if ($ch -eq "'") { $st.Mode = 0 } else { [void]$st.Buf.Append($ch) }
            $st.I++
            continue
        }
        if ($st.Mode -eq 2) {
            if ($ch -eq '\' -and ($st.I + 1) -lt $st.N) {
                $next = $st.Command[$st.I + 1]
                if ($next -eq '"' -or $next -eq '\' -or $next -eq '$' -or $next -eq '`') {
                    [void]$st.Buf.Append($next)
                    $st.I += 2
                    continue
                }
            }
            if ($ch -eq '"') { $st.Mode = 0; $st.I++; continue }
            [void]$st.Buf.Append($ch)
            $st.I++
            continue
        }
        if ($ch -eq "'") { $st.InWord = $true; $st.Single = $true; $st.Mode = 1; $st.I++; continue }
        if ($ch -eq '"') { $st.InWord = $true; $st.Double = $true; $st.Mode = 2; $st.I++; continue }
        if ($ch -eq ' ' -or $ch -eq [char]9) { Flush-HouseGuardWord; $st.I++; continue }
        if ($ch -eq "`r" -or $ch -eq "`n") {
            Save-HouseGuardCommand
            if ($ch -eq "`r") { $st.I++ }
            if ($st.I -lt $st.N -and $st.Command[$st.I] -eq "`n") { $st.I++ }
            Skip-HouseGuardHeredocs
            continue
        }
        if ($ch -eq '&') {
            if (($st.I + 1) -lt $st.N -and $st.Command[$st.I + 1] -eq '&') { Save-HouseGuardCommand; $st.I += 2; continue }
            if (($st.I + 1) -lt $st.N -and $st.Command[$st.I + 1] -eq '>') {
                Flush-HouseGuardWord
                $st.I += 2
                $op = '&>'
                if ($st.I -lt $st.N -and $st.Command[$st.I] -eq '>') { $op = '&>>'; $st.I++ }
                $st.Expect = $true
                $st.Op = $op
                continue
            }
            Save-HouseGuardCommand
            $st.I++
            continue
        }
        if ($ch -eq '|') {
            if (($st.I + 1) -lt $st.N -and $st.Command[$st.I + 1] -eq '|') { Save-HouseGuardCommand; $st.I += 2; continue }
            Save-HouseGuardCommand
            $st.I++
            continue
        }
        if ($ch -eq ';' -or $ch -eq '(' -or $ch -eq ')') { Save-HouseGuardCommand; $st.I++; continue }
        if ($ch -eq '<') {
            if (($st.I + 1) -lt $st.N -and $st.Command[$st.I + 1] -eq '<') {
                Flush-HouseGuardWord
                $st.I += 2
                $strip = $false
                if ($st.I -lt $st.N -and $st.Command[$st.I] -eq '-') { $strip = $true; $st.I++ }
                while ($st.I -lt $st.N -and ($st.Command[$st.I] -eq ' ' -or $st.Command[$st.I] -eq [char]9)) { $st.I++ }
                $delim = ''
                if ($st.I -lt $st.N -and ($st.Command[$st.I] -eq "'" -or $st.Command[$st.I] -eq '"')) {
                    $q = $st.Command[$st.I]
                    $st.I++
                    while ($st.I -lt $st.N -and $st.Command[$st.I] -ne $q) { $delim += $st.Command[$st.I]; $st.I++ }
                    if ($st.I -lt $st.N) { $st.I++ }
                }
                else {
                    while ($st.I -lt $st.N) {
                        $stop = $st.Command[$st.I]
                        if ($stop -eq ' ' -or $stop -eq [char]9 -or $stop -eq "`n" -or $stop -eq "`r" -or $stop -eq ';' -or $stop -eq '&' -or $stop -eq '|' -or $stop -eq '(' -or $stop -eq ')' -or $stop -eq '<' -or $stop -eq '>') { break }
                        $delim += $stop
                        $st.I++
                    }
                }
                $st.Heredocs.Add([pscustomobject]@{ Delim = $delim; Strip = $strip })
                continue
            }
            Flush-HouseGuardWord
            $st.I++
            $st.Expect = $true
            $st.Op = '<'
            continue
        }
        if ($ch -eq '>') {
            $fd = ''
            if ($st.InWord) {
                $cur = $st.Buf.ToString()
                if (-not $st.Expect -and -not $st.Single -and -not $st.Double -and (Test-HouseGuardDigits $cur)) {
                    $fd = $cur
                    Reset-HouseGuardWord
                }
                else { Flush-HouseGuardWord }
            }
            $st.I++
            $op = $fd + '>'
            if ($st.I -lt $st.N -and $st.Command[$st.I] -eq '>') { $op = $fd + '>>'; $st.I++ }
            elseif ($st.I -lt $st.N -and $st.Command[$st.I] -eq '&') { $op = '>&'; $st.I++ }
            $st.Expect = $true
            $st.Op = $op
            continue
        }
        if ($ch -eq '\') {
            $st.InWord = $true
            $st.Unq = $true
            [void]$st.Buf.Append($ch)
            $st.I++
            continue
        }
        $st.InWord = $true
        $st.Unq = $true
        [void]$st.Buf.Append($ch)
        $st.I++
    }
    Save-HouseGuardCommand
    return ,$st.Commands
}

function Get-HouseGuardCommandName {
    param($Words)
    foreach ($word in $Words) {
        if ($word.Target) { continue }
        if ($word.Quote -eq 'unquoted' -and $word.Text -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
        return [string]$word.Text
    }
    return ''
}

function Test-HouseGuardNulOp {
    param([string]$Op)
    if ($Op -eq '>' -or $Op -eq '>>' -or $Op -eq '1>' -or $Op -eq '2>' -or $Op -eq '&>' -or $Op -eq '2>>') { return $true }
    return $false
}

function ConvertTo-HouseGuardDeletePath {
    param([string]$Token, [string]$Cwd)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    if ($Token.IndexOf('$') -ge 0 -or $Token.IndexOf('%') -ge 0 -or $Token.IndexOf('*') -ge 0 -or $Token.IndexOf('?') -ge 0) { return $null }
    $path = $Token
    if ($path -match '^/([A-Za-z])(/.*)?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = ''
        if ($Matches[2]) { $rest = $Matches[2].Replace('/', '\') }
        $path = $drive + ':' + $rest
        if ($path.EndsWith(':')) { $path = $path + '\' }
    }
    elseif (-not [System.IO.Path]::IsPathRooted($path)) {
        if (-not $Cwd) { return $null }
        try { $path = [System.IO.Path]::GetFullPath((Join-Path $Cwd ($path.Replace('/', '\')))) } catch { return $null }
    }
    else {
        $path = $path.Replace('/', '\')
        try { $path = [System.IO.Path]::GetFullPath($path) } catch { return $null }
    }
    return $path
}

function Test-HouseGuardJunction {
    param([string]$Root)
    if (-not $Root) { return $false }
    if (-not [System.IO.Directory]::Exists($Root)) { return $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $count = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $directory = [System.IO.FileAttributes]::Directory
    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -ge 3) { return $true }
        $dir = $stack.Pop()
        try { $attrs = [System.IO.File]::GetAttributes($dir) } catch { continue }
        if (($attrs -band $reparse) -ne 0) { return $true }
        if (($attrs -band $directory) -eq 0) { continue }
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $count++
                if ($count -ge 20000 -or $sw.Elapsed.TotalSeconds -ge 3) { return $true }
                try { $entryAttr = [System.IO.File]::GetAttributes($entry) } catch { continue }
                if (($entryAttr -band $reparse) -ne 0) { return $true }
                if (($entryAttr -band $directory) -ne 0) { $stack.Push($entry) }
            }
        }
        catch { }
    }
    return $false
}

function Get-HouseGuardJunctionMessage {
    param([string]$FullPath)
    return 'This folder contains a junction or symbolic link (or is too large to check). Recursive delete in Git Bash and Windows PowerShell 5.1 can follow it and delete the target. Remove it with the PowerShell tool: cmd /c rmdir /s /q "' + $FullPath + '" (in the Bash tool: MSYS_NO_PATHCONV=1 cmd /c rmdir /s /q "' + $FullPath + '")'
}

function Invoke-HouseGuardDeleteTargets {
    param($Targets, [string]$Cwd)
    foreach ($token in @($Targets)) {
        $full = ConvertTo-HouseGuardDeletePath -Token ([string]$token) -Cwd $Cwd
        if (-not $full) { continue }
        if (Test-HouseGuardJunction -Root $full) {
            Stop-HouseGuard -Id 'delete-junction' -Message (Get-HouseGuardJunctionMessage -FullPath $full)
        }
    }
}

function Invoke-HouseGuardBash {
    param([string]$Command, [string]$Cwd)
    if ($null -eq $Command) { $Command = '' }
    $quotes = 0
    foreach ($ch in $Command.ToCharArray()) { if ($ch -eq "'") { $quotes++ } }
    if (($Command.Length + (3 * $quotes)) -gt 7500) {
        Stop-HouseGuard -Id 'bash-length' -Message 'The Bash tool cuts commands near 8 KB and then reports a fake quoting error. Write the script to a file with the Write tool and run the file.'
    }
    if (Test-HouseGuardBackslashRun -Command $Command) {
        Stop-HouseGuard -Id 'bash-backslash' -Message 'The Bash tool halves runs of backslashes before bash sees them, even in single quotes and heredocs. Use forward slashes for paths, or write the text to a file with the Write tool and run the file.'
    }
    $win = @{
        cmd = $true; taskkill = $true; tasklist = $true; ipconfig = $true; netstat = $true
        net = $true; sc = $true; reg = $true; wmic = $true; schtasks = $true; icacls = $true
        attrib = $true; robocopy = $true; xcopy = $true; findstr = $true; where = $true; shutdown = $true
    }
    $psNames = @{ powershell = $true; 'powershell.exe' = $true; pwsh = $true; 'pwsh.exe' = $true }
    $cmdisms = @{ move = $true; copy = $true; del = $true; erase = $true; cls = $true; ren = $true }
    $parsed = Get-HouseGuardBashCommands -Command $Command
    foreach ($words in $parsed) {
        $name = Get-HouseGuardCommandName -Words $words
        $lower = $name.ToLowerInvariant()
        if ($lower -ne 'cmd' -and $lower -ne 'cmd.exe') {
            foreach ($word in $words) {
                if ($word.Target -and $word.Quote -eq 'unquoted' -and $word.Text -match '^(?i)nul$' -and (Test-HouseGuardNulOp -Op $word.Op)) {
                    Stop-HouseGuard -Id 'bash-nul' -Message 'In Git Bash `nul` is an ordinary file name and leaves an undeletable file. Use /dev/null.'
                }
            }
        }
        if ($psNames.ContainsKey($lower)) {
            $seenFlag = $false
            foreach ($word in $words) {
                if (-not $seenFlag) {
                    if ($word.Text -match '^(?i)(-c|-command)$') { $seenFlag = $true }
                    continue
                }
                if (($word.Quote -eq 'double' -or $word.Quote -eq 'mixed') -and $word.Text -match '\$[A-Za-z_\{(]') {
                    Stop-HouseGuard -Id 'bash-powershell-dollar' -Message 'Bash expands `$_` and `$env:` inside double quotes before PowerShell runs. Use the PowerShell tool, or put the PowerShell code in single quotes or a .ps1 file.'
                }
            }
        }
        $base = $lower
        if ($base.EndsWith('.exe')) { $base = $base.Substring(0, $base.Length - 4) }
        if ($win.ContainsKey($base)) {
            $index = 0
            foreach ($word in $words) {
                if ($word.Quote -eq 'unquoted' -and -not $word.Target -and $word.Text -match '^/[A-Za-z?]' -and $word.Text -notmatch '^//') {
                    $precedes = $false
                    $j = 0
                    foreach ($earlier in $words) {
                        if ($j -ge $index) { break }
                        if ($earlier.Quote -eq 'unquoted' -and $earlier.Text -eq 'MSYS_NO_PATHCONV=1') { $precedes = $true }
                        $j++
                    }
                    if (-not $precedes) {
                        Stop-HouseGuard -Id 'bash-winswitch' -Message 'Git Bash turns `/c`-style switches into paths for Windows programs. Prefix the command with MSYS_NO_PATHCONV=1, write the switch as `//c`, or use the PowerShell tool.'
                    }
                }
                $index++
            }
        }
        foreach ($word in $words) {
            if ($word.Quote -eq 'unquoted' -and $word.Text -match '^[A-Za-z]:\\') {
                Stop-HouseGuard -Id 'bash-winpath' -Message 'Bash removes unquoted backslashes, so `C:\Users\x` becomes `C:Usersx`. Quote the path or write it as C:/Users/x.'
            }
        }
        if ($cmdisms.ContainsKey($lower)) {
            Stop-HouseGuard -Id 'bash-cmdism' -Message 'That is a cmd.exe command; the Bash tool runs Git Bash. Use mv, cp, rm, clear, or the PowerShell tool.'
        }
        if ($lower -eq 'chcp' -or $lower -eq 'chcp.com') {
            Stop-HouseGuard -Id 'shell-chcp' -Message 'chcp changes the shared console code page and garbles later output. Do not change the code page; read files with an explicit UTF-8 encoding instead.'
        }
        if ($name -eq 'rm') {
            $recursive = $false
            $endOpts = $false
            foreach ($word in $words) {
                if ($word.Target) { continue }
                if (-not $endOpts -and $word.Quote -eq 'unquoted' -and $word.Text -eq '--') { $endOpts = $true; continue }
                if ($endOpts -or $word.Quote -ne 'unquoted') { continue }
                if ($word.Text -eq '--recursive') { $recursive = $true }
                elseif ($word.Text -match '^-[A-Za-z]*[rR][A-Za-z]*$') { $recursive = $true }
            }
            if ($recursive) {
                $targets = New-Object System.Collections.Generic.List[string]
                $seenCmd = $false
                $endOpts = $false
                foreach ($word in $words) {
                    if ($word.Target) { continue }
                    if (-not $seenCmd) {
                        if ($word.Quote -eq 'unquoted' -and $word.Text -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
                        $seenCmd = $true
                        continue
                    }
                    if (-not $endOpts -and $word.Quote -eq 'unquoted' -and $word.Text -eq '--') { $endOpts = $true; continue }
                    if (-not $endOpts -and $word.Quote -eq 'unquoted' -and $word.Text.StartsWith('-')) { continue }
                    $targets.Add($word.Text)
                }
                Invoke-HouseGuardDeleteTargets -Targets $targets -Cwd $Cwd
            }
        }
    }
}

function Test-HouseGuardHasPwsh {
    # HOUSE_GUARD_ASSUME_NO_PWSH=1 is test-only. It skips the pwsh lookup so ps-syntax denies on machines that have pwsh.
    if ($env:HOUSE_GUARD_ASSUME_NO_PWSH -eq '1') { return $false }
    $found = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue
    return ($null -ne $found)
}

function Get-HouseGuardSyntaxHint {
    param($Err, [string]$Command)
    $extent = ''
    if ($null -ne $Err.Extent -and $Err.Extent.Text) { $extent = [string]$Err.Extent.Text }
    $start = 0
    $end = 0
    if ($null -ne $Err.Extent) {
        $start = [int]$Err.Extent.StartOffset
        $end = [int]$Err.Extent.EndOffset
    }
    if ($end -le $start) { $end = $start + 2 }
    $from = $start - 2
    if ($from -lt 0) { $from = 0 }
    $to = $end + 40
    if ($to -gt $Command.Length) { $to = $Command.Length }
    $slice = ''
    if ($to -gt $from) { $slice = $Command.Substring($from, $to - $from) }
    $blob = $extent + ' ' + $slice
    if ($blob.Contains('&&')) { return 'use A; if ($?) { B }' }
    if ($blob.Contains('||')) { return 'use A; if (-not $?) { B }' }
    if ($blob.Contains('<<')) { return 'use a here-string @'' ... ''@ with the closing ''@ at column 0' }
    if ($blob.Contains('??')) { return 'Windows PowerShell 5.1 has no null-coalescing or ternary operators; use if/else' }
    if ($blob.Contains('?.')) { return 'Windows PowerShell 5.1 has no null-coalescing or ternary operators; use if/else' }
    if ($blob.Contains('?') -and $blob.Contains(':')) { return 'Windows PowerShell 5.1 has no null-coalescing or ternary operators; use if/else' }
    return 'This is Windows PowerShell 5.1 syntax error'
}

function ConvertTo-HouseGuardComparePath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value.IndexOf('$') -ge 0) { return $null }
    $text = $Value.Trim()
    if ($text.Length -ge 2) {
        $head = $text[0]
        $tail = $text[$text.Length - 1]
        if (($head -eq '"' -and $tail -eq '"') -or ($head -eq "'" -and $tail -eq "'")) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }
    if ($text.IndexOf('$') -ge 0) { return $null }
    $text = $text.Replace('/', '\')
    while ($text.StartsWith('.\')) { $text = $text.Substring(2) }
    return $text
}

function Get-HouseGuardCommandStrings {
    param($CommandAst)
    $list = New-Object System.Collections.Generic.List[string]
    $first = $true
    foreach ($el in $CommandAst.CommandElements) {
        if ($first) { $first = $false; continue }
        if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $list.Add([string]$el.Value) }
        elseif ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $null -ne $el.Argument -and $el.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $list.Add([string]$el.Argument.Value)
        }
    }
    return ,$list
}

function Get-HouseGuardRedirPath {
    param($Redir)
    if ($null -eq $Redir) { return $null }
    if ($Redir -isnot [System.Management.Automation.Language.FileRedirectionAst]) { return $null }
    $loc = $Redir.Location
    if ($null -eq $loc) { return $null }
    if ($loc -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$loc.Value }
    if ($loc.Extent -and $loc.Extent.Text -and $loc.Extent.Text.IndexOf('$') -lt 0) { return [string]$loc.Extent.Text }
    return $null
}

function Test-HouseGuardRecurseParam {
    param([string]$Written)
    $body = $Written
    if ($body.StartsWith('-')) { $body = $body.Substring(1) }
    if (-not $body) { return $false }
    $names = @('Recurse', 'Path', 'LiteralPath', 'Filter', 'Include', 'Exclude', 'Force', 'WhatIf', 'Confirm', 'Credential', 'Verbose', 'Debug', 'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable', 'OutBuffer', 'OutVariable', 'PipelineVariable')
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        if ($name.StartsWith($body, [System.StringComparison]::OrdinalIgnoreCase)) { $hits.Add($name) }
    }
    return ($hits.Count -eq 1 -and $hits[0] -eq 'Recurse')
}

function Invoke-HouseGuardPowerShell {
    param([string]$Command, [string]$Cwd)
    if ($null -eq $Command) { $Command = '' }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    if ($script:HouseGuardOn['ps-syntax'] -eq $true -and $null -ne $errors -and @($errors).Count -gt 0 -and -not (Test-HouseGuardHasPwsh)) {
        $err = @($errors)[0]
        $hint = Get-HouseGuardSyntaxHint -Err $err -Command $Command
        $lineNo = 1
        if ($null -ne $err.Extent) { $lineNo = [int]$err.Extent.StartLineNumber }
        $text = ([string]$err.Message).Replace("`r", ' ').Replace("`n", ' ')
        Stop-HouseGuard -Id 'ps-syntax' -Message ($text + ' Line ' + $lineNo + '. ' + $hint)
    }
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    if ($script:HouseGuardOn['ps-native-stderr'] -eq $true) {
        foreach ($cmd in $commands) {
            $merge = $false
            if ($null -eq $cmd.Redirections) { continue }
            foreach ($redir in $cmd.Redirections) {
                if ($redir -is [System.Management.Automation.Language.MergingRedirectionAst]) {
                    $from = [string]$redir.FromStream
                    $to = [string]$redir.ToStream
                    if ($to -eq 'Output' -and ($from -eq 'Error' -or $from -eq 'All')) { $merge = $true }
                }
            }
            if (-not $merge) { continue }
            $cmdName = $cmd.GetCommandName()
            $info = $null
            if ($cmdName) {
                try { $info = Get-Command -Name $cmdName -ErrorAction SilentlyContinue } catch { $info = $null }
            }
            $isApp = $false
            if ($null -ne $info -and $info.CommandType -eq [System.Management.Automation.CommandTypes]::Application) { $isApp = $true }
            if ($null -eq $info -or $isApp) {
                Stop-HouseGuard -Id 'ps-native-stderr' -Message 'In Windows PowerShell 5.1, `2>&1` on a program turns its normal stderr into error records and sets $? to false. The PowerShell tool already captures stderr; drop `2>&1`.'
            }
        }
    }
    if ($script:HouseGuardOn['ps-same-file'] -eq $true) {
        $readNames = @{ 'get-content' = $true; 'gc' = $true; 'cat' = $true; 'type' = $true }
        $setContent = ('Set-' + 'Content').ToLowerInvariant()
        $addContent = ('Add-' + 'Content').ToLowerInvariant()
        $writeNames = @{ $setContent = $true; 'sc' = $true; $addContent = $true; 'ac' = $true; 'out-file' = $true }
        $pipes = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.PipelineAst] }, $true))
        foreach ($pipe in $pipes) {
            $reads = New-Object System.Collections.Generic.List[string]
            $writes = New-Object System.Collections.Generic.List[string]
            $pipeCommands = @($pipe.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            foreach ($cmd in $pipeCommands) {
                $cmdName = $cmd.GetCommandName()
                if (-not $cmdName) { continue }
                $key = $cmdName.ToLowerInvariant()
                $strings = Get-HouseGuardCommandStrings -CommandAst $cmd
                if ($readNames.ContainsKey($key)) {
                    foreach ($item in $strings) {
                        $norm = ConvertTo-HouseGuardComparePath -Value $item
                        if ($norm) { $reads.Add($norm) }
                    }
                }
                if ($writeNames.ContainsKey($key)) {
                    foreach ($item in $strings) {
                        $norm = ConvertTo-HouseGuardComparePath -Value $item
                        if ($norm) { $writes.Add($norm) }
                    }
                }
                if ($null -ne $cmd.Redirections) {
                    foreach ($redir in $cmd.Redirections) {
                        $norm = ConvertTo-HouseGuardComparePath -Value (Get-HouseGuardRedirPath -Redir $redir)
                        if ($norm) { $writes.Add($norm) }
                    }
                }
            }
            if ($null -ne $pipe.Redirections) {
                foreach ($redir in $pipe.Redirections) {
                    $norm = ConvertTo-HouseGuardComparePath -Value (Get-HouseGuardRedirPath -Redir $redir)
                    if ($norm) { $writes.Add($norm) }
                }
            }
            foreach ($readPath in $reads) {
                foreach ($writePath in $writes) {
                    if ([string]::Equals($readPath, $writePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Stop-HouseGuard -Id 'ps-same-file' -Message 'Reading and rewriting one file in a 5.1 pipeline decodes UTF-8 as ANSI and corrupts non-ASCII text. Use the Edit tool, or [System.IO.File]::ReadAllText/WriteAllText with New-Object System.Text.UTF8Encoding $false.'
                    }
                }
            }
        }
    }
    $scBad = @{ query = $true; start = $true; stop = $true; config = $true; delete = $true; create = $true; qc = $true }
    $removeName = ('Remove-' + 'Item').ToLowerInvariant()
    $deleteNames = @{ $removeName = $true; 'ri' = $true; 'rm' = $true; 'del' = $true; 'rmdir' = $true; 'rd' = $true; 'erase' = $true }
    foreach ($cmd in $commands) {
        $cmdName = $cmd.GetCommandName()
        if (-not $cmdName) { continue }
        $key = $cmdName.ToLowerInvariant()
        if ($script:HouseGuardOn['ps-alias'] -eq $true) {
            if ($key -eq 'curl' -or $key -eq 'wget') {
                Stop-HouseGuard -Id 'ps-alias' -Message 'In Windows PowerShell 5.1 curl and wget are Invoke-WebRequest. Use curl.exe or Invoke-RestMethod -UseBasicParsing.'
            }
            if ($key -eq 'where') {
                $argCount = 0
                $hasScript = $false
                $firstEl = $true
                foreach ($el in $cmd.CommandElements) {
                    if ($firstEl) { $firstEl = $false; continue }
                    $argCount++
                    if ($el -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $hasScript = $true }
                }
                # Piped input means Where-Object is meant, including its simplified 'where Name -eq x' form.
                $piped = $false
                if ($cmd.Parent -is [System.Management.Automation.Language.PipelineAst]) {
                    $piped = ($cmd.Parent.PipelineElements.IndexOf($cmd) -gt 0)
                }
                if ($argCount -ge 1 -and -not $hasScript -and -not $piped) {
                    Stop-HouseGuard -Id 'ps-alias' -Message 'where is Where-Object here. Use where.exe or Get-Command.'
                }
            }
            if ($key -eq 'sc') {
                $firstArg = ''
                $seen = $false
                foreach ($el in $cmd.CommandElements) {
                    if (-not $seen) { $seen = $true; continue }
                    if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $firstArg = $el.Value.ToLowerInvariant(); break }
                }
                if ($scBad.ContainsKey($firstArg)) {
                    Stop-HouseGuard -Id 'ps-alias' -Message ('sc is ' + 'Set-' + 'Content here. Use sc.exe or Get-Service/' + 'Start-' + 'Service.')
                }
            }
            if ($key -eq 'timeout') {
                Stop-HouseGuard -Id 'ps-alias' -Message ('timeout.exe fails without a console. Use ' + 'Start-' + 'Sleep -Seconds N.')
            }
        }
        if ($key -eq 'chcp' -or $key -eq 'chcp.com') {
            Stop-HouseGuard -Id 'shell-chcp' -Message 'chcp changes the shared console code page and garbles later output. Do not change the code page; read files with an explicit UTF-8 encoding instead.'
        }
    }
    if ($script:HouseGuardOn['delete-junction'] -eq $true) {
        foreach ($cmd in $commands) {
            $cmdName = $cmd.GetCommandName()
            if (-not $cmdName) { continue }
            $key = $cmdName.ToLowerInvariant()
            $strings = Get-HouseGuardCommandStrings -CommandAst $cmd
            if ($key -eq 'cmd' -or $key -eq 'cmd.exe') {
                $hasC = $false
                $hasRmdir = $false
                foreach ($item in $strings) {
                    if ($item -eq '/c' -or $item -eq '//c') { $hasC = $true }
                    if ($item -match '^(?i)rmdir(\.exe)?$') { $hasRmdir = $true }
                }
                if ($hasC -and $hasRmdir) { continue }
            }
            if (-not $deleteNames.ContainsKey($key)) { continue }
            $recursive = $false
            foreach ($el in $cmd.CommandElements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if (Test-HouseGuardRecurseParam -Written ([string]$el.ParameterName)) { $recursive = $true }
                }
            }
            if (-not $recursive) { continue }
            $targets = New-Object System.Collections.Generic.List[string]
            foreach ($item in $strings) {
                if ($item.StartsWith('-')) { continue }
                $targets.Add($item)
            }
            Invoke-HouseGuardDeleteTargets -Targets $targets -Cwd $Cwd
        }
    }
}

function Invoke-HouseGuardWrite {
    param($InputObj, [string]$ToolKey)
    $path = [string](Get-HouseGuardField -Object $InputObj -Name 'file_path')
    if (-not $path) { return }
    $leaf = [System.IO.Path]::GetFileName($path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $reserved = @{
        nul = $true; con = $true; prn = $true; aux = $true
        com1 = $true; com2 = $true; com3 = $true; com4 = $true; com5 = $true
        com6 = $true; com7 = $true; com8 = $true; com9 = $true
        lpt1 = $true; lpt2 = $true; lpt3 = $true; lpt4 = $true; lpt5 = $true
        lpt6 = $true; lpt7 = $true; lpt8 = $true; lpt9 = $true
    }
    if ($stem -and $reserved.ContainsKey($stem.ToLowerInvariant())) {
        Stop-HouseGuard -Id 'write-reserved-name' -Message 'That is a reserved Windows device name and makes an undeletable file. Choose another name.'
    }
    $ext = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if ($ext -eq '.ps1' -or $ext -eq '.psm1' -or $ext -eq '.psd1') {
        $field = 'content'
        if ($ToolKey -eq 'edit') { $field = 'new_string' }
        $text = [string](Get-HouseGuardField -Object $InputObj -Name $field)
        if ($text) {
            foreach ($ch in $text.ToCharArray()) {
                if ([int]$ch -gt 127) {
                    Stop-HouseGuard -Id 'write-ps1-nonascii' -Message 'Windows PowerShell 5.1 reads a script without a byte order mark as ANSI, so non-ASCII text breaks parsing. Keep the script ASCII: use [char]0x4E2D-style escapes or read text from a UTF-8 data file.'
                }
            }
        }
    }
}

try {
    $raw = Read-HouseGuardStdin
    $payload = $null
    try { $payload = $raw | ConvertFrom-Json }
    catch {
        Write-HouseGuardLog -Rule 'input' -Message $_.Exception.Message
        exit 0
    }
    if ($null -eq $payload) {
        Write-HouseGuardLog -Rule 'input' -Message 'empty payload'
        exit 0
    }
    $tool = [string](Get-HouseGuardField -Object $payload -Name 'tool_name')
    if (-not $tool) {
        Write-HouseGuardLog -Rule 'input' -Message 'missing tool_name'
        exit 0
    }
    $toolKey = $tool.ToLowerInvariant()
    $inputObj = Get-HouseGuardField -Object $payload -Name 'tool_input'
    $cwd = [string](Get-HouseGuardField -Object $payload -Name 'cwd')
    $inputCwd = [string](Get-HouseGuardField -Object $inputObj -Name 'cwd')
    if ($inputCwd) { $cwd = $inputCwd }
    if ($toolKey -eq 'bash') {
        Invoke-HouseGuardBash -Command ([string](Get-HouseGuardField -Object $inputObj -Name 'command')) -Cwd $cwd
        exit 0
    }
    if ($toolKey -eq 'powershell') {
        Invoke-HouseGuardPowerShell -Command ([string](Get-HouseGuardField -Object $inputObj -Name 'command')) -Cwd $cwd
        exit 0
    }
    if ($toolKey -eq 'write' -or $toolKey -eq 'edit') {
        Invoke-HouseGuardWrite -InputObj $inputObj -ToolKey $toolKey
        exit 0
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    if (-not $message) { $message = [string]$_ }
    Write-HouseGuardLog -Rule 'input' -Message $message
    exit 0
}

BeforeDiscovery {
    $guardUtf8 = New-Object System.Text.UTF8Encoding $false
    $script:guardCases = $guardUtf8.GetString([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\windows-guard-corpus.json'))) | ConvertFrom-Json
    $script:guardRows = New-Object System.Collections.Generic.List[hashtable]
    foreach ($case in @($script:guardCases)) {
        $script:guardRows.Add(@{ CaseId = [string]$case.id })
    }
}

Describe 'windows-guard corpus' {
    BeforeAll {
        $script:repo = Split-Path -Parent $PSScriptRoot
        $script:guardHook = Join-Path $script:repo 'rules\hooks\house-windows-guard.ps1'
        $guardUtf8 = New-Object System.Text.UTF8Encoding $false
        $script:guardCases = $guardUtf8.GetString([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\windows-guard-corpus.json'))) | ConvertFrom-Json
        Import-Module (Join-Path $script:repo 'lib\House.psm1') -Force
        $script:guardRoot = Join-Path $env:TEMP ('house-w8-' + [guid]::NewGuid().ToString('n'))
        $script:junctionTree = Join-Path $script:guardRoot 'junction-tree'
        $script:cleanParent = Join-Path $script:guardRoot 'clean'
        New-Item -ItemType Directory -Path (Join-Path $script:junctionTree 'real') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $script:junctionTree 'link') -Target (Join-Path $script:junctionTree 'real') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:cleanParent 'build') -Force | Out-Null
        $script:junctionFull = [System.IO.Path]::GetFullPath($script:junctionTree)
        $script:perfPath = Join-Path $env:TEMP 'house-w8-perf.txt'
        if (Test-Path -LiteralPath $script:perfPath) { Remove-Item -LiteralPath $script:perfPath -Force }

        function script:Invoke-HouseHookFile {
            param(
                [string]$HookName,
                [string]$Payload,
                [string]$RootsJson = '{"roots":[]}',
                [string]$HookPath = '',
                [switch]$Bom
            )
            $dir = Join-Path $env:TEMP ('house-hook-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $profile = Join-Path $dir 'profile'
            New-Item -ItemType Directory -Path $profile | Out-Null
            if (-not $HookPath) { $HookPath = Join-Path $script:repo ('rules\hooks\' + $HookName) }
            $dest = Join-Path $dir $HookName
            Copy-Item -LiteralPath $HookPath -Destination $dest
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText((Join-Path $dir 'house-roots.json'), $RootsJson, $utf8)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $dest + '"'
            $psi.WorkingDirectory = $dir
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $psi.EnvironmentVariables['HOUSE_GUARD_ASSUME_NO_PWSH'] = '1'
            $psi.EnvironmentVariables['USERPROFILE'] = $profile
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$proc.Start()
            $text = $Payload
            if ($Bom) { $text = [string][char]0xFEFF + $Payload }
            $bytes = $utf8.GetBytes($text)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(20000)) {
                try { $proc.Kill() } catch { }
                throw 'hook timed out'
            }
            [void]$stdoutTask.Wait(5000)
            [void]$stderrTask.Wait(5000)
            [void]$proc.WaitForExit()
            $sw.Stop()
            return [pscustomobject]@{ Exit = [int]$proc.ExitCode; Stderr = [string]$stderrTask.Result; Elapsed = $sw.Elapsed.TotalSeconds }
        }

        function script:Get-HouseGuardPayload {
            param($Case)
            if ($Case.PSObject.Properties['raw'] -and $null -ne $Case.raw) { return [string]$Case.raw }
            $payload = $Case.input | ConvertTo-Json -Compress -Depth 8
            $echo = 'echo ' + ('a' * 7595)
            $payload = $payload.Replace('__ECHO_7600__', $echo)
            $escapedJunction = $script:junctionFull.Replace('\', '\\')
            $payload = $payload.Replace('__JUNCTION_TREE__', $escapedJunction)
            $escapedClean = ([System.IO.Path]::GetFullPath($script:cleanParent)).Replace('\', '\\')
            $payload = $payload.Replace('__CLEAN_PARENT__', $escapedClean)
            return $payload
        }

        function script:Invoke-HouseGuardCase {
            param($Case, [string]$HookPath = '')
            $payload = Get-HouseGuardPayload -Case $Case
            $bom = $false
            if ($Case.PSObject.Properties['bom'] -and $Case.bom -eq $true) { $bom = $true }
            return Invoke-HouseHookFile -HookName 'house-windows-guard.ps1' -Payload $payload -HookPath $HookPath -Bom:$bom
        }
    }

    AfterAll {
        if ($script:guardRoot -and (Test-Path -LiteralPath $script:guardRoot)) {
            & cmd.exe /c rmdir /s /q "$script:guardRoot" | Out-Null
        }
    }

    It 'covers every rule family with a deny case' {
        $want = @('bash-length', 'bash-backslash', 'bash-nul', 'bash-powershell-dollar', 'bash-winswitch', 'bash-winpath', 'bash-cmdism', 'shell-chcp', 'ps-syntax', 'ps-native-stderr', 'ps-same-file', 'ps-alias', 'write-reserved-name', 'write-ps1-nonascii', 'delete-junction')
        foreach ($id in $want) {
            @($script:guardCases | Where-Object { $_.expect -eq $id }).Count | Should -BeGreaterThan 0
        }
    }

    It 'corpus <CaseId>' -TestCases @($script:guardRows) {
        param($CaseId)
        $captured = $null
        foreach ($item in @($script:guardCases)) {
            if ([string]$item.id -eq $CaseId) { $captured = $item; break }
        }
        $captured | Should -Not -BeNullOrEmpty
        $result = Invoke-HouseGuardCase -Case $captured
        if ($captured.expect -eq 'allow') {
            $result.Exit | Should -Be 0
        }
        else {
            $result.Exit | Should -Be 2
            $result.Stderr.StartsWith('windows-guard ' + $captured.expect + ':') | Should -Be $true
            if ($captured.expect -eq 'delete-junction') {
                $result.Stderr.Contains($script:junctionFull) | Should -Be $true
            }
        }
    }

    It 'notices a dead rule in each family' {
        $families = @('bash-length', 'bash-backslash', 'bash-nul', 'bash-powershell-dollar', 'bash-winswitch', 'bash-winpath', 'bash-cmdism', 'shell-chcp', 'ps-syntax', 'ps-native-stderr', 'ps-same-file', 'ps-alias', 'write-reserved-name', 'write-ps1-nonascii', 'delete-junction')
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $source = [System.IO.File]::ReadAllText($script:guardHook)
        foreach ($family in $families) {
            $needle = "'" + $family + "' = `$true"
            $source.Contains($needle) | Should -Be $true
            $sample = @($script:guardCases | Where-Object { $_.expect -eq $family } | Select-Object -First 1)
            $sample.Count | Should -Be 1
            $copy = Join-Path $env:TEMP ('house-guard-dead-' + $family + '.ps1')
            $dead = $source.Replace($needle, "'" + $family + "' = `$false")
            [System.IO.File]::WriteAllText($copy, $dead, $utf8)
            $result = Invoke-HouseGuardCase -Case $sample[0] -HookPath $copy
            $result.Exit | Should -Be 0
        }
    }

    It 'finishes a 30000 character Bash command within 2 seconds' {
        $command = 'echo ' + ('a' * 29995)
        $command.Length | Should -Be 30000
        $payload = '{"tool_name":"Bash","tool_input":{"command":"' + $command + '"},"cwd":"C:\\work"}'
        $result = Invoke-HouseHookFile -HookName 'house-windows-guard.ps1' -Payload $payload
        [System.IO.File]::AppendAllText($script:perfPath, ('bash ' + $result.Elapsed.ToString('0.000') + ' exit=' + $result.Exit + "`r`n"))
        $result.Exit | Should -Be 2
        $result.Stderr.StartsWith('windows-guard bash-length:') | Should -Be $true
        $result.Elapsed | Should -BeLessThan 2
    }

    It 'finishes a 30000 character PowerShell command within 2 seconds' {
        $command = "Write-Output '" + ('b' * 29985) + "'"
        $payload = '{"tool_name":"PowerShell","tool_input":{"command":"' + $command + '"},"cwd":"C:\\work"}'
        $command.Length | Should -Be 30000
        $result = Invoke-HouseHookFile -HookName 'house-windows-guard.ps1' -Payload $payload
        [System.IO.File]::AppendAllText($script:perfPath, ('powershell ' + $result.Elapsed.ToString('0.000') + ' exit=' + $result.Exit + "`r`n"))
        $result.Exit | Should -Be 0
        $result.Elapsed | Should -BeLessThan 2
    }
}

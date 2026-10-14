BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repo 'lib\House.psm1') -Force

    function Test-HouseMutatingLineExempt {
        param([string]$Line)
        $code = $Line
        $hash = $Line.IndexOf('#')
        if ($hash -ge 0) { $code = $Line.Substring(0, $hash) }
        if ($code -notmatch '(?i)\.house-probe-') { return $false }
        if ($code -notmatch '(?i)\b(Set-Content|Remove-Item|Add-Content|Out-File)\b') { return $false }
        if ($code -match '[A-Za-z]:\\') { return $false }
        return $true
    }

    function Test-HouseMutatingText {
        param(
            [string]$Text,
            [switch]$AllowProbeMarker
        )
        $source = $Text
        if ($AllowProbeMarker) {
            $kept = New-Object System.Collections.Generic.List[string]
            foreach ($line in ($Text -split "`r?`n")) {
                if (Test-HouseMutatingLineExempt -Line $line) { continue }
                $kept.Add($line)
            }
            $source = $kept.ToArray() -join "`n"
        }
        $scrub = [regex]::Replace($source, '(?i)\bNew-Object\b', 'Allow-Object')
        $scrub = [regex]::Replace($scrub, '(?i)\bSet-StrictMode\b', 'Allow-StrictMode')
        # House-named commands are the lib allowlist. Writers live in the lib on purpose:
        # New-HouseDesktopShortcut (the public desktop shortcut), New-HouseConsoleSettings
        # (the vmconnect choice) and Sync-HouseVmPassword (vm-user.cred.xml only).
        # Checks stay read-only.
        $scrub = [regex]::Replace($scrub, '\b[A-Za-z]+-House[A-Za-z]*\b', 'Allow-House')
        $pattern = '(?im)^\s*[^#\r\n]*\b(New|Set|Remove|Add|Enable|Disable|Start|Stop|Restart|Install|Uninstall|Rename|Move|Copy|Clear|Mount|Dismount|Register|Unregister|Grant|Revoke)-[A-Z]\w+|\bnetsh\b[^\r\n]*\b(add|delete|set)\b|\breg(\.exe)?\s+(add|delete)\b|\bicacls\b[^\r\n]*/(grant|remove|deny)'
        return [regex]::IsMatch($scrub, $pattern)
    }

    $script:steps = @(Get-HouseSteps -RepoRoot $script:repo)
    $script:sections = @('## Purpose', '## Before you start', '## Do', '## Verify', '## If it fails')
}

Describe 'runbook and check pairing' {
    It 'covers fifteen pages and the preflight check, and daily.md is not a step' {
        $script:steps.Count | Should -Be 15
        $checks = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'checks') -Filter '*.ps1')
        @($checks | Where-Object { $_.BaseName -ne 'preflight' }).Count | Should -Be 15
        @($checks | Where-Object { $_.Name -eq 'preflight.ps1' }).Count | Should -Be 1
        @($script:steps | Where-Object { $_.Id -eq 'preflight' }).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:repo 'runbook\daily.md') -PathType Leaf) | Should -Be $true
        @($script:steps | Where-Object { $_.PagePath -eq 'runbook/daily.md' }).Count | Should -Be 0
        $daily = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\daily.md'))
        $daily.StartsWith('---') | Should -Be $false
        @($daily -split "`r?`n").Count | Should -BeLessOrEqual 60
        $template = [System.IO.File]::ReadAllText((Join-Path $script:repo 'rules\CLAUDE.md.template'))
        @($template -split "`r?`n").Count | Should -BeLessOrEqual 60
    }

    It 'gives every numbered page a check with the same id' {
        $script:steps.Count | Should -BeGreaterThan 0
        foreach ($step in $script:steps) {
            $check = Join-Path $script:repo (($step.CheckPath -replace '/', '\'))
            (Test-Path -LiteralPath $check -PathType Leaf) | Should -Be $true
        }
    }

    It 'gives every check a runbook page' {
        $checks = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'checks') -Filter '*.ps1' | Where-Object { $_.BaseName -ne 'preflight' })
        $checks.Count | Should -Be $script:steps.Count
        foreach ($check in $checks) {
            $match = @($script:steps | Where-Object { $_.Id -eq $check.BaseName })
            $match.Count | Should -Be 1
        }
    }

    It 'uses the file number as the order' {
        foreach ($step in $script:steps) {
            $name = Split-Path -Leaf $step.PagePath
            $name -match '^(\d{2})-' | Should -Be $true
            [int]$Matches[1] | Should -Be $step.Order
        }
    }

    It 'keeps orders unique and contiguous from 0' {
        $orders = @($script:steps | ForEach-Object { $_.Order })
        $orders[0] | Should -Be 0
        for ($i = 0; $i -lt $orders.Count; $i++) {
            $orders[$i] | Should -Be $i
        }
    }

    It 'requires only earlier steps' {
        $byId = @{}
        foreach ($step in $script:steps) { $byId[$step.Id] = $step }
        foreach ($step in $script:steps) {
            foreach ($requiredId in @($step.Requires)) {
                $byId.ContainsKey($requiredId) | Should -Be $true
                $byId[$requiredId].Order | Should -BeLessThan $step.Order
            }
        }
    }

    It 'keeps the five sections in order' {
        foreach ($step in $script:steps) {
            $path = Join-Path $script:repo (($step.PagePath -replace '/', '\'))
            $text = [System.IO.File]::ReadAllText($path)
            $position = -1
            foreach ($heading in $script:sections) {
                $found = $text.IndexOf($heading)
                $found | Should -BeGreaterThan $position
                $position = $found
            }
        }
    }

    It 'tells the reader to run house check for that id' {
        foreach ($step in $script:steps) {
            $path = Join-Path $script:repo (($step.PagePath -replace '/', '\'))
            $text = [System.IO.File]::ReadAllText($path)
            $verifyAt = $text.IndexOf('## Verify')
            $failAt = $text.IndexOf('## If it fails')
            $verify = $text.Substring($verifyAt, $failAt - $verifyAt)
            $verify | Should -Match ("house check {0}" -f [regex]::Escape($step.Id))
        }
    }

    It 'never puts a password-printing line in a powershell block' {
        # An agent may run every powershell block on a page; a line that only prints a password must be human-only text.
        $printer = '(?m)^\s*\(.*\)\.GetNetworkCredential\(\)\.Password\s*$'
        foreach ($page in @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'runbook') -Filter '*.md')) {
            $text = [System.IO.File]::ReadAllText($page.FullName)
            foreach ($block in [regex]::Matches($text, '(?s)```powershell\r?\n(.*?)\r?\n```')) {
                $block.Groups[1].Value | Should -Not -Match $printer -Because $page.Name
            }
        }
    }
}

Describe 'mutating command detector' {
    It 'finds nothing in the real checks or lib, and New-Object is allowed' {
        $checks = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'checks') -Filter '*.ps1')
        foreach ($check in $checks) {
            $text = [System.IO.File]::ReadAllText($check.FullName)
            $allowMarker = $check.Name -eq 'guest-shares.ps1'
            Test-HouseMutatingText -Text $text -AllowProbeMarker:$allowMarker | Should -Be $false
        }
        $modules = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'lib') -Filter '*.psm1')
        $modules.Count | Should -BeGreaterThan 0
        foreach ($module in $modules) {
            $text = [System.IO.File]::ReadAllText($module.FullName)
            Test-HouseMutatingText -Text $text | Should -Be $false
        }
        # Building a cmdlet name from string pieces to dodge this scan is not allowed in lib.
        [System.IO.File]::ReadAllText((Join-Path $script:repo 'lib\House.psm1')) | Should -Not -Match "&\s*\(\s*'(New|Set|Remove|Add)-'\s*\+"
        Test-HouseMutatingText -Text 'New-Object System.Text.StringBuilder' | Should -Be $false
        Test-HouseMutatingText -Text "Set-StrictMode -Version Latest" | Should -Be $false
        Test-HouseMutatingText -Text "function Set-HouseExample { }" | Should -Be $false
        Test-HouseMutatingText -Text "Remove-Item `$env:TEMP\x" | Should -Be $true
    }

    It 'does not let checks reference HouseDo' {
        $checks = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'checks') -Filter '*.ps1')
        foreach ($check in $checks) {
            $text = [System.IO.File]::ReadAllText($check.FullName)
            $text | Should -Not -Match 'HouseDo'
        }
    }

    It 'ignores a commented command' {
        Test-HouseMutatingText -Text "# Set-Item -Path 'HKCU:\Software\Example'" | Should -Be $false
    }

    It 'accepts checks/preflight.ps1 as read-only' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repo 'checks\preflight.ps1'))
        Test-HouseMutatingText -Text $text | Should -Be $false
    }

    It 'keeps a single Hyper-V SKU list' {
        $needle = (@(Get-HouseHyperVSkus) -join ', ')
        $hits = 0
        $files = New-Object System.Collections.Generic.List[string]
        foreach ($name in @('house.ps1', 'README.md', 'AGENTS.md', 'ARCHITECTURE.md', 'house.config.example.psd1')) {
            $files.Add((Join-Path $script:repo $name))
        }
        foreach ($dir in @('checks', 'lib', 'runbook', 'tests', 'tools', 'examples', 'rules', 'schemas')) {
            Get-ChildItem -LiteralPath (Join-Path $script:repo $dir) -Recurse -File | ForEach-Object { $files.Add($_.FullName) }
        }
        foreach ($file in $files) {
            $ext = [System.IO.Path]::GetExtension($file)
            if (@('.ps1', '.psm1', '.md', '.psd1', '.json', '.yaml', '.yml') -notcontains $ext) { continue }
            $text = [System.IO.File]::ReadAllText($file)
            $hits += [regex]::Matches($text, [regex]::Escape($needle)).Count
        }
        $hits | Should -Be 1
    }

    It 'keeps rules/hooks read-only' {
        $hooks = @(Get-ChildItem -LiteralPath (Join-Path $script:repo 'rules\hooks') -Filter '*.ps1')
        $hooks.Count | Should -BeGreaterThan 0
        foreach ($hook in $hooks) {
            $text = [System.IO.File]::ReadAllText($hook.FullName)
            Test-HouseMutatingText -Text $text | Should -Be $false
        }
    }

    It 'allows only the guest-shares probe marker write' {
        $path = Join-Path $script:repo 'checks\guest-shares.ps1'
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -Match '\.house-probe-'
        Test-HouseMutatingText -Text $text | Should -Be $true
        Test-HouseMutatingText -Text $text -AllowProbeMarker | Should -Be $false
        $marker = "Set-Content -LiteralPath (`$root + '\' + ('.house-probe-' + `$stamp)) -Value 'ok'"
        Test-HouseMutatingText -Text $marker -AllowProbeMarker | Should -Be $false
        Test-HouseMutatingText -Text $marker | Should -Be $true
        $bypass = "Remove-Item -LiteralPath 'C:\Windows\x' -Force # .house-probe-"
        Test-HouseMutatingText -Text $bypass -AllowProbeMarker | Should -Be $true
        $drive = "Remove-Item -LiteralPath ('C:\temp\' + ('.house-probe-' + `$stamp)) -Force"
        Test-HouseMutatingText -Text $drive -AllowProbeMarker | Should -Be $true
    }

    It 'keeps the house default password and the desktop sign-in pages' {
        $windows = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\05-windows.md'))
        $doAt = $windows.IndexOf('## Do')
        $verifyAt = $windows.IndexOf('## Verify')
        $do = $windows.Substring($doAt, $verifyAt - $doAt)
        $do | Should -Not -Match 'RandomNumberGenerator'
        $do | Should -Match "'123456'"
        $age = $do.IndexOf('net accounts /maxpwage:unlimited')
        $del = $do.IndexOf('del /f')
        $age | Should -BeGreaterThan -1
        $del | Should -BeGreaterThan $age
        $login = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\14-claude-login.md'))
        $login | Should -Match '123456'
        $login | Should -Match 'daily\.md'
        $login | Should -Not -Match 'GetNetworkCredential'
        $readme = [System.IO.File]::ReadAllText((Join-Path $script:repo 'README.md'))
        $readme | Should -Match '123456'
        $readme | Should -Match '## First sign-in'
    }

    It 'flags a fixture check that contains Set-Item' {
        $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\mutating-check.ps1'))
        Test-HouseMutatingText -Text $text | Should -Be $true
    }
}

Describe 'front matter' {
    It 'parses strings, ints, bools and arrays' {
        $text = "---`r`nid: sample`r`ntitle: `"Hello`"`r`norder: 2`r`nrequires: []`r`nruns_on: host`r`nadmin: false`r`nreboot: true`r`nhuman: true`r`n# comment`r`n`r`n---`r`n"
        $front = ConvertFrom-HouseFrontMatter -Text $text
        $front['id'] | Should -Be 'sample'
        $front['title'] | Should -Be 'Hello'
        $front['order'] | Should -BeOfType ([int])
        $front['order'] | Should -Be 2
        @($front['requires']).Count | Should -Be 0
        $front['admin'] | Should -Be $false
        $front['reboot'] | Should -Be $true
        $front['human'] -is [bool] | Should -Be $true
    }

    It 'throws front matter line errors for unsupported lines' {
        $text = "---`r`nnot a key`r`n---`r`n"
        { ConvertFrom-HouseFrontMatter -Text $text } | Should -Throw -ExpectedMessage 'front matter: line 2:*'
    }

    It 'resolves the repo root from the module path' {
        Get-HouseRepoRoot | Should -Be $script:repo
    }
}

Describe 'Step order inside runbook pages' {
    It 'writes the console files in step 6 before polling the check that requires them' {
        # The poll waits for consoleSettings; with the poll first, a brand-new VM never passed (drill 2026-10-13).
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\06-vm-online.md'))
        $write = $text.IndexOf('New-HouseConsoleSettings -Config')
        $poll = $text.IndexOf('check vm-online --json')
        $write | Should -BeGreaterThan -1
        $poll | Should -BeGreaterThan $write
    }
}

Describe 'Blueprint reads in runbook pages' {
    It 'reads house.config.psd1 only through Import-HouseConfig' {
        # Import-PowerShellDataFile reads a BOM-less UTF-8 blueprint in the host code page, so on a
        # Chinese-locale host step 9 failed to parse it and silently skipped every flagged tool.
        $hits = @(Get-ChildItem -Path (Join-Path $script:repo 'runbook') -Recurse -File -Include *.md |
            Select-String -Pattern 'Import-PowerShellDataFile' |
            ForEach-Object { $_.Path + ':' + $_.LineNumber })
        $hits | Should -BeNullOrEmpty
    }

    It 'imports the house module in every page that calls Import-HouseConfig' {
        # Do blocks run in a fresh scope; step 9 called Import-HouseConfig without the module and lost its flags.
        $missing = @(Get-ChildItem -Path (Join-Path $script:repo 'runbook') -Recurse -File -Include *.md |
            Where-Object {
                (Select-String -LiteralPath $_.FullName -Pattern 'Import-HouseConfig' -SimpleMatch -Quiet) -and
                -not (Select-String -LiteralPath $_.FullName -Pattern 'Import-Module .*lib\\House\.psm1' -Quiet)
            } |
            ForEach-Object { $_.Name })
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'JSON arrays on Windows PowerShell 5.1' {
    It 'never wraps ConvertFrom-Json or Invoke-RestMethod in @() in lib, checks or runbook pages' {
        # On 5.1 ConvertFrom-Json emits a JSON array as one object, so @(...) makes a
        # one-item list whose properties join every row (step 13 failed live this way;
        # Invoke-RestMethod does the same, which hid every Node LTS row in step 9).
        $hits = @(Get-ChildItem -Path (Join-Path $script:repo 'lib'), (Join-Path $script:repo 'checks'), (Join-Path $script:repo 'runbook') -Recurse -File -Include *.ps1, *.psm1, *.md |
            Select-String -Pattern '@\(\s*(ConvertFrom-Json|Invoke-RestMethod)' |
            ForEach-Object { $_.Path + ':' + $_.LineNumber })
        $hits | Should -BeNullOrEmpty
    }

    It 'enumerates a parsed JSON array one row at a time without @()' {
        $rows = 0
        foreach ($row in (ConvertFrom-Json -InputObject '[{"b64":"AA=="},{"b64":"AQ=="}]')) {
            $null = [Convert]::FromBase64String([string]$row.b64)
            $rows++
        }
        $rows | Should -Be 2
    }
}

Describe 'PowerShell 7 compatibility' {
    It 'never passes a negative count to -split' {
        # PowerShell 7 reads a negative count as "split from the right": -1 returns the whole text
        # as one piece, so every runbook page lost its front matter under pwsh (seen 2026-10-13).
        $hits = @(Get-ChildItem -Path (Join-Path $script:repo 'lib'), (Join-Path $script:repo 'checks'), (Join-Path $script:repo 'runbook'), (Join-Path $script:repo 'rules') -Recurse -File -Include *.ps1, *.psm1, *.md -ErrorAction SilentlyContinue |
            Select-String -Pattern '-split\s+[^,]+,\s*-\d' |
            ForEach-Object { $_.Path + ':' + $_.LineNumber })
        $hits += @(Select-String -LiteralPath (Join-Path $script:repo 'house.ps1') -Pattern '-split\s+[^,]+,\s*-\d' | ForEach-Object { 'house.ps1:' + $_.LineNumber })
        $hits | Should -BeNullOrEmpty
    }
}
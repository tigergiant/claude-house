BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:fixture = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path (Join-Path $script:fixture 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:repo 'house.ps1') -Destination (Join-Path $script:fixture 'house.ps1')
    Copy-Item -LiteralPath (Join-Path $script:repo 'lib\House.psm1') -Destination (Join-Path $script:fixture 'lib\House.psm1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\cli\runbook') -Destination (Join-Path $script:fixture 'runbook') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\cli\checks') -Destination (Join-Path $script:fixture 'checks') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\cli\blueprint.psd1') -Destination (Join-Path $script:fixture 'house.config.psd1')

    function Invoke-FixtureCli {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$CliArgs,
            [hashtable]$EnvSet
        )
        $previous = @{}
        if ($EnvSet) {
            foreach ($key in @($EnvSet.Keys)) {
                $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
                [Environment]::SetEnvironmentVariable($key, [string]$EnvSet[$key], 'Process')
            }
        }
        try {
            $house = Join-Path $script:fixture 'house.ps1'
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $house @CliArgs 2>&1
            $code = $LASTEXITCODE
            $text = @($output | ForEach-Object { "$_" }) -join "`n"
            return [pscustomobject]@{ Text = $text; Code = $code }
        }
        finally {
            if ($EnvSet) {
                foreach ($key in @($EnvSet.Keys)) {
                    [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
                }
            }
        }
    }

    function New-MarkerDir {
        $dir = Join-Path $TestDrive ("markers-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }
}

Describe 'house.ps1 usage' {
    It 'rejects an unknown verb with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('nope')
        $result.Code | Should -Be 2
        $result.Text | Should -Match 'Usage:'
    }

    It 'rejects an unknown option with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('guide', '--nope')
        $result.Code | Should -Be 2
        $result.Text | Should -Match 'Usage:'
    }

    It 'rejects a missing check id with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('check')
        $result.Code | Should -Be 2
    }

    It 'rejects a missing step id with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('step', '--json')
        $result.Code | Should -Be 2
    }

    It 'rejects an unknown step id with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('step', 'missing-step')
        $result.Code | Should -Be 2
    }

    It 'rejects extra preflight arguments with exit 2' {
        $result = Invoke-FixtureCli -CliArgs @('preflight', 'extra')
        $result.Code | Should -Be 2
        $result.Text | Should -Match 'Usage:'
        $result.Text | Should -Match 'preflight'
    }
}

Describe 'house.ps1 guide and step' {
    It 'lists fixture steps in order and ignores daily.md' {
        $result = Invoke-FixtureCli -CliArgs @('guide', '--json')
        $result.Code | Should -Be 0
        $json = $result.Text | ConvertFrom-Json
        @($json.steps).Count | Should -Be 3
        $json.steps[0].id | Should -Be 'aa'
        $json.steps[1].id | Should -Be 'bb'
        $json.steps[2].id | Should -Be 'cc'
        $json.steps[0].order | Should -Be 0
        $json.steps[1].order | Should -Be 1
        $json.steps[2].order | Should -Be 2
        $json.steps[1].requires | Should -Be 'aa'
        $json.steps[1].admin | Should -Be $true
        $json.steps[1].human | Should -Be $true
        $json.steps[2].runs_on | Should -Be 'guest'
        $json.steps[2].reboot | Should -Be $true
        $json.steps[0].page | Should -Be 'runbook/00-aa.md'
        $json.note | Should -Be 'Run preflight first, before step 0.'
    }

    It 'tells the agent to run preflight before step 0' {
        $result = Invoke-FixtureCli -CliArgs @('guide')
        $result.Code | Should -Be 0
        $result.Text | Should -Match 'Run preflight first, before step 0\.'
    }

    It 'replaces blueprint placeholders in the page' {
        $result = Invoke-FixtureCli -CliArgs @('--json', 'step', 'aa')
        $result.Code | Should -Be 0
        $json = $result.Text | ConvertFrom-Json
        $json.id | Should -Be 'aa'
        $json.page | Should -Be 'runbook/00-aa.md'
        $json.content | Should -Match 'FixtureHouse'
        $json.content | Should -Match '192\.0\.2\.1'
        $json.content | Should -Match '192\.0\.2\.2'
        $json.content | Should -Match '3128'
        $json.content | Should -Match '7890'
        $json.content | Should -Match 'HouseNet'
        $json.content | Should -Match 'fixtureuser'
        $json.content | Should -Match 'computer FixtureHouse'
        $json.content | Should -Match 'C:\\Hyper-V\\fixture'
        $json.content | Should -Match 'C:\\ISO\\Win11\.iso'
        $json.content | Should -Match 'Windows 11 Pro'
        $json.content | Should -Match 'cpu 2'
        $json.content | Should -Match 'memory 8'
        $json.content | Should -Match 'disk 80'
        $json.content | Should -Match 'en-US'
        $json.content | Should -Match 'zone UTC'
        $json.content | Should -Not -Match '\{\{House\.Name\}\}'
        $json.content | Should -Not -Match '\{\{House\.ComputerName\}\}'
    }

    It 'leaves placeholders in place when the config is missing' {
        $missing = Join-Path $TestDrive 'missing.config.psd1'
        $result = Invoke-FixtureCli -CliArgs @('step', 'aa', '--json', '--config', $missing)
        $result.Code | Should -Be 0
        $json = $result.Text | ConvertFrom-Json
        $json.content | Should -Match '\{\{House\.Name\}\}'
    }
}

Describe 'house.ps1 check, next and doctor' {
    It 'returns exit 0 for a passing check' {
        $marker = New-MarkerDir
        $result = Invoke-FixtureCli -CliArgs @('check', 'aa') -EnvSet @{
            HOUSE_CHECK_SPEC   = 'aa=pass'
            HOUSE_MARKER_DIR   = $marker
        }
        $result.Code | Should -Be 0
        $result.Text | Should -Match 'PASS aa: detail-aa-pass'
    }

    It 'returns exit 1 for a failing check' {
        $result = Invoke-FixtureCli -CliArgs @('check', 'aa', '--json') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=fail'
        }
        $result.Code | Should -Be 1
        $json = $result.Text | ConvertFrom-Json
        $json.status | Should -Be 'fail'
        $json.ok | Should -Be $false
        $json.detail | Should -Be 'detail-aa-fail'
    }

    It 'reports blocked and does not run the blocked check' {
        $marker = New-MarkerDir
        $result = Invoke-FixtureCli -CliArgs @('check', 'bb', '--json') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=fail;bb=pass;cc=pass'
            HOUSE_MARKER_DIR = $marker
        }
        $result.Code | Should -Be 3
        $json = $result.Text | ConvertFrom-Json
        $json.status | Should -Be 'blocked'
        $json.ok | Should -Be $false
        $json.detail | Should -Be 'blocked by: aa'
        $json.fix | Should -Be 'runbook/00-aa.md'
        (Test-Path -LiteralPath (Join-Path $marker 'aa.ran')) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $marker 'bb.ran')) | Should -Be $false
    }

    It 'next returns the first non-passing step' {
        $result = Invoke-FixtureCli -CliArgs @('next') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=pass;bb=fail;cc=pass'
        }
        $result.Code | Should -Be 1
        $result.Text | Should -Match 'NEXT bb \(Beta step\) -> runbook/01-bb.md'
        $result.Text | Should -Match 'detail-bb-fail'
    }

    It 'next json reports done when every step passes' {
        $result = Invoke-FixtureCli -CliArgs @('next', '--json') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=pass;bb=pass;cc=pass'
        }
        $result.Code | Should -Be 0
        $result.Text | Should -Match 'ALL DONE'
        $result.Text | Should -Match '"done":true'
    }

    It 'doctor continues after a failure and counts every status' {
        $marker = New-MarkerDir
        $result = Invoke-FixtureCli -CliArgs @('doctor', '--json') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=fail;bb=pass;cc=pass'
            HOUSE_MARKER_DIR = $marker
        }
        $result.Code | Should -Be 1
        $json = $result.Text | ConvertFrom-Json
        $json.summary.pass | Should -Be 1
        $json.summary.fail | Should -Be 1
        $json.summary.blocked | Should -Be 1
        @($json.results).Count | Should -Be 3
        $json.results[0].status | Should -Be 'fail'
        $json.results[1].status | Should -Be 'blocked'
        $json.results[2].status | Should -Be 'pass'
        (Test-Path -LiteralPath (Join-Path $marker 'cc.ran')) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $marker 'bb.ran')) | Should -Be $false
    }

    It 'prints a text summary from doctor' {
        $result = Invoke-FixtureCli -CliArgs @('doctor') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=fail;bb=pass;cc=pass'
        }
        $result.Code | Should -Be 1
        $result.Text | Should -Match 'FAIL aa:'
        $result.Text | Should -Match 'BLOCKED bb:'
        $result.Text | Should -Match 'PASS cc:'
        $result.Text | Should -Match 'SUMMARY pass=1 fail=1 blocked=1'
    }

    It 'turns a thrown check into fail with check error' {
        $result = Invoke-FixtureCli -CliArgs @('check', 'aa', '--json') -EnvSet @{
            HOUSE_CHECK_SPEC = 'aa=throw'
        }
        $result.Code | Should -Be 1
        $json = $result.Text | ConvertFrom-Json
        $json.status | Should -Be 'fail'
        $json.ok | Should -Be $false
        $json.detail | Should -Match '^check error:'
        $json.detail | Should -Match 'boom-aa'
    }

    It 'turns an invalid check object into fail' {
        $result = Invoke-FixtureCli -CliArgs @('check', 'cc') -EnvSet @{
            HOUSE_CHECK_SPEC = 'cc=invalid'
        }
        $result.Code | Should -Be 1
        $result.Text | Should -Match 'FAIL cc: check error: invalid check result'
    }
}

Describe 'house.ps1 preflight' {
    BeforeAll {
        function New-CliDrive {
            param([string]$DeviceId, [string]$FileSystem, [int64]$FreeBytes)
            return [pscustomobject]@{
                DeviceId   = $DeviceId
                DriveType  = 3
                FileSystem = $FileSystem
                FreeBytes  = $FreeBytes
            }
        }

        function New-CliFacts {
            param(
                [string]$Model = 'Z790 AORUS MASTER',
                [string]$Manufacturer = 'Gigabyte',
                [bool]$HypervisorPresent = $true,
                [bool]$VmmsExists = $true,
                [bool]$VmmsRunning = $true,
                [bool]$HyperVModule = $true,
                [bool]$Hgs = $true,
                $Drives
            )
            if ($null -eq $Drives) {
                $Drives = @(
                    (New-CliDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 150GB),
                    (New-CliDrive -DeviceId 'F:' -FileSystem 'FAT32' -FreeBytes 8GB),
                    (New-CliDrive -DeviceId 'E:' -FileSystem 'ReFS' -FreeBytes 220GB)
                )
            }
            return [pscustomobject]@{
                Caption             = 'Fixture Windows 11 Pro'
                Sku                 = 48
                Build               = 26200
                Is64BitOs           = $true
                Processors          = @([pscustomobject]@{
                    Name                                    = 'Fixture CPU 9000'
                    Architecture                            = 9
                    VirtualizationFirmwareEnabled           = $true
                    SecondLevelAddressTranslationExtensions = $false
                })
                Model               = $Model
                Manufacturer        = $Manufacturer
                HypervisorPresent   = $HypervisorPresent
                TotalPhysicalMemory = 32GB
                Drives              = @($Drives)
                VmmsExists          = $VmmsExists
                VmmsRunning         = $VmmsRunning
                HyperVModule        = $HyperVModule
                HgsGuardian         = $Hgs
                Elevated            = $true
                ExecutionPolicy     = 'Bypass'
            }
        }

        function Invoke-PreflightCli {
            param(
                [Parameter(Mandatory = $true)]
                $Facts,
                [string[]]$CliArgs = @('preflight', '--json')
            )
            $root = Join-Path $TestDrive ('preflight-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'checks') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:repo 'house.ps1') -Destination (Join-Path $root 'house.ps1')
            Copy-Item -LiteralPath (Join-Path $script:repo 'lib\House.psm1') -Destination (Join-Path $root 'lib\House.psm1')
            Copy-Item -LiteralPath (Join-Path $script:repo 'checks\preflight.ps1') -Destination (Join-Path $root 'checks\preflight.ps1')
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $json = ConvertTo-Json -InputObject $Facts -Depth 6 -Compress
            [System.IO.File]::WriteAllText((Join-Path $root 'facts.json'), $json, $utf8)
            # Only this throwaway copy of the module learns to read fake facts; the shipped module has no test seam.
            $override = "`r`nfunction Get-HouseHostFacts { return ([System.IO.File]::ReadAllText((Join-Path `$PSScriptRoot '..\facts.json')) | ConvertFrom-Json) }`r`n"
            [System.IO.File]::AppendAllText((Join-Path $root 'lib\House.psm1'), $override, $utf8)
            $house = Join-Path $root 'house.ps1'
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $house @CliArgs 2>&1
            $code = $LASTEXITCODE
            $text = @($output | ForEach-Object { "$_" }) -join "`n"
            return [pscustomobject]@{ Text = $text; Code = $code }
        }
    }

    It 'returns exit 0 and JSON for fixture A' {
        $result = Invoke-PreflightCli -Facts (New-CliFacts)
        $result.Code | Should -Be 0
        $json = $result.Text | ConvertFrom-Json
        $json.id | Should -Be 'preflight'
        $json.ok | Should -Be $true
        $json.status | Should -Be 'pass'
        @($json.evidence.items | Where-Object { $_.level -eq 'blocker' }).Count | Should -Be 0
        @($json.evidence.items | Where-Object { $_.name -eq 'cpu-virtualization' })[0].value | Should -Be 'unknown (hypervisor running)'
    }

    It 'ends text output with VERDICT compatible for fixture A' {
        $result = Invoke-PreflightCli -Facts (New-CliFacts) -CliArgs @('preflight')
        $result.Code | Should -Be 0
        $result.Text.Trim() | Should -Match 'VERDICT compatible$'
        $result.Text | Should -Match 'INFO cpu-virtualization: unknown \(hypervisor running\)'
        # Setup items that are already satisfied must not read as work still to do.
        $result.Text | Should -Match 'OK hyperv:'
        $result.Text | Should -Not -Match 'FIXABLE'
    }

    It 'returns exit 1 and JSON for fixture B' {
        $facts = New-CliFacts -Model 'Virtual Machine' -Manufacturer 'Microsoft Corporation' -VmmsExists $false -VmmsRunning $false -HyperVModule $false -Hgs $false -Drives @(
            (New-CliDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 32GB)
        )
        $result = Invoke-PreflightCli -Facts $facts
        $result.Code | Should -Be 1
        $json = $result.Text | ConvertFrom-Json
        $json.ok | Should -Be $false
        $json.status | Should -Be 'fail'
        $names = @($json.evidence.items | Where-Object { $_.level -eq 'blocker' } | ForEach-Object { $_.name }) -join ','
        $names | Should -Be 'nested,disk'
    }

    It 'ends text output with the blocker verdict for fixture B' {
        $facts = New-CliFacts -Model 'Virtual Machine' -Manufacturer 'Microsoft Corporation' -VmmsExists $false -VmmsRunning $false -HyperVModule $false -Hgs $false -Drives @(
            (New-CliDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 32GB)
        )
        $result = Invoke-PreflightCli -Facts $facts -CliArgs @('preflight')
        $result.Code | Should -Be 1
        $result.Text | Should -Match 'BLOCKER nested:'
        $result.Text | Should -Match 'BLOCKER disk:'
        $result.Text | Should -Match 'FIXABLE hyperv:'
        $result.Text.Trim() | Should -Match 'VERDICT not compatible \(2 blockers\)$'
    }
}

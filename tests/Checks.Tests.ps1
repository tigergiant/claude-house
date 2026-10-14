BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:configs = Join-Path $PSScriptRoot 'fixtures\configs'
    Import-Module (Join-Path $script:repo 'lib\House.psm1') -Force
    $script:hostCheck = Join-Path $script:repo 'checks\host-ready.ps1'
    $script:blueprintCheck = Join-Path $script:repo 'checks\blueprint.ps1'

    function New-BlueprintConfig {
        return @{
            House = @{
                Name      = 'FixtureHouse'
                Path      = 'C:\Hyper-V\fixture'
                IsoPath   = 'C:\ISO\Win11.iso'
                ImageName = 'Windows 11 Pro'
                CpuCount  = 2
                MemoryGB  = 8
                DiskGB    = 80
                UserName  = 'fixtureuser'
                Locale    = 'en-US'
                TimeZone  = 'UTC'
            }
            Network = @{
                SwitchName   = 'HouseNet'
                Subnet       = '192.0.2.0/24'
                HostIP       = '192.0.2.1'
                VmIP         = '192.0.2.2'
                GatePort     = 3128
                ProxyAppPort = 7890
                ProxyMode    = 'Global'
            }
            Shares = @()
            Tools  = @{}
            Rules  = @{}
        }
    }

    function New-BlueprintContext {
        param($Config, $ConfigError)
        return @{
            RepoRoot    = $script:repo
            Config      = $Config
            ConfigError = $ConfigError
        }
    }

    function Get-ThrownMessage {
        param([scriptblock]$Script)
        try {
            & $Script
        }
        catch {
            return $_.Exception.Message
        }
        throw 'expected a failure'
    }
}

Describe 'host-ready check' {
    BeforeEach {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; OperatingSystemSKU = 48; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        Mock Get-WindowsOptionalFeature { return [pscustomobject]@{ State = 'Enabled' } }
        Mock Test-HouseElevation { return $true }
    }

    It 'passes when every host fact is ready' {
        $result = & $script:hostCheck -Context @{}
        $result.id | Should -Be 'host-ready'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'host ready'
        $result.evidence.editionOk | Should -Be $true
        $result.evidence.elevated | Should -Be $true
        $result.evidence.hyperv | Should -Be $true
        $result.evidence.virtualization | Should -Be $true
        $result.evidence.ramOk | Should -Be $true
        $result.evidence.edition | Should -Be 'Microsoft Windows 11 Pro'
        $result.fix | Should -Be 'runbook/00-host-ready.md#if-it-fails'
    }

    It 'passes Windows 11 Enterprise' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Enterprise'; OperatingSystemSKU = 4; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $true
        $result.evidence.editionOk | Should -Be $true
    }

    It 'passes when the hypervisor is present even if firmware reports false' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Education'; OperatingSystemSKU = 121; BuildNumber = '22631' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 32GB; HypervisorPresent = $true } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $false } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $true
        $result.evidence.virtualization | Should -Be $true
    }

    It 'fails when the edition is Windows 11 Home' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Home'; OperatingSystemSKU = 101; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.editionOk | Should -Be $false
        $result.detail | Should -Be 'edition'
    }

    It 'passes a localized Windows 11 Pro caption by SKU and build' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = ('Microsoft Windows 11 ' + [char]0x4E13 + [char]0x4E1A + [char]0x7248); OperatingSystemSKU = 48; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $true
        $result.evidence.editionOk | Should -Be $true
        $result.evidence.sku | Should -Be 48
    }

    It 'fails Windows 10 Pro even though the SKU is Pro' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 10 Pro'; OperatingSystemSKU = 48; BuildNumber = '19045' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.editionOk | Should -Be $false
        $result.detail | Should -Be 'edition'
    }

    It 'fails when the shell is not elevated and does not query Hyper-V' {
        Mock Test-HouseElevation { return $false }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.elevated | Should -Be $false
        $result.evidence.hyperv | Should -Be $false
        $result.detail | Should -Be 'elevated, hyper-v'
        Should -Invoke Get-WindowsOptionalFeature -Times 0
    }

    It 'fails when Hyper-V is not enabled' {
        Mock Get-WindowsOptionalFeature { return [pscustomobject]@{ State = 'Disabled' } }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.hyperv | Should -Be $false
        $result.evidence.elevated | Should -Be $true
        $result.detail | Should -Be 'hyper-v'
    }

    It 'fails when virtualization firmware and the hypervisor are both off' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; OperatingSystemSKU = 48; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = 16GB; HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $false } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.virtualization | Should -Be $false
        $result.detail | Should -Be 'virtualization'
    }

    It 'fails when RAM is under 16 GB' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; OperatingSystemSKU = 48; BuildNumber = '26100' } }
                'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory = (16GB - 1); HypervisorPresent = $false } }
                'Win32_Processor' { return [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
                default { throw "unexpected class $ClassName" }
            }
        }
        $result = & $script:hostCheck -Context @{}
        $result.ok | Should -Be $false
        $result.evidence.ramOk | Should -Be $false
        $result.detail | Should -Be 'ram'
    }
}

Describe 'blueprint check' {
    BeforeEach {
        Mock Test-Path { return $true } -ParameterFilter {
            $PathType -eq 'Leaf' -and ($LiteralPath -eq 'C:\ISO\Win11.iso' -or $Path -eq 'C:\ISO\Win11.iso')
        }
        Mock Get-PSDrive { return [pscustomobject]@{ Name = 'C'; Free = 90GB } } -ParameterFilter { $Name -eq 'C' }
        Mock Get-HouseVolumeMediaType { return 'SSD' }
        Mock Get-CimInstance { return [pscustomobject]@{ TotalPhysicalMemory = 12GB } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock Get-NetIPAddress {
            return [pscustomobject]@{
                IPAddress      = '203.0.113.10'
                PrefixLength   = 24
                InterfaceAlias = 'Ethernet'
            }
        }
    }

    It 'passes a valid blueprint' {
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'blueprint ready'
        $result.evidence.config | Should -Be $true
        $result.evidence.iso | Should -Be $true
        $result.evidence.disk | Should -Be $true
        $result.evidence.ram | Should -Be $true
        $result.evidence.subnet | Should -Be $true
        $result.fix | Should -Be 'runbook/01-blueprint.md#if-it-fails'
    }

    It 'ignores the house switch when HostIP is already on it' {
        Mock Get-NetIPAddress {
            return @(
                [pscustomobject]@{ IPAddress = '192.0.2.1'; PrefixLength = 24; InterfaceAlias = 'vEthernet (HouseNet)' }
                [pscustomobject]@{ IPAddress = '203.0.113.10'; PrefixLength = 24; InterfaceAlias = 'Ethernet' }
            )
        }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.subnet | Should -Be $true
    }

    It 'fails ssd when House.Path is on a spinning hard disk' {
        Mock Get-HouseVolumeMediaType { return 'HDD' }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'ssd'
        $result.evidence.ssd | Should -Be $false
        $result.evidence.disk | Should -Be $true
        $result.evidence.diskMedia | Should -Be 'HDD'
    }

    It 'passes ssd when Windows cannot tell the disk type' {
        Mock Get-HouseVolumeMediaType { return '' }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.ssd | Should -Be $true
    }
    It 'fails when the config was not loaded' {
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config $null -ConfigError $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'house.config.psd1 not found'
        $result.evidence.config | Should -Be $false
        Should -Invoke Get-NetIPAddress -Times 0
    }

    It 'reports the config error when one was captured' {
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config $null -ConfigError 'missing House.Name')
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'missing House.Name'
    }

    It 'fails when the ISO is missing' {
        Mock Test-Path { return $false } -ParameterFilter {
            $PathType -eq 'Leaf' -and ($LiteralPath -eq 'C:\ISO\Win11.iso' -or $Path -eq 'C:\ISO\Win11.iso')
        }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.iso | Should -Be $false
        $result.detail | Should -Be 'iso'
    }

    It 'fails when the volume does not have DiskGB + 10 GB free' {
        Mock Get-PSDrive { return [pscustomobject]@{ Name = 'C'; Free = (90GB - 1) } } -ParameterFilter { $Name -eq 'C' }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.disk | Should -Be $false
        $result.detail | Should -Be 'disk'
    }

    It 'fails when host RAM is under MemoryGB + 4 GB' {
        Mock Get-CimInstance { return [pscustomobject]@{ TotalPhysicalMemory = (12GB - 1) } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.ram | Should -Be $false
        $result.detail | Should -Be 'ram'
    }

    It 'fails when the subnet overlaps an existing IPv4 network' {
        Mock Get-NetIPAddress {
            return [pscustomobject]@{
                IPAddress      = '192.0.2.40'
                PrefixLength   = 24
                InterfaceAlias = 'Ethernet'
            }
        }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.subnet | Should -Be $false
        $result.detail | Should -Be 'subnet'
    }

    It 'still fails when another adapter overlaps even if the house switch is ours' {
        Mock Get-NetIPAddress {
            return @(
                [pscustomobject]@{ IPAddress = '192.0.2.1'; PrefixLength = 24; InterfaceAlias = 'vEthernet (HouseNet)' }
                [pscustomobject]@{ IPAddress = '192.0.2.50'; PrefixLength = 24; InterfaceAlias = 'Ethernet' }
            )
        }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.subnet | Should -Be $false
    }

    It 'fails when Look.Theme is not light or none' {
        $config = New-BlueprintConfig
        $config.Look = @{ Theme = 'dark' }
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'Look.Theme must be light or none'
    }

    It 'passes when Look is omitted' {
        $config = New-BlueprintConfig
        $result = & $script:blueprintCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'blueprint ready'
    }
}

Describe 'Import-HouseConfig' {
    It 'loads a valid blueprint' {
        $config = Import-HouseConfig -Path (Join-Path $script:configs 'valid.psd1')
        $config.House.Name | Should -Be 'FixtureHouse'
        $config.Network.ProxyMode | Should -Be 'Global'
        @($config.Shares).Count | Should -Be 1
    }

    It 'keeps a Chinese path intact in a BOM-less UTF-8 blueprint' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:configs 'valid.psd1'))
        $folder = 'D:\' + [char]0x8D44 + [char]0x6599
        $text = [regex]::Replace($text, "HostPath\s*=\s*'[^']*'", "HostPath = '$folder'")
        $text | Should -Match ([regex]::Escape($folder))
        $path = Join-Path $TestDrive 'utf8-nobom.psd1'
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
        $config = Import-HouseConfig -Path $path
        [string]@($config.Shares)[0].HostPath | Should -Be $folder
    }

    It 'accepts an empty share list and Rule mode' {
        $config = Import-HouseConfig -Path (Join-Path $script:configs 'empty-shares.psd1')
        @($config.Shares).Count | Should -Be 0
        $config.Network.ProxyMode | Should -Be 'Rule'
    }

    It 'fails when a required key is missing' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'missing-key.psd1') }
        $message | Should -Match 'missing House\.TimeZone'
    }

    It 'names a Password key nested in Shares[0]' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'secret-share.psd1') }
        $message | Should -Match 'secret key: Shares\[0\]\.Password'
    }

    It 'fails on a bad ProxyMode' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'bad-proxy.psd1') }
        $message | Should -Match 'Network\.ProxyMode must be Global, Rule, or Direct'
    }

    It 'fails when VmIP is outside the subnet' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'vmip-outside.psd1') }
        $message | Should -Match 'Network\.VmIP is outside Network\.Subnet'
    }

    It 'reports multiple problems together' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'multi.psd1') }
        $message | Should -Match 'missing House\.Locale'
        $message | Should -Match 'Network\.ProxyMode must be Global, Rule, or Direct'
        $message | Should -Match 'Network\.VmIP is outside Network\.Subnet'
    }

    It 'fails when HostIP and VmIP are the same' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'same-ip.psd1') }
        $message | Should -Match 'Network\.HostIP and Network\.VmIP must differ'
    }

    It 'fails when the subnet is not a CIDR prefix' {
        $message = Get-ThrownMessage { Import-HouseConfig -Path (Join-Path $script:configs 'bad-subnet.psd1') }
        $message | Should -Match 'Network\.Subnet must be CIDR a\.b\.c\.d/nn'
    }

    It 'throws when the guest credential file is missing' {
        $ctx = New-HouseContext -RepoRoot $script:repo -ConfigPath (Join-Path $script:configs 'valid.psd1')
        { & $ctx.InvokeGuest { return 1 } } | Should -Throw -ExpectedMessage '*guest credential not set up yet*'
    }
}

Describe 'host-network check' {
    BeforeAll {
        $script:hostNetworkCheck = Join-Path $script:repo 'checks\host-network.ps1'
        # Pester can only mock commands that exist. Machines without the Hyper-V
        # module (CI runners, nested VMs) get a throwaway stub so the mocks bind.
        $script:stubbed = @()
        foreach ($name in 'Get-VMSwitch', 'Get-NetNat') {
            $needsStub = -not (Get-Command $name -ErrorAction SilentlyContinue)
            if ($needsStub -or $env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                if ($env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                    Set-Item -Path "function:global:$name" -Value { param($Name, $ErrorAction) } -Force
                }
                else {
                    Set-Item -Path "function:global:$name" -Value { param($Name, $ErrorAction) }
                }
                $script:stubbed += $name
            }
        }
    }

    AfterAll {
        foreach ($name in $script:stubbed) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        Mock Get-VMSwitch { return [pscustomobject]@{ Name = 'HouseNet'; SwitchType = 'Internal' } }
        Mock Get-NetIPAddress {
            return [pscustomobject]@{
                IPAddress      = '192.0.2.1'
                PrefixLength   = 24
                InterfaceAlias = 'vEthernet (HouseNet)'
            }
        }
        Mock Get-NetNat { return $null }
        Mock Get-NetIPInterface {
            return @(
                [pscustomobject]@{ InterfaceAlias = 'vEthernet (HouseNet)'; AddressFamily = 'IPv4'; Forwarding = 'Disabled' },
                [pscustomobject]@{ InterfaceAlias = 'vEthernet (HouseNet)'; AddressFamily = 'IPv6'; Forwarding = 'Disabled' }
            )
        }
    }

    It 'fails noforward when the host routes for the house interface' {
        foreach ($family in 'IPv4', 'IPv6') {
            Mock Get-NetIPInterface {
                return @(
                    [pscustomobject]@{ InterfaceAlias = 'vEthernet (HouseNet)'; AddressFamily = 'IPv4'; Forwarding = $(if ($family -eq 'IPv4') { 'Enabled' } else { 'Disabled' }) },
                    [pscustomobject]@{ InterfaceAlias = 'vEthernet (HouseNet)'; AddressFamily = 'IPv6'; Forwarding = $(if ($family -eq 'IPv6') { 'Enabled' } else { 'Disabled' }) }
                )
            }.GetNewClosure()
            $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
            $result.ok | Should -Be $false
            $result.evidence.noforward | Should -Be $false
            @($result.evidence.forwarding) -join ',' | Should -Be $family
            $result.detail | Should -Be 'noforward'
        }
    }

    It 'fails noforward when the house interface cannot be read' {
        Mock Get-NetIPInterface { return $null }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.noforward | Should -Be $false
        $result.detail | Should -Be 'noforward'
    }

    It 'passes when the switch, host address and NAT absence all hold' {
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.id | Should -Be 'host-network'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'house network ready'
        $result.evidence.switch | Should -Be $true
        $result.evidence.switchType | Should -Be 'Internal'
        $result.evidence.hostip | Should -Be $true
        $result.evidence.prefixOk | Should -Be $true
        $result.evidence.nonat | Should -Be $true
        @($result.evidence.natNames | Where-Object { $_ }).Count | Should -Be 0
        $result.evidence.noforward | Should -Be $true
        $result.fix | Should -Be 'runbook/02-host-network.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-VMSwitch -Times 0
        Should -Invoke Get-NetNat -Times 0
    }

    It 'fails when the switch is missing' {
        Mock Get-VMSwitch { return $null }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.switch | Should -Be $false
        $result.evidence.switchType | Should -Be $null
        $result.detail | Should -Be 'switch'
    }

    It 'fails when the switch is External' {
        Mock Get-VMSwitch { return [pscustomobject]@{ Name = 'HouseNet'; SwitchType = 'External' } }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.switch | Should -Be $true
        $result.evidence.switchType | Should -Be 'External'
        $result.detail | Should -Be 'switchType'
    }

    It 'fails when the host IP is missing' {
        Mock Get-NetIPAddress {
            return [pscustomobject]@{
                IPAddress      = '198.51.100.9'
                PrefixLength   = 24
                InterfaceAlias = 'vEthernet (HouseNet)'
            }
        }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.hostip | Should -Be $false
        $result.evidence.prefixOk | Should -Be $false
        $result.detail | Should -Be 'hostip'
    }

    It 'fails when the prefix does not match the subnet' {
        Mock Get-NetIPAddress {
            return [pscustomobject]@{
                IPAddress      = '192.0.2.1'
                PrefixLength   = 16
                InterfaceAlias = 'vEthernet (HouseNet)'
            }
        }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.hostip | Should -Be $true
        $result.evidence.prefixOk | Should -Be $false
        $result.detail | Should -Be 'prefixOk'
    }

    It 'fails when a NAT overlaps the house subnet and names it' {
        Mock Get-NetNat {
            return [pscustomobject]@{
                Name                             = 'HouseOverlap'
                InternalIPInterfaceAddressPrefix = '192.0.2.0/24'
            }
        }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.nonat | Should -Be $false
        @($result.evidence.natNames) -join ',' | Should -Be 'HouseOverlap'
        $result.detail | Should -Be 'nonat: HouseOverlap'
    }

    It 'allows a NAT on another subnet such as 192.168.200.0/24' { # secretscan:allow
        Mock Get-NetNat {
            return [pscustomobject]@{
                Name                             = 'OtherNat'
                InternalIPInterfaceAddressPrefix = '192.168.200.0/24' # secretscan:allow
            }
        }
        $result = & $script:hostNetworkCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.nonat | Should -Be $true
        $result.detail | Should -Be 'house network ready'
    }
}

Describe 'ConvertFrom-HousePortProxyTable' {
    It 'parses two English portproxy rows and skips headers' {
        $sample = @"
Listen on ipv4:             Connect to ipv4:

Address         Port        Address         Port
--------------- ----------  --------------- ----------
192.0.2.1       3128        127.0.0.1       7890
198.51.100.8    443         127.0.0.1       8443

"@
        $rows = @(ConvertFrom-HousePortProxyTable -Text $sample)
        $rows.Count | Should -Be 2
        $rows[0].ListenAddress | Should -Be '192.0.2.1'
        $rows[0].ListenPort | Should -Be 3128
        $rows[0].ConnectAddress | Should -Be '127.0.0.1'
        $rows[0].ConnectPort | Should -Be 7890
        $rows[1].ListenAddress | Should -Be '198.51.100.8'
        $rows[1].ListenPort | Should -Be 443
        $rows[1].ConnectAddress | Should -Be '127.0.0.1'
        $rows[1].ConnectPort | Should -Be 8443
    }
}

Describe 'gate check' {
    BeforeAll {
        $script:gateCheck = Join-Path $script:repo 'checks\gate.ps1'
        if (-not ('HouseTestWebResponse' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net;
public sealed class HouseTestWebResponse : WebResponse {
    public HttpStatusCode StatusCode { get; private set; }
    public HouseTestWebResponse(int statusCode) {
        StatusCode = (HttpStatusCode)statusCode;
    }
}
'@
        }
        $forbiddenResponse = New-Object HouseTestWebResponse 403
        $script:forbiddenWeb = New-Object System.Net.WebException(
            'forbidden',
            $null,
            ([System.Net.WebExceptionStatus]::ProtocolError),
            $forbiddenResponse
        )
        $script:timeoutWeb = New-Object System.Net.WebException(
            'timed out',
            $null,
            ([System.Net.WebExceptionStatus]::Timeout),
            $null
        )

        function script:New-GatePortProxyText {
            param([string]$ListenPort = '3128', [string]$ConnectPort = '7890')
            return @"
Listen on ipv4:             Connect to ipv4:

Address         Port        Address         Port
--------------- ----------  --------------- ----------
192.0.2.1       $ListenPort        127.0.0.1       $ConnectPort

"@
        }
    }

    BeforeEach {
        Mock Get-NetTCPConnection {
            return [pscustomobject]@{ LocalAddress = '127.0.0.1'; OwningProcess = 4242 }
        }
        Mock Get-Process { return [pscustomobject]@{ ProcessName = 'mihomo' } }
        Mock Get-Service { return [pscustomobject]@{ Name = 'iphlpsvc'; Status = 'Running' } }
        Mock Get-HousePortProxyText { return (New-GatePortProxyText) }
        Mock Get-NetFirewallRule {
            return [pscustomobject]@{
                DisplayName = "claude-house gate"
                Enabled     = $true
                Direction   = 'Inbound'
                Action      = 'Allow'
            }
        }
        Mock Get-HouseFirewallAddressFilter {
            return [pscustomobject]@{ LocalAddress = '192.0.2.1'; RemoteAddress = '192.0.2.2' }
        }
        Mock Get-HouseFirewallPortFilter {
            return [pscustomobject]@{ Protocol = 'TCP'; LocalPort = 3128 }
        }
        Mock Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200 } }
    }

    It 'passes when the proxy, portproxy, firewall and upstream all hold' {
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.id | Should -Be 'gate'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'gate open'
        $result.evidence.proxyapp | Should -Be $true
        $result.evidence.proxyProcess | Should -Be 'mihomo'
        $result.evidence.lanExposed | Should -Be $false
        $result.evidence.iphlpsvc | Should -Be $true
        $result.evidence.portproxy | Should -Be $true
        $result.evidence.firewall | Should -Be $true
        $result.evidence.upstream | Should -Be $true
        $result.evidence.upstreamStatus | Should -Be 200
        $result.fix | Should -Be 'runbook/03-gate.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-NetTCPConnection -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'fails when nothing acceptable listens for the proxy app' {
        Mock Get-NetTCPConnection {
            return [pscustomobject]@{ LocalAddress = '198.51.100.50'; OwningProcess = 4242 }
        }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.proxyapp | Should -Be $false
        $result.detail | Should -Be 'proxyapp'
    }

    It 'fails when iphlpsvc is not running' {
        Mock Get-Service { return [pscustomobject]@{ Name = 'iphlpsvc'; Status = 'Stopped' } }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.iphlpsvc | Should -Be $false
        $result.detail | Should -Be 'iphlpsvc'
    }

    It 'fails when the portproxy row does not match' {
        Mock Get-HousePortProxyText { return (New-GatePortProxyText -ListenPort '1') }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.portproxy | Should -Be $false
        $result.detail | Should -Be 'portproxy'
    }

    It 'fails when the firewall rule does not allow the VM address' {
        Mock Get-HouseFirewallAddressFilter {
            return [pscustomobject]@{ LocalAddress = '192.0.2.1'; RemoteAddress = '198.51.100.77' }
        }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.firewall | Should -Be $false
        $result.detail | Should -Be 'firewall'
    }

    It 'stays ok when the proxy listens on all interfaces and warns' {
        Mock Get-NetTCPConnection {
            return [pscustomobject]@{ LocalAddress = '0.0.0.0'; OwningProcess = 4242 }
        }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.lanExposed | Should -Be $true
        $result.evidence.proxyapp | Should -Be $true
        $result.detail | Should -Be 'gate open; warning: proxy app listens on all interfaces (LAN exposed)'
    }

    It 'counts an upstream 403 WebException with a response as reached' {
        Mock Invoke-WebRequest {
            $response = New-Object HouseTestWebResponse 403
            $ex = New-Object System.Net.WebException('forbidden', $null, ([System.Net.WebExceptionStatus]::ProtocolError), $response)
            throw $ex
        }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.upstream | Should -Be $true
        $result.evidence.upstreamStatus | Should -Be 403
        $result.detail | Should -Be 'gate open'
    }

    It 'fails when the upstream WebException has no response' {
        Mock Invoke-WebRequest {
            $ex = New-Object System.Net.WebException('timed out', $null, ([System.Net.WebExceptionStatus]::Timeout), $null)
            throw $ex
        }
        $result = & $script:gateCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.upstream | Should -Be $false
        $result.evidence.upstreamStatus | Should -Be $null
        $result.detail | Should -Be 'upstream'
    }
}

Describe 'Get-HouseComputerName' {
    It 'keeps a short hyphenated name' {
        Get-HouseComputerName -Config @{ House = @{ Name = 'claude-house' } } | Should -Be 'claude-house'
    }

    It 'strips punctuation and cuts the name to 15 characters' {
        $name = Get-HouseComputerName -Config @{ House = @{ Name = "Bob's House 2026 dev box" } }
        $name | Should -Be 'BobsHouse2026de'
        $name.Length | Should -Be 15
    }

    It 'throws when the cleaned name is empty' {
        { Get-HouseComputerName -Config @{ House = @{ Name = '***' } } } | Should -Throw -ExpectedMessage 'computer name is empty'
        { Get-HouseComputerName -Config @{ House = @{ Name = '' } } } | Should -Throw -ExpectedMessage 'computer name is empty'
    }
}

Describe 'vm check' {
    BeforeAll {
        $script:vmCheck = Join-Path $script:repo 'checks\vm.ps1'
        $script:vmStubbed = @()
        foreach ($name in 'Get-VM', 'Get-VMMemory', 'Get-VMProcessor', 'Get-VMFirmware', 'Get-VMSecurity', 'Get-VMNetworkAdapter', 'Get-VMHardDiskDrive', 'Get-VHD') {
            $needsStub = -not (Get-Command $name -ErrorAction SilentlyContinue)
            if ($needsStub -or $env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                $body = "[CmdletBinding()]`r`nparam(`$Name, `$VMName, `$Path, `$SwitchName)"
                Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body)) -Force
                $script:vmStubbed += $name
            }
        }
    }

    AfterAll {
        foreach ($name in $script:vmStubbed) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        Mock Get-VM {
            return [pscustomobject]@{
                Name                         = 'FixtureHouse'
                Generation                   = 2
                State                        = 'Off'
                AutomaticCheckpointsEnabled  = $false
                DynamicMemoryEnabled         = $false
                MemoryStartup                = 8GB
            }
        }
        Mock Get-VMMemory {
            return [pscustomobject]@{
                DynamicMemoryEnabled = $true
                Maximum              = 8GB
                Startup              = 8GB
            }
        }
        Mock Get-VMProcessor { return [pscustomobject]@{ Count = 2 } }
        Mock Get-VMFirmware {
            return [pscustomobject]@{
                SecureBoot         = 'On'
                SecureBootTemplate = 'MicrosoftWindows'
            }
        }
        Mock Get-VMSecurity { return [pscustomobject]@{ TpmEnabled = $true } }
        Mock Get-VMNetworkAdapter { return [pscustomobject]@{ SwitchName = 'HouseNet' } }
        Mock Get-VMHardDiskDrive { return [pscustomobject]@{ Path = 'C:\Hyper-V\fixture\FixtureHouse.vhdx' } }
        Mock Get-VHD { return [pscustomobject]@{ Size = 80GB; FileSize = 8GB } }
    }

    It 'passes when every vm fact matches the blueprint' {
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.id | Should -Be 'vm'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'vm ready'
        $result.evidence.exists | Should -Be $true
        $result.evidence.generation | Should -Be $true
        $result.evidence.secureboot | Should -Be $true
        $result.evidence.tpm | Should -Be $true
        $result.evidence.cpu | Should -Be $true
        $result.evidence.memory | Should -Be $true
        $result.evidence.staticMemory | Should -Be $true
        $result.evidence.disk | Should -Be $true
        $result.evidence.oneadapter | Should -Be $true
        $result.evidence.switch | Should -Be $true
        $result.evidence.checkpoints | Should -Be $true
        $result.fix | Should -Be 'runbook/04-vm.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-VM -Times 0
    }

    It 'fails when the VM does not exist' {
        Mock Get-VM { return $null }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.exists | Should -Be $false
        $result.detail | Should -Be 'exists, generation, staticMemory, checkpoints'
    }

    It 'fails when the generation is not 2' {
        Mock Get-VM {
            return [pscustomobject]@{ Name = 'FixtureHouse'; Generation = 1; State = 'Off'; AutomaticCheckpointsEnabled = $false; DynamicMemoryEnabled = $false; MemoryStartup = 8GB }
        }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.generation | Should -Be $false
        $result.detail | Should -Be 'generation'
    }

    It 'fails when Secure Boot is off' {
        Mock Get-VMFirmware { return [pscustomobject]@{ SecureBoot = 'Off'; SecureBootTemplate = 'MicrosoftWindows' } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.secureboot | Should -Be $false
        $result.detail | Should -Be 'secureboot'
    }

    It 'fails when the Secure Boot template is not MicrosoftWindows' {
        Mock Get-VMFirmware { return [pscustomobject]@{ SecureBoot = 'On'; SecureBootTemplate = 'MicrosoftUEFICertificateAuthority' } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'secureboot'
    }

    It 'fails when the TPM is off' {
        Mock Get-VMSecurity { return [pscustomobject]@{ TpmEnabled = $false } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.tpm | Should -Be $false
        $result.detail | Should -Be 'tpm'
    }

    It 'fails when the processor count differs' {
        Mock Get-VMProcessor { return [pscustomobject]@{ Count = 1 } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.cpu | Should -Be $false
        $result.detail | Should -Be 'cpu'
    }

    It 'fails when dynamic memory maximum is not MemoryGB' {
        Mock Get-VMMemory { return [pscustomobject]@{ DynamicMemoryEnabled = $true; Maximum = 4GB; Startup = 8GB } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.memory | Should -Be $false
        $result.detail | Should -Be 'memory'
    }

    It 'uses startup bytes when dynamic memory is off' {
        Mock Get-VMMemory { return [pscustomobject]@{ DynamicMemoryEnabled = $false; Maximum = 4GB; Startup = 8GB } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $true
        $result.evidence.memory | Should -Be $true
    }

    It 'fails when dynamic memory is off and startup is not MemoryGB' {
        Mock Get-VMMemory { return [pscustomobject]@{ DynamicMemoryEnabled = $false; Maximum = 8GB; Startup = 4GB } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'memory'
    }

    It 'fails staticMemory when dynamic memory is on' {
        Mock Get-VM {
            return [pscustomobject]@{
                Name                        = 'FixtureHouse'
                Generation                  = 2
                State                       = 'Off'
                AutomaticCheckpointsEnabled = $false
                DynamicMemoryEnabled        = $true
                MemoryStartup               = 8GB
            }
        }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.staticMemory | Should -Be $false
        $result.evidence.memory | Should -Be $true
        $result.detail | Should -Be 'staticMemory'
    }

    It 'fails staticMemory when startup bytes differ from MemoryGB' {
        Mock Get-VM {
            return [pscustomobject]@{
                Name                        = 'FixtureHouse'
                Generation                  = 2
                State                       = 'Off'
                AutomaticCheckpointsEnabled = $false
                DynamicMemoryEnabled        = $false
                MemoryStartup               = 4GB
            }
        }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.staticMemory | Should -Be $false
        $result.evidence.memory | Should -Be $true
        $result.detail | Should -Be 'staticMemory'
    }

    It 'fails when the VHD is smaller than DiskGB' {
        Mock Get-VHD { return [pscustomobject]@{ Size = 10GB; FileSize = 8GB } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.disk | Should -Be $false
        $result.detail | Should -Be 'disk'
    }

    It 'fails when the VM has two adapters' {
        Mock Get-VMNetworkAdapter {
            return @(
                [pscustomobject]@{ SwitchName = 'HouseNet' },
                [pscustomobject]@{ SwitchName = 'Default Switch' }
            )
        }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.oneadapter | Should -Be $false
        $result.evidence.switch | Should -Be $false
        $result.detail | Should -Match '(^|, )oneadapter(,|$)'
    }

    It 'fails when the only adapter is on Default Switch' {
        Mock Get-VMNetworkAdapter { return [pscustomobject]@{ SwitchName = 'Default Switch' } }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.oneadapter | Should -Be $true
        $result.evidence.switch | Should -Be $false
        $result.detail | Should -Be 'switch'
    }

    It 'fails when automatic checkpoints are enabled' {
        Mock Get-VM {
            return [pscustomobject]@{ Name = 'FixtureHouse'; Generation = 2; State = 'Off'; AutomaticCheckpointsEnabled = $true; DynamicMemoryEnabled = $false; MemoryStartup = 8GB }
        }
        $result = & $script:vmCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.checkpoints | Should -Be $false
        $result.detail | Should -Be 'checkpoints'
    }
}

Describe 'windows check' {
    BeforeAll {
        $script:windowsCheck = Join-Path $script:repo 'checks\windows.ps1'
        $script:windowsProgramData = $env:ProgramData
        $script:windowsStubbed = @()
        foreach ($name in 'Get-VMFirmware', 'Get-VMHardDiskDrive', 'Get-VHD') {
            $needsStub = -not (Get-Command $name -ErrorAction SilentlyContinue)
            if ($needsStub -or $env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                $body = "[CmdletBinding()]`r`nparam(`$Name, `$VMName, `$Path, `$SwitchName)"
                Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body)) -Force
                $script:windowsStubbed += $name
            }
        }

        function script:New-WindowsHardDisk {
            $device = New-Object psobject
            $device.PSObject.TypeNames.Insert(0, 'Microsoft.HyperV.PowerShell.HardDiskDrive')
            return $device
        }

        function script:Write-WindowsEvidence {
            param([string]$MarkerText)
            $root = Join-Path $env:ProgramData 'claude-house\FixtureHouse'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $utf8 = New-Object System.Text.UTF8Encoding $false
            if ($null -ne $MarkerText) {
                [System.IO.File]::WriteAllText((Join-Path $root 'windows-applied.json'), $MarkerText, $utf8)
            }
            [System.IO.File]::WriteAllText((Join-Path $root 'vm-user.cred.xml'), '<not-a-credential>', $utf8)
        }
    }

    AfterAll {
        $env:ProgramData = $script:windowsProgramData
        foreach ($name in $script:windowsStubbed) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        $env:ProgramData = Join-Path $TestDrive ("programdata-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        Write-WindowsEvidence -MarkerText '{"imageName":"Windows 11 Pro","imageIndex":6,"appliedAt":"2026-10-12T00:00:00Z"}'
        Mock Get-VMFirmware {
            $device = New-Object psobject
            $device.PSObject.TypeNames.Insert(0, 'Microsoft.HyperV.PowerShell.HardDiskDrive')
            return [pscustomobject]@{ BootOrder = @([pscustomobject]@{ Device = $device }) }
        }
        Mock Get-VMHardDiskDrive { return [pscustomobject]@{ Path = 'C:\Hyper-V\fixture\FixtureHouse.vhdx' } }
        Mock Get-VHD { return [pscustomobject]@{ Size = 80GB; FileSize = 6GB } }
    }

    AfterEach {
        $env:ProgramData = $script:windowsProgramData
    }

    It 'passes when the marker, credential, boot disk and file size all hold' {
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.id | Should -Be 'windows'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'windows applied'
        $result.evidence.marker | Should -Be $true
        $result.evidence.credential | Should -Be $true
        $result.evidence.bootdisk | Should -Be $true
        $result.evidence.vhdsize | Should -Be $true
        $result.fix | Should -Be 'runbook/05-windows.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-VMFirmware -Times 0
    }

    It 'fails when the marker is missing' {
        Remove-Item -LiteralPath (Join-Path $env:ProgramData 'claude-house\FixtureHouse\windows-applied.json')
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.marker | Should -Be $false
        $result.detail | Should -Be 'marker'
    }

    It 'fails when the marker is not JSON' {
        Write-WindowsEvidence -MarkerText '{not json'
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.marker | Should -Be $false
        $result.detail | Should -Be 'marker'
    }

    It 'fails when the credential file is missing' {
        Remove-Item -LiteralPath (Join-Path $env:ProgramData 'claude-house\FixtureHouse\vm-user.cred.xml')
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.credential | Should -Be $false
        $result.detail | Should -Be 'credential'
    }

    It 'fails when the first boot device is not a hard disk' {
        Mock Get-VMFirmware {
            $device = New-Object psobject
            $device.PSObject.TypeNames.Insert(0, 'Microsoft.HyperV.PowerShell.DvdDrive')
            return [pscustomobject]@{ BootOrder = @([pscustomobject]@{ Device = $device }) }
        }
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.bootdisk | Should -Be $false
        $result.detail | Should -Be 'bootdisk'
    }

    It 'passes after first boot when Windows Boot Manager is first' {
        # Seen on a real host: after the first boot the firmware lists Windows Boot Manager before the disk.
        Mock Get-VMFirmware {
            $entry = [pscustomobject]@{ BootType = 'File'; Device = $null; FirmwarePath = 'HD(2,GPT,FIXTURE,0x8000,0x82000)/\EFI\Microsoft\Boot\bootmgfw.efi' }
            return [pscustomobject]@{ BootOrder = @($entry) }
        }
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.evidence.bootdisk | Should -Be $true
        $result.ok | Should -Be $true
    }

    It 'fails when a file boot entry is not Windows Boot Manager' {
        Mock Get-VMFirmware {
            $entry = [pscustomobject]@{ BootType = 'File'; Device = $null; FirmwarePath = 'HD(1,GPT,FIXTURE,0x800,0x1000)/\EFI\BOOT\other.efi' }
            return [pscustomobject]@{ BootOrder = @($entry) }
        }
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.evidence.bootdisk | Should -Be $false
    }

    It 'fails when the VHD file size is under 6 GB' {
        Mock Get-VHD { return [pscustomobject]@{ Size = 80GB; FileSize = (6GB - 1) } }
        $result = & $script:windowsCheck -Context (New-BlueprintContext -Config (New-BlueprintConfig))
        $result.ok | Should -Be $false
        $result.evidence.vhdsize | Should -Be $false
        $result.detail | Should -Be 'vhdsize'
    }
}

Describe 'vm-online check' {
    BeforeAll {
        $script:onlineCheck = Join-Path $script:repo 'checks\vm-online.ps1'
        $script:onlineStubbed = @()
        foreach ($name in 'Get-VM', 'Get-VMIntegrationService') {
            $needsStub = -not (Get-Command $name -ErrorAction SilentlyContinue)
            if ($needsStub -or $env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                $body = "[CmdletBinding()]`r`nparam(`$Name, `$VMName, `$Path, `$SwitchName, `$Id)"
                Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body)) -Force
                $script:onlineStubbed += $name
            }
        }

        function script:New-GoodOnlineShortcut {
            return [pscustomobject]@{
                exists     = $true
                target     = 'C:\Windows\System32\vmconnect.exe'
                arguments  = 'localhost "FixtureHouse"'
                runAsAdmin = $true
            }
        }

        function script:New-OnlineContext {
            param(
                $Guest,
                $Shortcut = 'default'
            )
            $ctx = New-BlueprintContext -Config (New-BlueprintConfig)
            $ctx.InvokeGuest = $Guest
            if ($Shortcut -eq 'default') { $Shortcut = New-GoodOnlineShortcut }
            $ctx.DesktopShortcut = $Shortcut
            return $ctx
        }
    }

    AfterAll {
        foreach ($name in $script:onlineStubbed) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        Mock Get-VM { return [pscustomobject]@{ Name = 'FixtureHouse'; State = 'Running' } }
        Mock Get-VMIntegrationService { return [pscustomobject]@{ Name = 'Heartbeat'; PrimaryStatusDescription = 'OK' } }
        Mock Get-HouseConsoleSettings { return [pscustomobject]@{ exists = $true; savedConfigExists = $true; path = 'C:\fixture\vmconnect.config' } }
    }

    It 'passes when the guest answers with the right name, build and no unattend file' {
        $ctx = New-OnlineContext -Guest {
            param($ScriptBlock, $ArgumentList)
            $text = [string]$ScriptBlock
            if ($text -notmatch 'COMPUTERNAME') { throw 'guest script missing computer name' }
            if ($text -notmatch 'Unattend\.xml') { throw 'guest script missing unattend probe' }
            if ($text -notmatch 'DefaultPassword') { throw 'guest script missing autologon probe' }
            if ($text -notmatch 'PasswordExpires') { throw 'guest script missing password expiry' }
            return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') }
        }
        $result = & $script:onlineCheck -Context $ctx
        $result.id | Should -Be 'vm-online'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'vm online'
        $result.evidence.running | Should -Be $true
        $result.evidence.heartbeat | Should -Be $true
        $result.evidence.psdirect | Should -Be $true
        $result.evidence.build | Should -Be $true
        $result.evidence.name | Should -Be $true
        $result.evidence.unattendGone | Should -Be $true
        $result.evidence.autologonGone | Should -Be $true
        $result.evidence.shortcut | Should -Be $true
        $result.evidence.consoleSettings | Should -Be $true
        $result.evidence.passwordNoExpiry | Should -Be $true
        $result.fix | Should -Be 'runbook/06-vm-online.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:onlineCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-VM -Times 0
    }

    It 'fails when the VM is not running' {
        Mock Get-VM { return [pscustomobject]@{ Name = 'FixtureHouse'; State = 'Off' } }
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.running | Should -Be $false
        $result.detail | Should -Be 'running'
    }

    It 'passes the heartbeat on a localized host from the operational status' {
        Mock Get-VMIntegrationService { return [pscustomobject]@{ Name = 'Heartbeat'; PrimaryOperationalStatus = 'Ok'; PrimaryStatusDescription = 'localized-ok' } }
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.evidence.heartbeat | Should -Be $true
    }

    It 'fails when the heartbeat is not OK' {
        Mock Get-VMIntegrationService { return [pscustomobject]@{ Name = 'Heartbeat'; PrimaryStatusDescription = 'No Contact' } }
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.heartbeat | Should -Be $false
        $result.detail | Should -Be 'heartbeat'
    }

    It 'fails and keeps the InvokeGuest message in detail' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) throw 'credential rejected' }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.psdirect | Should -Be $false
        $result.detail | Should -Match 'credential rejected'
    }

    It 'fails when an unattend file is still present' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $true; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.unattendGone | Should -Be $false
        $result.detail | Should -Be 'unattendGone'
    }

    It 'fails when the autologon password is still in the Winlogon key' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $true; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.autologonGone | Should -Be $false
        $result.detail | Should -Be 'autologonGone'
    }

    It 'fails when the guest does not report autologon at all' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'autologonGone'
    }

    It 'runs its guest probe for real without throwing' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) & $ScriptBlock }
        $result = & $script:onlineCheck -Context $ctx
        $result.evidence.psdirect | Should -Be $true
        $result.detail | Should -Not -Match 'InvokeGuest|returned no result'
    }

    It 'fails when the guest build is 19045' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 19045; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.build | Should -Be $false
        $result.detail | Should -Be 'build'
    }

    It 'fails when the guest computer name differs' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'OTHER'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.name | Should -Be $false
        $result.detail | Should -Be 'name'
    }

    It 'fails shortcut when the public desktop file is missing' {
        $shortcut = [pscustomobject]@{ exists = $false; target = 'C:\Windows\System32\vmconnect.exe'; arguments = 'localhost "FixtureHouse"'; runAsAdmin = $true }
        $ctx = New-OnlineContext -Shortcut $shortcut -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.shortcut | Should -Be $false
        $result.detail | Should -Be 'shortcut'
    }

    It 'fails shortcut when the target is not vmconnect' {
        $shortcut = [pscustomobject]@{ exists = $true; target = 'C:\Windows\System32\notepad.exe'; arguments = 'localhost "FixtureHouse"'; runAsAdmin = $true }
        $ctx = New-OnlineContext -Shortcut $shortcut -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.shortcut | Should -Be $false
        $result.detail | Should -Be 'shortcut'
    }

    It 'fails shortcut when the run-as bit is clear' {
        $shortcut = [pscustomobject]@{ exists = $true; target = 'C:\Windows\System32\vmconnect.exe'; arguments = 'localhost "FixtureHouse"'; runAsAdmin = $false }
        $ctx = New-OnlineContext -Shortcut $shortcut -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.shortcut | Should -Be $false
        $result.detail | Should -Be 'shortcut'
    }

    It 'passes consoleSettings when the saved vmconnect choice exists' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $true
        $result.evidence.consoleSettings | Should -Be $true
    }

    It 'fails consoleSettings when the vmconnect file is missing' {
        Mock Get-HouseConsoleSettings { return [pscustomobject]@{ exists = $false; savedConfigExists = $false; path = '' } }
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.consoleSettings | Should -Be $false
        $result.evidence.shortcut | Should -Be $true
        $result.detail | Should -Be 'consoleSettings'
    }

    It 'fails consoleSettings when SavedConfigExists is not True' {
        Mock Get-HouseConsoleSettings { return [pscustomobject]@{ exists = $true; savedConfigExists = $false; path = 'C:\fixture\vmconnect.config' } }
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.consoleSettings | Should -Be $false
        $result.detail | Should -Be 'consoleSettings'
    }

    It 'fails passwordNoExpiry when PasswordExpires is a date' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = (Get-Date); timeService = 'Automatic'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.passwordNoExpiry | Should -Be $false
        $result.evidence.shortcut | Should -Be $true
        $result.detail | Should -Be 'passwordNoExpiry'
    }

    It 'fails clock when the time service does not start on its own' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Manual'; utc = [DateTime]::UtcNow.ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.clock | Should -Be $false
        $result.detail | Should -Be 'clock'
    }

    It 'fails clock when the guest runs hours off the host (host local time read in another zone)' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null; timeService = 'Automatic'; utc = [DateTime]::UtcNow.AddHours(15).ToString('o') } }
        $result = & $script:onlineCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.clock | Should -Be $false
        $result.detail | Should -Be 'clock'
    }

    It 'fails clock when the guest reports no time' {
        $ctx = New-OnlineContext -Guest { param($ScriptBlock, $ArgumentList) return [pscustomobject]@{ name = 'FixtureHouse'; build = 26100; unattend = $false; autologon = $false; passwordExpires = $null } }
        $result = & $script:onlineCheck -Context $ctx
        $result.evidence.clock | Should -Be $false
        $result.detail | Should -Be 'clock'
    }

    It 'starts the time service from SetupComplete before the unattend file is deleted' {
        $windows = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\05-windows.md'))
        $auto = $windows.IndexOf('sc config w32time start= auto')
        $auto | Should -BeGreaterThan -1
        $windows.IndexOf('w32tm /resync') | Should -BeGreaterThan $auto
        $windows.IndexOf('del /f /q C:\Windows\Panther') | Should -BeGreaterThan $auto
    }
}

Describe 'desktop shortcut run-as flag' {
    It 'reads a set run-as bit as true and a cleared bit as false' {
        $set = New-Object byte[] 32
        $set[0x15] = 0x20
        Test-HouseShortcutRunAsAdmin -Bytes $set | Should -Be $true
        $clear = New-Object byte[] 32
        $clear[0x15] = 0x00
        Test-HouseShortcutRunAsAdmin -Bytes $clear | Should -Be $false
        $other = New-Object byte[] 32
        $other[0x15] = 0x01
        Test-HouseShortcutRunAsAdmin -Bytes $other | Should -Be $false
    }

    It 'sets the run-as bit without dropping other bits' {
        $bytes = New-Object byte[] 32
        $bytes[0x15] = 0x01
        $updated = Set-HouseShortcutRunAsAdmin -Bytes $bytes
        $updated[0x15] | Should -Be 0x21
        Test-HouseShortcutRunAsAdmin -Bytes $updated | Should -Be $true
        $bytes[0x15] | Should -Be 0x01
    }
}

Describe 'desktop shortcut icon' {
    BeforeEach {
        $script:previousProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('n'))
        $script:iconBag = @{ Link = $null }
        Mock New-HouseShellLink -ModuleName House -MockWith {
            $script:iconBag.Link = [pscustomobject]@{
                TargetPath        = ''
                Arguments         = ''
                WorkingDirectory  = ''
                IconLocation      = ''
                Description       = ''
            }
            return $script:iconBag.Link
        }
        Mock Save-HouseShellLink -ModuleName House -MockWith { }
        Mock New-HouseConsoleSettings -ModuleName House -MockWith { return 'skipped' }
    }

    AfterEach {
        $env:ProgramData = $script:previousProgramData
    }

    It 'points IconLocation at the ProgramData copy when house.ico exists' {
        $root = Join-Path $TestDrive 'house-icon'
        $iconDir = Join-Path $root 'assets\icons'
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'house.ico'), [byte[]]@(0, 1, 2, 3))
        New-HouseDesktopShortcut -Config (New-BlueprintConfig) -RepoRoot $root | Out-Null
        $expected = Join-Path (Join-Path (Join-Path $env:ProgramData 'claude-house') 'FixtureHouse') 'house.ico'
        $script:iconBag.Link.IconLocation | Should -Be ($expected + ',0')
        [System.IO.File]::ReadAllBytes($expected).Length | Should -Be 4
        [System.IO.File]::ReadAllBytes($expected)[0] | Should -Be 0
        [System.IO.File]::ReadAllBytes($expected)[3] | Should -Be 3
    }

    It 'keeps vmconnect.exe,0 when house.ico is missing' {
        $root = Join-Path $TestDrive 'house-no-icon'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-HouseDesktopShortcut -Config (New-BlueprintConfig) -RepoRoot $root | Out-Null
        $vmconnect = Join-Path $env:WINDIR 'System32\vmconnect.exe'
        $script:iconBag.Link.IconLocation | Should -Be ($vmconnect + ',0')
    }
}

Describe 'Get-HouseShareShortcutPlan' {
    It 'gives one plan per share when called the way step 13 calls it' {
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'C:\fixture\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = 'C:\fixture\docs'; Writable = $false; Mirror = $true }
        )
        $plans = @(Get-HouseShareShortcutPlan -Config $config -RepoRoot $script:repo)
        $plans.Count | Should -Be 2
        $plans[0].Name | Should -Be 'projects'
        $plans[0].SourcePath | Should -Be (Join-Path $script:repo 'assets\icons\folder-projects.ico')
        $plans[1].SourcePath | Should -Be (Join-Path $script:repo 'assets\icons\folder-docs.ico')
        Test-Path -LiteralPath $plans[1].SourcePath -PathType Leaf | Should -Be $true
    }

    It 'gives one countable plan for a single share' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'docs'; HostPath = 'C:\fixture\docs'; Writable = $false; Mirror = $true })
        $plans = @(Get-HouseShareShortcutPlan -Config $config -RepoRoot $script:repo)
        $plans.Count | Should -Be 1
        $plans[0].Target | Should -Be 'C:\fixture\docs'
    }
}
Describe 'Sync-HouseVmPassword' {
    BeforeEach {
        $script:previousProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('n'))
        $script:credRoot = Join-Path $env:ProgramData 'claude-house\FixtureHouse'
        New-Item -ItemType Directory -Path $script:credRoot -Force | Out-Null
        $script:credPath = Join-Path $script:credRoot 'vm-user.cred.xml'
        [System.IO.File]::WriteAllText($script:credPath, 'OLD-XML')
        $script:houseSample = 'purple-octopus'
        # The fake credential follows the file content, so the proof call sees the newly stored value.
        Mock Import-Clixml -ModuleName House -MockWith {
            $value = 'stored-old-value'
            if ([System.IO.File]::ReadAllText([string]$PesterBoundParameters['LiteralPath']) -eq 'NEW-XML') { $value = $script:houseSample }
            $secure = ConvertTo-SecureString $value -AsPlainText -Force
            return New-Object System.Management.Automation.PSCredential('FixtureHouse\fixtureuser', $secure)
        }
        Mock Export-Clixml -ModuleName House -MockWith {
            $path = [string]$PesterBoundParameters['LiteralPath']
            [System.IO.File]::WriteAllText($path, 'NEW-XML')
        }
    }

    AfterEach {
        $env:ProgramData = $script:previousProgramData
    }

    It 'stores a password that opens the VM and never changes the guest account' {
        Mock Invoke-Command -ModuleName House -MockWith { return 'fixtureuser' }
        $secure = ConvertTo-SecureString $script:houseSample -AsPlainText -Force
        $result = Sync-HouseVmPassword -Config (New-BlueprintConfig) -Password $secure
        $result.stored | Should -Be $true
        [System.IO.File]::ReadAllText($script:credPath) | Should -Be 'NEW-XML'
        ([string]$result) | Should -Not -Match ([regex]::Escape($script:houseSample))
        Should -Invoke Invoke-Command -ModuleName House -Times 1 -Exactly
        Should -Invoke Invoke-Command -ModuleName House -Times 0 -Exactly -ParameterFilter { [string]$ScriptBlock -match 'LocalUser|ChangePassword|SetPassword' }
    }

    It 'restores the old credential file when the typed password does not open the VM' {
        Mock Invoke-Command -ModuleName House -MockWith {
            $plain = $PesterBoundParameters['Credential'].GetNetworkCredential().Password
            throw ($plain + ' was rejected')
        }
        $secure = ConvertTo-SecureString $script:houseSample -AsPlainText -Force
        $message = Get-ThrownMessage { Sync-HouseVmPassword -Config (New-BlueprintConfig) -Password $secure }
        $message | Should -Be 'that password does not open the VM; the stored credential was restored'
        $message | Should -Not -Match ([regex]::Escape($script:houseSample))
        [System.IO.File]::ReadAllText($script:credPath) | Should -Be 'OLD-XML'
    }

    It 'has no code path that changes the guest password' {
        $source = [System.IO.File]::ReadAllText((Join-Path $script:repo 'lib\House.psm1'))
        $source | Should -Not -Match 'ChangePassword\(|SetPassword\(|Set-LocalUser'
    }
}

Describe 'preflight check' {
    BeforeAll {
        $script:preflightCheck = Join-Path $script:repo 'checks\preflight.ps1'

        function New-PreflightDrive {
            param(
                [string]$DeviceId,
                [string]$FileSystem,
                [int64]$FreeBytes,
                [int]$DriveType = 3
            )
            return [pscustomobject]@{
                DeviceId   = $DeviceId
                DriveType  = $DriveType
                FileSystem = $FileSystem
                FreeBytes  = $FreeBytes
            }
        }

        function New-PreflightFacts {
            param(
                [string]$Model = 'Z790 AORUS MASTER',
                [string]$Manufacturer = 'Gigabyte',
                [bool]$HypervisorPresent = $true,
                [bool]$Firmware = $true,
                [bool]$Slat = $false,
                [int]$Sku = 48,
                [int]$Build = 26200,
                [int]$Architecture = 9,
                [bool]$Is64BitOs = $true,
                [int64]$Ram = 32GB,
                [bool]$VmmsExists = $true,
                [bool]$VmmsRunning = $true,
                [bool]$HyperVModule = $true,
                [bool]$Hgs = $true,
                [bool]$Elevated = $true,
                [string]$Policy = 'Bypass',
                [string]$CpuName = 'Fixture CPU 9000',
                [string]$Caption = 'Fixture Windows 11 Pro',
                $Drives
            )
            if ($null -eq $Drives) {
                $Drives = @(
                    (New-PreflightDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 150GB),
                    (New-PreflightDrive -DeviceId 'F:' -FileSystem 'FAT32' -FreeBytes 8GB),
                    (New-PreflightDrive -DeviceId 'E:' -FileSystem 'ReFS' -FreeBytes 220GB)
                )
            }
            return [pscustomobject]@{
                Caption             = $Caption
                Sku                 = $Sku
                Build               = $Build
                Is64BitOs           = $Is64BitOs
                Processors          = @([pscustomobject]@{
                    Name                                    = $CpuName
                    Architecture                            = $Architecture
                    VirtualizationFirmwareEnabled           = $Firmware
                    SecondLevelAddressTranslationExtensions = $Slat
                })
                Model               = $Model
                Manufacturer        = $Manufacturer
                HypervisorPresent   = $HypervisorPresent
                TotalPhysicalMemory = $Ram
                Drives              = @($Drives)
                VmmsExists          = $VmmsExists
                VmmsRunning         = $VmmsRunning
                HyperVModule        = $HyperVModule
                HgsGuardian         = $Hgs
                Elevated            = $Elevated
                ExecutionPolicy     = $Policy
            }
        }

        function Get-PreflightNamed {
            param($Result, [string]$Name)
            return @($Result.evidence.items | Where-Object { $_.name -eq $Name })
        }

        function Get-PreflightBlockerNames {
            param($Result)
            return @($Result.evidence.items | Where-Object { $_.level -eq 'blocker' } | ForEach-Object { [string]$_.name })
        }
    }

    BeforeEach {
        $global:HousePreflightFacts = New-PreflightFacts
        Mock Get-HouseHostFacts { return $global:HousePreflightFacts }
    }

    AfterAll {
        Remove-Variable -Name HousePreflightFacts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'fixture A real host is compatible and does not trust CPU flags' {
        $result = & $script:preflightCheck -Context @{}
        $result.id | Should -Be 'preflight'
        $result.ok | Should -Be $true
        $result.status | Should -Be 'pass'
        $result.detail | Should -Be 'compatible'
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be ''
        $cpuFlag = @(Get-PreflightNamed $result 'cpu-virtualization')
        $cpuFlag.Count | Should -Be 1
        $cpuFlag[0].level | Should -Be 'info'
        $cpuFlag[0].ok | Should -Be $true
        $cpuFlag[0].value | Should -Be 'unknown (hypervisor running)'
        (Get-PreflightNamed $result 'cpu')[0].value | Should -Be 'Fixture CPU 9000'
        (Get-PreflightNamed $result 'hyperv')[0].ok | Should -Be $true
        (Get-PreflightNamed $result 'hgs')[0].ok | Should -Be $true
        (Get-PreflightNamed $result 'disk')[0].level | Should -Be 'info'
    }

    It 'fixture B VM is blocked on nested and disk, with Hyper-V still fixable' {
        $global:HousePreflightFacts = New-PreflightFacts -Model 'Virtual Machine' -Manufacturer 'Microsoft Corporation' -VmmsExists $false -VmmsRunning $false -HyperVModule $false -Hgs $false -Drives @(
            (New-PreflightDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 32GB)
        )
        $result = & $script:preflightCheck -Context @{}
        $result.ok | Should -Be $false
        $result.status | Should -Be 'fail'
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'nested,disk'
        (Get-PreflightNamed $result 'nested')[0].why | Should -Be 'nested virtualization is not supported by this project'
        (Get-PreflightNamed $result 'nested')[0].ok | Should -Be $false
        $hyperv = Get-PreflightNamed $result 'hyperv'
        $hyperv[0].level | Should -Be 'fixable'
        $hyperv[0].ok | Should -Be $false
        $hyperv[0].fix | Should -Be 'host-ready'
        $hgs = Get-PreflightNamed $result 'hgs'
        $hgs[0].level | Should -Be 'fixable'
        $hgs[0].ok | Should -Be $false
        $hgs[0].fix | Should -Be 'host-ready'
        (Get-PreflightNamed $result 'cpu-virtualization')[0].level | Should -Be 'info'
    }

    It 'blocks Windows Home SKU 101 and tells the human to upgrade to Pro' {
        $global:HousePreflightFacts = New-PreflightFacts -Sku 101 -Caption 'Microsoft Windows 11 Home'
        $result = & $script:preflightCheck -Context @{}
        $item = (Get-PreflightNamed $result 'edition')[0]
        $item.level | Should -Be 'blocker'
        $item.ok | Should -Be $false
        $item.why | Should -Be 'Windows Home cannot run Hyper-V'
        $item.fix | Should -Be 'upgrade to Pro'
        $item.why | Should -Not -Match 'dism|registry'
        $item.fix | Should -Not -Match 'dism|registry'
    }

    It 'blocks an old build that is not Home' {
        $global:HousePreflightFacts = New-PreflightFacts -Build 19045 -Caption 'Microsoft Windows 10 Pro'
        $result = & $script:preflightCheck -Context @{}
        $item = (Get-PreflightNamed $result 'edition')[0]
        $item.level | Should -Be 'blocker'
        $item.why | Should -Not -Be 'Windows Home cannot run Hyper-V'
    }

    It 'blocks ARM64' {
        $global:HousePreflightFacts = New-PreflightFacts -Architecture 12 -HypervisorPresent $false -Firmware $true -Slat $true
        $result = & $script:preflightCheck -Context @{}
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'arch'
        (Get-PreflightNamed $result 'arch')[0].why | Should -Match 'ARM64'
    }

    It 'blocks under 16 GB of RAM' {
        $global:HousePreflightFacts = New-PreflightFacts -Ram 8GB
        $result = & $script:preflightCheck -Context @{}
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'ram'
        (Get-PreflightNamed $result 'ram')[0].value | Should -Be '8 GB, need 16 GB'
    }

    It 'blocks firmware virtualization when no hypervisor is running' {
        $global:HousePreflightFacts = New-PreflightFacts -HypervisorPresent $false -Firmware $false -Slat $true
        $result = & $script:preflightCheck -Context @{}
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'cpu-virtualization'
        (Get-PreflightNamed $result 'cpu-virtualization')[0].fix | Should -Be 'turn on VT-x/AMD-V in firmware'
    }

    It 'blocks a CPU without SLAT when no hypervisor is running' {
        $global:HousePreflightFacts = New-PreflightFacts -HypervisorPresent $false -Firmware $true -Slat $false
        $result = & $script:preflightCheck -Context @{}
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'cpu-virtualization'
        (Get-PreflightNamed $result 'cpu-virtualization')[0].fix | Should -Be 'SLAT missing means the CPU is too old'
    }

    It 'treats vmcompute without vmms as fixable Hyper-V, not a blocker' {
        $global:HousePreflightFacts = New-PreflightFacts -VmmsExists $false -VmmsRunning $false -HyperVModule $false
        $result = & $script:preflightCheck -Context @{}
        $result.ok | Should -Be $true
        $hyperv = (Get-PreflightNamed $result 'hyperv')[0]
        $hyperv.level | Should -Be 'fixable'
        $hyperv.ok | Should -Be $false
        $hyperv.fix | Should -Be 'host-ready'
    }

    It 'does not count a large FAT32 drive as a VHDX target' {
        $global:HousePreflightFacts = New-PreflightFacts -Drives @(
            (New-PreflightDrive -DeviceId 'C:' -FileSystem 'FAT32' -FreeBytes 500GB),
            (New-PreflightDrive -DeviceId 'D:' -FileSystem 'NTFS' -FreeBytes 30GB)
        )
        $result = & $script:preflightCheck -Context @{}
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'disk'
        (Get-PreflightNamed $result 'disk')[0].value | Should -Match 'D:'
        (Get-PreflightNamed $result 'disk')[0].value | Should -Not -Match 'FAT32'
    }

    It 'accepts a ReFS drive with 200 GB free' {
        $global:HousePreflightFacts = New-PreflightFacts -Drives @(
            (New-PreflightDrive -DeviceId 'C:' -FileSystem 'ReFS' -FreeBytes 200GB)
        )
        $result = & $script:preflightCheck -Context @{}
        $result.ok | Should -Be $true
        $disk = (Get-PreflightNamed $result 'disk')[0]
        $disk.level | Should -Be 'info'
        $disk.ok | Should -Be $true
        $disk.value | Should -Match 'ReFS'
        $disk.value | Should -Match '200 GB'
    }

    It 'judges only the configured House.Path drive' {
        $global:HousePreflightFacts = New-PreflightFacts -Drives @(
            (New-PreflightDrive -DeviceId 'C:' -FileSystem 'NTFS' -FreeBytes 400GB),
            (New-PreflightDrive -DeviceId 'D:' -FileSystem 'NTFS' -FreeBytes 50GB)
        )
        $ctx = @{
            Config = @{
                House = @{
                    Path   = 'D:\Hyper-V\house'
                    DiskGB = 80
                }
            }
        }
        $result = & $script:preflightCheck -Context $ctx
        (Get-PreflightBlockerNames $result) -join ',' | Should -Be 'disk'
        (Get-PreflightNamed $result 'disk')[0].value | Should -Match '^D:'
    }

    It 'reports a non-admin shell and AllSigned as fixable' {
        $global:HousePreflightFacts = New-PreflightFacts -Elevated $false -Policy 'AllSigned'
        $result = & $script:preflightCheck -Context @{}
        $result.ok | Should -Be $true
        $elevated = (Get-PreflightNamed $result 'elevated')[0]
        $elevated.level | Should -Be 'fixable'
        $elevated.ok | Should -Be $false
        $elevated.fix | Should -Be 'open PowerShell as Administrator'
        $policy = (Get-PreflightNamed $result 'execution-policy')[0]
        $policy.ok | Should -Be $false
        $policy.fix | Should -Be 'powershell -NoProfile -ExecutionPolicy Bypass -File .\house.ps1 ...'
    }

    It 'recognises common virtual-machine model strings and ignores a physical board' {
        Test-HouseNestedComputer -Model 'Virtual Machine' -Manufacturer 'Microsoft Corporation' | Should -Be $true
        Test-HouseNestedComputer -Model 'VMware20,1' -Manufacturer 'VMware, Inc.' | Should -Be $true
        Test-HouseNestedComputer -Model 'Standard PC' -Manufacturer 'innotek GmbH' | Should -Be $true
        Test-HouseNestedComputer -Model 'Parallels Virtual Platform' -Manufacturer 'Parallels Software' | Should -Be $true
        Test-HouseNestedComputer -Model 'Z790 AORUS MASTER' -Manufacturer 'Gigabyte' | Should -Be $false
        Test-HouseNestedComputer -Model 'Standard PC' -Manufacturer 'Microsoft Corporation' | Should -Be $false
    }
}

Describe 'WinHTTP proxy parser' {
    BeforeAll {
        function script:New-EnglishWinHttp {
            param([string]$HostIP = '192.0.2.1', [int]$Port = 3128, [string]$Bypass = '<local>;192.0.2.1')
            return "Current WinHTTP proxy settings:`r`n`r`n    Proxy Server(s) :  ${HostIP}:${Port}`r`n    Bypass List     :  $Bypass`r`n"
        }

        function script:New-ChineseWinHttp {
            param([string]$HostIP = '192.0.2.1', [int]$Port = 3128)
            $proxyLabel = -join @([char]0x4EE3, [char]0x7406, [char]0x670D, [char]0x52A1, [char]0x5668)
            $bypassLabel = -join @([char]0x7ED5, [char]0x8FC7, [char]0x5217, [char]0x8868)
            return "${proxyLabel}: ${HostIP}:${Port}`r`n${bypassLabel}: <local>;${HostIP}`r`n"
        }
    }

    It 'parses an English netsh winhttp show proxy sample' {
        $parsed = Test-HouseWinHttpProxy -Text (New-EnglishWinHttp) -HostIP '192.0.2.1' -GatePort 3128
        $parsed.proxy | Should -Be $true
        $parsed.bypass | Should -Be $true
        $parsed.ok | Should -Be $true
    }

    It 'parses a Chinese sample by the address, not by the labels' {
        $parsed = Test-HouseWinHttpProxy -Text (New-ChineseWinHttp) -HostIP '192.0.2.1' -GatePort 3128
        $parsed.proxy | Should -Be $true
        $parsed.bypass | Should -Be $true
        $parsed.ok | Should -Be $true
    }

    It 'rejects a proxy token that is not also in the bypass list' {
        $parsed = Test-HouseWinHttpProxy -Text '192.0.2.1:3128' -HostIP '192.0.2.1' -GatePort 3128
        $parsed.proxy | Should -Be $true
        $parsed.bypass | Should -Be $false
        $parsed.ok | Should -Be $false
    }

    It 'does not treat a longer address as the host bypass token' {
        $text = "192.0.2.1:3128`r`n192.0.2.10"
        $parsed = Test-HouseWinHttpProxy -Text $text -HostIP '192.0.2.1' -GatePort 3128
        $parsed.bypass | Should -Be $false
    }
}

Describe 'negative probe classifiers' {
    It 'classifies an unexpected TCP exception as probe-error' {
        $parsed = ConvertTo-HouseTcpProbeOutcome -Target '1.1.1.1:443' -Connected $false -TimedOut $false -ErrorRecord (New-Object System.InvalidOperationException 'null reference')
        $parsed.outcome | Should -Be 'probe-error'
        $parsed.error | Should -Match 'null reference'
    }

    It 'classifies a refused socket as blocked and a connected socket as connected' {
        $refused = New-Object System.Net.Sockets.SocketException 10061
        $parsed = ConvertTo-HouseTcpProbeOutcome -Target '9.9.9.9:443' -Connected $false -TimedOut $false -ErrorRecord $refused
        $parsed.outcome | Should -Be 'blocked'
        $parsed.error | Should -Be 'ConnectionRefused'
        $open = ConvertTo-HouseTcpProbeOutcome -Target '1.1.1.1:443' -Connected $true -TimedOut $false -ErrorRecord $null
        $open.outcome | Should -Be 'connected'
        $timed = ConvertTo-HouseTcpProbeOutcome -Target '1.1.1.1:443' -Connected $false -TimedOut $true -ErrorRecord $null
        $timed.outcome | Should -Be 'blocked'
        $timed.error | Should -Be 'timeout'
    }

    It 'does not treat an unclassified socket error as blocked' {
        $denied = New-Object System.Net.Sockets.SocketException 10013
        $parsed = ConvertTo-HouseTcpProbeOutcome -Target '1.1.1.1:443' -Connected $false -TimedOut $false -ErrorRecord $denied
        $parsed.outcome | Should -Be 'probe-error'
    }

    It 'classifies DNS timeout, no servers and server failure as blocked' {
        $timeout = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception 'The operation timed out'),
            'DnsTimeout',
            ([System.Management.Automation.ErrorCategory]::OperationTimeout),
            $null)
        $noServer = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception 'No DNS servers configured'),
            'DnsNone',
            ([System.Management.Automation.ErrorCategory]::ResourceUnavailable),
            $null)
        $failure = New-Object System.Exception 'DNS server failure'
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $timeout).outcome | Should -Be 'blocked'
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $timeout).category | Should -Be 'OperationTimeout'
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $noServer).outcome | Should -Be 'blocked'
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com@1.1.1.1' -Answer $null -ErrorRecord $failure).outcome | Should -Be 'blocked'
    }

    It 'classifies DNS failures by Win32 code, so a localized message still counts' {
        $noServers = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.ComponentModel.Win32Exception 9852, ('example.com : ' + [string][char]0x672A + [char]0x914D + [char]0x7F6E + ' DNS')),
            'DNS_ERROR_NO_DNS_SERVERS,Microsoft.DnsClient.Commands.ResolveDnsName',
            ([System.Management.Automation.ErrorCategory]::NotSpecified),
            $null)
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $noServers).outcome | Should -Be 'blocked'
        $unknown = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.ComponentModel.Win32Exception 5, ([string][char]0x62D2 + [char]0x7EDD)),
            'Other',
            ([System.Management.Automation.ErrorCategory]::NotSpecified),
            $null)
        (ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $unknown).outcome | Should -Be 'probe-error'
    }

    It 'classifies a DNS answer as answered and any other DNS error as probe-error' {
        $answer = ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer @([pscustomobject]@{ IPAddress = '203.0.113.5' }) -ErrorRecord $null
        $answer.outcome | Should -Be 'answered'
        $other = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception 'DNS name does not exist'),
            'DnsNx',
            ([System.Management.Automation.ErrorCategory]::ObjectNotFound),
            $null)
        $parsed = ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord $other
        $parsed.outcome | Should -Be 'probe-error'
        $parsed.category | Should -Be 'ObjectNotFound'
        $parsed.error | Should -Match 'does not exist'
    }

    It 'counts an HTTP status on a WebException as the gate and a timeout as a miss' {
        if (-not ('HouseTestWebResponse' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net;
public sealed class HouseTestWebResponse : WebResponse {
    public HttpStatusCode StatusCode { get; private set; }
    public HouseTestWebResponse(int statusCode) {
        StatusCode = (HttpStatusCode)statusCode;
    }
}
'@
        }
        $response = New-Object HouseTestWebResponse 401
        $denied = New-Object System.Net.WebException('denied', $null, ([System.Net.WebExceptionStatus]::ProtocolError), $response)
        $parsed = ConvertTo-HouseGateProbeOutcome -Response $null -ErrorRecord $denied
        $parsed.reached | Should -Be $true
        $parsed.status | Should -Be 401
        $timeout = New-Object System.Net.WebException('timed out', $null, ([System.Net.WebExceptionStatus]::Timeout), $null)
        $miss = ConvertTo-HouseGateProbeOutcome -Response $null -ErrorRecord $timeout
        $miss.reached | Should -Be $false
        $miss.status | Should -Be $null
    }
}

Describe 'guest-network check' {
    BeforeAll {
        $script:guestNetworkCheck = Join-Path $script:repo 'checks\guest-network.ps1'

        function New-GuestAdapter {
            param([string]$Name = 'Ethernet', [string]$Description = 'Fixture adapter', [string]$Status = 'Up', [bool]$Hidden = $false, [bool]$Loopback = $false, [int]$InterfaceIndex = 4)
            return [pscustomobject]@{
                Name = $Name
                InterfaceDescription = $Description
                Status = $Status
                Hidden = $Hidden
                Loopback = $Loopback
                InterfaceIndex = $InterfaceIndex
            }
        }

        function New-GuestFirewall {
            param([string]$BrokenProfile = '', [string]$Outbound = 'Block')
            $rows = @()
            foreach ($name in @('Domain', 'Private', 'Public')) {
                $out = 'Allow'
                if ($name -eq $BrokenProfile) { $out = $Outbound }
                $rows += [pscustomobject]@{
                    Name = $name
                    Enabled = 'True'
                    DefaultInboundAction = 'Block'
                    DefaultOutboundAction = $out
                }
            }
            return $rows
        }

        function New-GuestNetworkFacts {
            param($Adapters, $Addresses, $Routes, $Dns, $Firewall, $Http = 'http://192.0.2.1:3128/', $Https = 'http://192.0.2.1:3128', $NoProxy = 'localhost,127.0.0.1,192.0.2.1', $WinHttp, $Enable = 1, $ProxyServer = '192.0.2.1:3128', $Override = '<local>;192.0.2.1')
            if ($null -eq $Adapters) { $Adapters = @((New-GuestAdapter)) }
            if ($null -eq $Addresses) { $Addresses = @([pscustomobject]@{ InterfaceIndex = 4; IPAddress = '192.0.2.2'; PrefixLength = 24 }) }
            if ($null -eq $Routes) { $Routes = @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.0.2.1'; InterfaceIndex = 4 }) }
            if ($null -eq $Dns) { $Dns = @([pscustomobject]@{ InterfaceIndex = 4; ServerAddresses = @() }) }
            if ($null -eq $Firewall) { $Firewall = @(New-GuestFirewall) }
            if (-not $WinHttp) { $WinHttp = "Proxy Server(s) : 192.0.2.1:3128`r`nBypass List : <local>;192.0.2.1`r`n" }
            return [pscustomobject]@{
                adapters = @($Adapters)
                addresses = @($Addresses)
                routes = @($Routes)
                dns = @($Dns)
                firewall = @($Firewall)
                env = [pscustomobject]@{ HTTP_PROXY = $Http; HTTPS_PROXY = $Https; NO_PROXY = $NoProxy }
                winhttp = [string]$WinHttp
                userproxy = [pscustomobject]@{ ProxyEnable = $Enable; ProxyServer = $ProxyServer; ProxyOverride = $Override }
                error = $null
            }
        }

        function New-GuestNetworkContext {
            param($Facts, [switch]$Throw, [string]$Message = 'credential rejected')
            $ctx = New-BlueprintContext -Config (New-BlueprintConfig)
            $ctx.InvokeGuest = {
                param($ScriptBlock, $ArgumentList)
                if ([string]$ScriptBlock -notmatch 'IncludeHidden') { throw 'guest network probe missed hidden adapters' }
                if ($Throw) { throw $Message }
                return $Facts
            }.GetNewClosure()
            return $ctx
        }
    }

    It 'builds a read-only guest probe that includes hidden adapters' {
        $probe = Get-HouseGuestNetworkProbe
        $text = [string]$probe
        $text | Should -Match '-IncludeHidden'
        $text | Should -Match 'winhttp show proxy'
        $text | Should -Not -Match 'winhttp set'
    }

    It 'passes when the guest has one static adapter and the gate proxy' {
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts (New-GuestNetworkFacts))
        $result.id | Should -Be 'guest-network'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'guest network'
        $result.fix | Should -Be 'runbook/07-guest-network.md#if-it-fails'
        $result.evidence.oneadapter | Should -Be $true
        $result.evidence.staticip | Should -Be $true
        $result.evidence.gateway | Should -Be $true
        $result.evidence.nodns | Should -Be $true
        $result.evidence.firewall | Should -Be $true
        $result.evidence.envproxy | Should -Be $true
        $result.evidence.winhttp | Should -Be $true
        $result.evidence.userproxy | Should -Be $true
    }

    It 'fails when the blueprint was not loaded' {
        $called = $false
        $ctx = New-BlueprintContext -Config $null
        $ctx.InvokeGuest = { $called = $true }
        $result = & $script:guestNetworkCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $called | Should -Be $false
    }

    It 'fails oneadapter when a hidden Wintun adapter is Up' {
        $facts = New-GuestNetworkFacts -Adapters @(
            (New-GuestAdapter),
            (New-GuestAdapter -Name 'Wintun' -Description 'Wintun Userspace Tunnel' -Hidden $true -InterfaceIndex 9)
        )
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.oneadapter | Should -Be $false
        $result.detail | Should -Match 'oneadapter'
    }

    It 'ignores an Up loopback adapter' {
        $facts = New-GuestNetworkFacts -Adapters @(
            (New-GuestAdapter),
            (New-GuestAdapter -Name 'Loopback Pseudo-Interface' -Description 'Software Loopback' -InterfaceIndex 1)
        )
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $true
        $result.evidence.oneadapter | Should -Be $true
    }

    It 'fails staticip when an APIPA address sits next to VmIP' {
        $facts = New-GuestNetworkFacts -Addresses @(
            [pscustomobject]@{ InterfaceIndex = 4; IPAddress = '192.0.2.2'; PrefixLength = 24 },
            [pscustomobject]@{ InterfaceIndex = 4; IPAddress = '169.254.10.20'; PrefixLength = 16 }
        )
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.staticip | Should -Be $false
        $result.evidence.oneadapter | Should -Be $true
        $result.detail | Should -Be 'staticip'
    }

    It 'fails gateway when the default route is not the host' {
        $facts = New-GuestNetworkFacts -Routes @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '198.51.100.1'; InterfaceIndex = 4 })
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.gateway | Should -Be $false
        $result.detail | Should -Be 'gateway'
    }

    It 'fails nodns when the adapter has a DNS server' {
        $facts = New-GuestNetworkFacts -Dns @([pscustomobject]@{ InterfaceIndex = 4; ServerAddresses = @('1.1.1.1') })
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.nodns | Should -Be $false
        $result.detail | Should -Be 'nodns'
    }

    It 'fails firewall when Public outbound is Block' {
        $facts = New-GuestNetworkFacts -Firewall (New-GuestFirewall -BrokenProfile 'Public')
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.firewall | Should -Be $false
        $result.detail | Should -Be 'firewall'
    }

    It 'fails envproxy when the machine proxy is not the gate' {
        $facts = New-GuestNetworkFacts -Http 'http://198.51.100.1:9' -NoProxy 'localhost'
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.envproxy | Should -Be $false
        $result.detail | Should -Be 'envproxy'
    }

    It 'fails winhttp when the bypass list has no host address' {
        $facts = New-GuestNetworkFacts -WinHttp "192.0.2.1:3128`r`n<local>"
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.winhttp | Should -Be $false
        $result.detail | Should -Be 'winhttp'
    }

    It 'fails userproxy when ProxyEnable is off' {
        $facts = New-GuestNetworkFacts -Enable 0
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.userproxy | Should -Be $false
        $result.detail | Should -Be 'userproxy'
    }

    It 'fails every item and keeps the InvokeGuest message when the guest call throws' {
        $result = & $script:guestNetworkCheck -Context (New-GuestNetworkContext -Facts $null -Throw)
        $result.ok | Should -Be $false
        $result.evidence.oneadapter | Should -Be $false
        $result.evidence.staticip | Should -Be $false
        $result.evidence.gateway | Should -Be $false
        $result.evidence.nodns | Should -Be $false
        $result.evidence.firewall | Should -Be $false
        $result.evidence.envproxy | Should -Be $false
        $result.evidence.winhttp | Should -Be $false
        $result.evidence.userproxy | Should -Be $false
        $result.detail | Should -Match 'credential rejected'
    }
}

Describe 'one-way-out check' {
    BeforeAll {
        $script:oneWayCheck = Join-Path $script:repo 'checks\one-way-out.ps1'

        function New-BlockedTcp {
            return @(
                [pscustomobject]@{ target = '1.1.1.1:443'; outcome = 'blocked'; error = 'NetworkUnreachable' },
                [pscustomobject]@{ target = '9.9.9.9:443'; outcome = 'blocked'; error = 'TimedOut' },
                [pscustomobject]@{ target = '1.1.1.1:53'; outcome = 'blocked'; error = 'TimedOut' },
                [pscustomobject]@{ target = '9.9.9.9:53'; outcome = 'blocked'; error = 'TimedOut' }
            )
        }

        function New-BlockedDns {
            return @(
                [pscustomobject]@{ target = 'example.com'; outcome = 'blocked'; error = 'No DNS servers configured'; category = 'ResourceUnavailable' },
                [pscustomobject]@{ target = 'example.com@1.1.1.1'; outcome = 'blocked'; error = 'timeout'; category = 'OperationTimeout' }
            )
        }

        function New-OneWayFacts {
            param($Tcp, $Dns, $Adapters, $Routes, $Gate)
            if ($null -eq $Tcp) { $Tcp = @(New-BlockedTcp) }
            if ($null -eq $Dns) { $Dns = @(New-BlockedDns) }
            if ($null -eq $Adapters) {
                $Adapters = @([pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Fixture'; Status = 'Up'; Hidden = $false; Loopback = $false; InterfaceIndex = 4 })
            }
            if ($null -eq $Routes) {
                $Routes = @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.0.2.1'; InterfaceIndex = 4 })
            }
            if ($null -eq $Gate) { $Gate = [pscustomobject]@{ reached = $true; status = 404; error = $null; target = 'https://api.anthropic.com' } }
            return [pscustomobject]@{
                tcp = @($Tcp)
                dns = @($Dns)
                adapters = @($Adapters)
                routes = @($Routes)
                gate = $Gate
                error = $null
            }
        }

        function New-OneWayContext {
            param($Facts, [switch]$Throw, [string]$Message = 'credential rejected')
            $ctx = New-BlueprintContext -Config (New-BlueprintConfig)
            $ctx.InvokeGuest = {
                param($ScriptBlock, $ArgumentList)
                if ([string]$ScriptBlock -notmatch '1\.1\.1\.1') { throw 'one-way probe missing tcp target' }
                $joined = @($ArgumentList) -join ' '
                if ($joined -notmatch 'http://192\.0\.2\.1:3128') { throw 'one-way probe missing gate url' }
                if ($Throw) { throw $Message }
                return $Facts
            }.GetNewClosure()
            return $ctx
        }
    }

    It 'builds a probe that carries the classifiers and both public targets' {
        $probe = Get-HouseOneWayOutProbe
        $text = [string]$probe
        $text | Should -Match '1\.1\.1\.1'
        $text | Should -Match '9\.9\.9\.9'
        $text | Should -Match 'Resolve-DnsName'
        $text | Should -Match 'api\.anthropic\.com'
        $text | Should -Match '-IncludeHidden'
        $text | Should -Match 'NetworkUnreachable'
        $text | Should -Match 'probe-error'
        $text | Should -Match 'WaitOne\(3000\)'
        $text | Should -Match "'1\.1\.1\.1:53'"
        $text | Should -Match "'9\.9\.9\.9:53'"
    }

    It 'passes when negatives are blocked and the gate returns 404' {
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts))
        $result.id | Should -Be 'one-way-out'
        $result.ok | Should -BeOfType ([bool])
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'one way out'
        $result.fix | Should -Be 'runbook/08-one-way-out.md#if-it-fails'
        $result.evidence.notcp | Should -Be $true
        $result.evidence.nodns | Should -Be $true
        $result.evidence.noroute | Should -Be $true
        $result.evidence.gate | Should -Be $true
        $result.evidence.gateStatus | Should -Be 404
        @($result.evidence.dns | Where-Object { $_.target -eq 'example.com' })[0].category | Should -Be 'ResourceUnavailable'
    }

    It 'fails notcp when any TCP target connects, including port 53' {
        foreach ($target in @('1.1.1.1:443', '9.9.9.9:443', '1.1.1.1:53', '9.9.9.9:53')) {
            $tcp = @(New-BlockedTcp)
            $tcp = @(foreach ($row in $tcp) {
                if ($row.target -eq $target) { [pscustomobject]@{ target = $row.target; outcome = 'connected'; error = $null } }
                else { $row }
            })
            $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Tcp $tcp))
            $result.ok | Should -Be $false
            $result.evidence.notcp | Should -Be $false
            $result.detail | Should -Be 'notcp'
        }
    }

    It 'fails notcp on a TCP probe-error and keeps the error in detail' {
        $parsed = ConvertTo-HouseTcpProbeOutcome -Target '1.1.1.1:443' -Connected $false -TimedOut $false -ErrorRecord (New-Object System.InvalidOperationException 'null reference')
        $parsed.outcome | Should -Be 'probe-error'
        $tcp = @(New-BlockedTcp)
        $tcp = @(foreach ($row in $tcp) {
            if ($row.target -eq '1.1.1.1:443') { $parsed } else { $row }
        })
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Tcp $tcp))
        $result.ok | Should -Be $false
        $result.evidence.notcp | Should -Be $false
        $result.detail | Should -Match 'notcp'
        $result.detail | Should -Match 'null reference'
    }

    It 'fails nodns when DNS answers' {
        $dns = @(New-BlockedDns)
        $dns = @(foreach ($row in $dns) {
            if ($row.target -eq 'example.com') { [pscustomobject]@{ target = 'example.com'; outcome = 'answered'; error = $null; category = '' } }
            else { $row }
        })
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Dns $dns))
        $result.ok | Should -Be $false
        $result.evidence.nodns | Should -Be $false
        $result.detail | Should -Be 'nodns'
    }

    It 'fails nodns on a DNS probe-error' {
        $parsed = ConvertTo-HouseDnsProbeOutcome -Target 'example.com' -Answer $null -ErrorRecord (New-Object System.Exception 'parse error')
        $parsed.outcome | Should -Be 'probe-error'
        $dns = @(New-BlockedDns)
        $dns = @(foreach ($row in $dns) {
            if ($row.target -eq 'example.com') { $parsed } else { $row }
        })
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Dns $dns))
        $result.ok | Should -Be $false
        $result.evidence.nodns | Should -Be $false
        $result.detail | Should -Match 'nodns'
        $result.detail | Should -Match 'parse error'
    }

    It 'fails noroute when a second default route exists' {
        $routes = @(
            [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.0.2.1'; InterfaceIndex = 4 },
            [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '198.51.100.1'; InterfaceIndex = 4 }
        )
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Routes $routes))
        $result.ok | Should -Be $false
        $result.evidence.noroute | Should -Be $false
        $result.detail | Should -Be 'noroute'
    }

    It 'fails noroute when a second Up adapter exists' {
        $adapters = @(
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Fixture'; Status = 'Up'; Hidden = $false; Loopback = $false; InterfaceIndex = 4 },
            [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Passthrough'; Status = 'Up'; Hidden = $false; Loopback = $false; InterfaceIndex = 7 }
        )
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Adapters $adapters))
        $result.ok | Should -Be $false
        $result.evidence.noroute | Should -Be $false
        $result.detail | Should -Be 'noroute'
    }

    It 'fails gate when the network is dead and every negative probe is blocked' {
        $gate = [pscustomobject]@{ reached = $false; status = $null; error = 'connection refused'; target = 'https://api.anthropic.com' }
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Gate $gate))
        $result.ok | Should -Be $false
        $result.evidence.notcp | Should -Be $true
        $result.evidence.nodns | Should -Be $true
        $result.evidence.noroute | Should -Be $true
        $result.evidence.gate | Should -Be $false
        $result.detail | Should -Be 'gate'
    }

    It 'passes gate when a WebException carries HTTP 401' {
        if (-not ('HouseTestWebResponse' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net;
public sealed class HouseTestWebResponse : WebResponse {
    public HttpStatusCode StatusCode { get; private set; }
    public HouseTestWebResponse(int statusCode) {
        StatusCode = (HttpStatusCode)statusCode;
    }
}
'@
        }
        $response = New-Object HouseTestWebResponse 401
        $denied = New-Object System.Net.WebException('denied', $null, ([System.Net.WebExceptionStatus]::ProtocolError), $response)
        $parsed = ConvertTo-HouseGateProbeOutcome -Response $null -ErrorRecord $denied
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts (New-OneWayFacts -Gate $parsed))
        $result.ok | Should -Be $true
        $result.evidence.gate | Should -Be $true
        $result.evidence.gateStatus | Should -Be 401
        $result.detail | Should -Be 'one way out'
    }

    It 'fails every item and keeps the InvokeGuest message when the guest call throws' {
        $result = & $script:oneWayCheck -Context (New-OneWayContext -Facts $null -Throw)
        $result.ok | Should -Be $false
        $result.evidence.notcp | Should -Be $false
        $result.evidence.nodns | Should -Be $false
        $result.evidence.noroute | Should -Be $false
        $result.evidence.gate | Should -Be $false
        $result.detail | Should -Match 'notcp'
        $result.detail | Should -Match 'nodns'
        $result.detail | Should -Match 'noroute'
        $result.detail | Should -Match 'gate'
        $result.detail | Should -Match 'credential rejected'
    }
}

Describe 'write probe outcome' {
    It 'classifies a completed write as success' {
        $result = ConvertTo-HouseWriteProbeOutcome -Succeeded $true -ErrorRecord $null
        $result.outcome | Should -Be 'success'
        $result.error | Should -BeNullOrEmpty
    }

    It 'classifies UnauthorizedAccessException as access-denied' {
        $denied = New-Object System.UnauthorizedAccessException('Access is denied')
        $result = ConvertTo-HouseWriteProbeOutcome -Succeeded $false -ErrorRecord $denied
        $result.outcome | Should -Be 'access-denied'
    }

    It 'classifies an ordinary IOException as probe-error' {
        $full = New-Object System.IO.IOException('disk full')
        $result = ConvertTo-HouseWriteProbeOutcome -Succeeded $false -ErrorRecord $full
        $result.outcome | Should -Be 'probe-error'
        $result.error | Should -Match 'disk full'
    }

    It 'classifies Win32 error 5 as access-denied' {
        $denied = New-Object System.ComponentModel.Win32Exception(5)
        $result = ConvertTo-HouseWriteProbeOutcome -Succeeded $false -ErrorRecord $denied
        $result.outcome | Should -Be 'access-denied'
    }

    It 'classifies a missing error as probe-error' {
        $result = ConvertTo-HouseWriteProbeOutcome -Succeeded $false -ErrorRecord $null
        $result.outcome | Should -Be 'probe-error'
        $result.error | Should -Be 'unrecognised write failure'
    }
}

Describe 'forbidden mirror paths' {
    It 'refuses the VM profile, Windows, and Program Files' {
        $profile = Test-HouseForbiddenMirrorPath -HostPath 'C:\Users\fixtureuser\x' -UserName 'fixtureuser'
        $profile | Should -Match 'VM user profile'
        $profile | Should -Match 'C:\\Users\\fixtureuser\\x'
        $windows = Test-HouseForbiddenMirrorPath -HostPath 'C:\Windows\x' -UserName 'fixtureuser'
        $windows | Should -Match 'inside Windows'
        $programs = Test-HouseForbiddenMirrorPath -HostPath 'C:\Program Files\x' -UserName 'fixtureuser'
        $programs | Should -Match 'inside Program Files'
    }

    It 'refuses Program Files (x86) and allows ProgramData' {
        $x86 = Test-HouseForbiddenMirrorPath -HostPath 'C:\Program Files (x86)\x' -UserName 'fixtureuser'
        $x86 | Should -Match 'inside Program Files'
        Test-HouseForbiddenMirrorPath -HostPath 'C:\ProgramData\x' -UserName 'fixtureuser' | Should -BeNullOrEmpty
    }

    It 'refuses a drive root and any parent of the profile or system folders' {
        Test-HouseForbiddenMirrorPath -HostPath 'C:\' -UserName 'fixtureuser' | Should -Match 'drive root'
        Test-HouseForbiddenMirrorPath -HostPath 'D:\' -UserName 'fixtureuser' | Should -Match 'drive root'
        Test-HouseForbiddenMirrorPath -HostPath 'C:\Users' -UserName 'fixtureuser' | Should -Match 'contains the VM user profile'
        Test-HouseForbiddenMirrorPath -HostPath 'C:\Users\fixtureuser' -UserName 'fixtureuser' | Should -Match 'VM user profile'
    }

    It 'allows another user folder and a data drive' {
        Test-HouseForbiddenMirrorPath -HostPath 'C:\Users\alice\Documents\notes' -UserName 'fixtureuser' | Should -BeNullOrEmpty
        Test-HouseForbiddenMirrorPath -HostPath 'D:\projects' -UserName 'fixtureuser' | Should -BeNullOrEmpty
    }
}

Describe 'non-ASCII symlink' {
    It 'round-trips a non-ASCII symbolic link name' {
        $folder = Join-Path $TestDrive 'link-target'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $leaf = ([char]0x8D44).ToString() + [char]0x6599
        $link = Join-Path $TestDrive $leaf
        try {
            # Non-terminating by default; -ErrorAction Stop makes the missing-privilege case reach catch.
            New-Item -ItemType SymbolicLink -Path $link -Target $folder -ErrorAction Stop | Out-Null
        }
        catch {
            $message = [string]$_.Exception.Message
            if ([string]$_.FullyQualifiedErrorId -match 'ElevationRequired' -or $message -match '(?i)privilege|1314') {
                Set-ItResult -Skipped -Because $message
                return
            }
            throw
        }
        $item = Get-Item -LiteralPath $link -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $target = [string]@($item.Target)[0]
        $target | Should -Be $folder
    }
}

Describe 'tools check' {
    BeforeAll {
        $script:toolsCheck = Join-Path $script:repo 'checks\tools.ps1'

        function script:New-ToolsContext {
            param($Config, $Guest, [switch]$Throw)
            $ctx = New-BlueprintContext -Config $Config
            $bag = @{ Probe = ''; Args = @(); Guest = $Guest }
            $script:toolsBag = $bag
            if ($Throw) {
                $ctx.InvokeGuest = { param($ScriptBlock, $ArgumentList) throw 'credential rejected' }
            }
            else {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Probe = $ScriptBlock.ToString()
                    $bag.Args = @($ArgumentList)
                    return $bag.Guest
                }.GetNewClosure()
            }
            return $ctx
        }

        function script:New-ToolRow {
            param([bool]$Ok, [string]$Version, [string]$ErrorText)
            return [pscustomobject]@{ ok = $Ok; version = $Version; error = $ErrorText }
        }

        function script:New-ToolsGuest {
            param($Desktop, $GitHubCli, $VSCode)
            return [pscustomobject]@{
                git = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
                claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
                claudeOnPath = $true
                desktop = $Desktop
                gh = $GitHubCli
                vscode = $VSCode
                error = $null
            }
        }
    }

    It 'passes git and claude and omits python and node when they are off' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $false; Node = $false }
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            python = $null
            node   = $null
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.id | Should -Be 'tools'
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'tools ready'
        $result.evidence.git | Should -Be $true
        $result.evidence.gitVersion | Should -Be 'git version 2.46.0'
        $result.evidence.claudeVersion | Should -Be '1.0.24'
        $result.evidence.PSObject.Properties.Name | Should -Not -Contain 'python'
        $result.evidence.PSObject.Properties.Name | Should -Not -Contain 'node'
        $script:toolsBag.Probe | Should -Match '--version'
        $script:toolsBag.Probe | Should -Match '\.local'
        $script:toolsBag.Probe | Should -Not -Match 'https://'
        $script:toolsBag.Args[0] | Should -Be 'False'
        $script:toolsBag.Args[1] | Should -Be 'False'
        $result.fix | Should -Be 'runbook/09-tools.md#if-it-fails'
    }

    It 'passes python and node when the blueprint enables them' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $true; Node = $true }
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            python = (New-ToolRow -Ok $true -Version 'Python 3.12.6' -ErrorText '')
            node   = (New-ToolRow -Ok $true -Version 'v20.17.0' -ErrorText '')
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'tools ready'
        $result.evidence.python | Should -Be $true
        $result.evidence.pythonVersion | Should -Be 'Python 3.12.6'
        $result.evidence.nodeVersion | Should -Be 'v20.17.0'
        $script:toolsBag.Args[0] | Should -Be 'True'
        $script:toolsBag.Args[1] | Should -Be 'True'
    }

    It 'fails desktop when its blueprint flag is on and the package is missing' {
        $config = New-BlueprintConfig
        $config.Tools = @{ ClaudeDesktop = $true }
        $guest = New-ToolsGuest -Desktop (New-ToolRow -Ok $false -Version '' -ErrorText 'Claude desktop package not found')
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.detail | Should -Match '^desktop'
        $result.evidence.desktop | Should -Be $false
        $result.evidence.desktopVersion | Should -Be ''
        $script:toolsBag.Args[2] | Should -Be 'True'
    }

    It 'passes desktop when its package has a version' {
        $config = New-BlueprintConfig
        $config.Tools = @{ ClaudeDesktop = $true }
        $guest = New-ToolsGuest -Desktop (New-ToolRow -Ok $true -Version '2.31226.1.0' -ErrorText '')
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'tools ready'
        $result.evidence.desktop | Should -Be $true
        $result.evidence.desktopVersion | Should -Be '2.31226.1.0'
    }

    It 'fails gh only when the GitHub CLI flag is enabled' {
        $config = New-BlueprintConfig
        $config.Tools = @{ GitHubCli = $true }
        $guest = New-ToolsGuest -GitHubCli (New-ToolRow -Ok $false -Version '' -ErrorText 'gh not found')
        $onResult = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $onResult.ok | Should -Be $false
        $onResult.detail | Should -Match 'gh'
        $onResult.detail | Should -Match 'gh not found'
        $onResult.evidence.gh | Should -Be $false

        $offConfig = New-BlueprintConfig
        $offResult = & $script:toolsCheck -Context (New-ToolsContext -Config $offConfig -Guest $guest)
        $offResult.ok | Should -Be $true
        $offResult.evidence.PSObject.Properties.Name | Should -Not -Contain 'gh'
        $script:toolsBag.Args[3] | Should -Be 'False'
    }

    It 'fails vscode only when the VS Code flag is enabled' {
        $config = New-BlueprintConfig
        $config.Tools = @{ VSCode = $true }
        $guest = New-ToolsGuest -VSCode (New-ToolRow -Ok $false -Version '' -ErrorText 'code not found')
        $onResult = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $onResult.ok | Should -Be $false
        $onResult.detail | Should -Match 'vscode'
        $onResult.detail | Should -Match 'code not found'
        $onResult.evidence.vscode | Should -Be $false

        $offConfig = New-BlueprintConfig
        $offResult = & $script:toolsCheck -Context (New-ToolsContext -Config $offConfig -Guest $guest)
        $offResult.ok | Should -Be $true
        $offResult.evidence.PSObject.Properties.Name | Should -Not -Contain 'vscode'
        $script:toolsBag.Args[4] | Should -Be 'False'
    }

    It 'loads an old blueprint without new flags and does not request those tools' {
        $config = Import-HouseConfig -Path (Join-Path $script:configs 'valid.psd1')
        foreach ($name in @('ClaudeDesktop', 'GitHubCli', 'VSCode')) {
            (Get-HousePropertyValue -Object $config.Tools -Name $name) | Should -BeNullOrEmpty
        }
        $guest = New-ToolsGuest
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $true
        foreach ($name in @('desktop', 'gh', 'vscode')) {
            $result.evidence.PSObject.Properties.Name | Should -Not -Contain $name
        }
        $script:toolsBag.Args[2] | Should -Be 'False'
        $script:toolsBag.Args[3] | Should -Be 'False'
        $script:toolsBag.Args[4] | Should -Be 'False'
        $script:toolsBag.Probe | Should -Match 'if \(\$WantClaudeDesktop -eq ''True''\)'
        $script:toolsBag.Probe | Should -Match 'if \(\$WantGitHubCli -eq ''True''\)'
        $script:toolsBag.Probe | Should -Match 'if \(\$WantVSCode -eq ''True''\)'
    }

    It 'keeps the rendered step 9 script block ASCII with the Claude desktop signature checks' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $true; Node = $true }
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\09-tools.md'))
        $rendered = Format-HousePage -Content $page -Config $config
        $match = [regex]::Match($rendered, '(?s)```powershell\s*(.*?)\s*```')
        $match.Success | Should -Be $true
        $block = $match.Groups[1].Value
        $block.Contains('{{') | Should -Be $false
        @($block.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        $block | Should -Match 'downloads\.claude\.ai'
        $block | Should -Match 'Anthropic, PBC'
        foreach ($name in @('ClaudeDesktop', 'GitHubCli', 'VSCode')) { $block | Should -Match $name }

        $example = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repo 'house.config.example.psd1')
        foreach ($name in @('Python', 'Node', 'ClaudeDesktop', 'GitHubCli', 'VSCode')) {
            [string]$example.Tools[$name] | Should -Be 'True'
        }
    }

    It 'fails git when the version text is empty' {
        $config = New-BlueprintConfig
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version '' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.evidence.git | Should -Be $false
        $result.detail | Should -Match 'git'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:toolsCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $result.evidence.git | Should -Be $false
        $result.evidence.claude | Should -Be $false
    }

    It 'fails git when the guest reports it missing' {
        $config = New-BlueprintConfig
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $false -Version '' -ErrorText 'git not found')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.evidence.git | Should -Be $false
        $result.detail | Should -Match 'git'
        $result.detail | Should -Match 'git not found'
    }

    It 'fails claudePath when claude runs only by its full path' {
        $config = New-BlueprintConfig
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '2.1.296' -ErrorText '')
            claudeOnPath = $false
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.evidence.claude | Should -Be $true
        $result.evidence.claudePath | Should -Be $false
        $result.detail | Should -Be 'claudePath'
        $script:toolsBag.Probe | Should -Match "GetEnvironmentVariable\('Path'"
    }

    It 'fails claude when the guest reports it missing' {
        $config = New-BlueprintConfig
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $false -Version '' -ErrorText 'claude not found')
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.evidence.claude | Should -Be $false
        $result.detail | Should -Match 'claude'
        $result.detail | Should -Match 'claude not found'
    }

    It 'fails python only when the blueprint enables it' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $true; Node = $false }
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            python = (New-ToolRow -Ok $false -Version '' -ErrorText 'python not found')
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'python'
        $result.detail | Should -Match 'python not found'

        $off = New-BlueprintConfig
        $off.Tools = @{ Python = $false; Node = $false }
        $offResult = & $script:toolsCheck -Context (New-ToolsContext -Config $off -Guest $guest)
        $offResult.ok | Should -Be $true
        $offResult.evidence.PSObject.Properties.Name | Should -Not -Contain 'python'
    }

    It 'fails node only when the blueprint enables it' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $false; Node = $true }
        $guest = [pscustomobject]@{
            git    = (New-ToolRow -Ok $true -Version 'git version 2.46.0' -ErrorText '')
            claude = (New-ToolRow -Ok $true -Version '1.0.24' -ErrorText '')
            claudeOnPath = $true
            node   = (New-ToolRow -Ok $false -Version '' -ErrorText 'node not found')
            error  = $null
        }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Guest $guest)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'node'
        $result.detail | Should -Match 'node not found'

        $off = New-BlueprintConfig
        $offResult = & $script:toolsCheck -Context (New-ToolsContext -Config $off -Guest $guest)
        $offResult.ok | Should -Be $true
        $offResult.evidence.PSObject.Properties.Name | Should -Not -Contain 'node'
    }

    It 'fails git, claude and python and keeps the InvokeGuest message' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $true; Node = $false }
        $result = & $script:toolsCheck -Context (New-ToolsContext -Config $config -Throw)
        $result.ok | Should -Be $false
        $result.evidence.git | Should -Be $false
        $result.evidence.claude | Should -Be $false
        $result.evidence.python | Should -Be $false
        $result.evidence.PSObject.Properties.Name | Should -Not -Contain 'node'
        $result.detail | Should -Match 'git'
        $result.detail | Should -Match 'claude'
        $result.detail | Should -Match 'python'
        $result.detail | Should -Match 'credential rejected'
    }
}

Describe 'shares check' {
    BeforeAll {
        $script:sharesCheck = Join-Path $script:repo 'checks\shares.ps1'
        $script:shareStubbed = @()
        foreach ($name in @('Get-LocalUser', 'Get-LocalGroupMember', 'Get-SmbShare', 'Get-SmbShareAccess', 'Get-NetFirewallRule')) {
            $needsStub = -not (Get-Command $name -ErrorAction SilentlyContinue)
            if ($needsStub -or $env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                $body = { param($Name, $SID, $Group, $Member, $DisplayName, $Path, $ErrorAction) }
                if ($env:HOUSE_FORCE_CMDLET_STUBS -eq '1') {
                    Set-Item -Path "function:global:$name" -Value $body -Force
                }
                else {
                    Set-Item -Path "function:global:$name" -Value $body
                }
                $script:shareStubbed += $name
            }
        }
        $script:oldProgramData = $env:ProgramData
        $script:notesPath = 'C:\Users\alice\Documents\notes'
        $script:projectsPath = 'D:\projects'
        $script:docsPath = 'D:\docs'
        $script:folderPath = 'D:\' + [char]0x8D44 + [char]0x6599
    }

    AfterAll {
        foreach ($name in $script:shareStubbed) {
            Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
        }
        $env:ProgramData = $script:oldProgramData
    }

    BeforeEach {
        $env:ProgramData = Join-Path $TestDrive 'pd'
        $state = Join-Path $env:ProgramData 'claude-house\FixtureHouse'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'share-user.cred.xml') -Value '<not-a-password>' -Encoding ASCII
        Mock Get-LocalUser { return [pscustomobject]@{ Name = 'house-share'; Enabled = $true } }
        Mock Get-LocalGroupMember { return [pscustomobject]@{ Name = 'FIXTURE\Administrator' } }
        $notesPath = $script:notesPath
        $projectsPath = $script:projectsPath
        $folderPath = $script:folderPath
        $docsPath = $script:docsPath
        $shareMock = {
            param($Name, $ErrorAction)
            switch ($Name) {
                'notes' { return [pscustomobject]@{ Name = 'notes'; Path = $notesPath } }
                'projects' { return [pscustomobject]@{ Name = 'projects'; Path = $projectsPath } }
                'ziliao' { return [pscustomobject]@{ Name = 'ziliao'; Path = $folderPath } }
                'docs' { return [pscustomobject]@{ Name = 'docs'; Path = $docsPath } }
            }
        }.GetNewClosure()
        Mock Get-SmbShare $shareMock
        Mock Get-SmbShareAccess {
            param($Name)
            if ($Name -eq 'docs') {
                return [pscustomobject]@{ AccountName = 'FIXTURE\house-share'; AccessRight = 'Read' }
            }
            return [pscustomobject]@{ AccountName = 'house-share'; AccessRight = 'Change' }
        }
        Mock Get-NetFirewallRule {
            return [pscustomobject]@{
                DisplayName = "claude-house SMB"
                Enabled     = $true
                Direction   = 'Inbound'
                Action      = 'Allow'
            }
        }
        Mock Get-HouseFirewallAddressFilter { return [pscustomobject]@{ RemoteAddress = '192.0.2.2' } }
        Mock Get-HouseFirewallPortFilter { return [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '445' } }
    }

    function script:New-ShareBlueprint {
        return @(
            @{ Name = 'notes'; HostPath = $script:notesPath; Writable = $true; Mirror = $true },
            @{ Name = 'projects'; HostPath = $script:projectsPath; Writable = $true; Mirror = $true },
            @{ Name = 'ziliao'; HostPath = $script:folderPath; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = $script:docsPath; Writable = $false; Mirror = $true }
        )
    }

    It 'passes when the account, credential, shares and firewall match' {
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.id | Should -Be 'shares'
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'shares ready'
        $result.evidence.account | Should -Be $true
        $result.evidence.credential | Should -Be $true
        $result.evidence.shares | Should -Be $true
        $result.evidence.smbfirewall | Should -Be $true
        @($result.evidence.shareNames) | Should -Contain 'ziliao'
        $result.detail | Should -Not -Match 'not-a-password'
        $result.fix | Should -Be 'runbook/10-shares.md#if-it-fails'
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        Should -Invoke Get-LocalUser -Times 0
    }

    It 'fails account when house-share is disabled' {
        Mock Get-LocalUser { return [pscustomobject]@{ Name = 'house-share'; Enabled = $false } }
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.evidence.account | Should -Be $false
        $result.detail | Should -Match 'account'
        $result.detail | Should -Match 'disabled'
    }

    It 'fails account when house-share is an administrator' {
        Mock Get-LocalGroupMember { return [pscustomobject]@{ Name = 'FIXTURE\house-share' } }
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.evidence.account | Should -Be $false
        $result.detail | Should -Match 'Administrators'
    }

    It 'fails credential when the file is missing and does not read a password' {
        $cred = Join-Path $env:ProgramData 'claude-house\FixtureHouse\share-user.cred.xml'
        Remove-Item -LiteralPath $cred -Force
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.evidence.credential | Should -Be $false
        $result.detail | Should -Match 'credential'
        $result.detail | Should -Not -Match 'not-a-password'
    }

    It 'fails shares when a path does not match and names the share' {
        $notesPath = $script:notesPath
        $folderPath = $script:folderPath
        $docsPath = $script:docsPath
        $shareMock = {
            param($Name, $ErrorAction)
            if ($Name -eq 'projects') { return [pscustomobject]@{ Name = 'projects'; Path = 'C:\wrong' } }
            switch ($Name) {
                'notes' { return [pscustomobject]@{ Name = 'notes'; Path = $notesPath } }
                'ziliao' { return [pscustomobject]@{ Name = 'ziliao'; Path = $folderPath } }
                'docs' { return [pscustomobject]@{ Name = 'docs'; Path = $docsPath } }
            }
        }.GetNewClosure()
        Mock Get-SmbShare $shareMock
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.evidence.shares | Should -Be $false
        $result.detail | Should -Be 'shares: projects'
    }

    It 'fails shares when Everyone is granted anything and names every share' {
        Mock Get-SmbShareAccess {
            return @(
                [pscustomobject]@{ AccountName = 'Everyone'; AccessRight = 'Read' },
                [pscustomobject]@{ AccountName = 'house-share'; AccessRight = 'Change' }
            )
        }
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = $script:projectsPath; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = $script:docsPath; Writable = $false; Mirror = $true }
        )
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'shares: projects, docs'
    }

    It 'fails a writable share that only has Read' {
        Mock Get-SmbShareAccess { return [pscustomobject]@{ AccountName = 'house-share'; AccessRight = 'Read' } }
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'projects'; HostPath = $script:projectsPath; Writable = $true; Mirror = $true })
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'shares: projects'
    }

    It 'fails smbfirewall when the remote address is not exactly the VM' {
        Mock Get-HouseFirewallAddressFilter { return [pscustomobject]@{ RemoteAddress = 'Any' } }
        $config = New-BlueprintConfig
        $config.Shares = New-ShareBlueprint
        $result = & $script:sharesCheck -Context (New-BlueprintContext -Config $config)
        $result.ok | Should -Be $false
        $result.evidence.smbfirewall | Should -Be $false
        $result.detail | Should -Be 'smbfirewall'
    }
}

Describe 'guest-shares check' {
    BeforeAll {
        $script:guestSharesCheck = Join-Path $script:repo 'checks\guest-shares.ps1'
        $script:notesPath = 'C:\Users\alice\Documents\notes'
        $script:projectsPath = 'D:\projects'
        $script:docsPath = 'D:\docs'
        $script:folderPath = 'D:\' + [char]0x8D44 + [char]0x6599
        $script:dosValue = '\??\C:\HouseMirror\D'

        function script:New-GuestShareBlueprint {
            return @(
                @{ Name = 'notes'; HostPath = $script:notesPath; Writable = $true; Mirror = $true },
                @{ Name = 'projects'; HostPath = $script:projectsPath; Writable = $true; Mirror = $true },
                @{ Name = 'ziliao'; HostPath = $script:folderPath; Writable = $true; Mirror = $true },
                @{ Name = 'docs'; HostPath = $script:docsPath; Writable = $false; Mirror = $true }
            )
        }

        function script:New-GuestShareRow {
            param(
                [string]$Name,
                [string]$Target,
                [string]$Reach = 'ok',
                [string]$Dos = '',
                [string]$Write = 'skipped',
                [string]$Forward = 'ok',
                [string]$Reverse = 'ok',
                [bool]$Writable = $true
            )
            if (-not $Writable) {
                $Forward = 'skipped'
                $Reverse = 'skipped'
            }
            else {
                $Write = 'skipped'
            }
            return [pscustomobject]@{
                name         = $Name
                reach        = $Reach
                reachError   = ''
                exists       = $true
                linkType     = 'SymbolicLink'
                target       = $Target
                listed       = $true
                listError    = ''
                dos          = $Dos
                dosError     = ''
                write        = $Write
                writeError   = ''
                forward      = $Forward
                forwardError = ''
                reverse      = $Reverse
                reverseError = ''
            }
        }

        function script:New-GuestFacts {
            param($Shares, [string]$Hosts = '192.0.2.1', [bool]$Cmdkey = $true, [int]$Linked = 1)
            return [pscustomobject]@{
                hosts       = $Hosts
                hostsError  = ''
                cmdkey      = $Cmdkey
                cmdkeyError = ''
                linked      = $Linked
                linkedError = ''
                shares      = @($Shares)
                error       = $null
            }
        }

        function script:New-PassingGuestFacts {
            $rows = @(
                (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes' -Dos ''),
                (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos $script:dosValue),
                (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
                (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
            )
            return New-GuestFacts -Shares $rows
        }

        function script:New-GuestSharesContext {
            param($Config, $Facts, [switch]$Throw)
            $ctx = New-BlueprintContext -Config $Config
            $bag = @{ Probe = ''; Args = @(); Facts = $Facts }
            $script:guestBag = $bag
            if ($Throw) {
                $ctx.InvokeGuest = { param($ScriptBlock, $ArgumentList) throw 'credential rejected' }
            }
            else {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Probe = $ScriptBlock.ToString()
                    $bag.Args = @($ArgumentList)
                    return $bag.Facts
                }.GetNewClosure()
            }
            return $ctx
        }

        function script:Get-HouseScriptBlocks {
            param([string]$Text)
            $blocks = New-Object System.Collections.Generic.List[string]
            $idx = 0
            while ($idx -lt $Text.Length) {
                $at = $Text.IndexOf('-ScriptBlock', $idx)
                if ($at -lt 0) { break }
                $brace = $Text.IndexOf('{', $at)
                if ($brace -lt 0) { throw 'script block was not opened' }
                $depth = 0
                $i = $brace
                $inSingle = $false
                $inDouble = $false
                $closed = $false
                while ($i -lt $Text.Length) {
                    $ch = $Text[$i]
                    if ($inSingle) {
                        if ($ch -eq "'") {
                            if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i += 2; continue }
                            $inSingle = $false
                        }
                        $i++
                        continue
                    }
                    if ($inDouble) {
                        if ($ch -eq '`') { $i += 2; continue }
                        if ($ch -eq '"') { $inDouble = $false }
                        $i++
                        continue
                    }
                    if ($ch -eq "'") { $inSingle = $true; $i++; continue }
                    if ($ch -eq '"') { $inDouble = $true; $i++; continue }
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') {
                        $depth--
                        if ($depth -eq 0) {
                            $blocks.Add($Text.Substring($brace + 1, $i - $brace - 1))
                            $idx = $i + 1
                            $closed = $true
                            break
                        }
                    }
                    $i++
                }
                if (-not $closed) { throw 'script block was not closed' }
            }
            return @($blocks.ToArray())
        }
    }

    It 'fails when the blueprint was not loaded' {
        $result = & $script:guestSharesCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $result.evidence.hostname | Should -Be $false
    }

    It 'passes hostname, credential, reach, mirror, readonly, writable and linked' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-PassingGuestFacts))
        $result.id | Should -Be 'guest-shares'
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'guest shares ready'
        $result.evidence.hostname | Should -Be $true
        $result.evidence.credential | Should -Be $true
        $result.evidence.reach | Should -Be $true
        $result.evidence.mirror | Should -Be $true
        $result.evidence.readonly | Should -Be $true
        $result.evidence.writable | Should -Be $true
        $result.evidence.linked | Should -Be $true
        $script:guestBag.Probe | Should -Match '\.house-probe-'
        # Set-Content hides a missing drive behind "parameter Encoding not found"; the probe must report the real path error.
        $script:guestBag.Probe | Should -Not -Match 'Set-Content'
        $script:guestBag.Probe | Should -Match 'finally'
        $script:guestBag.Probe | Should -Not -Match 'D:\\projects'
        @($script:guestBag.Probe.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        $script:guestBag.Args[0] | Should -Be '192.0.2.1'
        $script:guestBag.Args[1] | Should -Be 'fixtureuser'
        $script:guestBag.Args[2] | Should -Match 'notes'
        $result.fix | Should -Be 'runbook/11-guest-shares.md#if-it-fails'
    }

    It 'fails hostname when house-host does not resolve to HostIP' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $facts = New-PassingGuestFacts
        $facts.hosts = '198.51.100.9'
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.hostname | Should -Be $false
        $result.evidence.reach | Should -Be $true
        $result.detail | Should -Match 'hostname'
    }

    It 'fails credential when cmdkey has no house-host entry' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $facts = New-PassingGuestFacts
        $facts.cmdkey = $false
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.credential | Should -Be $false
        $result.detail | Should -Match 'credential'
        $result.detail | Should -Not -Match 'pass'
    }

    It 'fails reach when a share root cannot be listed' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes' -Reach 'fail'),
            (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.reach | Should -Be $false
        $result.evidence.mirror | Should -Be $true
        $result.detail | Should -Match 'reach'
    }

    It 'accepts a mirror target reported in NT UNC form' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target 'UNC\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target '\??\UNC\house-host\projects' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao\' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.evidence.mirror | Should -Be $true
        $result.ok | Should -Be $true
    }

    It 'fails mirror when the symlink target is a drive letter' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target 'D:\projects' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.mirror | Should -Be $false
        $result.detail | Should -Match 'mirror'
        $result.detail | Should -Match 'D:\\projects'
    }

    It 'fails mirror when the DOS Devices value is not HouseMirror' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos 'D:'),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.mirror | Should -Be $false
        $result.detail | Should -Match 'mirror dos'
    }

    It 'fails readonly when the write succeeds' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'success')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.readonly | Should -Be $false
        $result.evidence.writable | Should -Be $true
        $result.detail | Should -Match 'docs readonly success'
    }

    It 'fails readonly as probe-error when the write fails for another reason' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'probe-error')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.readonly | Should -Be $false
        $result.detail | Should -Match 'docs readonly probe-error'
    }

    It 'fails writable when the reverse marker does not match' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $rows = @(
            (New-GuestShareRow -Name 'notes' -Target '\\house-host\notes'),
            (New-GuestShareRow -Name 'projects' -Target '\\house-host\projects' -Dos $script:dosValue -Reverse 'fail'),
            (New-GuestShareRow -Name 'ziliao' -Target '\\house-host\ziliao' -Dos $script:dosValue),
            (New-GuestShareRow -Name 'docs' -Target '\\house-host\docs' -Dos $script:dosValue -Writable $false -Write 'access-denied')
        )
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts (New-GuestFacts -Shares $rows))
        $result.ok | Should -Be $false
        $result.evidence.writable | Should -Be $false
        $result.evidence.readonly | Should -Be $true
        $result.detail | Should -Match 'writable'
    }

    It 'fails linked when EnableLinkedConnections is not 1' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $facts = New-PassingGuestFacts
        $facts.linked = 0
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.linked | Should -Be $false
        $result.evidence.hostname | Should -Be $true
        $result.detail | Should -Match 'linked'
    }

    It 'rejects a mirror inside the VM user profile' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'bad'; HostPath = 'C:\Users\fixtureuser\x'; Writable = $true; Mirror = $true })
        $facts = New-GuestFacts -Shares @((New-GuestShareRow -Name 'bad' -Target '\\house-host\bad'))
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.mirror | Should -Be $false
        $result.detail | Should -Match 'VM user profile'
        $result.detail | Should -Match 'C:\\Users\\fixtureuser\\x'
    }

    It 'rejects a mirror inside Windows' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'bad'; HostPath = 'C:\Windows\x'; Writable = $true; Mirror = $true })
        $facts = New-GuestFacts -Shares @((New-GuestShareRow -Name 'bad' -Target '\\house-host\bad'))
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'inside Windows'
    }

    It 'rejects a mirror inside Program Files' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'bad'; HostPath = 'C:\Program Files\x'; Writable = $true; Mirror = $true })
        $facts = New-GuestFacts -Shares @((New-GuestShareRow -Name 'bad' -Target '\\house-host\bad'))
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'inside Program Files'
    }

    It 'fails every item and keeps the InvokeGuest message when the guest call throws' {
        $config = New-BlueprintConfig
        $config.Shares = New-GuestShareBlueprint
        $result = & $script:guestSharesCheck -Context (New-GuestSharesContext -Config $config -Throw)
        $result.ok | Should -Be $false
        $result.evidence.hostname | Should -Be $false
        $result.evidence.credential | Should -Be $false
        $result.evidence.reach | Should -Be $false
        $result.evidence.mirror | Should -Be $false
        $result.evidence.readonly | Should -Be $false
        $result.evidence.writable | Should -Be $false
        $result.evidence.linked | Should -Be $false
        $result.detail | Should -Match 'credential rejected'
    }

    It 'keeps the rendered step 11 script block ASCII and free of blueprint values' {
        $config = New-BlueprintConfig
        $config.House.UserName = 'fixtureuser'
        $config.Shares = New-GuestShareBlueprint
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\11-guest-shares.md'))
        $rendered = Format-HousePage -Content $page -Config $config
        $blocks = @(Get-HouseScriptBlocks -Text $rendered)
        $blocks.Count | Should -Be 1
        $folder = $script:folderPath
        $rendered.Contains($folder) | Should -Be $true
        $rendered.Contains('{{') | Should -Be $false
        foreach ($block in $blocks) {
            $block.Contains('{{') | Should -Be $false
            $block.Contains($folder) | Should -Be $false
            $block.Contains($script:notesPath) | Should -Be $false
            $block.Contains($script:projectsPath) | Should -Be $false
            $block.Contains($script:docsPath) | Should -Be $false
            $block.Contains('192.0.2.1') | Should -Be $false
            $block.Contains('fixtureuser') | Should -Be $false
            $block.Contains('FixtureHouse') | Should -Be $false
            @($block.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        }
        $bodyStart = $rendered.IndexOf('-ScriptBlock')
        $rendered.Substring(0, $bodyStart).Contains($folder) | Should -Be $true
    }
}

Describe 'house rules rendering' {
    It 'maps mirror paths to themselves and other shares to UNC' {
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'drop'; HostPath = 'E:\drop'; Writable = $false; Mirror = $false }
        )
        $rows = @(Get-HouseAddressBook -Config $config)
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'projects'
        $rows[0].HostPath | Should -Be 'D:\projects'
        $rows[0].VmPath | Should -Be 'D:\projects'
        $rows[0].Writable | Should -Be $true
        $rows[1].VmPath | Should -Be '\\house-host\drop'
        $rows[1].Writable | Should -Be $false
    }

    It 'lists UNC roots, mirror paths, and a drive root only for non-C mirrors' {
        $folder = 'D:\' + [char]0x8D44 + [char]0x6599
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'notes'; HostPath = 'C:\Users\alice\Documents\notes'; Writable = $true; Mirror = $true },
            @{ Name = 'drop'; HostPath = 'E:\drop'; Writable = $false; Mirror = $false },
            @{ Name = 'ziliao'; HostPath = $folder; Writable = $true; Mirror = $true }
        )
        $roots = @(Get-HouseShareRoots -Config $config)
        $roots -contains '\\house-host\projects' | Should -Be $true
        $roots -contains '\\house-host\notes' | Should -Be $true
        $roots -contains '\\house-host\drop' | Should -Be $true
        $roots -contains '\\house-host\ziliao' | Should -Be $true
        $roots -contains 'D:\projects' | Should -Be $true
        $roots -contains $folder | Should -Be $true
        $roots -contains 'D:\' | Should -Be $true
        $roots -contains 'C:\Users\alice\Documents\notes' | Should -Be $true
        $roots -contains 'C:\' | Should -Be $false
        $roots -contains 'E:\' | Should -Be $false
        $roots -contains 'E:\drop' | Should -Be $false
        $sorted = New-Object string[] $roots.Count
        [Array]::Copy([string[]]$roots, $sorted, $roots.Count)
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        ($roots -join '|') | Should -Be ($sorted -join '|')
    }

    It 'renders one house block with no placeholders left' {
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true }
        )
        $block = Format-HouseRulesBlock -Config $config
        $block | Should -Match '<!-- claude-house:begin -->'
        $block | Should -Match '<!-- claude-house:end -->'
        ([regex]::Matches($block, [regex]::Escape('<!-- claude-house:begin -->'))).Count | Should -Be 1
        $block.Contains('{{') | Should -Be $false
        $block | Should -Match 'http://192\.0\.2\.1:3128'
        $block.Contains('| D:\projects | D:\projects | yes |') | Should -Be $true
        $json = Format-HouseRootsJson -Config $config
        $json.StartsWith('{"roots":[') | Should -Be $true
        ($json | ConvertFrom-Json).roots -contains 'D:\' | Should -Be $true
    }

    It 'uses the first writable VmPath, including a non-mirror share' {
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'docs'; HostPath = 'D:\docs'; Writable = $false; Mirror = $true },
            @{ Name = 'drop'; HostPath = 'E:\drop'; Writable = $true; Mirror = $false },
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true }
        )
        $block = Format-HouseRulesBlock -Config $config
        $deliver = ($block -split '## Deliverables', 2)[1]
        $deliver.Trim().StartsWith('\\house-host\drop') | Should -Be $true
    }

    It 'uses the no-writable sentence when every share refuses writes' {
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'docs'; HostPath = 'D:\docs'; Writable = $false; Mirror = $true }
        )
        $block = Format-HouseRulesBlock -Config $config
        $block | Should -Match 'There is no writable share; keep deliverables in your user folder and tell the human\.'
        $block.Contains('{{') | Should -Be $false
    }

    It 'hashes CRLF and trailing spaces the same as LF' {
        $crlf = ConvertTo-HouseRulesHash -Text "alpha`r`nbeta  "
        $lf = ConvertTo-HouseRulesHash -Text "alpha`nbeta"
        $crlf | Should -Be $lf
        $crlf | Should -Match '^[0-9a-f]{64}$'
        ConvertTo-HouseRulesHash -Text 'other' | Should -Not -Be $crlf
    }
}

Describe 'house hooks' {
    BeforeAll {
        function script:Invoke-HouseHookFile {
            param([string]$HookName, [string]$Payload, [string]$RootsJson)
            $dir = Join-Path $TestDrive ('hook-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $dest = Join-Path $dir $HookName
            Copy-Item -LiteralPath (Join-Path $script:repo ('rules\hooks\' + $HookName)) -Destination $dest
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
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $bytes = $utf8.GetBytes($Payload)
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
            return [pscustomobject]@{ Exit = [int]$proc.ExitCode; Stderr = [string]$stderrTask.Result }
        }

        $script:hookFolder = 'D:\' + [char]0x8D44 + [char]0x6599
        $rootConfig = New-BlueprintConfig
        $rootConfig.Shares = @(
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = 'D:\docs'; Writable = $false; Mirror = $true },
            @{ Name = 'ziliao'; HostPath = $script:hookFolder; Writable = $true; Mirror = $true }
        )
        $script:hookRootsJson = Format-HouseRootsJson -Config $rootConfig
    }

    It 'blocks Grep at a share root and allows a subfolder' {
        $root = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Grep","tool_input":{"path":"\\\\house-host\\projects","pattern":"foo"},"cwd":"C:\\Users\\claude"}'
        $root.Exit | Should -Be 2
        $root.Stderr | Should -Match 'Search a subfolder'
        $child = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Grep","tool_input":{"path":"\\\\house-host\\projects\\src","pattern":"foo"},"cwd":"C:\\Users\\claude"}'
        $child.Exit | Should -Be 0
    }

    It 'still blocks when the payload starts with a byte order mark' {
        $payload = [string][char]0xFEFF + '{"tool_name":"Grep","tool_input":{"path":"D:\\projects","pattern":"foo"},"cwd":"C:\\Users\\claude"}'
        $search = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload $payload
        $search.Exit | Should -Be 2
        $payload = [string][char]0xFEFF + '{"tool_name":"Bash","tool_input":{"command":"rm -rf D:/projects"},"cwd":"C:\\Users\\claude"}'
        $delete = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload $payload
        $delete.Exit | Should -Be 2
    }

    It 'blocks a recursive delete of a folder that only contains a share root' {
        # D:\ is itself a root in the shared fixture; this one proves the parent rule on its own.
        $roots = '{"roots":["C:\\Users\\alice\\Documents\\notes"]}'
        $parent = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $roots -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item -Recurse -Force C:\\Users\\alice"},"cwd":"C:\\Users\\claude"}'
        $parent.Exit | Should -Be 2
        $child = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $roots -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item -Recurse -Force C:\\Users\\alice\\Documents\\notes\\tmp"},"cwd":"C:\\Users\\claude"}'
        $child.Exit | Should -Be 0
    }

    It 'blocks Grep when path is empty and cwd is a share root' {
        $result = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Grep","tool_input":{"path":"","pattern":"foo"},"cwd":"D:\\projects"}'
        $result.Exit | Should -Be 2
        $result.Stderr | Should -Match 'D:\\projects'
    }

    It 'blocks a recursive rg at a root and allows a quoted subfolder' {
        $root = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Bash","tool_input":{"command":"rg foo D:/projects/"},"cwd":"C:\\Users\\claude"}'
        $root.Exit | Should -Be 2
        $child = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Bash","tool_input":{"command":"rg foo \"D:\\projects\\app\""},"cwd":"C:\\Users\\claude"}'
        $child.Exit | Should -Be 0
    }

    It 'blocks a recursive listing of a Chinese share root' {
        $escaped = $script:hookFolder.Replace('\', '\\')
        $payload = '{"tool_name":"PowerShell","tool_input":{"command":"Get-ChildItem -Recurse ' + $escaped + '"},"cwd":"C:\\Users\\claude"}'
        $payload.Contains([string][char]0x8D44) | Should -Be $true
        $result = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload $payload
        $result.Exit | Should -Be 2
    }

    It 'allows a non-recursive listing and a Read call' {
        $list = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Get-ChildItem D:\\projects"},"cwd":"C:\\Users\\claude"}'
        $list.Exit | Should -Be 0
        $read = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Read","tool_input":{"file_path":"D:\\projects\\a.txt"},"cwd":"D:\\projects"}'
        $read.Exit | Should -Be 0
    }

    It 'ignores malformed JSON with one stderr line' {
        $result = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{not-json'
        $result.Exit | Should -Be 0
        $lines = @($result.Stderr -split "`r?`n" | Where-Object { $_ -ne '' })
        $lines.Count | Should -Be 1
    }

    It 'blocks recursive delete of a root, a parent, and a UNC root' {
        $rm = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Bash","tool_input":{"command":"rm -rf D:/projects"},"cwd":"C:\\Users\\claude"}'
        $rm.Exit | Should -Be 2
        $parent = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item -Recurse -Force D:\\"},"cwd":"C:\\Users\\claude"}'
        $parent.Exit | Should -Be 2
        $unc = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Bash","tool_input":{"command":"rd /s /q \\\\house-host\\docs"},"cwd":"C:\\Users\\claude"}'
        $unc.Exit | Should -Be 2
    }

    It 'blocks rg with no path when cwd is a share root' {
        $result = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Bash","tool_input":{"command":"rg foo"},"cwd":"D:\\projects"}'
        $result.Exit | Should -Be 2
    }

    It 'blocks grep -r, find, dir /s, findstr /s and Select-String -Recurse at a root' {
        $cases = @(
            '{"tool_name":"Bash","tool_input":{"command":"grep -r foo \\\\house-host\\projects"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"Bash","tool_input":{"command":"find \\\\house-host\\projects"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"Bash","tool_input":{"command":"dir /s D:\\projects"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"Bash","tool_input":{"command":"findstr /s foo D:\\projects"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"PowerShell","tool_input":{"command":"Get-ChildItem -Recurse D:\\projects | Select-String -Pattern foo"},"cwd":"C:\\Users\\claude"}'
        )
        foreach ($payload in $cases) {
            $result = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload $payload
            $result.Exit | Should -Be 2
        }
    }

    It 'blocks Glob at a share root and gci -r, and allows ls of a subfolder' {
        $glob = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"Glob","tool_input":{"path":"\\\\house-host\\docs"},"cwd":"C:\\Users\\claude"}'
        $glob.Exit | Should -Be 2
        $gci = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"gci -r D:\\docs"},"cwd":"C:\\Users\\claude"}'
        $gci.Exit | Should -Be 2
        $ls = Invoke-HouseHookFile -HookName 'house-bounded-search.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"ls -r D:\\projects\\app"},"cwd":"D:\\projects"}'
        $ls.Exit | Should -Be 0
    }

    It 'blocks rmdir, del and ri recursive deletes of a share root' {
        $cases = @(
            '{"tool_name":"Bash","tool_input":{"command":"rmdir /s D:\\projects"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"Bash","tool_input":{"command":"del /s D:\\docs"},"cwd":"C:\\Users\\claude"}',
            '{"tool_name":"PowerShell","tool_input":{"command":"ri -Recurse \\\\house-host\\projects"},"cwd":"C:\\Users\\claude"}'
        )
        foreach ($payload in $cases) {
            $result = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload $payload
            $result.Exit | Should -Be 2
        }
    }

    It 'ignores malformed JSON in the delete guard with one stderr line' {
        $result = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{not-json'
        $result.Exit | Should -Be 0
        @($result.Stderr -split "`r?`n" | Where-Object { $_ -ne '' }).Count | Should -Be 1
    }

    It 'allows recursive delete of a subfolder and a non-recursive delete' {
        $sub = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item -Recurse D:\\projects\\tmp"},"cwd":"C:\\Users\\claude"}'
        $sub.Exit | Should -Be 0
        $file = Invoke-HouseHookFile -HookName 'house-share-delete-guard.ps1' -RootsJson $script:hookRootsJson -Payload '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item D:\\projects\\a.txt"},"cwd":"D:\\projects"}'
        $file.Exit | Should -Be 0
    }
}

Describe 'house-rules check' {
    BeforeAll {
        $script:houseRulesCheck = Join-Path $script:repo 'checks\house-rules.ps1'

        function script:Get-HouseScriptBlocks {
            param([string]$Text)
            $blocks = New-Object System.Collections.Generic.List[string]
            $idx = 0
            while ($idx -lt $Text.Length) {
                $at = $Text.IndexOf('-ScriptBlock', $idx)
                if ($at -lt 0) { break }
                $brace = $Text.IndexOf('{', $at)
                if ($brace -lt 0) { throw 'script block was not opened' }
                $depth = 0
                $i = $brace
                $inSingle = $false
                $inDouble = $false
                $closed = $false
                while ($i -lt $Text.Length) {
                    $ch = $Text[$i]
                    if ($inSingle) {
                        if ($ch -eq "'") {
                            if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i += 2; continue }
                            $inSingle = $false
                        }
                        $i++
                        continue
                    }
                    if ($inDouble) {
                        if ($ch -eq '`') { $i += 2; continue }
                        if ($ch -eq '"') { $inDouble = $false }
                        $i++
                        continue
                    }
                    if ($ch -eq "'") { $inSingle = $true; $i++; continue }
                    if ($ch -eq '"') { $inDouble = $true; $i++; continue }
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') {
                        $depth--
                        if ($depth -eq 0) {
                            $blocks.Add($Text.Substring($brace + 1, $i - $brace - 1))
                            $idx = $i + 1
                            $closed = $true
                            break
                        }
                    }
                    $i++
                }
                if (-not $closed) { throw 'script block was not closed' }
            }
            return @($blocks.ToArray())
        }

        function script:New-HouseRulesConfig {
            param([string[]]$Hooks = @('bounded-search', 'share-delete-guard'))
            $config = New-BlueprintConfig
            $config.Shares = @(
                @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true },
                @{ Name = 'docs'; HostPath = 'D:\docs'; Writable = $false; Mirror = $true }
            )
            $config.Rules = @{ Hooks = $Hooks }
            return $config
        }

        function script:New-HouseRulesFacts {
            param($Config, [string]$BlockHash, [int]$BlockCount = 1, [string]$RootsHash, $Hooks, [bool]$SettingsOk = $true, [string]$SettingsError = '', [string[]]$Commands)
            if (-not $BlockHash) { $BlockHash = ConvertTo-HouseRulesHash -Text (Format-HouseRulesBlock -Config $Config) }
            if (-not $RootsHash) { $RootsHash = ConvertTo-HouseRulesHash -Text (Format-HouseRootsJson -Config $Config) }
            if ($null -eq $Hooks) {
                $Hooks = @()
                foreach ($name in @($Config.Rules.Hooks)) {
                    $file = Join-Path (Join-Path $script:repo 'rules\hooks') ('house-' + [string]$name + '.ps1')
                    if (Test-Path -LiteralPath $file) {
                        $Hooks += [pscustomobject]@{ name = [string]$name; hash = (ConvertTo-HouseRulesHash -Text ([System.IO.File]::ReadAllText($file))) }
                    }
                }
            }
            $entryList = New-Object System.Collections.Generic.List[object]
            if ($null -eq $Commands) {
                $Commands = @()
                foreach ($name in @($Config.Rules.Hooks)) {
                    $file = Join-Path (Join-Path $script:repo 'rules\hooks') ('house-' + [string]$name + '.ps1')
                    if (-not (Test-Path -LiteralPath $file)) { continue }
                    $commandLine = Get-HouseHookCommandLine -UserName 'fixtureuser' -HookName ([string]$name)
                    $Commands += $commandLine
                    $entryList.Add([pscustomobject]@{
                        matcher = (Get-HouseHookMatcher -Name ([string]$name))
                        command = $commandLine
                        timeout = '10'
                    })
                }
            }
            return [pscustomobject]@{
                claudeExists     = $true
                blockCount       = $BlockCount
                blockHash        = $BlockHash
                rootsHash        = $RootsHash
                hooks            = @($Hooks)
                settingsOk       = $SettingsOk
                settingsError    = $SettingsError
                commands         = @($Commands)
                entries          = $entryList
                pythonUtf8       = '1'
                pythonIo         = 'utf-8'
                pwshTool         = '1'
                gitLongpaths     = 'true'
                gitQuotepath     = 'false'
                longPathsEnabled = '1'
                error            = $null
                userNotes        = 'notes the human wrote outside the house block'
            }
        }

        function script:New-HouseRulesContext {
            param($Config, $Facts, [switch]$Throw)
            $ctx = New-BlueprintContext -Config $Config
            $bag = @{ Probe = ''; Facts = $Facts }
            $script:rulesBag = $bag
            if ($Throw) {
                $ctx.InvokeGuest = { param($ScriptBlock, $ArgumentList) throw 'credential rejected' }
            }
            else {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Probe = $ScriptBlock.ToString()
                    $bag.Args = @($ArgumentList)
                    return $bag.Facts
                }.GetNewClosure()
            }
            return $ctx
        }
    }

    It 'fails closed when the blueprint was not loaded' {
        $result = & $script:houseRulesCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $result.evidence.claudemd | Should -Be $false
        $result.evidence.roots | Should -Be $false
        $result.evidence.hooks | Should -Be $false
    }

    It 'fails every item when the guest call throws' {
        $config = New-HouseRulesConfig
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Throw)
        $result.ok | Should -Be $false
        $result.evidence.claudemd | Should -Be $false
        $result.evidence.roots | Should -Be $false
        $result.evidence.hooks | Should -Be $false
        $result.detail | Should -Match 'credential rejected'
    }

    It 'passes claudemd, roots and hooks' {
        $config = New-HouseRulesConfig
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts (New-HouseRulesFacts -Config $config))
        $result.id | Should -Be 'house-rules'
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'house rules ready'
        $result.evidence.claudemd | Should -Be $true
        $result.evidence.roots | Should -Be $true
        $result.evidence.hooks | Should -Be $true
        $result.fix | Should -Be 'runbook/12-house-rules.md#if-it-fails'
        $result.detail | Should -Not -Match 'notes the human wrote'
    }

    It 'fails claudemd when the block hash does not match' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config -BlockHash ('ab' * 32)
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.claudemd | Should -Be $false
        $result.evidence.roots | Should -Be $true
        $result.evidence.hooks | Should -Be $true
        $result.detail | Should -Match 'claudemd hash'
    }

    It 'fails claudemd when two house blocks are present' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config -BlockCount 2
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.claudemd | Should -Be $false
        $result.detail | Should -Match 'claudemd blocks 2'
    }

    It 'fails roots when the roots hash does not match' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config -RootsHash ('cd' * 32)
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.roots | Should -Be $false
        $result.evidence.claudemd | Should -Be $true
        $result.detail | Should -Match 'roots hash'
    }

    It 'fails hooks when settings.json does not parse' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config -SettingsOk $false -SettingsError 'Unexpected token at line 1'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.hooks | Should -Be $false
        $result.evidence.claudemd | Should -Be $true
        $result.detail | Should -Match 'Unexpected token at line 1'
    }

    It 'fails hooks when an unselected hook is still registered' {
        $config = New-HouseRulesConfig -Hooks @('bounded-search')
        $extra = Get-HouseHookCommandLine -UserName 'fixtureuser' -HookName 'share-delete-guard'
        $facts = New-HouseRulesFacts -Config $config
        $facts.commands = @($facts.commands) + $extra
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.hooks | Should -Be $false
        $result.evidence.roots | Should -Be $true
        $result.detail | Should -Match 'share-delete-guard still registered'
    }

    It 'fails hooks when the blueprint names an unknown hook' {
        $config = New-HouseRulesConfig -Hooks @('not-a-hook')
        $facts = New-HouseRulesFacts -Config $config -Hooks @() -Commands @()
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.hooks | Should -Be $false
        $result.evidence.claudemd | Should -Be $true
        $result.detail | Should -Match 'not-a-hook'
    }

    It 'does not fail when user content outside the block is left alone' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $true
        $result.evidence.claudemd | Should -Be $true
        ($result | ConvertTo-Json -Depth 6).Contains('notes the human wrote') | Should -Be $false
    }

    It 'keeps the rendered step 12 script block ASCII and free of placeholders' {
        $config = New-HouseRulesConfig
        $folder = 'D:\' + [char]0x8D44 + [char]0x6599
        $config.Shares = @(@{ Name = 'ziliao'; HostPath = $folder; Writable = $true; Mirror = $true })
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\12-house-rules.md'))
        $rendered = Format-HousePage -Content $page -Config $config
        $blocks = @(Get-HouseScriptBlocks -Text $rendered)
        $blocks.Count | Should -Be 1
        $rendered.Contains('{{') | Should -Be $false
        foreach ($block in $blocks) {
            $block.Contains('{{') | Should -Be $false
            $block.Contains($folder) | Should -Be $false
            @($block.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        }
    }

    It 'registers each hook with its matcher and a timeout of 10' {
        Get-HouseHookMatcher -Name 'bounded-search' | Should -Be 'Grep|Glob|Bash|PowerShell'
        Get-HouseHookMatcher -Name 'share-delete-guard' | Should -Be 'Grep|Glob|Bash|PowerShell'
        Get-HouseHookMatcher -Name 'windows-guard' | Should -Be 'Bash|PowerShell|Write|Edit'
        $config = New-HouseRulesConfig -Hooks @('bounded-search', 'share-delete-guard', 'windows-guard')
        $facts = New-HouseRulesFacts -Config $config
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $true
        $result.evidence.winshell | Should -Be $true
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\12-house-rules.md'))
        $page.Contains('Get-HouseHookMatcher') | Should -Be $true
        $page.Contains('timeout = 10') | Should -Be $true
        $page.Contains('core.longpaths true') | Should -Be $true
        $page.Contains('LongPathsEnabled') | Should -Be $true
        $page.Contains('PYTHONUTF8') | Should -Be $true
    }

    It 'fails hooks when the windows-guard matcher is wrong' {
        $config = New-HouseRulesConfig -Hooks @('windows-guard')
        $facts = New-HouseRulesFacts -Config $config
        foreach ($entry in $facts.entries) { $entry.matcher = 'Grep|Glob|Bash|PowerShell' }
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.hooks | Should -Be $false
        $result.detail | Should -Match 'windows-guard matcher'
    }

    It 'fails hooks when the timeout is not 10' {
        $config = New-HouseRulesConfig -Hooks @('windows-guard')
        $facts = New-HouseRulesFacts -Config $config
        foreach ($entry in $facts.entries) { $entry.timeout = '5' }
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'windows-guard timeout'
    }

    It 'passes winshell when the shell settings match' {
        $config = New-HouseRulesConfig
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts (New-HouseRulesFacts -Config $config))
        $result.ok | Should -Be $true
        $result.evidence.winshell | Should -Be $true
        $script:rulesBag.Probe.Contains('PYTHONUTF8') | Should -Be $true
        $script:rulesBag.Probe.Contains('core.longpaths') | Should -Be $true
        $script:rulesBag.Probe.Contains('core.quotepath') | Should -Be $true
        $script:rulesBag.Probe.Contains('LongPathsEnabled') | Should -Be $true
    }

    It 'fails winshell when PYTHONUTF8 is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.pythonUtf8 = '0'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.winshell | Should -Be $false
        $result.evidence.hooks | Should -Be $true
        $result.detail | Should -Match 'PYTHONUTF8'
    }

    It 'fails winshell when PYTHONIOENCODING is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.pythonIo = 'ascii'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.ok | Should -Be $false
        $result.detail | Should -Match 'PYTHONIOENCODING'
        $result.detail | Should -Not -Match 'CLAUDE_CODE_USE_POWERSHELL_TOOL'
    }

    It 'fails winshell when CLAUDE_CODE_USE_POWERSHELL_TOOL is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.pwshTool = '0'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.detail | Should -Match 'CLAUDE_CODE_USE_POWERSHELL_TOOL'
    }

    It 'fails winshell when core.longpaths is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.gitLongpaths = 'false'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.detail | Should -Match 'core\.longpaths'
        $result.detail | Should -Not -Match 'core\.quotepath'
    }

    It 'fails winshell when core.quotepath is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.gitQuotepath = 'true'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.detail | Should -Match 'core\.quotepath'
        $result.detail | Should -Not -Match 'LongPathsEnabled'
    }

    It 'fails winshell when LongPathsEnabled is wrong' {
        $config = New-HouseRulesConfig
        $facts = New-HouseRulesFacts -Config $config
        $facts.longPathsEnabled = '0'
        $result = & $script:houseRulesCheck -Context (New-HouseRulesContext -Config $config -Facts $facts)
        $result.detail | Should -Match 'LongPathsEnabled'
        $result.evidence.claudemd | Should -Be $true
    }

    It 'keeps an empty selection when Rules.Hooks is missing' {
        $config = New-BlueprintConfig
        $config.Rules = @{}
        $selection = Get-HouseHookSelection -Config $config
        @($selection.Selected | Where-Object { $_ }).Count | Should -Be 0
        @($selection.Unknown | Where-Object { $_ }).Count | Should -Be 0
        @($selection.Known) -contains 'windows-guard' | Should -Be $true
    }
}

Describe 'claude-login check' {
    BeforeAll {
        $script:claudeLoginCheck = Join-Path $script:repo 'checks\claude-login.ps1'

        function script:New-ClaudeLoginContext {
            param($Facts, [switch]$Throw)
            $ctx = New-BlueprintContext -Config (New-BlueprintConfig)
            $bag = @{ Probe = ''; Facts = $Facts }
            $script:loginBag = $bag
            if ($Throw) {
                $ctx.InvokeGuest = { param($ScriptBlock, $ArgumentList) throw 'credential rejected' }
            }
            else {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Probe = $ScriptBlock.ToString()
                    return $bag.Facts
                }.GetNewClosure()
            }
            return $ctx
        }
    }

    It 'passes when the credentials file is present' {
        $facts = [pscustomobject]@{ credentials = $true; apiKey = $false; claudeOk = $true; claudeVersion = '1.2.3'; error = $null }
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Facts $facts)
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'claude login ready'
        $result.evidence.signedin | Should -Be $true
        $result.evidence.credentials | Should -Be $true
        $result.evidence.apiKey | Should -Be $false
        $result.evidence.claude | Should -Be $true
        $result.evidence.claudeVersion | Should -Be '1.2.3'
        $result.fix | Should -Be 'runbook/14-claude-login.md#if-it-fails'
    }

    It 'passes when only the API key variable is set and drops any leaked value' {
        $secret = 'sk-' + 'fixture-123'
        $facts = [pscustomobject]@{ credentials = $false; apiKey = $true; claudeOk = $true; claudeVersion = '1.2.3'; error = $null; leaked = $secret }
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Facts $facts)
        $result.ok | Should -Be $true
        $result.evidence.credentials | Should -Be $false
        $result.evidence.apiKey | Should -Be $true
        $json = $result | ConvertTo-Json -Depth 6
        $json.Contains($secret) | Should -Be $false
        $script:loginBag.Probe | Should -Match 'IsNullOrEmpty'
        $script:loginBag.Probe | Should -Not -Match 'Get-Content'
        $script:loginBag.Probe | Should -Not -Match 'ReadAllText'
        $script:loginBag.Probe | Should -Not -Match 'ReadAllBytes'
    }

    It 'passes when only an auth token for a compatible endpoint is set' {
        $facts = [pscustomobject]@{ credentials = $false; apiKey = $false; authToken = $true; claudeOk = $true; claudeVersion = '1.2.3'; error = $null }
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Facts $facts)
        $result.ok | Should -Be $true
        $result.evidence.authToken | Should -Be $true
        $result.evidence.apiKey | Should -Be $false
        $script:loginBag.Probe | Should -Match 'ANTHROPIC_AUTH_TOKEN'
    }

    It 'fails signedin when neither sign-in is present' {
        $facts = [pscustomobject]@{ credentials = $false; apiKey = $false; authToken = $false; claudeOk = $true; claudeVersion = '1.2.3'; error = $null }
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.signedin | Should -Be $false
        $result.evidence.claude | Should -Be $true
        $result.detail | Should -Match 'signedin'
        $result.detail | Should -Match 'credentials=false'
        $result.detail | Should -Match 'apiKey=false'
    }

    It 'fails closed when the blueprint was not loaded' {
        $result = & $script:claudeLoginCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $result.evidence.signedin | Should -Be $false
        $result.evidence.claude | Should -Be $false
    }

    It 'fails both items when the guest call throws' {
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Throw)
        $result.ok | Should -Be $false
        $result.evidence.signedin | Should -Be $false
        $result.evidence.claude | Should -Be $false
        $result.detail | Should -Match 'guest probe failed'
        $result.detail | Should -Not -Match 'credential rejected'
    }

    It 'fails claude when the version command does not succeed' {
        $facts = [pscustomobject]@{ credentials = $true; apiKey = $false; claudeOk = $false; claudeVersion = 'hidden'; error = $null }
        $result = & $script:claudeLoginCheck -Context (New-ClaudeLoginContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.claude | Should -Be $false
        $result.evidence.signedin | Should -Be $true
        $result.evidence.claudeVersion | Should -Be ''
        $result.detail | Should -Match 'claude'
        $result.detail | Should -Not -Match 'hidden'
    }
}

Describe 'look helpers' {
    It 'converts hex colours to the look DWORD values' {
        '{0:X8}' -f (ConvertTo-HouseAbgrDword -Hex '#C96442') | Should -Be 'FF4264C9'
        '{0:X8}' -f (ConvertTo-HouseAbgrDword -Hex '#C96442' -Alpha 0xFF) | Should -Be 'FF4264C9'
        '{0:X8}' -f (ConvertTo-HouseAbgrDword -Hex '#C96442' -Alpha 0xC4) | Should -Be 'C44264C9'
        '{0:X8}' -f ([Convert]::ToUInt32('C4C96442', 16)) | Should -Be 'C4C96442'
        '{0:X8}' -f ([Convert]::ToUInt32('FF2C4387', 16)) | Should -Be 'FF2C4387'
    }

    It 'builds a 1920x1080 PNG wallpaper that is deterministic' {
        $first = New-HouseWallpaper
        $second = New-HouseWallpaper
        $first.Length | Should -BeGreaterThan 8
        [Convert]::ToBase64String($first) | Should -Be ([Convert]::ToBase64String($second))
        $first[0] | Should -Be 0x89
        $first[1] | Should -Be 0x50
        $first[2] | Should -Be 0x4E
        $first[3] | Should -Be 0x47
        Add-Type -AssemblyName System.Drawing
        $stream = New-Object System.IO.MemoryStream (,$first)
        $image = $null
        try {
            $image = [System.Drawing.Image]::FromStream($stream)
            $image.Width | Should -Be 1920
            $image.Height | Should -Be 1080
        }
        finally {
            if ($null -ne $image) { $image.Dispose() }
            $stream.Dispose()
        }
    }

    It 'draws a 448 avatar with an accent or cream centre and a clear corner' {
        $bytes = New-HouseAvatar -Size 448
        $bytes[0] | Should -Be 0x89
        $bytes[1] | Should -Be 0x50
        $bytes[2] | Should -Be 0x4E
        $bytes[3] | Should -Be 0x47
        Add-Type -AssemblyName System.Drawing
        $stream = New-Object System.IO.MemoryStream (,$bytes)
        $image = $null
        try {
            $image = [System.Drawing.Bitmap]::FromStream($stream)
            $image.Width | Should -Be 448
            $image.Height | Should -Be 448
            $centre = $image.GetPixel(224, 224)
            $accent = ($centre.R -eq 201 -and $centre.G -eq 100 -and $centre.B -eq 66)
            $cream = ($centre.R -eq 250 -and $centre.G -eq 249 -and $centre.B -eq 245)
            ($accent -or $cream) | Should -Be $true
            $image.GetPixel(0, 0).A | Should -Be 0
        }
        finally {
            if ($null -ne $image) { $image.Dispose() }
            $stream.Dispose()
        }
    }

    It 'builds ConfigureStartPins JSON with 5 entries' {
        $json = Get-HouseStartPinsJson
        $parsed = $json | ConvertFrom-Json
        @($parsed.pinnedList).Count | Should -Be 5
    }

    It 'pins the Claude desktop app on the taskbar after Explorer, Terminal and Edge' {
        $xml = [xml](Format-HouseTaskbarLayoutXml)
        $pins = @($xml.LayoutModificationTemplate.CustomTaskbarLayoutCollection.TaskbarLayout.TaskbarPinList.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        $pins.Count | Should -Be 4
        $pins[3].AppUserModelID | Should -Be 'Claude_pzs8sxrjxfjjc!Claude'
    }

    It 'renders a terminal fragment with the scheme name and both profile GUIDs' {
        $text = Format-HouseTerminalFragment
        { $null = $text | ConvertFrom-Json } | Should -Not -Throw
        $text | Should -Match 'claude-house Light'
        $text | Should -Match '61c54bbd-c2c6-5271-96e7-009a87ff44bf'
        $text | Should -Match '0caa0dad-35be-5f56-a8ff-afceeeaa6101'
    }

    It 'keeps the unadorned terminal fragment bytes pinned' {
        $text = Format-HouseTerminalFragment
        (ConvertTo-HouseTextHash -Text $text) | Should -Be '0d5928f2d6d0efa9f00691e4bc2993bb38ebe574e715bf381a7b1cfcb2b2efe3'
    }

    It 'adds icon and background keys when art paths are given' {
        $icon = 'C:\ProgramData\claude-house\look\terminal.png'
        $background = 'C:\ProgramData\claude-house\look\terminal-background.png'
        $text = Format-HouseTerminalFragment -IconPath $icon -BackgroundPath $background
        { $null = $text | ConvertFrom-Json } | Should -Not -Throw
        $text.Contains('"icon":"C:\\ProgramData\\claude-house\\look\\terminal.png"') | Should -Be $true
        $text.Contains('"backgroundImage":"C:\\ProgramData\\claude-house\\look\\terminal-background.png"') | Should -Be $true
        $text.Contains('"backgroundImageOpacity":0.08') | Should -Be $true
        $text.Contains('"backgroundImageStretchMode":"uniformToFill"') | Should -Be $true
        $text.Contains('"backgroundImageAlignment":"bottomRight"') | Should -Be $true
        $parsed = $text | ConvertFrom-Json
        @($parsed.profiles).Count | Should -Be 2
        foreach ($profile in @($parsed.profiles)) {
            $profile.icon | Should -Be $icon
            $profile.backgroundImage | Should -Be $background
            $profile.backgroundImageStretchMode | Should -Be 'uniformToFill'
            $profile.backgroundImageAlignment | Should -Be 'bottomRight'
            ([math]::Round([double]$profile.backgroundImageOpacity, 2)) | Should -Be 0.08
        }
    }
}

Describe 'welcome page' {
    BeforeAll {
        # The test file stays ASCII, so Chinese words are written as \u escapes and decoded here.
        function script:ConvertFrom-TestEscape {
            param([string]$Text)
            return [regex]::Unescape($Text)
        }
    }

    It 'escapes blueprint values such as a share name with a bold tag, ampersand and quote' {
        $config = New-BlueprintConfig
        $config.House.Name = 'Test <i>House</i>'
        $config.House.UserName = 'u&<x>'
        $config.Shares = @(
            @{ Name = 'a<b>&"z'; HostPath = 'C:\share\o"dd'; Writable = $false; Mirror = $false }
        )
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('a<b>&"z') | Should -Be $false
        $html.Contains('<b>') | Should -Be $false
        $html.Contains('<i>') | Should -Be $false
        $html.Contains('<td>a&lt;b&gt;&amp;&quot;z</td>') | Should -Be $true
        $html.Contains('<code>C:\share\o&quot;dd</code>') | Should -Be $true
        $html.Contains('\\house-host\a&lt;b&gt;&amp;&quot;z') | Should -Be $true
        $html.Contains('<h1 class="en">Welcome to Test &lt;i&gt;House&lt;/i&gt;</h1>') | Should -Be $true
        $html.Contains('<title>Welcome to Test &lt;i&gt;House&lt;/i&gt;</title>') | Should -Be $true
        $html.Contains('<code>u&amp;&lt;x&gt;</code>') | Should -Be $true
        $html.Contains('<span class="en">Read-only</span>') | Should -Be $true
    }

    It 'never expands a token-like blueprint value twice' {
        $config = New-BlueprintConfig
        $config.House.Name = '{user}'
        $config.House.UserName = 'someone'
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('<h1 class="en">Welcome to {user}</h1>') | Should -Be $true
    }

    It 'lists Git and Claude Code always and each other tool only when its flag is true' {
        $config = New-BlueprintConfig
        $config.Tools = @{ Python = $true; Node = $false; ClaudeDesktop = $true; GitHubCli = $false; VSCode = $false }
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('<p class="en"><strong>Installed:</strong> Git, Claude Code, Python, Claude desktop.</p>') | Should -Be $true
        $html.Contains('VS Code') | Should -Be $false
        $html.Contains('Node.js') | Should -Be $false
        $html.Contains('GitHub CLI') | Should -Be $false
        $html.Contains('click <strong>Claude</strong> on the taskbar') | Should -Be $true
        $config.Tools.VSCode = $true
        $config.Tools.ClaudeDesktop = $false
        $html2 = Format-HouseWelcomeHtml -Config $config
        $html2.Contains('<p class="en"><strong>Installed:</strong> Git, Claude Code, Python, VS Code.</p>') | Should -Be $true
        $html2.Contains('Claude desktop') | Should -Be $false
        $html2.Contains('click <strong>Claude</strong> on the taskbar') | Should -Be $false
        $html2.Contains('open <strong>Terminal</strong> and type <code>claude</code>') | Should -Be $true
    }

    It 'shows each share with its host path, its path inside the VM and its access, or says none are shared' {
        $config = New-BlueprintConfig
        $config.Shares = @()
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('<p class="en">No folders are shared with this house.') | Should -Be $true
        $html.Contains('<table') | Should -Be $false
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = 'D:\docs'; Writable = $false; Mirror = $false }
        )
        $html2 = Format-HouseWelcomeHtml -Config $config
        $html2.Contains('No folders are shared') | Should -Be $false
        $html2.Contains('<span class="en">Path inside this VM</span>') | Should -Be $true
        $html2.Contains('Path in this computer') | Should -Be $false
        $html2.Contains('<tr><td>projects</td><td><code>D:\projects</code></td><td><code>D:\projects</code></td><td><span class="en">Writable</span>') | Should -Be $true
        $html2.Contains('<tr><td>docs</td><td><code>D:\docs</code></td><td><code>\\house-host\docs</code></td><td><span class="en">Read-only</span>') | Should -Be $true
        $html2.Contains('These are your real files, not copies.') | Should -Be $true
    }

    It 'names every hook in Rules.Hooks in one footer line, known ones with a plain description' {
        $config = New-BlueprintConfig
        $config.Rules = @{ Hooks = @('bounded-search', 'share-delete-guard', 'windows-guard', 'my-own-hook') }
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('<p class="en"><strong>House rules:</strong> <code>bounded-search</code> (stops searches of whole shared drives), <code>share-delete-guard</code> (stops deleting on shared folders), <code>windows-guard</code> (stops common Windows command mistakes), <code>my-own-hook</code>.</p>') | Should -Be $true
        $config.Rules = @{ Hooks = @() }
        (Format-HouseWelcomeHtml -Config $config).Contains('<strong>House rules:</strong> none are switched on.') | Should -Be $true
    }

    It 'has no scripts and no web address at all' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true; Mirror = $true })
        $config.Tools = @{ Python = $true; Node = $true; ClaudeDesktop = $true; GitHubCli = $true; VSCode = $true }
        $config.Rules = @{ Hooks = @('bounded-search', 'share-delete-guard', 'windows-guard') }
        foreach ($locale in @('en-US', 'zh-CN')) {
            $config.House.Locale = $locale
            $html = Format-HouseWelcomeHtml -Config $config
            $html | Should -Not -Match '(?i)<script'
            $html | Should -Not -Match '(?i)\bon[a-z]+\s*='
            $html | Should -Not -Match '(?i)https?:'
            $html | Should -Not -Match '(?i)@import|url\('
            $html.Contains('<meta charset="utf-8">') | Should -Be $true
            $html.Contains('<img src="house.png"') | Should -Be $true
            $palette = Get-HouseLookPalette
            foreach ($key in @('background', 'surface', 'text', 'accent')) { $html.Contains($palette[$key]) | Should -Be $true }
            (Format-HouseWelcomeHtml -Config $config) | Should -Be $html
        }
    }

    It 'carries English and Chinese, switched by two radio buttons and CSS only' {
        $config = New-BlueprintConfig
        $html = Format-HouseWelcomeHtml -Config $config
        $html.Contains('<label for="lang-en">English</label>') | Should -Be $true
        $html.Contains('<label for="lang-zh" lang="zh-CN">' + (ConvertFrom-TestEscape '\u4e2d\u6587') + '</label>') | Should -Be $true
        $html.Contains('#lang-en:checked ~ .page .zh, #lang-zh:checked ~ .page .en { display: none; }') | Should -Be $true
        $html.IndexOf('id="lang-zh"') | Should -BeLessThan $html.IndexOf('<div class="page">')
        $html.Contains('<h2 class="en">Start Claude</h2>') | Should -Be $true
        $html.Contains('<h2 class="zh" lang="zh-CN">' + (ConvertFrom-TestEscape '\u542f\u52a8 Claude') + '</h2>') | Should -Be $true
        $html.Contains('<h1 class="zh" lang="zh-CN">' + (ConvertFrom-TestEscape '\u6b22\u8fce\u6765\u5230 FixtureHouse') + '</h1>') | Should -Be $true
        $enCount = ([regex]::Matches($html, 'class="(?:[a-z]+ )?en"')).Count
        $zhCount = ([regex]::Matches($html, 'class="(?:[a-z]+ )?zh" lang="zh-CN"')).Count
        $enCount | Should -BeGreaterThan 20
        $zhCount | Should -Be $enCount
    }

    It 'checks English by default and Chinese when the blueprint Locale is zh-*' {
        $config = New-BlueprintConfig
        $config.House.Locale = 'en-US'
        $en = Format-HouseWelcomeHtml -Config $config
        $en.Contains('id="lang-en" aria-label="English" checked>') | Should -Be $true
        $en | Should -Not -Match 'id="lang-zh"[^>]*checked'
        $en.Contains('<html lang="en">') | Should -Be $true
        $en.Contains('<title>Welcome to FixtureHouse</title>') | Should -Be $true
        $config.House.Locale = 'zh-CN'
        $zh = Format-HouseWelcomeHtml -Config $config
        $zh | Should -Match 'id="lang-zh"[^>]*checked>'
        $zh.Contains('id="lang-en" aria-label="English">') | Should -Be $true
        $zh.Contains('<html lang="zh-CN">') | Should -Be $true
        $zh.Contains('<title>' + (ConvertFrom-TestEscape '\u6b22\u8fce\u6765\u5230 FixtureHouse') + '</title>') | Should -Be $true
        $config.House.Locale = 'zh-TW'
        (Format-HouseWelcomeHtml -Config $config) | Should -Match 'id="lang-zh"[^>]*checked>'
        $config.House.Locale = 'de-DE'
        (Format-HouseWelcomeHtml -Config $config).Contains('id="lang-en" aria-label="English" checked>') | Should -Be $true
    }

    It 'round-trips Chinese text through UTF-8 without a BOM' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'docs'; HostPath = (ConvertFrom-TestEscape 'D:\\\u8d44\u6599'); Writable = $true; Mirror = $true })
        $html = Format-HouseWelcomeHtml -Config $config
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $bytes = $utf8.GetBytes($html)
        ($bytes[0] -eq 0xEF) | Should -Be $false
        $back = $utf8.GetString($bytes)
        $back.Contains((ConvertFrom-TestEscape '\u4f60\u7684\u6587\u4ef6\u5939')) | Should -Be $true
        $back.Contains((ConvertFrom-TestEscape '<code>D:\\\u8d44\u6599</code>')) | Should -Be $true
        $back.Contains([string][char]0xFFFD) | Should -Be $false
        $back | Should -Not -Match '\\u[0-9a-fA-F]{4}'
    }

    It 'answers first-week questions and drops the old safety promise' {
        $config = New-BlueprintConfig
        $config.House.UserName = 'fixtureuser'
        $config.House.TimeZone = 'Pacific Standard Time'
        $html = Format-HouseWelcomeHtml -Config $config
        $html | Should -Not -Match '(?i)stays safe'
        $html.Contains('Sign in to Windows as <code>fixtureuser</code>.') | Should -Be $true
        $html.Contains('<code>runbook/daily.md</code>') | Should -Be $true
        $html.Contains('Start &gt; Power &gt; Shut down') | Should -Be $true
        $html.Contains('<code>claude update</code>') | Should -Be $true
        $html.Contains('not activated') | Should -Be $true
        $html.Contains('the time zone <code>Pacific Standard Time</code> and the language <code>en-US</code>') | Should -Be $true
        $html.Contains('"No internet" on the taskbar is normal.') | Should -Be $true
        $html.Contains('run <code>house doctor</code>, then <code>house next</code>') | Should -Be $true
    }

    It 'sets Pacific Standard Time as the example blueprint time zone' {
        $example = Import-HouseConfig -Path (Join-Path $script:repo 'house.config.example.psd1')
        $example.House.TimeZone | Should -Be 'Pacific Standard Time'
    }
}

Describe 'cursor scheme' {
    BeforeAll {
    function script:New-CursorSchemeFixture {
        param(
            [string]$Root,
            [string]$DropRole,
            [string]$BadRole,
            [string]$BadExtension,
            [switch]$MissingFile
        )
        $dir = Join-Path $Root 'assets\cursors'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $map = @{ SchemeName = 'claude-house' }
        $index = 0
        foreach ($role in @('Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No', 'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person')) {
            if ($role -eq $DropRole) { continue }
            $ext = '.cur'
            if ($role -eq 'Hand') { $ext = '.ani' }
            if ($role -eq $BadRole -and $BadExtension) { $ext = $BadExtension }
            $name = $role.ToLowerInvariant() + $ext
            $map[$role] = $name
            $write = -not ($MissingFile -and $role -eq 'Pin')
            if ($write) {
                [System.IO.File]::WriteAllBytes((Join-Path $dir $name), [byte[]]@(10, [byte]$index))
            }
            $index++
        }
        $json = ConvertTo-Json -InputObject $map -Compress -Depth 4
        [System.IO.File]::WriteAllText((Join-Path $dir 'scheme.json'), $json)
    }
    }

    It 'returns 17 cursor pairs in Windows scheme order' {
        $root = Join-Path $TestDrive 'cursors-full'
        New-CursorSchemeFixture -Root $root
        $pairs = @(Get-HouseCursorScheme -RepoRoot $root)
        $pairs.Count | Should -Be 17
        ($pairs | ForEach-Object { $_.Role }) -join ',' | Should -Be 'Arrow,Help,AppStarting,Wait,Crosshair,IBeam,NWPen,No,SizeNS,SizeWE,SizeNWSE,SizeNESW,SizeAll,UpArrow,Hand,Pin,Person'
        $pairs[0].File | Should -Be 'arrow.cur'
        $pairs[14].File | Should -Be 'hand.ani'
        Test-Path -LiteralPath $pairs[0].SourcePath -PathType Leaf | Should -Be $true
    }

    It 'returns null when a cursor role is missing' {
        $root = Join-Path $TestDrive 'cursors-missing-role'
        New-CursorSchemeFixture -Root $root -DropRole 'Pin'
        Get-HouseCursorScheme -RepoRoot $root | Should -Be $null
    }

    It 'returns null when a cursor file is missing' {
        $root = Join-Path $TestDrive 'cursors-missing-file'
        New-CursorSchemeFixture -Root $root -MissingFile
        Get-HouseCursorScheme -RepoRoot $root | Should -Be $null
    }

    It 'returns null when a cursor extension is wrong' {
        $root = Join-Path $TestDrive 'cursors-bad-ext'
        New-CursorSchemeFixture -Root $root -BadRole 'Wait' -BadExtension '.png'
        Get-HouseCursorScheme -RepoRoot $root | Should -Be $null
    }

    It 'joins 17 cursor paths in Windows scheme order' {
        $root = Join-Path $TestDrive 'cursors-join'
        New-CursorSchemeFixture -Root $root
        $pairs = @(Get-HouseCursorScheme -RepoRoot $root)
        $expected = @(
            'C:\ProgramData\claude-house\look\cursors\arrow.cur',
            'C:\ProgramData\claude-house\look\cursors\help.cur',
            'C:\ProgramData\claude-house\look\cursors\appstarting.cur',
            'C:\ProgramData\claude-house\look\cursors\wait.cur',
            'C:\ProgramData\claude-house\look\cursors\crosshair.cur',
            'C:\ProgramData\claude-house\look\cursors\ibeam.cur',
            'C:\ProgramData\claude-house\look\cursors\nwpen.cur',
            'C:\ProgramData\claude-house\look\cursors\no.cur',
            'C:\ProgramData\claude-house\look\cursors\sizens.cur',
            'C:\ProgramData\claude-house\look\cursors\sizewe.cur',
            'C:\ProgramData\claude-house\look\cursors\sizenwse.cur',
            'C:\ProgramData\claude-house\look\cursors\sizenesw.cur',
            'C:\ProgramData\claude-house\look\cursors\sizeall.cur',
            'C:\ProgramData\claude-house\look\cursors\uparrow.cur',
            'C:\ProgramData\claude-house\look\cursors\hand.ani',
            'C:\ProgramData\claude-house\look\cursors\pin.cur',
            'C:\ProgramData\claude-house\look\cursors\person.cur'
        ) -join ','
        Format-HouseCursorSchemeValue -Pairs $pairs | Should -Be $expected
    }
}

Describe 'look check' {
    BeforeAll {
        $script:lookCheck = Join-Path $script:repo 'checks\look.ps1'

        function script:Get-HouseScriptBlocks {
            param([string]$Text)
            $blocks = New-Object System.Collections.Generic.List[string]
            $idx = 0
            while ($idx -lt $Text.Length) {
                $at = $Text.IndexOf('-ScriptBlock', $idx)
                if ($at -lt 0) { break }
                $brace = $Text.IndexOf('{', $at)
                if ($brace -lt 0) { throw 'script block was not opened' }
                $depth = 0
                $i = $brace
                $inSingle = $false
                $inDouble = $false
                $closed = $false
                while ($i -lt $Text.Length) {
                    $ch = $Text[$i]
                    if ($inSingle) {
                        if ($ch -eq "'") {
                            if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i += 2; continue }
                            $inSingle = $false
                        }
                        $i++
                        continue
                    }
                    if ($inDouble) {
                        if ($ch -eq '`') { $i += 2; continue }
                        if ($ch -eq '"') { $inDouble = $false }
                        $i++
                        continue
                    }
                    if ($ch -eq "'") { $inSingle = $true; $i++; continue }
                    if ($ch -eq '"') { $inDouble = $true; $i++; continue }
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') {
                        $depth--
                        if ($depth -eq 0) {
                            $blocks.Add($Text.Substring($brace + 1, $i - $brace - 1))
                            $idx = $i + 1
                            $closed = $true
                            break
                        }
                    }
                    $i++
                }
                if (-not $closed) { throw 'script block was not closed' }
            }
            return @($blocks.ToArray())
        }

        function script:New-LookFacts {
            param($Config)
            if ($null -eq $Config) { $Config = New-BlueprintConfig }
            $wallpaperPath = 'C:\Users\fixtureuser\Pictures\claude-house-wallpaper.png'
            $art = Get-HouseTerminalArtPaths -RepoRoot $script:repo
            $fragment = Format-HouseTerminalFragment -IconPath $art.IconPath -BackgroundPath $art.BackgroundPath
            $wallpaperBytes = Get-HouseLookBytes -RepoRoot $script:repo -FileName 'wallpaper.png' -Generate { New-HouseWallpaper }
            $lockBytes = Get-HouseLookBytes -RepoRoot $script:repo -FileName 'lockscreen.png' -Generate { New-HouseWallpaper }
            $avatarBytes = Get-HouseLookBytes -RepoRoot $script:repo -FileName 'avatar.png' -Generate { New-HouseAvatar -Size 448 }
            $facts = [pscustomobject]@{
                appsUseLightTheme          = 1
                systemUsesLightTheme       = 1
                personalizeColorPrevalence = 0
                accentColor                = (ConvertTo-HouseAbgrDword -Hex '#C96442')
                colorizationColor          = [Convert]::ToUInt32('C4C96442', 16)
                dwmColorPrevalence         = 1
                accentColorMenu            = (ConvertTo-HouseAbgrDword -Hex '#C96442')
                startColorMenu             = [Convert]::ToUInt32('FF2C4387', 16)
                accentPalette              = (Get-HouseLookAccentPalette)
                wallpaper                  = $wallpaperPath
                wallpaperExpected          = $wallpaperPath
                wallpaperExists            = $true
                wallpaperHash              = (ConvertTo-HouseBytesHash -Bytes $wallpaperBytes)
                wallpaperStale             = $false
                hideFileExt                = 0
                launchTo                   = 1
                startIrisRecommendations   = 0
                showTaskViewButton         = 0
                searchboxTaskbarMode       = 1
                allowNewsAndInterests      = 0
        widgetsInstalled           = $true
                hideFirstRunExperience     = 1
                edgeStartupBoost           = 0
                edgeBackgroundMode         = 0
                oneDriveDisabled           = 1
                terminalExists             = $true
                terminalParseOk            = $true
                terminalHash               = (ConvertTo-HouseTextHash -Text $fragment)
                terminalText               = ''
                terminalIconExists         = $false
                terminalIconHash           = ''
                terminalBackgroundExists   = $false
                terminalBackgroundHash     = ''
                cursorSchemeSource         = $null
                cursorValues               = @{}
                cursorHashes               = @{}
                shareShortcuts             = @()
                enableFirstLogonAnimation  = 0
                enableTransparency         = 0
                taskbarAnimations          = 0
                minAnimate                 = '0'
                spotlightEnabledState      = 0
                backgroundType             = 0
                disableSpotlightCollection = 1
                disableWindowsSpotlight    = 1
                rotatingLockScreenEnabled  = 0
                rotatingLockScreenOverlay  = 0
                subscribedContent338387    = 0
                systemPaneSuggestionsEnabled = 0
                silentInstalledAppsEnabled = 0
                lockScreenImagePath        = 'C:\ProgramData\claude-house\look\lockscreen.png'
                lockScreenImageUrl         = 'C:\ProgramData\claude-house\look\lockscreen.png'
                lockScreenImageStatus      = 1
                disableAcrylicBackgroundOnLogon = 1
                lockscreenExists           = $true
                lockscreenHash             = (ConvertTo-HouseBytesHash -Bytes $lockBytes)
                useDefaultTile             = 1
                userTileExists             = $true
                userTileHash               = (ConvertTo-HouseBytesHash -Bytes (ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 448))
                turnOffWindowsCopilot      = 1
                showCopilotButton          = 0
                searchOnTaskbarMode        = 1
                startLayoutFile            = 'C:\ProgramData\claude-house\look\taskbar.xml'
                lockedStartLayout          = 1
                taskbarExists              = $true
                taskbarHash                = (ConvertTo-HouseTextHash -Text (Format-HouseTaskbarLayoutXml))
                configureStartPins         = (Get-HouseStartPinsJson)
                configureStartPinsProviderSet = 1
                startTrackDocs             = 0
                startAccountNotifications  = 0
                welcomeExists              = $true
                welcomeHash                = (ConvertTo-HouseTextHash -Text (Format-HouseWelcomeHtml -Config $Config))
                welcomeShortcutExists      = $true
                welcomeShortcutTarget      = 'C:\ProgramData\claude-house\welcome\index.html'
                error                      = $null
            }
            if ($art.IconSource -or $art.BackgroundSource) { $facts.terminalText = $fragment }
            if ($art.IconSource) {
                $facts.terminalIconExists = $true
                $facts.terminalIconHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$art.IconSource))
            }
            if ($art.BackgroundSource) {
                $facts.terminalBackgroundExists = $true
                $facts.terminalBackgroundHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$art.BackgroundSource))
            }
            $scheme = Get-HouseCursorScheme -RepoRoot $script:repo
            if ($null -ne $scheme) {
                $facts.cursorSchemeSource = 1
                foreach ($pair in @($scheme)) {
                    $facts.cursorValues[$pair.Role] = Get-HouseCursorGuestPath -FileName ([string]$pair.File)
                    $facts.cursorHashes[$pair.Role] = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$pair.SourcePath))
                }
            }
            return $facts
        }

        function script:Set-LookArtFacts {
            param($Facts, [string]$Root)
            $wallpaperBytes = Get-HouseLookBytes -RepoRoot $Root -FileName 'wallpaper.png' -Generate { New-HouseWallpaper }
            $lockBytes = Get-HouseLookBytes -RepoRoot $Root -FileName 'lockscreen.png' -Generate { New-HouseWallpaper }
            $avatarBytes = Get-HouseLookBytes -RepoRoot $Root -FileName 'avatar.png' -Generate { New-HouseAvatar -Size 448 }
            $Facts.wallpaperHash = ConvertTo-HouseBytesHash -Bytes $wallpaperBytes
            $Facts.lockscreenHash = ConvertTo-HouseBytesHash -Bytes $lockBytes
            $Facts.userTileHash = ConvertTo-HouseBytesHash -Bytes (ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 448)
            $art = Get-HouseTerminalArtPaths -RepoRoot $Root
            $fragment = Format-HouseTerminalFragment -IconPath $art.IconPath -BackgroundPath $art.BackgroundPath
            $Facts.terminalHash = ConvertTo-HouseTextHash -Text $fragment
            $Facts.terminalText = ''
            $Facts.terminalIconExists = $false
            $Facts.terminalIconHash = ''
            $Facts.terminalBackgroundExists = $false
            $Facts.terminalBackgroundHash = ''
            if ($art.IconSource -or $art.BackgroundSource) { $Facts.terminalText = $fragment }
            if ($art.IconSource) {
                $Facts.terminalIconExists = $true
                $Facts.terminalIconHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$art.IconSource))
            }
            if ($art.BackgroundSource) {
                $Facts.terminalBackgroundExists = $true
                $Facts.terminalBackgroundHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$art.BackgroundSource))
            }
        }

        function script:New-CursorSchemeFixture {
            param([string]$Root)
            $dir = Join-Path $Root 'assets\cursors'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $map = @{ SchemeName = 'claude-house' }
            $index = 0
            foreach ($role in @('Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No', 'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person')) {
                $ext = '.cur'
                if ($role -eq 'Hand') { $ext = '.ani' }
                $name = $role.ToLowerInvariant() + $ext
                $map[$role] = $name
                [System.IO.File]::WriteAllBytes((Join-Path $dir $name), [byte[]]@(10, [byte]$index))
                $index++
            }
            [System.IO.File]::WriteAllText((Join-Path $dir 'scheme.json'), (ConvertTo-Json -InputObject $map -Compress -Depth 4))
        }

        function script:Add-LookCursorFacts {
            param($Facts, [string]$Root)
            $scheme = @(Get-HouseCursorScheme -RepoRoot $Root)
            $Facts.cursorSchemeSource = 1
            $Facts.cursorValues = @{}
            $Facts.cursorHashes = @{}
            foreach ($pair in $scheme) {
                $Facts.cursorValues[$pair.Role] = Get-HouseCursorGuestPath -FileName ([string]$pair.File)
                $Facts.cursorHashes[$pair.Role] = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$pair.SourcePath))
            }
        }

        function script:New-LookContext {
            param($Config, $Facts, [switch]$Throw, [hashtable]$Call)
            if ($null -eq $Config) { $Config = New-BlueprintConfig }
            $ctx = New-BlueprintContext -Config $Config
            if ($null -eq $Call) { $Call = @{ n = 0 } }
            $bag = @{ Probe = ''; Facts = $Facts; Call = $Call }
            $script:lookBag = $bag
            if ($Throw) {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Call.n++
                    throw 'credential rejected'
                }.GetNewClosure()
            }
            else {
                $ctx.InvokeGuest = {
                    param($ScriptBlock, $ArgumentList)
                    $bag.Call.n++
                    $bag.Probe = $ScriptBlock.ToString()
                    $bag.Args = @($ArgumentList)
                    return $bag.Facts
                }.GetNewClosure()
            }
            return $ctx
        }
    }

    It 'fails closed when the blueprint was not loaded' {
        $result = & $script:lookCheck -Context (New-BlueprintContext -Config $null)
        $result.ok | Should -Be $false
        $result.detail | Should -Be 'blueprint not loaded'
        $result.evidence.theme | Should -Be $false
        $result.evidence.accent | Should -Be $false
        $result.evidence.wallpaper | Should -Be $false
        $result.evidence.explorer | Should -Be $false
        $result.evidence.quiet | Should -Be $false
        $result.evidence.terminal | Should -Be $false
    }

    It 'passes with a full fact fixture' {
        $result = & $script:lookCheck -Context (New-LookContext -Facts (New-LookFacts))
        $result.id | Should -Be 'look'
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'look ready'
        $result.evidence.theme | Should -Be $true
        $result.evidence.accent | Should -Be $true
        $result.evidence.wallpaper | Should -Be $true
        $result.evidence.explorer | Should -Be $true
        $result.evidence.quiet | Should -Be $true
        $result.evidence.terminal | Should -Be $true
        $result.evidence.spotlightOff | Should -Be $true
        $result.evidence.signinScreen | Should -Be $true
        $result.evidence.avatar | Should -Be $true
        $result.evidence.taskbar | Should -Be $true
        $result.evidence.startPins | Should -Be $true
        $result.evidence.smooth | Should -Be $true
        $result.evidence.welcome | Should -Be $true
        $result.evidence.lookTheme | Should -Be 'light'
        $result.fix | Should -Be 'runbook/13-look.md#if-it-fails'
    }

    It 'fails theme when a Personalize value differs' {
        $facts = New-LookFacts
        $facts.appsUseLightTheme = 0
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.theme | Should -Be $false
        $result.evidence.accent | Should -Be $true
        $result.detail | Should -Match '^theme'
    }

    It 'fails accent when AccentColor differs' {
        $facts = New-LookFacts
        $facts.accentColor = 0
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.accent | Should -Be $false
        $result.evidence.theme | Should -Be $true
        $result.detail | Should -Match 'accent'
        $result.detail | Should -Match 'AccentColor'
    }

    It 'fails wallpaper when Windows still shows an older cached copy' {
        $facts = New-LookFacts
        $facts.wallpaperStale = $true
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.wallpaper | Should -Be $false
        $result.detail | Should -Match 'wallpaper'
    }
    It 'fails wallpaper when the hash differs' {
        $facts = New-LookFacts
        $facts.wallpaperHash = ('ab' * 32)
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.wallpaper | Should -Be $false
        $result.evidence.theme | Should -Be $true
        $result.detail | Should -Match 'wallpaper'
    }

    It 'fails explorer when HideFileExt differs' {
        $facts = New-LookFacts
        $facts.hideFileExt = 1
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.explorer | Should -Be $false
        $result.evidence.quiet | Should -Be $true
        $result.detail | Should -Match 'explorer'
        $result.detail | Should -Match 'HideFileExt'
    }

    It 'fails quiet when OneDrive may still start at sign-in' {
        $facts = New-LookFacts
        $facts.oneDriveDisabled = $null
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.evidence.quiet | Should -Be $false
        $result.detail | Should -Match 'DisableFileSyncNGSC'
    }
    It 'fails quiet when AllowNewsAndInterests differs' {
        $facts = New-LookFacts
        $facts.allowNewsAndInterests = 1
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.quiet | Should -Be $false
        $result.evidence.explorer | Should -Be $true
        $result.detail | Should -Match 'quiet'
        $result.detail | Should -Match 'AllowNewsAndInterests'
    }

    It 'passes quiet without the news policy when the Widgets app is gone' {
        # Build 26300 refuses the policy write (User Choice Protection Driver); step 13 then removes Widgets.
        $facts = New-LookFacts
        $facts.allowNewsAndInterests = $null
        $facts.widgetsInstalled = $false
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.evidence.quiet | Should -Be $true
    }

    It 'fails quiet without the news policy while the Widgets app is still installed' {
        $facts = New-LookFacts
        $facts.allowNewsAndInterests = $null
        $facts.widgetsInstalled = $true
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.evidence.quiet | Should -Be $false
        $result.detail | Should -Match 'AllowNewsAndInterests'
    }

    It 'writes and reads share shortcut targets through the Unicode Shell.Application' {
        # WScript.Shell threw on a Chinese folder name on the English drill guest (2026-10-13) and reads it back as ??.
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\13-look.md'))
        $check = [System.IO.File]::ReadAllText((Join-Path $script:repo 'checks\look.ps1'))
        $page | Should -Not -Match 'TargetPath = \[string\]\$shortcutRow\.target'
        $page | Should -Match '\$lnk\.Path = \[string\]\$shortcutRow\.target'
        $check | Should -Not -Match '\$shortcutLink\.TargetPath'
        $check | Should -Match 'target = \[string\]\$shortcutLink\.Path'
    }

    It 'removes the Widgets app in step 13 only when Windows refuses the news policy' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\13-look.md'))
        $text | Should -Match "-is \[System\.UnauthorizedAccessException\]"
        $text | Should -Match "Remove-AppxPackage -AllUsers"
        $text | Should -Match "MicrosoftWindows\.Client\.WebExperience"
    }

    It 'fails spotlightOff when BackgroundType differs' {
        $facts = New-LookFacts
        $facts.backgroundType = 1
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.spotlightOff | Should -Be $false
        $result.evidence.signinScreen | Should -Be $true
        $result.evidence.wallpaper | Should -Be $true
        $result.detail | Should -Match 'spotlightOff'
        $result.detail | Should -Match 'BackgroundType'
    }

    It 'fails signinScreen when the lock screen status differs' {
        $facts = New-LookFacts
        $facts.lockScreenImageStatus = 0
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.signinScreen | Should -Be $false
        $result.evidence.spotlightOff | Should -Be $true
        $result.detail | Should -Match 'signinScreen'
        $result.detail | Should -Match 'LockScreenImageStatus'
    }

    It 'fails avatar when UseDefaultTile differs' {
        $facts = New-LookFacts
        $facts.useDefaultTile = 0
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.avatar | Should -Be $false
        $result.evidence.taskbar | Should -Be $true
        $result.detail | Should -Match 'avatar'
        $result.detail | Should -Match 'UseDefaultTile'
    }

    It 'fails taskbar when TurnOffWindowsCopilot differs' {
        $facts = New-LookFacts
        $facts.turnOffWindowsCopilot = 0
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.taskbar | Should -Be $false
        $result.evidence.startPins | Should -Be $true
        $result.evidence.explorer | Should -Be $true
        $result.detail | Should -Match 'taskbar'
        $result.detail | Should -Match 'TurnOffWindowsCopilot'
    }

    It 'fails startPins when ConfigureStartPins differs' {
        $facts = New-LookFacts
        $facts.configureStartPins = '{}'
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.startPins | Should -Be $false
        $result.evidence.smooth | Should -Be $true
        $result.evidence.explorer | Should -Be $true
        $result.detail | Should -Match 'startPins'
        $result.detail | Should -Match 'ConfigureStartPins'
    }

    It 'fails smooth when MinAnimate differs' {
        $facts = New-LookFacts
        $facts.minAnimate = '1'
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.smooth | Should -Be $false
        $result.evidence.spotlightOff | Should -Be $true
        $result.detail | Should -Match 'smooth'
        $result.detail | Should -Match 'MinAnimate'
    }

    It 'uses assets/look/wallpaper.png bytes for the wallpaper hash' {
        $root = Join-Path $TestDrive 'look-repo'
        $dir = Join-Path $root 'assets\look'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $bytes = [byte[]]@(1, 2, 3, 4, 5)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'wallpaper.png'), $bytes)
        $facts = New-LookFacts
        $facts.wallpaperHash = ConvertTo-HouseBytesHash -Bytes $bytes
        $ctx = New-LookContext -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.evidence.wallpaper | Should -Be $true
        $facts.wallpaperHash = ConvertTo-HouseBytesHash -Bytes (New-HouseWallpaper)
        $ctx2 = New-LookContext -Facts $facts
        $ctx2.RepoRoot = $root
        $result2 = & $script:lookCheck -Context $ctx2
        $result2.evidence.wallpaper | Should -Be $false
    }

    It 'fails terminal when the fragment hash differs' {
        $facts = New-LookFacts
        $facts.terminalHash = ('cd' * 32)
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.terminal | Should -Be $false
        $result.evidence.wallpaper | Should -Be $true
        $result.detail | Should -Match 'terminal'
    }

    It 'skips without calling InvokeGuest when Look.Theme is none' {
        $config = New-BlueprintConfig
        $config.Look = @{ Theme = 'none' }
        $call = @{ n = 0 }
        $result = & $script:lookCheck -Context (New-LookContext -Config $config -Facts (New-LookFacts) -Call $call)
        $result.ok | Should -Be $true
        $result.detail | Should -Be 'look skipped'
        $result.evidence.lookTheme | Should -Be 'none'
        $call.n | Should -Be 0
    }

    It 'fails every item when the guest call throws and keeps the message' {
        $result = & $script:lookCheck -Context (New-LookContext -Throw)
        $result.ok | Should -Be $false
        $result.evidence.theme | Should -Be $false
        $result.evidence.accent | Should -Be $false
        $result.evidence.wallpaper | Should -Be $false
        $result.evidence.explorer | Should -Be $false
        $result.evidence.quiet | Should -Be $false
        $result.evidence.terminal | Should -Be $false
        $result.detail | Should -Match 'credential rejected'
    }

    It 'passes cursors, terminalArt and shareShortcuts with good stubs' {
        $root = Join-Path $TestDrive 'look-art-pass'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-CursorSchemeFixture -Root $root
        $iconDir = Join-Path $root 'assets\icons'
        $terminalDir = Join-Path $root 'assets\terminal'
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
        New-Item -ItemType Directory -Path $terminalDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'terminal.png'), [byte[]]@(9, 9, 9))
        [System.IO.File]::WriteAllBytes((Join-Path $terminalDir 'background.png'), [byte[]]@(8, 8, 8))
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'folder-projects.ico'), [byte[]]@(3, 1))
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'folder-docs.ico'), [byte[]]@(3, 2))
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'C:\share\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = 'C:\share\docs'; Writable = $false; Mirror = $false }
        )
        $facts = New-LookFacts -Config $config
        Set-LookArtFacts -Facts $facts -Root $root
        Add-LookCursorFacts -Facts $facts -Root $root
        $facts.shareShortcuts = @(
            [pscustomobject]@{ name = 'projects'; target = 'C:\share\projects'; icon = 'C:\ProgramData\claude-house\look\folder-projects.ico,0' },
            [pscustomobject]@{ name = 'docs'; target = '\\house-host\docs'; icon = 'C:\ProgramData\claude-house\look\folder-docs.ico,0' }
        )
        $ctx = New-LookContext -Config $config -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.ok | Should -Be $true
        $result.evidence.cursors | Should -Be $true
        $result.evidence.terminalArt | Should -Be $true
        $result.evidence.shareShortcuts | Should -Be $true
        $result.evidence.theme | Should -Be $true
        $result.detail | Should -Be 'look ready'
    }

    It 'fails cursors alone when a role path is wrong' {
        $root = Join-Path $TestDrive 'look-art-cursor-fail'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-CursorSchemeFixture -Root $root
        $facts = New-LookFacts
        Set-LookArtFacts -Facts $facts -Root $root
        Add-LookCursorFacts -Facts $facts -Root $root
        $facts.cursorValues['Arrow'] = 'C:\wrong\arrow.cur'
        $ctx = New-LookContext -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.cursors | Should -Be $false
        $result.evidence.theme | Should -Be $true
        $result.evidence.terminal | Should -Be $true
        $result.detail | Should -Be 'cursors'
    }

    It 'passes cursors as skipped when the host has no scheme' {
        $root = Join-Path $TestDrive 'look-art-no-scheme'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $facts = New-LookFacts
        Set-LookArtFacts -Facts $facts -Root $root
        $ctx = New-LookContext -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.ok | Should -Be $true
        $result.evidence.cursors | Should -Be 'skipped'
        $result.detail | Should -Be 'look ready'
    }

    It 'fails terminalArt alone when the icon hash differs' {
        $root = Join-Path $TestDrive 'look-art-terminal-fail'
        $iconDir = Join-Path $root 'assets\icons'
        $terminalDir = Join-Path $root 'assets\terminal'
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
        New-Item -ItemType Directory -Path $terminalDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'terminal.png'), [byte[]]@(9, 9, 9))
        [System.IO.File]::WriteAllBytes((Join-Path $terminalDir 'background.png'), [byte[]]@(8, 8, 8))
        $facts = New-LookFacts
        Set-LookArtFacts -Facts $facts -Root $root
        $facts.terminalIconHash = ('ab' * 32)
        $ctx = New-LookContext -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.terminalArt | Should -Be $false
        $result.evidence.terminal | Should -Be $true
        $result.evidence.cursors | Should -Be 'skipped'
        $result.detail | Should -Be 'terminalArt'
    }

    It 'fails shareShortcuts alone when a target differs' {
        $root = Join-Path $TestDrive 'look-art-shortcut-fail'
        $iconDir = Join-Path $root 'assets\icons'
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'folder-projects.ico'), [byte[]]@(3, 1))
        [System.IO.File]::WriteAllBytes((Join-Path $iconDir 'folder-docs.ico'), [byte[]]@(3, 2))
        $config = New-BlueprintConfig
        $config.Shares = @(
            @{ Name = 'projects'; HostPath = 'C:\share\projects'; Writable = $true; Mirror = $true },
            @{ Name = 'docs'; HostPath = 'C:\share\docs'; Writable = $false; Mirror = $false }
        )
        $facts = New-LookFacts -Config $config
        Set-LookArtFacts -Facts $facts -Root $root
        $facts.shareShortcuts = @(
            [pscustomobject]@{ name = 'projects'; target = 'C:\share\projects'; icon = 'C:\ProgramData\claude-house\look\folder-projects.ico,0' },
            [pscustomobject]@{ name = 'docs'; target = 'C:\wrong\docs'; icon = 'C:\ProgramData\claude-house\look\folder-docs.ico,0' }
        )
        $ctx = New-LookContext -Config $config -Facts $facts
        $ctx.RepoRoot = $root
        $result = & $script:lookCheck -Context $ctx
        $result.ok | Should -Be $false
        $result.evidence.shareShortcuts | Should -Be $false
        $result.evidence.theme | Should -Be $true
        $result.evidence.cursors | Should -Be 'skipped'
        $result.detail | Should -Be 'shareShortcuts'
    }

    It 'passes welcome when the guest page hash matches the blueprint page' {
        $config = New-BlueprintConfig
        $config.Shares = @(@{ Name = 'projects'; HostPath = 'C:\share\projects'; Writable = $true; Mirror = $true })
        $config.Rules = @{ Hooks = @('bounded-search') }
        $facts = New-LookFacts -Config $config
        $facts.welcomeHash | Should -Be (ConvertTo-HouseTextHash -Text (Format-HouseWelcomeHtml -Config $config))
        $result = & $script:lookCheck -Context (New-LookContext -Config $config -Facts $facts)
        $result.evidence.welcome | Should -Be $true
        $result.detail | Should -Not -Match 'welcome'
    }

    It 'fails welcome alone when the guest page hash differs' {
        $facts = New-LookFacts
        $facts.welcomeHash = ('ef' * 32)
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.ok | Should -Be $false
        $result.evidence.welcome | Should -Be $false
        $result.evidence.theme | Should -Be $true
        $result.evidence.shareShortcuts | Should -Be $true
        $result.detail | Should -Be 'welcome'
    }

    It 'fails welcome when the page was built from another blueprint' {
        $config = New-BlueprintConfig
        $config.Tools = @{ VSCode = $true }
        $facts = New-LookFacts
        $result = & $script:lookCheck -Context (New-LookContext -Config $config -Facts $facts)
        $result.evidence.welcome | Should -Be $false
        $result.detail | Should -Be 'welcome'
    }

    It 'fails welcome when the Start here shortcut is missing or points elsewhere' {
        $facts = New-LookFacts
        $facts.welcomeShortcutExists = $false
        $facts.welcomeShortcutTarget = ''
        $result = & $script:lookCheck -Context (New-LookContext -Facts $facts)
        $result.evidence.welcome | Should -Be $false
        $result.detail | Should -Be 'welcome'
        $facts2 = New-LookFacts
        $facts2.welcomeShortcutTarget = 'C:\Users\Public\index.html'
        $result2 = & $script:lookCheck -Context (New-LookContext -Facts $facts2)
        $result2.evidence.welcome | Should -Be $false
    }

    It 'keeps the rendered step 13 script block ASCII and free of placeholders' {
        $config = New-BlueprintConfig
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\13-look.md'))
        $rendered = Format-HousePage -Content $page -Config $config
        $blocks = @(Get-HouseScriptBlocks -Text $rendered)
        # Four small first-sign-in calls, then the one call that applies the look.
        $blocks.Count | Should -Be 5
        $blocks[4] | Should -Match 'WallpaperB64'
        $rendered.Contains('{{') | Should -Be $false
        $rendered | Should -Match 'light'
        foreach ($block in $blocks) {
            $block.Contains('{{') | Should -Be $false
            @($block.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        }
    }

    It 'signs the VM user in once before step 13 writes the look, and clears automatic sign-in in every case' {
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repo 'runbook\13-look.md'))
        $doAt = $page.IndexOf('## Do')
        $do = $page.Substring($doAt, $page.IndexOf('## Verify') - $doAt)
        $firstSignIn = $do.IndexOf('Active Setup\Installed Components')
        $firstSignIn | Should -BeGreaterThan -1
        $do.IndexOf('$WallpaperB64') | Should -BeGreaterThan $firstSignIn
        $do | Should -Match "'AutoLogonCount' -Type DWord -Value 1"
        # The password travels as an argument, never inside the script text, and is never printed.
        $do | Should -Match '\} -ArgumentList \$credential\.GetNetworkCredential\(\)\.Password'
        $do | Should -Not -Match '(?m)^\s*\$credential\.GetNetworkCredential\(\)\.Password\s*$'
        $finallyAt = $do.IndexOf('finally {')
        $finallyAt | Should -BeGreaterThan $firstSignIn
        $cleanup = $do.Substring($finallyAt, 600)
        $cleanup | Should -Match "Remove-ItemProperty -LiteralPath \`$key -Name 'DefaultPassword'"
        $cleanup | Should -Match "'AutoAdminLogon' -Value '0'"
        $page | Should -Match '(?m)^reboot: true'
    }

    It 'lists 15 steps with look at 13 and claude-login at 14' {
        $house = Join-Path $script:repo 'house.ps1'
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $house --json guide
        $LASTEXITCODE | Should -Be 0
        $json = @($output | Where-Object { $_ -match '\{' }) -join "`n" | ConvertFrom-Json
        @($json.steps).Count | Should -Be 15
        $json.steps[13].id | Should -Be 'look'
        $json.steps[13].order | Should -Be 13
        $json.steps[14].id | Should -Be 'claude-login'
        $json.steps[14].order | Should -Be 14
        $json.steps[14].requires | Should -Contain 'look'
    }
}

Describe 'console settings' {
    It 'sizes the console to 80 percent, on a multiple of 8, and never below 1366x768' {
        $large = Get-HouseConsoleSize -ScreenWidth 2560 -ScreenHeight 1440
        $large.Width | Should -Be 2048
        $large.Height | Should -Be 1152
        $hd = Get-HouseConsoleSize -ScreenWidth 1920 -ScreenHeight 1080
        $hd.Width | Should -Be 1536
        $hd.Height | Should -Be 864
        $floor = Get-HouseConsoleSize -ScreenWidth 1366 -ScreenHeight 768
        $floor.Width | Should -Be 1366
        $floor.Height | Should -Be 768
        $small = Get-HouseConsoleSize -ScreenWidth 1280 -ScreenHeight 720
        $small.Width | Should -Be 1366
        $small.Height | Should -Be 768
        ($large.Width % 8) | Should -Be 0
        ($large.Height % 8) | Should -Be 0
        ($hd.Width % 8) | Should -Be 0
        ($small.Height % 8) | Should -Be 0
    }

    It 'builds vmconnect XML with 16 settings and an escaped VM name' {
        $names = @(
            'AudioCaptureRedirectionMode',
            'EnablePrinterRedirection',
            'FullScreen',
            'SmartCardsRedirection',
            'RedirectedPnpDevices',
            'ClipboardRedirection',
            'DesktopSize',
            'VmServerName',
            'RedirectedUsbDevices',
            'SavedConfigExists',
            'UseAllMonitors',
            'AudioPlaybackRedirectionMode',
            'PrinterRedirection',
            'RedirectedDrives',
            'VmName',
            'SaveButtonChecked'
        )
        $xml = Format-HouseConsoleSettingsXml -Width 1600 -Height 900 -HostName 'HOST' -VmName 'A&B'
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xml)
        $nodes = @($doc.GetElementsByTagName('setting'))
        $nodes.Count | Should -Be 16
        for ($i = 0; $i -lt $names.Count; $i++) {
            $nodes[$i].GetAttribute('name') | Should -Be $names[$i]
        }
        $saved = @($nodes | Where-Object { $_.GetAttribute('name') -eq 'SavedConfigExists' })
        $saved[0].InnerText.Trim() | Should -Be 'True'
        $button = @($nodes | Where-Object { $_.GetAttribute('name') -eq 'SaveButtonChecked' })
        $button[0].InnerText.Trim() | Should -Be 'True'
        $vm = @($nodes | Where-Object { $_.GetAttribute('name') -eq 'VmName' })
        $vm[0].InnerText | Should -Be 'A&B'
        $xml.Contains('&amp;') | Should -Be $true
    }

    It 'does not write console settings when the file already exists' {
        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Get-VM' -Value ([scriptblock]::Create("[CmdletBinding()]`r`nparam(`$Name)")) -Force
        }
        InModuleScope House {
            Mock Get-VM { return [pscustomobject]@{ Id = [guid]'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' } }
            Mock Test-Path { return $true }
            Mock Set-HouseConsoleSettingsText { throw 'should not write' }
            $config = @{ House = @{ Name = 'FixtureHouse' } }
            $path = New-HouseConsoleSettings -Config $config
            $path | Should -Match 'vmconnect\.rdp\.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\.config'
            Should -Invoke Set-HouseConsoleSettingsText -Times 0
        }
    }
}

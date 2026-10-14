# claude-house blueprint.
# Copy to house.config.psd1 (git-ignored) and fill it in together with your agent.
# Never put passwords, tokens or keys in this file.
@{
    House = @{
        Name      = 'claude-house'
        Path      = 'C:\Hyper-V\claude-house'   # VM files (VHDX, config)
        IsoPath   = 'C:\ISO\Win11_English_x64.iso'
        ImageName = 'Windows 11 Pro'              # edition inside the ISO
        CpuCount  = 4
        MemoryGB  = 8                             # fixed, not dynamic; 8 is the comfortable minimum for Windows 11 with a browser and Claude Code
        DiskGB    = 80
        UserName  = 'claude'                      # local user inside the VM
        Locale    = 'en-US'
        TimeZone  = 'Pacific Standard Time'       # any id from Get-TimeZone -ListAvailable
    }

    # One gate: the only way the house reaches any network besides the host's shared folders.
    Network = @{
        SwitchName   = 'HouseNet'                 # internal switch, never NAT
        Subnet       = '172.31.250.0/24'          # secretscan:allow
        HostIP       = '172.31.250.1'             # secretscan:allow
        VmIP         = '172.31.250.2'             # secretscan:allow
        GatePort     = 3128                       # port the VM uses on HostIP
        ProxyAppPort = 7890                       # loopback port of the proxy app on the host
        ProxyMode    = 'Global'                   # Global (recommended) | Rule | Direct - how the proxy app connects
    }

    # Host folders shared into the house.
    # Mirror = $true makes the same host path resolve inside the VM.
    Shares = @(
        @{ Name = 'projects'; HostPath = 'D:\projects'; Writable = $true;  Mirror = $true }
        @{ Name = 'docs';     HostPath = 'D:\docs';     Writable = $false; Mirror = $true }
    )

    Tools = @{
        Python       = $true
        Node         = $true
        ClaudeDesktop = $true
        GitHubCli    = $true
        VSCode       = $true
    }

    Rules = @{
        Hooks = @('bounded-search', 'share-delete-guard', 'windows-guard')
    }

    # Warm light desktop in the guest. Theme is 'light' (default) or 'none'.
    Look = @{
        Theme = 'light'   # 'light' or 'none'
    }
}

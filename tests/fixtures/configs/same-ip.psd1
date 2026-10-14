@{
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
        VmIP         = '192.0.2.1'
        GatePort     = 3128
        ProxyAppPort = 7890
        ProxyMode    = 'Direct'
    }
    Shares = @()
    Tools = @{ Python = $false; Node = $false }
    Rules = @{ Hooks = @() }
}

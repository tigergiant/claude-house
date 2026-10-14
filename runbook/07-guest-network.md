---
id: guest-network
title: Point the house at the gate
order: 7
requires: [vm-online]
runs_on: guest
admin: true
reboot: false
human: false
---

## Purpose

Give the VM one static address, send its default route to the host, and make every proxy-aware program use the gate. The Windows taskbar will say "No internet". That is expected: Windows' own connectivity probe does not use the proxy. Name resolution for the internet happens inside the proxy app on the host, because the proxy receives host names.

## Before you start

The vm-online check must already pass. Open PowerShell as Administrator from the repository root. Show the script in Do to the human and wait for approval before running it. PowerShell Direct runs as the VM user, so the user-proxy writes land in that user's HKCU.

Values come from the blueprint: subnet `{{Network.Subnet}}`, host `{{Network.HostIP}}`, VM `{{Network.VmIP}}`, gate port `{{Network.GatePort}}`. The gate URL is `http://{{Network.HostIP}}:{{Network.GatePort}}`.

## Do

1. Configure the single Up adapter through PowerShell Direct. Hidden adapters count, so a VPN adapter cannot hide. Loopback does not count. DHCP is turned off before DNS is cleared, then the script reads the DNS list back and throws if anything remains.

```powershell
Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $vmIp = '{{Network.VmIP}}'
    $hostIp = '{{Network.HostIP}}'
    $gatePort = '{{Network.GatePort}}'
    $subnet = '{{Network.Subnet}}'
    if ($subnet -notmatch '/(\d{1,2})$') { throw 'Network.Subnet has no prefix length' }
    $prefix = [int]$Matches[1]
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object {
        $_.Status -eq 'Up' -and ([string]$_.Name -notmatch '(?i)loopback') -and ([string]$_.InterfaceDescription -notmatch '(?i)loopback')
    })
    if ($adapters.Count -ne 1) { throw 'expected exactly one Up adapter' }
    $index = [int]$adapters[0].ifIndex
    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceIndex $index -IPAddress $vmIp -PrefixLength $prefix -DefaultGateway $hostIp | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
    $servers = New-Object System.Collections.Generic.List[string]
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach ($row in $dns) {
        foreach ($server in @($row.ServerAddresses)) {
            if ($server) { $servers.Add([string]$server) }
        }
    }
    if ($servers.Count -ne 0) { throw 'DNS server list is not empty' }
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow
    $gateUrl = 'http://' + $hostIp + ':' + $gatePort
    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $gateUrl, 'Machine')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $gateUrl, 'Machine')
    [Environment]::SetEnvironmentVariable('NO_PROXY', ('localhost,127.0.0.1,' + $hostIp), 'Machine')
    & netsh.exe winhttp set proxy ("proxy-server=" + $hostIp + ':' + $gatePort) ("bypass-list=<local>;" + $hostIp)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -LiteralPath $key -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $key -Name ProxyServer -Value ($hostIp + ':' + $gatePort)
    Set-ItemProperty -LiteralPath $key -Name ProxyOverride -Value ('<local>;' + $hostIp)
}
```

## Verify

Run:

```powershell
house check guest-network
```

A pass looks like `PASS guest-network: guest network`. The taskbar can still say "No internet".

## If it fails

- **oneadapter:** More than one adapter is Up, or none is. Hidden adapters count and loopback does not. Remove the extra NIC, VPN or Wi-Fi passthrough in Hyper-V, then run Do again.
- **staticip:** The Up adapter does not have exactly `{{Network.VmIP}}` with the prefix from `{{Network.Subnet}}`. A DHCP address or an APIPA address (`169.254.x.x`) next to it fails this item. Run Do again so the DHCP address is removed.
- **gateway:** The only IPv4 default route is not via `{{Network.HostIP}}`. A second default route, or a route to anywhere else, fails this item. Run Do again. Do not add NAT on the host.
- **nodns:** The adapter still has an IPv4 DNS server. Run Do again. DNS for the internet belongs to the proxy app on the host.
- **firewall:** Domain, Private or Public is not enabled with inbound Block and outbound Allow. Run the firewall line in Do again.
- **envproxy:** Machine `HTTP_PROXY` or `HTTPS_PROXY` is not `http://{{Network.HostIP}}:{{Network.GatePort}}`, or `NO_PROXY` does not contain `{{Network.HostIP}}`. A trailing slash on the gate URL is fine. Run the environment lines in Do again.
- **winhttp:** WinHTTP is not `{{Network.HostIP}}:{{Network.GatePort}}` with `{{Network.HostIP}}` in the bypass list. Run the `netsh winhttp set proxy` line in Do again.
- **userproxy:** HKCU `ProxyEnable` is not 1, `ProxyServer` is not `{{Network.HostIP}}:{{Network.GatePort}}`, or `ProxyOverride` does not contain `{{Network.HostIP}}`. PowerShell Direct must run as the VM user. Run the HKCU lines in Do again.

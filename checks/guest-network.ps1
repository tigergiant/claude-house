param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/07-guest-network.md#if-it-fails'
$itemNames = @('oneadapter', 'staticip', 'gateway', 'nodns', 'firewall', 'envproxy', 'winhttp', 'userproxy')

function ConvertTo-GuestNetworkResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'guest-network'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-GuestNetworkEvidence {
    param(
        [bool]$OneAdapter,
        [bool]$StaticIp,
        [bool]$Gateway,
        [bool]$NoDns,
        [bool]$Firewall,
        [bool]$EnvProxy,
        [bool]$WinHttp,
        [bool]$UserProxy
    )
    return [pscustomobject]@{
        oneadapter = $OneAdapter
        staticip   = $StaticIp
        gateway    = $Gateway
        nodns      = $NoDns
        firewall   = $Firewall
        envproxy   = $EnvProxy
        winhttp    = $WinHttp
        userproxy  = $UserProxy
    }
}

function Get-GuestNetworkDetail {
    param(
        $Flags,
        [string[]]$Notes
    )
    $failing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $itemNames) {
        if (-not $Flags[$name]) { $failing.Add($name) }
    }
    $detail = 'guest network'
    if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($note in @($Notes)) {
        if ($note) { $clean.Add([string]$note) }
    }
    if ($clean.Count -gt 0) {
        $suffix = ($clean.ToArray() -join '; ')
        if ($failing.Count -eq 0) { $detail = $suffix }
        else { $detail = $detail + '; ' + $suffix }
    }
    return $detail
}

$empty = ConvertTo-GuestNetworkEvidence -OneAdapter $false -StaticIp $false -Gateway $false -NoDns $false -Firewall $false -EnvProxy $false -WinHttp $false -UserProxy $false
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-GuestNetworkResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$network = $config.Network
$subnet = [string]$network.Subnet
$hostIp = [string]$network.HostIP
$vmIp = [string]$network.VmIP
$gatePort = [int]$network.GatePort
$prefix = $null
if ($subnet -match '/(\d{1,2})$') {
    $parsedPrefix = [int]$Matches[1]
    if ($parsedPrefix -ge 1 -and $parsedPrefix -le 32) { $prefix = $parsedPrefix }
}
$gateUrl = 'http://' + $hostIp + ':' + [string]$gatePort

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-HouseGuestNetworkProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$oneadapter = $false
$staticip = $false
$gateway = $false
$nodns = $false
$firewall = $false
$envproxy = $false
$winhttp = $false
$userproxy = $false
$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add($guestError) }

if ($null -ne $guest) {
    $observedError = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observedError) { $notes.Add($observedError) }
    $adapters = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'adapters')
    $up = Get-HouseUpAdapters -Adapters $adapters
    $oneadapter = ($up.Count -eq 1)

    $addresses = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'addresses')
    $dnsRows = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'dns')
    if ($up.Count -eq 1 -and $null -ne $prefix) {
        $index = [string](Get-HousePropertyValue -Object $up[0] -Name 'InterfaceIndex')
        $ips = New-Object System.Collections.Generic.List[object]
        foreach ($address in $addresses) {
            if ([string](Get-HousePropertyValue -Object $address -Name 'InterfaceIndex') -ne $index) { continue }
            $ips.Add($address)
        }
        if ($ips.Count -eq 1) {
            $only = $ips[0]
            $ipText = [string](Get-HousePropertyValue -Object $only -Name 'IPAddress')
            $prefixText = 0
            $prefixOk = [int]::TryParse([string](Get-HousePropertyValue -Object $only -Name 'PrefixLength'), [ref]$prefixText)
            $staticip = $prefixOk -and ($ipText -eq $vmIp) -and ($prefixText -eq $prefix)
        }
        $servers = New-Object System.Collections.Generic.List[string]
        foreach ($dns in $dnsRows) {
            if ([string](Get-HousePropertyValue -Object $dns -Name 'InterfaceIndex') -ne $index) { continue }
            $rawServers = Get-HousePropertyValue -Object $dns -Name 'ServerAddresses'
            foreach ($server in (ConvertTo-HouseItemList -Value $rawServers)) {
                if ($server) { $servers.Add([string]$server) }
            }
        }
        $nodns = ($servers.Count -eq 0)
    }

    $routes = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'routes')
    $defaults = New-Object System.Collections.Generic.List[object]
    foreach ($route in $routes) {
        $dest = [string](Get-HousePropertyValue -Object $route -Name 'DestinationPrefix')
        if ($dest -eq '0.0.0.0/0') { $defaults.Add($route) }
    }
    if ($defaults.Count -eq 1) {
        $hop = [string](Get-HousePropertyValue -Object $defaults[0] -Name 'NextHop')
        $gateway = ($hop -eq $hostIp)
    }

    $profiles = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'firewall')
    $firewall = $true
    foreach ($profileName in @('Domain', 'Private', 'Public')) {
        $found = $null
        foreach ($profile in $profiles) {
            if ([string](Get-HousePropertyValue -Object $profile -Name 'Name') -eq $profileName) { $found = $profile; break }
        }
        if ($null -eq $found) { $firewall = $false; continue }
        $enabled = [string](Get-HousePropertyValue -Object $found -Name 'Enabled')
        $inbound = [string](Get-HousePropertyValue -Object $found -Name 'DefaultInboundAction')
        $outbound = [string](Get-HousePropertyValue -Object $found -Name 'DefaultOutboundAction')
        $enabledOk = ($enabled -eq 'True') -or ($enabled -eq '1')
        if (-not $enabledOk -or $inbound -ne 'Block' -or $outbound -ne 'Allow') { $firewall = $false }
    }

    $env = Get-HousePropertyValue -Object $guest -Name 'env'
    $httpProxy = [string](Get-HousePropertyValue -Object $env -Name 'HTTP_PROXY')
    $httpsProxy = [string](Get-HousePropertyValue -Object $env -Name 'HTTPS_PROXY')
    $noProxy = [string](Get-HousePropertyValue -Object $env -Name 'NO_PROXY')
    $envproxy = (Test-HouseSameGateUrl -Value $httpProxy -GateUrl $gateUrl) -and (Test-HouseSameGateUrl -Value $httpsProxy -GateUrl $gateUrl) -and (Test-HouseListToken -Text $noProxy -Token $hostIp)

    $winText = [string](Get-HousePropertyValue -Object $guest -Name 'winhttp')
    $winParsed = Test-HouseWinHttpProxy -Text $winText -HostIP $hostIp -GatePort $gatePort
    $winhttp = [bool]$winParsed.ok

    $user = Get-HousePropertyValue -Object $guest -Name 'userproxy'
    $enable = [string](Get-HousePropertyValue -Object $user -Name 'ProxyEnable')
    $server = [string](Get-HousePropertyValue -Object $user -Name 'ProxyServer')
    $override = [string](Get-HousePropertyValue -Object $user -Name 'ProxyOverride')
    $serverOk = ($server.Trim() -eq ($hostIp + ':' + [string]$gatePort))
    $userproxy = ($enable -eq '1') -and $serverOk -and (Test-HouseListToken -Text $override -Token $hostIp)
}

$flags = @{
    oneadapter = [bool]$oneadapter
    staticip   = [bool]$staticip
    gateway    = [bool]$gateway
    nodns      = [bool]$nodns
    firewall   = [bool]$firewall
    envproxy   = [bool]$envproxy
    winhttp    = [bool]$winhttp
    userproxy  = [bool]$userproxy
}
$evidence = ConvertTo-GuestNetworkEvidence -OneAdapter $oneadapter -StaticIp $staticip -Gateway $gateway -NoDns $nodns -Firewall $firewall -EnvProxy $envproxy -WinHttp $winhttp -UserProxy $userproxy
$detail = Get-GuestNetworkDetail -Flags $flags -Notes @($notes.ToArray())
$ok = $true
foreach ($name in $itemNames) {
    if (-not $flags[$name]) { $ok = $false }
}
return (ConvertTo-GuestNetworkResult -Ok $ok -Detail $detail -Evidence $evidence)

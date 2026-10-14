param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

# Known false positive: connecting from the host itself to HostIP:GatePort succeeds
# through Windows loopback even when the VM could not reach it. This check must not
# use a host-side connection to HostIP:GatePort as proof. The VM-side proof comes in step 8.

$fix = 'runbook/03-gate.md#if-it-fails'

function ConvertTo-GateResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'gate'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-GateEvidence {
    param(
        [bool]$ProxyApp,
        $ProxyProcess,
        [bool]$LanExposed,
        [bool]$IpHelp,
        [bool]$PortProxy,
        [bool]$Firewall,
        [bool]$Upstream,
        $UpstreamStatus
    )
    return [pscustomobject]@{
        proxyapp       = $ProxyApp
        proxyProcess   = $ProxyProcess
        lanExposed     = $LanExposed
        iphlpsvc       = $IpHelp
        portproxy      = $PortProxy
        firewall       = $Firewall
        upstream       = $Upstream
        upstreamStatus = $UpstreamStatus
    }
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-GateResult -Ok $false -Detail 'blueprint not loaded' -Evidence (ConvertTo-GateEvidence -ProxyApp $false -ProxyProcess $null -LanExposed $false -IpHelp $false -PortProxy $false -Firewall $false -Upstream $false -UpstreamStatus $null))
}

$network = $config.Network
$proxyPort = [int]$network.ProxyAppPort
$gatePort = [int]$network.GatePort
$hostIp = [string]$network.HostIP
$vmIp = [string]$network.VmIP

$proxyapp = $false
$lanExposed = $false
$proxyProcess = $null
$ownerId = $null
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $proxyPort -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
foreach ($listener in $listeners) {
    $local = [string]$listener.LocalAddress
    if ($local.StartsWith('[') -and $local.EndsWith(']') -and $local.Length -ge 2) {
        $local = $local.Substring(1, $local.Length - 2)
    }
    $accepted = @('127.0.0.1', '0.0.0.0', '::', '::1') -contains $local
    if (-not $accepted) { continue }
    $proxyapp = $true
    if ($local -eq '0.0.0.0' -or $local -eq '::') { $lanExposed = $true }
    if ($null -eq $ownerId -and $null -ne $listener.OwningProcess) { $ownerId = [int]$listener.OwningProcess }
}
if ($null -ne $ownerId) {
    $process = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
    if ($null -ne $process) { $proxyProcess = [string]$process.ProcessName }
}

$iphlpsvc = $false
$service = Get-Service -Name iphlpsvc -ErrorAction SilentlyContinue
if ($null -ne $service -and [string]$service.Status -eq 'Running') { $iphlpsvc = $true }

$portproxy = $false
$rows = @(ConvertFrom-HousePortProxyTable -Text (Get-HousePortProxyText))
foreach ($row in $rows) {
    if ($null -eq $row) { continue }
    $listenOk = [string]$row.ListenAddress -eq $hostIp
    $listenPortOk = [string]$row.ListenPort -eq [string]$gatePort
    $connectOk = [string]$row.ConnectAddress -eq '127.0.0.1'
    $connectPortOk = [string]$row.ConnectPort -eq [string]$proxyPort
    if ($listenOk -and $listenPortOk -and $connectOk -and $connectPortOk) { $portproxy = $true }
}

$firewall = $false
$rules = @(Get-NetFirewallRule -DisplayName "claude-house gate" -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
foreach ($rule in $rules) {
    $enabledText = [string]$rule.Enabled
    $enabled = ($rule.Enabled -eq $true) -or ($enabledText -eq 'True')
    if (-not $enabled) { continue }
    if ([string]$rule.Direction -ne 'Inbound') { continue }
    if ([string]$rule.Action -ne 'Allow') { continue }
    $addressFilters = @(Get-HouseFirewallAddressFilter -Rule $rule | Where-Object { $null -ne $_ })
    $portFilters = @(Get-HouseFirewallPortFilter -Rule $rule | Where-Object { $null -ne $_ })
    foreach ($addressFilter in $addressFilters) {
        if ([string]$addressFilter.LocalAddress -ne $hostIp) { continue }
        if ([string]$addressFilter.RemoteAddress -ne $vmIp) { continue }
        foreach ($portFilter in $portFilters) {
            $protocol = [string]$portFilter.Protocol
            $protocolOk = ($protocol -eq 'TCP') -or ($protocol -eq '6')
            if (-not $protocolOk) { continue }
            if ([string]$portFilter.LocalPort -ne [string]$gatePort) { continue }
            $firewall = $true
        }
    }
}

$upstream = $false
$upstreamStatus = $null
$proxyUrl = 'http://127.0.0.1:' + [string]$proxyPort
try {
    $response = Invoke-WebRequest -Uri 'https://api.anthropic.com' -Proxy $proxyUrl -Method Head -UseBasicParsing -TimeoutSec 15
    $upstream = $true
    if ($null -ne $response -and $null -ne $response.StatusCode) {
        $upstreamStatus = [int]$response.StatusCode
    }
}
catch {
    $web = $null
    $current = $_.Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.WebException]) { $web = $current; break }
        if ($null -eq $current.InnerException) { break }
        $current = $current.InnerException
    }
    if ($null -ne $web -and $null -ne $web.Response) {
        $upstream = $true
        if ($null -ne $web.Response.StatusCode) { $upstreamStatus = [int]$web.Response.StatusCode }
    }
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $proxyapp) { $failing.Add('proxyapp') }
if (-not $iphlpsvc) { $failing.Add('iphlpsvc') }
if (-not $portproxy) { $failing.Add('portproxy') }
if (-not $firewall) { $failing.Add('firewall') }
if (-not $upstream) { $failing.Add('upstream') }

$detail = 'gate open'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
if ($lanExposed) { $detail = $detail + '; warning: proxy app listens on all interfaces (LAN exposed)' }

return (ConvertTo-GateResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-GateEvidence -ProxyApp $proxyapp -ProxyProcess $proxyProcess -LanExposed $lanExposed -IpHelp $iphlpsvc -PortProxy $portproxy -Firewall $firewall -Upstream $upstream -UpstreamStatus $upstreamStatus))

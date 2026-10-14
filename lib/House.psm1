Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HouseRepoRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function ConvertTo-HouseIpv4UInt64 {
    param([string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    $octets = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
    foreach ($octet in $octets) {
        if ($octet -lt 0 -or $octet -gt 255) { return $null }
    }
    return ([uint64]$octets[0] * 16777216) + ([uint64]$octets[1] * 65536) + ([uint64]$octets[2] * 256) + [uint64]$octets[3]
}

function Get-HouseIpv4Mask {
    param([int]$Prefix)
    if ($Prefix -le 0) { return [uint64]0 }
    if ($Prefix -gt 32) { $Prefix = 32 }
    $mask = [uint64]0
    for ($i = 0; $i -lt $Prefix; $i++) {
        $mask = $mask + [uint64]([math]::Pow(2, 31 - $i))
    }
    return $mask
}

function Get-HouseIpv4Range {
    param(
        [uint64]$IpValue,
        [int]$Prefix
    )
    if ($Prefix -lt 0 -or $Prefix -gt 32) { return $null }
    $mask = Get-HouseIpv4Mask -Prefix $Prefix
    $start = $IpValue -band $mask
    $size = [uint64]([math]::Pow(2, 32 - $Prefix))
    $end = ($start + $size) - 1
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Test-HouseIpv4InCidr {
    param(
        [string]$Ip,
        [string]$Cidr
    )
    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { return $false }
    $networkIp = ConvertTo-HouseIpv4UInt64 -Ip $Matches[1]
    $address = ConvertTo-HouseIpv4UInt64 -Ip $Ip
    $prefix = [int]$Matches[2]
    if ($null -eq $networkIp -or $null -eq $address -or $prefix -gt 32) { return $false }
    $range = Get-HouseIpv4Range -IpValue $networkIp -Prefix $prefix
    if ($null -eq $range) { return $false }
    return ($address -ge $range.Start -and $address -le $range.End)
}

function Test-HouseCidrOverlap {
    param(
        [string]$LeftCidr,
        [string]$RightIp,
        [int]$RightPrefix
    )
    if ($LeftCidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { return $false }
    $leftIp = ConvertTo-HouseIpv4UInt64 -Ip $Matches[1]
    $leftPrefix = [int]$Matches[2]
    $rightValue = ConvertTo-HouseIpv4UInt64 -Ip $RightIp
    if ($null -eq $leftIp -or $null -eq $rightValue -or $leftPrefix -gt 32 -or $RightPrefix -lt 0 -or $RightPrefix -gt 32) {
        return $false
    }
    $left = Get-HouseIpv4Range -IpValue $leftIp -Prefix $leftPrefix
    $right = Get-HouseIpv4Range -IpValue $rightValue -Prefix $RightPrefix
    if ($null -eq $left -or $null -eq $right) { return $false }
    return ($left.Start -le $right.End -and $right.Start -le $left.End)
}

function ConvertFrom-HousePortProxyTable {
    param([string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }
    $lines = $Text -split "`r?`n", 0
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        if ($trim -match '^[\s\-]+$') { continue }
        $parts = @($trim -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 4) { continue }
        $listenAddress = [string]$parts[0]
        $connectAddress = [string]$parts[2]
        if ($listenAddress -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { continue }
        if ($connectAddress -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { continue }
        $listenPort = 0
        $connectPort = 0
        $listenParsed = [int]::TryParse([string]$parts[1], [ref]$listenPort)
        $connectParsed = [int]::TryParse([string]$parts[3], [ref]$connectPort)
        if (-not $listenParsed -or -not $connectParsed) { continue }
        $rows.Add([pscustomobject]@{
            ListenAddress  = $listenAddress
            ListenPort     = $listenPort
            ConnectAddress = $connectAddress
            ConnectPort    = $connectPort
        })
    }
    return @($rows.ToArray())
}

function Get-HouseFirewallAddressFilter {
    param($Rule)
    return Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule
}

function Get-HouseFirewallPortFilter {
    param($Rule)
    return Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule
}

function Get-HousePortProxyText {
    $captured = & netsh.exe interface portproxy show v4tov4 | Out-String
    if ($null -eq $captured) { return '' }
    return [string]$captured
}

function Get-HousePropertyValue {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object -or -not $Name) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ConvertTo-HouseItemList {
    param($Value)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Value) {
        $many = ($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])
        if ($many) {
            foreach ($item in $Value) {
                if ($null -ne $item) { $list.Add($item) }
            }
        }
        else {
            $list.Add($Value)
        }
    }
    # A List stays one object. Wrapping it in @() throws on Windows PowerShell 5.1.
    return ,$list
}

function Test-HouseAdapterLoopback {
    param($Adapter)
    $flag = Get-HousePropertyValue -Object $Adapter -Name 'Loopback'
    if ($flag -eq $true) { return $true }
    if ([string]$flag -eq 'True') { return $true }
    $name = [string](Get-HousePropertyValue -Object $Adapter -Name 'Name')
    $desc = [string](Get-HousePropertyValue -Object $Adapter -Name 'InterfaceDescription')
    if ($name -match '(?i)loopback') { return $true }
    if ($desc -match '(?i)loopback') { return $true }
    return $false
}

function Get-HouseUpAdapters {
    param($Adapters)
    # Hidden adapters stay in the count. A Wintun/Tailscale adapter must not disappear.
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in (ConvertTo-HouseItemList -Value $Adapters)) {
        if ($null -eq $adapter) { continue }
        $status = [string](Get-HousePropertyValue -Object $adapter -Name 'Status')
        if ($status -ne 'Up') { continue }
        if (Test-HouseAdapterLoopback -Adapter $adapter) { continue }
        $list.Add($adapter)
    }
    return ,$list
}

function Test-HouseWinHttpProxy {
    param(
        [string]$Text,
        [string]$HostIP,
        [int]$GatePort
    )
    $proxy = $false
    $bypass = $false
    if ($Text -and $HostIP) {
        $proxyEndpoint = '{0}:{1}' -f $HostIP, $GatePort
        $proxyPattern = [regex]::Escape($proxyEndpoint)
        $proxy = [regex]::IsMatch($Text, $proxyPattern)
        $rest = [regex]::Replace($Text, $proxyPattern, '')
        $ipPattern = '(?<![0-9])' + [regex]::Escape($HostIP) + '(?![0-9])'
        $bypass = [regex]::IsMatch($rest, $ipPattern)
    }
    return [pscustomobject]@{
        proxy  = [bool]$proxy
        bypass = [bool]$bypass
        ok     = ([bool]($proxy -and $bypass))
    }
}

function Test-HouseSameGateUrl {
    param(
        [string]$Value,
        [string]$GateUrl
    )
    if (-not $Value -or -not $GateUrl) { return $false }
    $left = $Value.Trim().TrimEnd('/')
    $right = $GateUrl.Trim().TrimEnd('/')
    return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HouseListToken {
    param(
        [string]$Text,
        [string]$Token
    )
    if (-not $Text -or -not $Token) { return $false }
    $parts = $Text.Split(@(',', ';', ' '), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($part in $parts) {
        if ([string]::Equals($part.Trim(), $Token, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function ConvertTo-HouseTcpProbeOutcome {
    param(
        [string]$Target,
        [bool]$Connected,
        [bool]$TimedOut,
        $ErrorRecord
    )
    # Connected is a leak. A timeout, or one of the four unreachable socket codes, is blocked.
    # Every other exception is probe-error so a broken probe cannot pass.
    if ($Connected) {
        return [pscustomobject]@{ target = $Target; outcome = 'connected'; error = $null }
    }
    if ($TimedOut) {
        return [pscustomobject]@{ target = $Target; outcome = 'blocked'; error = 'timeout' }
    }
    $socket = $null
    $current = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $current = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [System.Exception]) { $current = $ErrorRecord }
    while ($null -ne $current) {
        if ($current -is [System.Net.Sockets.SocketException]) { $socket = $current; break }
        $current = $current.InnerException
    }
    if ($null -ne $socket) {
        $code = [string]$socket.SocketErrorCode
        $known = @('NetworkUnreachable', 'HostUnreachable', 'TimedOut', 'ConnectionRefused', '10051', '10065', '10060', '10061')
        if ($known -contains $code) {
            return [pscustomobject]@{ target = $Target; outcome = 'blocked'; error = $code }
        }
    }
    $message = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord] -and $null -ne $ErrorRecord.Exception) {
        $message = [string]$ErrorRecord.Exception.Message
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $message = [string]$ErrorRecord.Message
    }
    elseif ($null -ne $ErrorRecord) {
        $message = [string]$ErrorRecord
    }
    if (-not $message) { $message = 'unclassified tcp failure' }
    return [pscustomobject]@{ target = $Target; outcome = 'probe-error'; error = $message }
}

function ConvertTo-HouseDnsProbeOutcome {
    param(
        [string]$Target,
        $Answer,
        $ErrorRecord
    )
    $answered = $false
    if ($null -ne $Answer) {
        foreach ($item in @($Answer)) {
            if ($null -ne $item) { $answered = $true; break }
        }
    }
    $message = ''
    $category = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ($null -ne $ErrorRecord.Exception) { $message = [string]$ErrorRecord.Exception.Message }
        if ($null -ne $ErrorRecord.CategoryInfo) { $category = [string]$ErrorRecord.CategoryInfo.Category }
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $message = [string]$ErrorRecord.Message
    }
    elseif ($null -ne $ErrorRecord) {
        $message = [string]$ErrorRecord
    }
    if ($answered) {
        return [pscustomobject]@{ target = $Target; outcome = 'answered'; error = $null; category = $category }
    }
    $blob = $message + ' ' + $category
    $blocked = $false
    # Messages are localized; Win32 codes are not. 1460 timeout, 9002 server failure,
    # 9852 no DNS servers configured, 10060 socket timeout.
    $native = $null
    $current = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $current = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [System.Exception]) { $current = $ErrorRecord }
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception]) { $native = [int]$current.NativeErrorCode; break }
        $current = $current.InnerException
    }
    if (@(1460, 9002, 9852, 10060) -contains $native) { $blocked = $true }
    if ($blob -match '(?i)timeout|timed out|operationtimeout') { $blocked = $true }
    if ($blob -match '(?i)no DNS servers') { $blocked = $true }
    if ($blob -match '(?i)server failure') { $blocked = $true }
    if ($blocked) {
        return [pscustomobject]@{ target = $Target; outcome = 'blocked'; error = $message; category = $category }
    }
    if (-not $message) { $message = 'unclassified dns failure' }
    return [pscustomobject]@{ target = $Target; outcome = 'probe-error'; error = $message; category = $category }
}

function ConvertTo-HouseGateProbeOutcome {
    param(
        $Response,
        $ErrorRecord
    )
    $status = $null
    if ($null -ne $Response) {
        $statusProp = $Response.PSObject.Properties['StatusCode']
        if ($null -ne $statusProp -and $null -ne $statusProp.Value -and [string]$statusProp.Value -ne '') {
            $parsedStatus = 0
            if ([int]::TryParse([string]$statusProp.Value, [ref]$parsedStatus)) {
                $status = $parsedStatus
            }
            else {
                try { $status = [int]$statusProp.Value } catch { $status = $null }
            }
        }
    }
    if ($null -ne $status) {
        return [pscustomobject]@{ target = 'https://api.anthropic.com'; reached = $true; status = [int]$status; error = $null }
    }
    $web = $null
    $current = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $current = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [System.Exception]) { $current = $ErrorRecord }
    while ($null -ne $current) {
        if ($current -is [System.Net.WebException]) { $web = $current; break }
        $current = $current.InnerException
    }
    if ($null -ne $web -and $null -ne $web.Response) {
        $responseStatus = $null
        $prop = $web.Response.PSObject.Properties['StatusCode']
        if ($null -ne $prop) { $responseStatus = $prop.Value }
        if ($null -ne $responseStatus) {
            $parsedStatus = 0
            $parsedOk = [int]::TryParse([string]$responseStatus, [ref]$parsedStatus)
            if (-not $parsedOk) {
                try { $parsedStatus = [int]$responseStatus; $parsedOk = $true } catch { $parsedOk = $false }
            }
            if ($parsedOk) {
                return [pscustomobject]@{ target = 'https://api.anthropic.com'; reached = $true; status = [int]$parsedStatus; error = $null }
            }
        }
    }
    $message = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord] -and $null -ne $ErrorRecord.Exception) {
        $message = [string]$ErrorRecord.Exception.Message
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $message = [string]$ErrorRecord.Message
    }
    elseif ($null -ne $ErrorRecord) {
        $message = [string]$ErrorRecord
    }
    if (-not $message) { $message = 'gate connection failed' }
    return [pscustomobject]@{ target = 'https://api.anthropic.com'; reached = $false; status = $null; error = $message }
}

function ConvertTo-HouseWriteProbeOutcome {
    param(
        [bool]$Succeeded,
        $ErrorRecord
    )
    # A completed write is success. Access denied is the read-only proof.
    # Every other failure is probe-error so a broken probe cannot pass.
    if ($Succeeded) {
        return [pscustomobject]@{ outcome = 'success'; error = $null }
    }
    $message = ''
    $current = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ($null -ne $ErrorRecord.Exception) {
            $message = [string]$ErrorRecord.Exception.Message
            $current = $ErrorRecord.Exception
        }
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $message = [string]$ErrorRecord.Message
        $current = $ErrorRecord
    }
    elseif ($null -ne $ErrorRecord) {
        $message = [string]$ErrorRecord
    }
    $denied = $false
    while ($null -ne $current) {
        if ($current -is [System.UnauthorizedAccessException]) { $denied = $true }
        if ($current -is [System.ComponentModel.Win32Exception] -and [int]$current.NativeErrorCode -eq 5) { $denied = $true }
        $hresultProp = $current.PSObject.Properties['HResult']
        if ($null -ne $hresultProp -and $null -ne $hresultProp.Value) {
            $hresult = 0
            if ([int]::TryParse([string]$hresultProp.Value, [ref]$hresult) -and $hresult -eq -2147024891) { $denied = $true }
        }
        $text = [string]$current.Message
        if ($text -match '(?i)access is denied|access denied|unauthorized') { $denied = $true }
        if ($null -eq $current.InnerException) { break }
        $current = $current.InnerException
    }
    if (-not $denied -and $message -match '(?i)access is denied|access denied|unauthorized') { $denied = $true }
    if ($denied) {
        return [pscustomobject]@{ outcome = 'access-denied'; error = $message }
    }
    if (-not $message) { $message = 'unrecognised write failure' }
    return [pscustomobject]@{ outcome = 'probe-error'; error = $message }
}

function Test-HousePathIsUnder {
    param(
        [string]$Path,
        [string]$Root
    )
    if (-not $Path -or -not $Root) { return $false }
    $left = $Path.Trim().TrimEnd('\')
    $right = $Root.Trim().TrimEnd('\')
    if ([string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $left.StartsWith($right + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HouseForbiddenMirrorPath {
    param(
        [string]$HostPath,
        [string]$UserName
    )
    if ([string]::IsNullOrWhiteSpace($HostPath)) { return 'mirror refused: mirror path is empty' }
    $trimmed = $HostPath.Trim()
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) { return 'mirror refused: mirror path must be absolute' }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($trimmed) }
    catch { return 'mirror refused: mirror path is not usable' }
    $normal = $full.TrimEnd('\')
    if ($normal -match '^[A-Za-z]:$') {
        return ('mirror refused: ' + $normal + '\ is a drive root')
    }
    $user = [string]$UserName
    if ($user.Trim()) {
        $profile = 'C:\Users\' + $user.Trim()
        if (Test-HousePathIsUnder -Path $normal -Root $profile) {
            return ('mirror refused: ' + $normal + ' is inside the VM user profile')
        }
        # A mirror replaces its last folder with a link, so a parent of the profile is just as bad.
        if (Test-HousePathIsUnder -Path $profile -Root $normal) {
            return ('mirror refused: ' + $normal + ' contains the VM user profile')
        }
    }
    foreach ($system in 'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)') {
        if (Test-HousePathIsUnder -Path $system -Root $normal) {
            return ('mirror refused: ' + $normal + ' contains ' + $system)
        }
    }
    if (Test-HousePathIsUnder -Path $normal -Root 'C:\Windows') {
        return ('mirror refused: ' + $normal + ' is inside Windows')
    }
    $lower = $normal.ToLowerInvariant()
    if ($lower.StartsWith('c:\program files')) {
        return ('mirror refused: ' + $normal + ' is inside Program Files')
    }
    return $null
}

function Get-HouseGuestObservationText {
    return @'
$adapterRows = New-Object System.Collections.Generic.List[object]
$addressRows = New-Object System.Collections.Generic.List[object]
$routeRows = New-Object System.Collections.Generic.List[object]
$dnsRows = New-Object System.Collections.Generic.List[object]
$firewallRows = New-Object System.Collections.Generic.List[object]
$observedError = $null
try {
    $rawAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    foreach ($adapter in $rawAdapters) {
        if ($null -eq $adapter) { continue }
        $adapterName = [string]$adapter.Name
        $adapterDescription = [string]$adapter.InterfaceDescription
        $loopback = $false
        if ($adapterName -match '(?i)loopback' -or $adapterDescription -match '(?i)loopback') { $loopback = $true }
        $hidden = $false
        $hiddenProp = $adapter.PSObject.Properties['Hidden']
        if ($null -ne $hiddenProp -and $hiddenProp.Value) { $hidden = $true }
        $adapterRows.Add([pscustomobject]@{
            Name = $adapterName
            InterfaceDescription = $adapterDescription
            Status = [string]$adapter.Status
            Hidden = [bool]$hidden
            Loopback = [bool]$loopback
            InterfaceIndex = [int]$adapter.ifIndex
        })
    }
    $rawAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach ($address in $rawAddresses) {
        if ($null -eq $address) { continue }
        $addressRows.Add([pscustomobject]@{
            InterfaceIndex = [int]$address.InterfaceIndex
            IPAddress = [string]$address.IPAddress
            PrefixLength = [int]$address.PrefixLength
        })
    }
    $rawRoutes = @()
    try {
        $rawRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    }
    catch {
        $rawRoutes = @()
    }
    foreach ($route in $rawRoutes) {
        if ($null -eq $route) { continue }
        $routeRows.Add([pscustomobject]@{
            DestinationPrefix = [string]$route.DestinationPrefix
            NextHop = [string]$route.NextHop
            InterfaceIndex = [int]$route.InterfaceIndex
        })
    }
    $rawDns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach ($dns in $rawDns) {
        if ($null -eq $dns) { continue }
        $servers = New-Object System.Collections.Generic.List[string]
        foreach ($server in @($dns.ServerAddresses)) {
            if ($server) { $servers.Add([string]$server) }
        }
        $dnsRows.Add([pscustomobject]@{
            InterfaceIndex = [int]$dns.InterfaceIndex
            ServerAddresses = @($servers.ToArray())
        })
    }
    $rawProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    foreach ($profile in $rawProfiles) {
        if ($null -eq $profile) { continue }
        $firewallRows.Add([pscustomobject]@{
            Name = [string]$profile.Name
            Enabled = [string]$profile.Enabled
            DefaultInboundAction = [string]$profile.DefaultInboundAction
            DefaultOutboundAction = [string]$profile.DefaultOutboundAction
        })
    }
}
catch {
    $observedError = [string]$_.Exception.Message
    if (-not $observedError) { $observedError = [string]$_ }
}
$winhttp = ''
try {
    $winhttp = [string](& netsh.exe winhttp show proxy | Out-String)
}
catch {
    if (-not $observedError) {
        $observedError = [string]$_.Exception.Message
        if (-not $observedError) { $observedError = [string]$_ }
    }
}
$httpProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Machine')
$httpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')
$noProxy = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Machine')
$userEnable = $null
$userServer = $null
$userOverride = $null
try {
    $userKey = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($null -ne $userKey) {
        $enableProp = $userKey.PSObject.Properties['ProxyEnable']
        $serverProp = $userKey.PSObject.Properties['ProxyServer']
        $overrideProp = $userKey.PSObject.Properties['ProxyOverride']
        if ($null -ne $enableProp) { $userEnable = $enableProp.Value }
        if ($null -ne $serverProp) { $userServer = [string]$serverProp.Value }
        if ($null -ne $overrideProp) { $userOverride = [string]$overrideProp.Value }
    }
}
catch {
    if (-not $observedError) {
        $observedError = [string]$_.Exception.Message
        if (-not $observedError) { $observedError = [string]$_ }
    }
}
$HouseSnap = [pscustomobject]@{
    adapters = @($adapterRows.ToArray())
    addresses = @($addressRows.ToArray())
    routes = @($routeRows.ToArray())
    dns = @($dnsRows.ToArray())
    firewall = @($firewallRows.ToArray())
    env = [pscustomobject]@{
        HTTP_PROXY = [string]$httpProxy
        HTTPS_PROXY = [string]$httpsProxy
        NO_PROXY = [string]$noProxy
    }
    winhttp = [string]$winhttp
    userproxy = [pscustomobject]@{
        ProxyEnable = $userEnable
        ProxyServer = [string]$userServer
        ProxyOverride = [string]$userOverride
    }
    error = $observedError
}
'@
}

function Get-HouseGuestNetworkProbe {
    $text = " `$ErrorActionPreference = 'Stop'`r`n" + (Get-HouseGuestObservationText) + "`r`n`$HouseSnap`r`n"
    return [scriptblock]::Create($text)
}

function Get-HouseOneWayProbeBody {
    return @'
$ErrorActionPreference = 'Stop'
$tcpProbes = New-Object System.Collections.Generic.List[object]
foreach ($targetName in @('1.1.1.1:443', '9.9.9.9:443', '1.1.1.1:53', '9.9.9.9:53')) {
    $targetIp = ($targetName -split ':')[0]
    $targetPort = [int](($targetName -split ':')[1])
    $client = $null
    $connected = $false
    $timedOut = $false
    $tcpError = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $parsedIp = [System.Net.IPAddress]::Parse($targetIp)
        $async = $client.BeginConnect($parsedIp, $targetPort, $null, $null)
        $signaled = $async.AsyncWaitHandle.WaitOne(3000)
        if (-not $signaled) {
            $timedOut = $true
        }
        else {
            try {
                $client.EndConnect($async)
                $connected = $true
            }
            catch {
                $tcpError = $_
            }
        }
    }
    catch {
        $tcpError = $_
    }
    finally {
        if ($null -ne $client) {
            try { $client.Close() } catch { $null = $_ }
        }
    }
    $null = $tcpProbes.Add((ConvertTo-HouseTcpProbeOutcome -Target $targetName -Connected $connected -TimedOut $timedOut -ErrorRecord $tcpError))
}
$dnsProbes = New-Object System.Collections.Generic.List[object]
foreach ($specTarget in @('example.com', 'example.com@1.1.1.1')) {
    $answer = $null
    $dnsError = $null
    try {
        if ($specTarget -eq 'example.com@1.1.1.1') {
            $answer = @(Resolve-DnsName -Name 'example.com' -Server '1.1.1.1' -DnsOnly -QuickTimeout -ErrorAction Stop)
        }
        else {
            $answer = @(Resolve-DnsName -Name 'example.com' -DnsOnly -QuickTimeout -ErrorAction Stop)
        }
    }
    catch {
        $dnsError = $_
        $answer = $null
    }
    $null = $dnsProbes.Add((ConvertTo-HouseDnsProbeOutcome -Target $specTarget -Answer $answer -ErrorRecord $dnsError))
}
$gateResponse = $null
$gateError = $null
try {
    $gateResponse = Invoke-WebRequest -Uri 'https://api.anthropic.com' -Proxy $GateUrl -UseBasicParsing -TimeoutSec 15
}
catch {
    $gateError = $_
    $gateResponse = $null
}
$gateProbe = ConvertTo-HouseGateProbeOutcome -Response $gateResponse -ErrorRecord $gateError
'@
}

function Get-HouseOneWayOutProbe {
    $tcp = ${function:ConvertTo-HouseTcpProbeOutcome}.ToString()
    $dns = ${function:ConvertTo-HouseDnsProbeOutcome}.ToString()
    $gateFn = ${function:ConvertTo-HouseGateProbeOutcome}.ToString()
    $text = "param([string]`$GateUrl)`r`n"
    $text += "function ConvertTo-HouseTcpProbeOutcome {`r`n" + $tcp + "`r`n}`r`n"
    $text += "function ConvertTo-HouseDnsProbeOutcome {`r`n" + $dns + "`r`n}`r`n"
    $text += "function ConvertTo-HouseGateProbeOutcome {`r`n" + $gateFn + "`r`n}`r`n"
    $text += (Get-HouseOneWayProbeBody) + "`r`n"
    $text += (Get-HouseGuestObservationText) + "`r`n"
    $text += @'
[pscustomobject]@{
    tcp = @($tcpProbes.ToArray())
    dns = @($dnsProbes.ToArray())
    adapters = @($HouseSnap.adapters)
    routes = @($HouseSnap.routes)
    gate = $gateProbe
    error = $HouseSnap.error
}
'@
    return [scriptblock]::Create($text)
}

function Test-HouseElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HouseHyperVSkus {
    return [int[]](4, 27, 48, 49, 121, 122, 125, 126, 161, 162, 175, 188, 191)
}

function Test-HouseHyperVEdition {
    param($Sku, $Build)
    $skuValue = 0
    $buildValue = 0
    [void][int]::TryParse([string]$Sku, [ref]$skuValue)
    [void][int]::TryParse([string]$Build, [ref]$buildValue)
    return (($buildValue -ge 22000) -and (@(Get-HouseHyperVSkus) -contains $skuValue))
}

function Test-HouseHomeEdition {
    param($Sku)
    $skuValue = 0
    [void][int]::TryParse([string]$Sku, [ref]$skuValue)
    return ($skuValue -eq 100 -or $skuValue -eq 101)
}

function Test-HouseNestedComputer {
    param(
        [string]$Model,
        [string]$Manufacturer
    )
    # One list. A trailing * is a prefix wildcard (VMware*, Parallels*).
    $patterns = @(
        'Virtual Machine',
        'VMware*',
        'VirtualBox',
        'innotek',
        'QEMU',
        'KVM',
        'Xen',
        'Parallels*',
        'Amazon EC2',
        'Google Compute Engine'
    )
    foreach ($value in @($Model, $Manufacturer)) {
        if ([string]::IsNullOrEmpty($value)) { continue }
        foreach ($pattern in $patterns) {
            $token = [string]$pattern
            if ($token.EndsWith('*')) { $token = $token.Substring(0, $token.Length - 1) }
            if ($token.Length -eq 0) { continue }
            if ($value.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Format-HouseGigabytes {
    param([int64]$Bytes)
    if ($Bytes -lt 0) { $Bytes = 0 }
    $whole = [math]::Round($Bytes / 1GB, 2)
    $rounded = [math]::Round($whole, 0)
    if ([math]::Abs($whole - $rounded) -lt 0.001) {
        return ('{0} GB' -f [int]$rounded)
    }
    return ('{0} GB' -f $whole)
}

function Get-HouseHostFacts {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $skuValue = 0
    $buildValue = 0
    [void][int]::TryParse([string]$os.OperatingSystemSKU, [ref]$skuValue)
    [void][int]::TryParse([string]$os.BuildNumber, [ref]$buildValue)

    $processors = New-Object System.Collections.Generic.List[object]
    foreach ($processor in @(Get-CimInstance -ClassName Win32_Processor)) {
        $processors.Add([pscustomobject]@{
            Name                                       = ([string]$processor.Name).Trim()
            Architecture                               = [int]$processor.Architecture
            VirtualizationFirmwareEnabled              = ($processor.VirtualizationFirmwareEnabled -eq $true)
            SecondLevelAddressTranslationExtensions    = ($processor.SecondLevelAddressTranslationExtensions -eq $true)
        })
    }

    $drives = New-Object System.Collections.Generic.List[object]
    foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk)) {
        $free = [int64]0
        if ($null -ne $disk.FreeSpace) { $free = [int64]$disk.FreeSpace }
        $drives.Add([pscustomobject]@{
            DeviceId   = [string]$disk.DeviceID
            DriveType  = [int]$disk.DriveType
            FileSystem = [string]$disk.FileSystem
            FreeBytes  = $free
        })
    }

    $vmmsExists = $false
    $vmmsRunning = $false
    try {
        $vmms = Get-Service -Name 'vmms' -ErrorAction Stop
        $vmmsExists = $true
        if ($null -ne $vmms -and [string]$vmms.Status -eq 'Running') { $vmmsRunning = $true }
    }
    catch {
        $vmmsExists = $false
        $vmmsRunning = $false
    }

    $hyperVModule = $false
    $modules = @(Get-Module -ListAvailable -Name 'Hyper-V')
    if ($modules.Count -gt 0) { $hyperVModule = $true }

    # The guardian cmdlets used by the vm step ship in the HgsClient module.
    $hgs = (@(Get-Module -ListAvailable -Name 'HgsClient').Count -gt 0)

    return [pscustomobject]@{
        Caption              = [string]$os.Caption
        Sku                  = $skuValue
        Build                = $buildValue
        Is64BitOs            = [bool][Environment]::Is64BitOperatingSystem
        Processors           = @($processors.ToArray())
        Model                = [string]$computer.Model
        Manufacturer         = [string]$computer.Manufacturer
        HypervisorPresent    = ($computer.HypervisorPresent -eq $true)
        TotalPhysicalMemory  = [int64]$computer.TotalPhysicalMemory
        Drives               = @($drives.ToArray())
        VmmsExists           = [bool]$vmmsExists
        VmmsRunning          = [bool]$vmmsRunning
        HyperVModule         = [bool]$hyperVModule
        HgsGuardian          = [bool]$hgs
        Elevated             = [bool](Test-HouseElevation)
        ExecutionPolicy      = [string](Get-ExecutionPolicy)
    }
}

function New-HousePreflightItem {
    param(
        [string]$Name,
        [string]$Level,
        [bool]$Ok,
        [string]$Value,
        [string]$Why,
        [string]$Fix
    )
    return [pscustomobject]@{
        name  = $Name
        level = $Level
        ok    = [bool]$Ok
        value = $Value
        why   = $Why
        fix   = $Fix
    }
}

function Get-HousePreflightDisk {
    param(
        $Facts,
        [int]$DiskGB,
        [string]$HousePath
    )
    $needGb = $DiskGB + 20
    $needBytes = [int64]$needGb * 1GB
    $letterLimit = ''
    if ($HousePath) {
        $root = [System.IO.Path]::GetPathRoot($HousePath)
        if ($root -match '^([A-Za-z]):') { $letterLimit = $Matches[1].ToUpperInvariant() }
    }

    $best = $null
    $bestFree = [int64]-1
    $limited = $null
    foreach ($drive in @($Facts.Drives)) {
        $device = [string]$drive.DeviceId
        $letter = ''
        if ($device -match '^([A-Za-z]):') { $letter = $Matches[1].ToUpperInvariant() }
        if ($letterLimit -and $letter -ne $letterLimit) { continue }
        if ($letterLimit) { $limited = $drive }
        $type = [int]$drive.DriveType
        $fs = [string]$drive.FileSystem
        $free = [int64]$drive.FreeBytes
        $fsOk = (($fs -eq 'NTFS') -or ($fs -eq 'ReFS'))
        if ($type -ne 3 -or -not $fsOk) { continue }
        if ($null -eq $best -or $free -gt $bestFree) {
            $best = $drive
            $bestFree = $free
        }
    }

    $ok = ($null -ne $best -and $bestFree -ge $needBytes)
    $shown = $best
    if ($null -eq $shown) { $shown = $limited }
    if ($null -ne $shown) {
        $value = '{0} {1} {2} free' -f [string]$shown.DeviceId, [string]$shown.FileSystem, (Format-HouseGigabytes -Bytes ([int64]$shown.FreeBytes))
    }
    elseif ($letterLimit) {
        $value = '{0}: missing' -f $letterLimit
    }
    else {
        $value = 'no NTFS or ReFS fixed drive'
    }
    return [pscustomobject]@{
        Ok     = [bool]$ok
        Value  = [string]$value
        NeedGB = $needGb
    }
}

function New-HousePreflightResult {
    param(
        $Facts,
        [int]$DiskGB = 80,
        [string]$HousePath = '',
        [int]$Milliseconds = 0
    )
    $sku = 0
    $build = 0
    [void][int]::TryParse([string]$Facts.Sku, [ref]$sku)
    [void][int]::TryParse([string]$Facts.Build, [ref]$build)

    $blockers = New-Object System.Collections.Generic.List[object]
    $fixable = New-Object System.Collections.Generic.List[object]
    $info = New-Object System.Collections.Generic.List[object]

    if (-not (Test-HouseHyperVEdition -Sku $sku -Build $build)) {
        $why = 'need Windows 11 Pro, Enterprise or Education (build 22000 or newer)'
        $fix = 'install Windows 11 Pro, Enterprise or Education'
        if (Test-HouseHomeEdition -Sku $sku) {
            $why = 'Windows Home cannot run Hyper-V'
            $fix = 'upgrade to Pro'
        }
        $blockers.Add((New-HousePreflightItem -Name 'edition' -Level 'blocker' -Ok $false -Value $why -Why $why -Fix $fix))
    }

    $archOk = ($Facts.Is64BitOs -eq $true)
    $sawArm = $false
    $processors = @($Facts.Processors)
    if ($processors.Count -eq 0) { $archOk = $false }
    foreach ($cpu in $processors) {
        $architecture = [int]$cpu.Architecture
        if ($architecture -eq 12) { $sawArm = $true }
        if ($architecture -ne 9) { $archOk = $false }
    }
    if (-not $archOk) {
        $why = 'need a 64-bit x64 PC'
        $fix = 'use a 64-bit x64 PC'
        if ($sawArm) {
            $why = 'ARM64 is not supported; this install needs 64-bit x64'
            $fix = 'use a 64-bit x64 PC'
        }
        $blockers.Add((New-HousePreflightItem -Name 'arch' -Level 'blocker' -Ok $false -Value $why -Why $why -Fix $fix))
    }

    $ramBytes = [int64]$Facts.TotalPhysicalMemory
    if ($ramBytes -lt 16GB) {
        $why = '{0}, need 16 GB' -f (Format-HouseGigabytes -Bytes $ramBytes)
        $blockers.Add((New-HousePreflightItem -Name 'ram' -Level 'blocker' -Ok $false -Value $why -Why $why -Fix 'use a PC with at least 16 GB of RAM'))
    }

    if (Test-HouseNestedComputer -Model ([string]$Facts.Model) -Manufacturer ([string]$Facts.Manufacturer)) {
        $why = 'nested virtualization is not supported by this project'
        $value = '{0}; {1}' -f [string]$Facts.Model, $why
        $blockers.Add((New-HousePreflightItem -Name 'nested' -Level 'blocker' -Ok $false -Value $value -Why $why -Fix ''))
    }

    $hypervisor = ($Facts.HypervisorPresent -eq $true)
    if ($hypervisor) {
        $info.Add((New-HousePreflightItem -Name 'cpu-virtualization' -Level 'info' -Ok $true -Value 'unknown (hypervisor running)' -Why 'CPU flags are not trusted while a hypervisor is running' -Fix ''))
    }
    else {
        $firmwareOk = $true
        $slatOk = $true
        if ($processors.Count -eq 0) {
            $firmwareOk = $false
            $slatOk = $false
        }
        foreach ($cpu in $processors) {
            if ($cpu.VirtualizationFirmwareEnabled -ne $true) { $firmwareOk = $false }
            if ($cpu.SecondLevelAddressTranslationExtensions -ne $true) { $slatOk = $false }
        }
        if (-not $firmwareOk -or -not $slatOk) {
            $why = 'firmware virtualization is off'
            $fix = 'turn on VT-x/AMD-V in firmware'
            if ((-not $firmwareOk) -and (-not $slatOk)) {
                $why = 'firmware virtualization is off and SLAT is missing'
                $fix = 'turn on VT-x/AMD-V in firmware; SLAT missing means the CPU is too old'
            }
            elseif (-not $slatOk) {
                $why = 'SLAT is missing'
                $fix = 'SLAT missing means the CPU is too old'
            }
            $blockers.Add((New-HousePreflightItem -Name 'cpu-virtualization' -Level 'blocker' -Ok $false -Value $why -Why $why -Fix $fix))
        }
    }

    $disk = Get-HousePreflightDisk -Facts $Facts -DiskGB $DiskGB -HousePath $HousePath
    if ($disk.Ok) {
        $info.Add((New-HousePreflightItem -Name 'disk' -Level 'info' -Ok $true -Value ([string]$disk.Value) -Why '' -Fix ''))
    }
    else {
        $why = '{0}, need {1} GB on NTFS or ReFS' -f [string]$disk.Value, [int]$disk.NeedGB
        $blockers.Add((New-HousePreflightItem -Name 'disk' -Level 'blocker' -Ok $false -Value $why -Why $why -Fix ('free at least {0} GB on an NTFS or ReFS drive' -f [int]$disk.NeedGB)))
    }

    $hyperOk = (($Facts.VmmsExists -eq $true) -and ($Facts.VmmsRunning -eq $true) -and ($Facts.HyperVModule -eq $true))
    $hyperValue = 'vmms Running, Hyper-V module present'
    if (-not $hyperOk) { $hyperValue = 'vmms is not running or the Hyper-V module is missing' }
    $fixable.Add((New-HousePreflightItem -Name 'hyperv' -Level 'fixable' -Ok $hyperOk -Value $hyperValue -Why $hyperValue -Fix 'host-ready'))

    $hgsOk = ($Facts.HgsGuardian -eq $true)
    $hgsValue = 'HGS guardian command present'
    if (-not $hgsOk) { $hgsValue = 'HGS guardian command is not available' }
    $fixable.Add((New-HousePreflightItem -Name 'hgs' -Level 'fixable' -Ok $hgsOk -Value $hgsValue -Why $hgsValue -Fix 'host-ready'))

    $elevatedOk = ($Facts.Elevated -eq $true)
    $elevatedValue = 'Administrator'
    if (-not $elevatedOk) { $elevatedValue = 'this shell is not Administrator' }
    $fixable.Add((New-HousePreflightItem -Name 'elevated' -Level 'fixable' -Ok $elevatedOk -Value $elevatedValue -Why $elevatedValue -Fix 'open PowerShell as Administrator'))

    $policy = [string]$Facts.ExecutionPolicy
    $policyOk = (@('Restricted', 'AllSigned') -notcontains $policy)
    $policyValue = $policy
    if (-not $policyValue) { $policyValue = 'Undefined' }
    $fixable.Add((New-HousePreflightItem -Name 'execution-policy' -Level 'fixable' -Ok $policyOk -Value $policyValue -Why $policyValue -Fix 'powershell -NoProfile -ExecutionPolicy Bypass -File .\house.ps1 ...'))

    $cpuNames = New-Object System.Collections.Generic.List[string]
    foreach ($cpu in $processors) {
        if ([string]$cpu.Name) { $cpuNames.Add([string]$cpu.Name) }
    }
    $cpuValue = $cpuNames -join ', '
    if (-not $cpuValue) { $cpuValue = 'unknown' }
    $hvText = 'False'
    if ($hypervisor) { $hvText = 'True' }
    $info.Insert(0, (New-HousePreflightItem -Name 'windows' -Level 'info' -Ok $true -Value ('{0}, SKU {1}, build {2}' -f [string]$Facts.Caption, $sku, $build) -Why '' -Fix ''))
    $info.Insert(1, (New-HousePreflightItem -Name 'cpu' -Level 'info' -Ok $true -Value $cpuValue -Why '' -Fix ''))
    $info.Insert(2, (New-HousePreflightItem -Name 'ramGB' -Level 'info' -Ok $true -Value (Format-HouseGigabytes -Bytes $ramBytes) -Why '' -Fix ''))
    $info.Insert(3, (New-HousePreflightItem -Name 'hypervisorPresent' -Level 'info' -Ok $true -Value $hvText -Why '' -Fix ''))

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $blockers) { $items.Add($item) }
    foreach ($item in $fixable) { $items.Add($item) }
    foreach ($item in $info) { $items.Add($item) }

    $ok = ($blockers.Count -eq 0)
    $detail = 'compatible'
    $topFix = ''
    if (-not $ok) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($item in $blockers) { $names.Add([string]$item.name) }
        $detail = $names -join ', '
        foreach ($item in $blockers) {
            if ([string]$item.fix) { $topFix = [string]$item.fix; break }
        }
    }
    $status = 'fail'
    if ($ok) { $status = 'pass' }
    return [pscustomobject]@{
        id       = 'preflight'
        ok       = [bool]$ok
        status   = $status
        detail   = [string]$detail
        fix      = [string]$topFix
        evidence = [pscustomobject]@{ items = @($items.ToArray()) }
        ms       = [int]$Milliseconds
    }
}

function ConvertFrom-HouseFrontValue {
    param(
        [string]$Raw,
        [int]$LineNo
    )
    if ($Raw -match '^\[(.*)\]$') {
        $inner = $Matches[1].Trim()
        if ($inner -eq '') { return ,([string[]]@()) }
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($part in $inner.Split(',')) {
            $text = $part.Trim()
            if ($text.Length -ge 2) {
                $quote = $text[0]
                if (($quote -eq '"' -or $quote -eq "'") -and $text[$text.Length - 1] -eq $quote) {
                    $text = $text.Substring(1, $text.Length - 2)
                }
            }
            $items.Add($text)
        }
        return ,([string[]]$items.ToArray())
    }
    if ($Raw -eq 'true') { return $true }
    if ($Raw -eq 'false') { return $false }
    if ($Raw.Length -ge 2) {
        $quote = $Raw[0]
        if (($quote -eq '"' -or $quote -eq "'") -and $Raw[$Raw.Length - 1] -eq $quote) {
            return $Raw.Substring(1, $Raw.Length - 2)
        }
    }
    if ($Raw -match '^-?\d+$') { return [int]$Raw }
    if ($Raw -match '^\s|\s$') {
        throw "front matter: line ${LineNo}: unsupported syntax"
    }
    return $Raw
}

function ConvertFrom-HouseFrontMatter {
    param([string]$Text)
    if ($Text.Length -gt 0 -and [int]$Text[0] -eq 0xFEFF) { $Text = $Text.Substring(1) }
    $lines = $Text -split "`r?`n", 0
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'front matter: line 1: missing opening marker' }
    $end = -1
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { throw "front matter: line $($lines.Count): missing closing marker" }

    $result = @{}
    for ($i = $start + 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1
        if ($line.Trim() -eq '') { continue }
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            throw "front matter: line ${lineNo}: unsupported syntax"
        }
        $key = $Matches[1]
        $raw = $Matches[2].Trim()
        $result[$key] = ConvertFrom-HouseFrontValue -Raw $raw -LineNo $lineNo
    }
    return $result
}

function Get-HouseSteps {
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-HouseRepoRoot }
    $dir = Join-Path $RepoRoot 'runbook'
    $steps = @()
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $steps }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' | Where-Object { $_.Name -match '^[0-9]{2}-.+\.md$' })
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $front = ConvertFrom-HouseFrontMatter -Text $text
        foreach ($key in @('id', 'title', 'order', 'requires', 'runs_on', 'admin', 'reboot', 'human')) {
            if (-not $front.ContainsKey($key)) {
                throw "missing front matter key '$key' in $($file.Name)"
            }
        }
        $requires = $front['requires']
        if ($requires -isnot [System.Array]) {
            throw "front matter: line 1: requires must be an array in $($file.Name)"
        }
        $steps += [pscustomobject]@{
            Id        = [string]$front['id']
            Title     = [string]$front['title']
            Order     = [int]$front['order']
            Requires  = [string[]]$requires
            RunsOn    = [string]$front['runs_on']
            Admin     = [bool]$front['admin']
            Reboot    = [bool]$front['reboot']
            Human     = [bool]$front['human']
            PagePath  = 'runbook/' + $file.Name
            CheckPath = 'checks/' + [string]$front['id'] + '.ps1'
        }
    }
    return @($steps | Sort-Object -Property Order)
}

function Add-HouseSecretProblems {
    param(
        $Node,
        [string]$Path,
        $Problems
    )
    if ($null -eq $Node -or $Node -is [string]) { return }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $name = [string]$key
            $childPath = if ($Path) { "$Path.$name" } else { $name }
            if ($name -match '(?i)password|passwd|secret|token|apikey|api_key|credential') {
                $Problems.Add("secret key: $childPath")
            }
            Add-HouseSecretProblems -Node $Node[$key] -Path $childPath -Problems $Problems
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $Node) {
            Add-HouseSecretProblems -Node $item -Path ("{0}[{1}]" -f $Path, $index) -Problems $Problems
            $index++
        }
    }
}

function Import-HouseDataFile {
    param([string]$Path)
    # Windows PowerShell 5.1 reads a BOM-less .psd1 in the ANSI code page, so a UTF-8 blueprint
    # with a path such as D:\资料 would load garbled. Valid BOM-less UTF-8 with non-ASCII bytes is
    # parsed from memory the way Import-PowerShellDataFile does it (one hashtable, SafeGetValue,
    # so no code runs); anything else (ASCII, BOM, ANSI) loads as before.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -ge 0x80) { $nonAscii = $true; break } }
    if ($hasBom -or -not $nonAscii) { return (Import-PowerShellDataFile -LiteralPath $Path) }
    $text = $null
    try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { return (Import-PowerShellDataFile -LiteralPath $Path) }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ("blueprint does not parse: " + [string]@($errors)[0].Message) }
    # Find walks the tree in order, so the first hashtable is the top-level one.
    $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if ($null -eq $table -or @($ast.EndBlock.Statements).Count -ne 1) { throw 'blueprint must contain exactly one top-level hashtable' }
    return $table.SafeGetValue()
}

function Import-HouseConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $data = Import-HouseDataFile -Path $Path
    $problems = New-Object System.Collections.Generic.List[string]

    $houseKeys = @('Name', 'Path', 'IsoPath', 'ImageName', 'CpuCount', 'MemoryGB', 'DiskGB', 'UserName', 'Locale', 'TimeZone')
    $networkKeys = @('SwitchName', 'Subnet', 'HostIP', 'VmIP', 'GatePort', 'ProxyAppPort', 'ProxyMode')
    $shareKeys = @('Name', 'HostPath', 'Writable', 'Mirror')

    if (-not $data.ContainsKey('House') -or $null -eq $data['House']) {
        $problems.Add('missing House')
    }
    else {
        foreach ($key in $houseKeys) {
            $value = $data['House'][$key]
            $missing = -not $data['House'].ContainsKey($key) -or $null -eq $value
            if (-not $missing -and $value -is [string] -and $value.Trim() -eq '') { $missing = $true }
            if ($missing) { $problems.Add("missing House.$key") }
        }
    }

    if (-not $data.ContainsKey('Network') -or $null -eq $data['Network']) {
        $problems.Add('missing Network')
    }
    else {
        $network = $data['Network']
        foreach ($key in $networkKeys) {
            $value = $network[$key]
            $missing = -not $network.ContainsKey($key) -or $null -eq $value
            if (-not $missing -and $value -is [string] -and $value.Trim() -eq '') { $missing = $true }
            if ($missing) { $problems.Add("missing Network.$key") }
        }
        if ($network.ContainsKey('ProxyMode') -and $null -ne $network['ProxyMode'] -and [string]$network['ProxyMode'] -ne '') {
            $mode = [string]$network['ProxyMode']
            if (@('Global', 'Rule', 'Direct') -notcontains $mode) {
                $problems.Add('Network.ProxyMode must be Global, Rule, or Direct')
            }
        }
        $subnet = ''
        if ($network.ContainsKey('Subnet') -and $null -ne $network['Subnet']) { $subnet = [string]$network['Subnet'].Trim() }
        if ($subnet) {
            $subnetMatch = $subnet -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$'
            $prefixOk = $false
            if ($subnetMatch) {
                $prefixValue = [int]$Matches[2]
                $prefixOk = $prefixValue -ge 0 -and $prefixValue -le 32 -and $null -ne (ConvertTo-HouseIpv4UInt64 -Ip $Matches[1])
            }
            if (-not $prefixOk) {
                $problems.Add('Network.Subnet must be CIDR a.b.c.d/nn')
            }
            else {
                foreach ($ipKey in @('HostIP', 'VmIP')) {
                    if (-not $network.ContainsKey($ipKey) -or $null -eq $network[$ipKey] -or [string]$network[$ipKey] -eq '') { continue }
                    $ipText = [string]$network[$ipKey].Trim()
                    if ($null -eq (ConvertTo-HouseIpv4UInt64 -Ip $ipText)) {
                        $problems.Add("Network.$ipKey is not an IPv4 address")
                    }
                    elseif (-not (Test-HouseIpv4InCidr -Ip $ipText -Cidr $subnet)) {
                        $problems.Add("Network.$ipKey is outside Network.Subnet")
                    }
                }
                if ($network.ContainsKey('HostIP') -and $network.ContainsKey('VmIP') -and $null -ne $network['HostIP'] -and $null -ne $network['VmIP']) {
                    $hostText = [string]$network['HostIP'].Trim()
                    $vmText = [string]$network['VmIP'].Trim()
                    $hostValue = ConvertTo-HouseIpv4UInt64 -Ip $hostText
                    $vmValue = ConvertTo-HouseIpv4UInt64 -Ip $vmText
                    $same = $false
                    if ($null -ne $hostValue -and $null -ne $vmValue) { $same = ($hostValue -eq $vmValue) }
                    elseif ($hostText -eq $vmText) { $same = $true }
                    if ($same) { $problems.Add('Network.HostIP and Network.VmIP must differ') }
                }
            }
        }
    }

    if (-not $data.ContainsKey('Shares') -or $null -eq $data['Shares']) {
        $problems.Add('missing Shares')
    }
    elseif ($data['Shares'] -is [System.Collections.IDictionary] -or $data['Shares'] -is [string]) {
        $problems.Add('Shares must be an array')
    }
    else {
        $index = 0
        foreach ($share in @($data['Shares'])) {
            if ($share -isnot [System.Collections.IDictionary]) {
                $problems.Add("Shares[$index] is not a record")
            }
            else {
                foreach ($key in $shareKeys) {
                    $value = $share[$key]
                    $missing = -not $share.ContainsKey($key) -or $null -eq $value
                    if (-not $missing -and $key -ne 'Writable' -and $key -ne 'Mirror' -and $value -is [string] -and $value.Trim() -eq '') {
                        $missing = $true
                    }
                    if ($missing) { $problems.Add("missing Shares[$index].$key") }
                }
            }
            $index++
        }
    }

    if (-not $data.ContainsKey('Tools') -or $null -eq $data['Tools']) { $problems.Add('missing Tools') }
    if (-not $data.ContainsKey('Rules') -or $null -eq $data['Rules']) { $problems.Add('missing Rules') }

    if ($data.ContainsKey('Look') -and $null -ne $data['Look']) {
        $look = $data['Look']
        if ($look -isnot [System.Collections.IDictionary]) {
            $problems.Add('Look must be a record')
        }
        elseif ($look.ContainsKey('Theme') -and $null -ne $look['Theme'] -and [string]$look['Theme'].Trim() -ne '') {
            $theme = [string]$look['Theme'].Trim()
            if (@('light', 'none') -notcontains $theme) {
                $problems.Add('Look.Theme must be light or none')
            }
        }
    }

    Add-HouseSecretProblems -Node $data -Path '' -Problems $problems

    if ($problems.Count -gt 0) {
        throw ($problems -join [Environment]::NewLine)
    }
    return $data
}

function New-HouseCheckError {
    param(
        $Step,
        [string]$Message,
        [int]$Milliseconds
    )
    return [pscustomobject]@{
        id     = $Step.Id
        ok     = $false
        status = 'fail'
        detail = "check error: $Message"
        ms     = $Milliseconds
    }
}

function Test-HouseCheckResult {
    param(
        $Item,
        [string]$ExpectedId
    )
    if ($null -eq $Item) { return $false }
    $names = @()
    if ($Item -is [System.Collections.IDictionary]) {
        $names = @($Item.Keys)
        $id = [string]$Item['id']
        $ok = $Item['ok']
        $detail = $Item['detail']
    }
    else {
        $names = @($Item.PSObject.Properties.Name)
        if ($names -notcontains 'id' -or $names -notcontains 'ok' -or $names -notcontains 'detail') { return $false }
        $id = [string]$Item.id
        $ok = $Item.ok
        $detail = $Item.detail
    }
    if ($names -notcontains 'id' -or $names -notcontains 'ok' -or $names -notcontains 'detail') { return $false }
    if ($id -ne $ExpectedId) { return $false }
    if ($ok -isnot [bool]) { return $false }
    if ($detail -isnot [string]) { return $false }
    return $true
}

function Invoke-HouseCheck {
    param(
        $Step,
        [hashtable]$Context
    )
    $root = $null
    if ($Context -and $Context.ContainsKey('RepoRoot') -and $Context['RepoRoot']) {
        $root = [string]$Context['RepoRoot']
    }
    else {
        $root = Get-HouseRepoRoot
    }
    $relative = ([string]$Step.CheckPath) -replace '/', '\'
    $script = Join-Path $root $relative
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
            throw "check script not found: $($Step.CheckPath)"
        }
        $output = @(& $script -Context $Context)
        $sw.Stop()
        $ms = [int]$sw.Elapsed.TotalMilliseconds
        if ($output.Count -ne 1) {
            return (New-HouseCheckError -Step $Step -Message 'invalid check result' -Milliseconds $ms)
        }
        $item = $output[0]
        if (-not (Test-HouseCheckResult -Item $item -ExpectedId $Step.Id)) {
            return (New-HouseCheckError -Step $Step -Message 'invalid check result' -Milliseconds $ms)
        }
        $ok = $false
        $detail = ''
        $fix = $null
        $evidence = $null
        $hasFix = $false
        $hasEvidence = $false
        if ($item -is [System.Collections.IDictionary]) {
            $ok = [bool]$item['ok']
            $detail = [string]$item['detail']
            if ($item.Contains('fix') -or $item.ContainsKey('fix')) { $hasFix = $true; $fix = $item['fix'] }
            if ($item.Contains('evidence') -or $item.ContainsKey('evidence')) { $hasEvidence = $true; $evidence = $item['evidence'] }
        }
        else {
            $ok = [bool]$item.ok
            $detail = [string]$item.detail
            $propNames = @($item.PSObject.Properties.Name)
            if ($propNames -contains 'fix') { $hasFix = $true; $fix = $item.fix }
            if ($propNames -contains 'evidence') { $hasEvidence = $true; $evidence = $item.evidence }
        }
        $result = [ordered]@{
            id     = [string]$Step.Id
            ok     = $ok
            status = $(if ($ok) { 'pass' } else { 'fail' })
            detail = $detail
            ms     = $ms
        }
        if ($hasFix -and $null -ne $fix -and [string]$fix -ne '') { $result.fix = [string]$fix }
        if ($hasEvidence -and $null -ne $evidence) { $result.evidence = $evidence }
        return [pscustomobject]$result
    }
    catch {
        if ($sw.IsRunning) { $sw.Stop() }
        $ms = [int]$sw.Elapsed.TotalMilliseconds
        $message = $_.Exception.Message
        if (-not $message) { $message = $_.ToString() }
        return (New-HouseCheckError -Step $Step -Message $message -Milliseconds $ms)
    }
}

function Invoke-HouseStepStatus {
    param(
        [string]$Id,
        [hashtable]$Context,
        [hashtable]$Cache
    )
    if ($Cache.ContainsKey($Id)) { return $Cache[$Id] }
    $visitKey = "visiting:$Id"
    if ($Cache.ContainsKey($visitKey)) { throw "step cycle at $Id" }
    $Cache[$visitKey] = $true
    try {
        $root = $null
        if ($Context.ContainsKey('RepoRoot')) { $root = [string]$Context['RepoRoot'] }
        $steps = @(Get-HouseSteps -RepoRoot $root)
        $step = $null
        foreach ($candidate in $steps) {
            if ($candidate.Id -eq $Id) { $step = $candidate; break }
        }
        if ($null -eq $step) { throw "unknown step: $Id" }

        $blocking = New-Object System.Collections.Generic.List[string]
        $firstFix = $null
        foreach ($requiredId in @($step.Requires)) {
            if (-not $requiredId) { continue }
            $requiredStatus = Invoke-HouseStepStatus -Id $requiredId -Context $Context -Cache $Cache
            if ([string]$requiredStatus.status -ne 'pass') {
                $blocking.Add([string]$requiredId)
                if (-not $firstFix) {
                    foreach ($candidate in $steps) {
                        if ($candidate.Id -eq $requiredId) { $firstFix = $candidate.PagePath; break }
                    }
                }
            }
        }
        if ($blocking.Count -gt 0) {
            $blocked = [pscustomobject]@{
                id     = $step.Id
                ok     = $false
                status = 'blocked'
                detail = 'blocked by: ' + ($blocking -join ', ')
                fix    = $firstFix
            }
            $Cache[$Id] = $blocked
            return $blocked
        }
        $checked = Invoke-HouseCheck -Step $step -Context $Context
        $Cache[$Id] = $checked
        return $checked
    }
    finally {
        [void]$Cache.Remove($visitKey)
    }
}

function Format-HouseQuotedText {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + ($Value.Replace("'", "''")) + "'"
}

function Format-HouseSwitchToken {
    param($Value)
    if ($Value -eq $true) { return '$true' }
    if ([string]$Value -eq 'True') { return '$true' }
    return '$false'
}

function Format-HouseBoolToken {
    param(
        $Config,
        [string]$Section,
        [string]$Name
    )
    $sectionValue = Get-HousePropertyValue -Object $Config -Name $Section
    $value = Get-HousePropertyValue -Object $sectionValue -Name $Name
    if ($Value -eq $true) { return 'True' }
    if ([string]$Value -eq 'True') { return 'True' }
    return 'False'
}

function Format-HouseShareLiteral {
    param($Config)
    $shares = @()
    $raw = Get-HousePropertyValue -Object $Config -Name 'Shares'
    if ($null -ne $raw) { $shares = @($raw) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@(')
    foreach ($share in $shares) {
        if ($null -eq $share) { continue }
        $name = Format-HouseQuotedText -Value ([string](Get-HousePropertyValue -Object $share -Name 'Name'))
        $path = Format-HouseQuotedText -Value ([string](Get-HousePropertyValue -Object $share -Name 'HostPath'))
        $writable = Format-HouseSwitchToken -Value (Get-HousePropertyValue -Object $share -Name 'Writable')
        $mirror = Format-HouseSwitchToken -Value (Get-HousePropertyValue -Object $share -Name 'Mirror')
        $lines.Add(('    @{{ Name = {0}; HostPath = {1}; Writable = {2}; Mirror = {3} }}' -f $name, $path, $writable, $mirror))
    }
    $lines.Add(')')
    return ($lines.ToArray() -join "`r`n")
}

function Test-HouseBoolValue {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ([string]$Value -eq 'True') { return $true }
    return $false
}

function Get-HouseShareRows {
    param($Config)
    $rows = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Config) { return ,$rows }
    foreach ($share in @(Get-HousePropertyValue -Object $Config -Name 'Shares')) {
        if ($null -eq $share) { continue }
        $name = [string](Get-HousePropertyValue -Object $share -Name 'Name')
        if (-not $name) { continue }
        $rows.Add([pscustomobject]@{
            Name     = $name
            HostPath = [string](Get-HousePropertyValue -Object $share -Name 'HostPath')
            Writable = (Test-HouseBoolValue -Value (Get-HousePropertyValue -Object $share -Name 'Writable'))
            Mirror   = (Test-HouseBoolValue -Value (Get-HousePropertyValue -Object $share -Name 'Mirror'))
        })
    }
    return ,$rows
}

function Get-HouseAddressBook {
    param($Config)
    $book = New-Object System.Collections.Generic.List[object]
    foreach ($share in (Get-HouseShareRows -Config $Config)) {
        $vmPath = '\\house-host\' + $share.Name
        if ($share.Mirror) { $vmPath = [string]$share.HostPath }
        $book.Add([pscustomobject]@{
            Name     = [string]$share.Name
            HostPath = [string]$share.HostPath
            VmPath   = [string]$vmPath
            Writable = [bool]$share.Writable
        })
    }
    return @($book.ToArray())
}

function Add-HouseUniqueRoot {
    param(
        $List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    foreach ($existing in $List) {
        if ([string]::Equals([string]$existing, $Path, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    }
    $List.Add($Path)
}

function Get-HouseShareRoots {
    param($Config)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($share in (Get-HouseShareRows -Config $Config)) {
        Add-HouseUniqueRoot -List $roots -Path ('\\house-host\' + $share.Name)
        if (-not $share.Mirror) { continue }
        $hostPath = [string]$share.HostPath
        Add-HouseUniqueRoot -List $roots -Path $hostPath
        if ($hostPath -match '^(?i)([A-Z]):') {
            $letter = $Matches[1].ToUpperInvariant()
            if ($letter -ne 'C') { Add-HouseUniqueRoot -List $roots -Path ($letter + ':\') }
        }
    }
    $sorted = $roots.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function Format-HouseAddressTable {
    param($Config)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('| host path | path in the house | writable |')
    $lines.Add('| --- | --- | --- |')
    foreach ($row in @(Get-HouseAddressBook -Config $Config)) {
        $writable = 'no'
        if ($row.Writable) { $writable = 'yes' }
        $lines.Add('| ' + $row.HostPath + ' | ' + $row.VmPath + ' | ' + $writable + ' |')
    }
    return ($lines.ToArray() -join "`r`n")
}

function Get-HouseDeliverablesText {
    param($Config)
    foreach ($row in @(Get-HouseAddressBook -Config $Config)) {
        if ($row.Writable) { return [string]$row.VmPath }
    }
    return 'There is no writable share; keep deliverables in your user folder and tell the human.'
}

function Get-HouseGateUrl {
    param($Config)
    $network = Get-HousePropertyValue -Object $Config -Name 'Network'
    $hostIp = [string](Get-HousePropertyValue -Object $network -Name 'HostIP')
    $port = [string](Get-HousePropertyValue -Object $network -Name 'GatePort')
    return 'http://' + $hostIp + ':' + $port
}

function Format-HouseRulesBlock {
    param($Config)
    $path = Join-Path (Get-HouseRepoRoot) 'rules\CLAUDE.md.template'
    $text = [System.IO.File]::ReadAllText($path)
    $text = $text.Replace('{{AddressBook}}', (Format-HouseAddressTable -Config $Config))
    $text = $text.Replace('{{Deliverables}}', (Get-HouseDeliverablesText -Config $Config))
    $text = $text.Replace('{{GateUrl}}', (Get-HouseGateUrl -Config $Config))
    return $text
}

function Format-HouseRootsJson {
    param($Config)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-HouseShareRoots -Config $Config)) {
        $escaped = ([string]$root).Replace('\', '\\').Replace('"', '\"')
        $parts.Add('"' + $escaped + '"')
    }
    return '{"roots":[' + ($parts.ToArray() -join ',') + ']}'
}

function ConvertTo-HouseRulesHash {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $normal = $Text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd()
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8.GetBytes($normal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) { [void]$builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function Get-HouseKnownHookNames {
    return @('bounded-search', 'share-delete-guard', 'windows-guard')
}

function Get-HouseHookMatcher {
    param([string]$Name)
    if ($Name -eq 'windows-guard') { return 'Bash|PowerShell|Write|Edit' }
    return 'Grep|Glob|Bash|PowerShell'
}

function Get-HouseHookSelection {
    param($Config)
    $known = @(Get-HouseKnownHookNames)
    $selected = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
    $rules = Get-HousePropertyValue -Object $Config -Name 'Rules'
    foreach ($name in @(Get-HousePropertyValue -Object $rules -Name 'Hooks')) {
        if ($null -eq $name) { continue }
        $hookName = [string]$name
        if (-not $hookName) { continue }
        $found = $false
        foreach ($knownName in $known) {
            if ($knownName -eq $hookName) { $found = $true }
        }
        if ($found) { $selected.Add($hookName) }
        else { $unknown.Add($hookName) }
    }
    return [pscustomobject]@{
        Known    = @($known)
        Selected = @($selected.ToArray())
        Unknown  = @($unknown.ToArray())
    }
}

function Get-HouseHookCommandLine {
    param(
        [string]$UserName,
        [string]$HookName
    )
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/' + $UserName + '/.claude/hooks/house-' + $HookName + '.ps1"'
}

function Get-HouseLookPalette {
    return [ordered]@{
        background  = '#FAF9F5'
        surface     = '#F0EEE6'
        text        = '#3D3929'
        'muted text' = '#8A8170'
        accent      = '#C96442'
    }
}

function Get-HouseLookTheme {
    param($Config)
    $look = Get-HousePropertyValue -Object $Config -Name 'Look'
    if ($null -eq $look) { return 'light' }
    $theme = Get-HousePropertyValue -Object $look -Name 'Theme'
    if ($null -eq $theme) { return 'light' }
    $text = ([string]$theme).Trim()
    if ($text -eq '') { return 'light' }
    return $text
}

function Get-HouseLookAccentPalette {
    return [byte[]]@(
        0xEA, 0xC1, 0xB3, 0x00,
        0xDF, 0xA2, 0x8D, 0x00,
        0xD4, 0x83, 0x68, 0x00,
        0xC9, 0x64, 0x42, 0x00,
        0xA1, 0x50, 0x35, 0x00,
        0x79, 0x3C, 0x28, 0x00,
        0x50, 0x28, 0x1A, 0x00,
        0x28, 0x14, 0x0D, 0x00
    )
}

function ConvertTo-HouseAbgrDword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex,
        [ValidateRange(0, 255)]
        [int]$Alpha = 0xFF
    )
    $clean = ([string]$Hex).Trim()
    if ($clean.StartsWith('#')) { $clean = $clean.Substring(1) }
    if ($clean.Length -ne 6) { throw 'hex colour must be RRGGBB' }
    $rgb = [Convert]::ToUInt32($clean, 16)
    $r = [uint32](($rgb -shr 16) -band [uint32]0xFF)
    $g = [uint32](($rgb -shr 8) -band [uint32]0xFF)
    $b = [uint32]($rgb -band [uint32]0xFF)
    $a = [uint32]$Alpha
    return [uint32](($a -shl 24) -bor ($b -shl 16) -bor ($g -shl 8) -bor $r)
}

function ConvertTo-HouseBytesHash {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) { [void]$builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function ConvertTo-HouseTextHash {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $normal = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding $false
    return (ConvertTo-HouseBytesHash -Bytes $utf8.GetBytes($normal))
}

function ConvertFrom-HouseHexRgb {
    param([string]$Hex)
    $clean = ([string]$Hex).Trim()
    if ($clean.StartsWith('#')) { $clean = $clean.Substring(1) }
    $value = [Convert]::ToInt32($clean, 16)
    $r = ($value -shr 16) -band 0xFF
    $g = ($value -shr 8) -band 0xFF
    $b = $value -band 0xFF
    return [pscustomobject]@{ R = [int]$r; G = [int]$g; B = [int]$b }
}

function New-HouseWallpaper {
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    $palette = Get-HouseLookPalette
    $surface = ConvertFrom-HouseHexRgb -Hex $palette['surface']
    $accent = ConvertFrom-HouseHexRgb -Hex $palette['accent']
    $muted = ConvertFrom-HouseHexRgb -Hex $palette['muted text']
    $bitmap = $null
    $graphics = $null
    $barBrush = $null
    $textBrush = $null
    $font = $null
    $stream = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap 1920, 1080
        $bitmap.SetResolution(96, 96)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::FromArgb(255, [int]$surface.R, [int]$surface.G, [int]$surface.B))
        $barBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, [int]$accent.R, [int]$accent.G, [int]$accent.B))
        $graphics.FillRectangle($barBrush, 120, 944, 240, 6)
        $font = New-Object System.Drawing.Font('Segoe UI', [single]20, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, [int]$muted.R, [int]$muted.G, [int]$muted.B))
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.DrawString('claude-house', $font, $textBrush, [single]120, [single]966)
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $barBrush) { $barBrush.Dispose() }
        if ($null -ne $textBrush) { $textBrush.Dispose() }
        if ($null -ne $font) { $font.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-HouseAvatar {
    param([int]$Size = 448)
    if ($Size -lt 16) { throw 'avatar size is too small' }
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    $bitmap = $null
    $graphics = $null
    $accentBrush = $null
    $pen = $null
    $stream = $null
    try {
        $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, $format
        $bitmap.SetResolution(96, 96)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $accent = [System.Drawing.Color]::FromArgb(255, 201, 100, 66)
        $cream = [System.Drawing.Color]::FromArgb(255, 250, 249, 245)
        $margin = [single]($Size * 0.08)
        $diameter = [single]($Size - (2 * $margin))
        $accentBrush = New-Object System.Drawing.SolidBrush $accent
        $graphics.FillEllipse($accentBrush, $margin, $margin, $diameter, $diameter)
        $penWidth = [single]([Math]::Max(2.0, ($Size / 28.0)))
        $pen = New-Object System.Drawing.Pen $cream, $penWidth
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $left = [single]($Size * 0.32)
        $right = [single]($Size * 0.68)
        $top = [single]($Size * 0.58)
        $bottom = [single]($Size * 0.78)
        $peakX = [single](($left + $right) / 2.0)
        $peakY = [single]($Size * 0.30)
        $roof = New-Object 'System.Drawing.PointF[]' 3
        $roof[0] = New-Object System.Drawing.PointF -ArgumentList $peakX, $peakY
        $roof[1] = New-Object System.Drawing.PointF -ArgumentList $left, $top
        $roof[2] = New-Object System.Drawing.PointF -ArgumentList $right, $top
        $graphics.DrawPolygon($pen, $roof)
        $bodyWidth = [single]($right - $left)
        $bodyHeight = [single]($bottom - $top)
        $graphics.DrawRectangle($pen, $left, $top, $bodyWidth, $bodyHeight)
        $doorWidth = [single]($Size * 0.10)
        $doorHeight = [single]($Size * 0.12)
        $doorX = [single]($peakX - ($doorWidth / 2.0))
        $doorY = [single]($bottom - $doorHeight)
        $graphics.DrawRectangle($pen, $doorX, $doorY, $doorWidth, $doorHeight)
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $accentBrush) { $accentBrush.Dispose() }
        if ($null -ne $pen) { $pen.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertTo-HouseScaledPng {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Size
    )
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    $inputStream = $null
    $source = $null
    $bitmap = $null
    $graphics = $null
    $output = $null
    try {
        $inputStream = New-Object System.IO.MemoryStream (,$Bytes)
        $source = [System.Drawing.Image]::FromStream($inputStream)
        $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, $format
        $bitmap.SetResolution(96, 96)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $dest = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
        $graphics.DrawImage($source, $dest)
        $output = New-Object System.IO.MemoryStream
        $bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$output.ToArray()
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $output) { $output.Dispose() }
    }
}

function Get-HouseLookBytes {
    param(
        [string]$RepoRoot,
        [string]$FileName,
        [scriptblock]$Generate
    )
    $path = $null
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $path = Join-Path (Join-Path (Join-Path $RepoRoot 'assets') 'look') $FileName
    }
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ,([System.IO.File]::ReadAllBytes($path))
    }
    if ($null -eq $Generate) { throw 'look bytes are missing' }
    return ,(& $Generate)
}

function Get-HouseStartPinsJson {
    $pins = @(
        @{ packagedAppId = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App' },
        @{ desktopAppLink = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\File Explorer.lnk' },
        @{ packagedAppId = 'windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel' },
        @{ desktopAppLink = '%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk' },
        @{ packagedAppId = 'Microsoft.WindowsNotepad_8wekyb3d8bbwe!App' }
    )
    return (ConvertTo-Json -InputObject @{ pinnedList = $pins } -Compress -Depth 5)
}

function Format-HouseTaskbarLayoutXml {
    $lines = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
        '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
        '    <defaultlayout:TaskbarLayout>',
        '      <taskbar:TaskbarPinList>',
        '        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />',
        '        <taskbar:UWA AppUserModelID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" />',
        '        <taskbar:DesktopApp DesktopApplicationID="MSEdge" />',
        # Step 9 installs the Claude desktop app; Windows skips this pin when the package is absent.
        '        <taskbar:UWA AppUserModelID="Claude_pzs8sxrjxfjjc!Claude" />',
        '      </taskbar:TaskbarPinList>',
        '    </defaultlayout:TaskbarLayout>',
        '  </CustomTaskbarLayoutCollection>',
        '</LayoutModificationTemplate>'
    )
    return (($lines -join "`n") + "`n")
}

function Get-HouseCursorRoleNames {
    # Windows stores a pointer scheme in this order.
    return @(
        'Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No',
        'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person'
    )
}

function Get-HouseCursorGuestPath {
    param([string]$FileName)
    return (Join-Path 'C:\ProgramData\claude-house\look\cursors' $FileName)
}

function Get-HouseCursorScheme {
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return $null }
    $dir = Join-Path (Join-Path $RepoRoot 'assets') 'cursors'
    $schemePath = Join-Path $dir 'scheme.json'
    if (-not (Test-Path -LiteralPath $schemePath -PathType Leaf)) { return $null }
    $raw = $null
    try {
        $raw = [System.IO.File]::ReadAllText($schemePath) | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ($null -eq $raw) { return $null }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($role in @(Get-HouseCursorRoleNames)) {
        $prop = $raw.PSObject.Properties[$role]
        if ($null -eq $prop) { return $null }
        $file = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($file)) { return $null }
        if ($file.Contains('\') -or $file.Contains('/') -or $file.Contains('..')) { return $null }
        $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($ext -ne '.cur' -and $ext -ne '.ani') { return $null }
        $full = Join-Path $dir $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        $pairs.Add([pscustomobject]@{
            Role       = $role
            File       = $file
            SourcePath = $full
        })
    }
    return @($pairs.ToArray())
}

function Format-HouseCursorSchemeValue {
    param($Pairs)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @($Pairs)) {
        if ($null -eq $pair) { continue }
        $file = [string](Get-HousePropertyValue -Object $pair -Name 'File')
        $paths.Add((Get-HouseCursorGuestPath -FileName $file))
    }
    return ($paths.ToArray() -join ',')
}

function Get-HouseTerminalArtPaths {
    param([string]$RepoRoot)
    $iconPath = $null
    $iconSource = $null
    $backgroundPath = $null
    $backgroundSource = $null
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $iconCandidate = Join-Path (Join-Path (Join-Path $RepoRoot 'assets') 'icons') 'terminal.png'
        if (Test-Path -LiteralPath $iconCandidate -PathType Leaf) {
            $iconSource = $iconCandidate
            $iconPath = 'C:\ProgramData\claude-house\look\terminal.png'
        }
        $backgroundCandidate = Join-Path (Join-Path (Join-Path $RepoRoot 'assets') 'terminal') 'background.png'
        if (Test-Path -LiteralPath $backgroundCandidate -PathType Leaf) {
            $backgroundSource = $backgroundCandidate
            $backgroundPath = 'C:\ProgramData\claude-house\look\terminal-background.png'
        }
    }
    return [pscustomobject]@{
        IconPath         = $iconPath
        IconSource       = $iconSource
        BackgroundPath   = $backgroundPath
        BackgroundSource = $backgroundSource
    }
}

function Get-HouseVolumeMediaType {
    # 'SSD', 'HDD', or '' when Windows cannot tell (virtual disks, storage spaces).
    param([string]$DriveLetter)
    try {
        $disk = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $physical = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number })
        if ($physical.Count -eq 0) { return '' }
        $media = [string]$physical[0].MediaType
        if (@('SSD', 'HDD') -contains $media) { return $media }
        return ''
    }
    catch {
        return ''
    }
}

function Get-HouseShareShortcutPlan {
    param(
        $Config,
        [string]$RepoRoot
    )
    $plans = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($RepoRoot)) { return @() }
    foreach ($row in @(Get-HouseAddressBook -Config $Config)) {
        $iconName = 'folder-docs.ico'
        if ($row.Writable) { $iconName = 'folder-projects.ico' }
        $source = Join-Path (Join-Path (Join-Path $RepoRoot 'assets') 'icons') $iconName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $plans.Add([pscustomobject]@{
            Name       = [string]$row.Name
            Target     = [string]$row.VmPath
            IconName   = $iconName
            IconPath   = (Join-Path 'C:\ProgramData\claude-house\look' $iconName)
            SourcePath = $source
        })
    }
    # Unrolled on purpose: callers write @(Get-HouseShareShortcutPlan ...), and a comma-wrapped list
    # would arrive as one item whose properties join every share (seen live on the drill).
    return $plans.ToArray()
}

function Format-HouseJsonString {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Format-HouseTerminalFragment {
    param(
        [string]$IconPath,
        [string]$BackgroundPath
    )
    $p = Get-HouseLookPalette
    $scheme = 'claude-house Light'
    $schemeJson = '{' +
        '"name":"' + $scheme + '",' +
        '"background":"' + $p['background'] + '",' +
        '"foreground":"' + $p['text'] + '",' +
        '"cursorColor":"' + $p['accent'] + '",' +
        '"selectionBackground":"' + $p['surface'] + '",' +
        '"black":"#3D3929",' +
        '"red":"#B5452F",' +
        '"green":"#5A7A3A",' +
        '"yellow":"#A0712A",' +
        '"blue":"#3E6A8A",' +
        '"purple":"#8A4F7D",' +
        '"cyan":"#3F7F7A",' +
        '"white":"#E8E4D8",' +
        '"brightBlack":"#8A8170",' +
        '"brightRed":"#C96442",' +
        '"brightGreen":"#6E8F48",' +
        '"brightYellow":"#B8873A",' +
        '"brightBlue":"#4F7FA3",' +
        '"brightPurple":"#A0628F",' +
        '"brightCyan":"#4F948E",' +
        '"brightWhite":"#FAF9F5"' +
        '}'
    $extra = ''
    if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
        $extra += ',"icon":"' + (Format-HouseJsonString -Value $IconPath) + '"'
    }
    if (-not [string]::IsNullOrWhiteSpace($BackgroundPath)) {
        $extra += ',"backgroundImage":"' + (Format-HouseJsonString -Value $BackgroundPath) + '"'
        $extra += ',"backgroundImageOpacity":0.08'
        $extra += ',"backgroundImageStretchMode":"uniformToFill"'
        $extra += ',"backgroundImageAlignment":"bottomRight"'
    }
    $psGuid = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
    $cmdGuid = '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}'
    $profileJson = {
        param([string]$Guid, [string]$Extra)
        return ('{"updates":"' + $Guid + '","colorScheme":"' + $scheme + '","font":{"face":"Cascadia Mono"}' + $Extra + '}')
    }
    return ('{"schemes":[' + $schemeJson + '],"profiles":[' + (& $profileJson $psGuid $extra) + ',' + (& $profileJson $cmdGuid $extra) + ']}' + "`n")
}

function ConvertTo-HouseHtmlText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function ConvertFrom-HouseUnicodeEscape {
    # This module stays ASCII: PowerShell 5.1 reads a BOM-less file with the ANSI code page, so Chinese text is written as \uXXXX here.
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, '\\u([0-9A-Fa-f]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

function Get-HouseHookDescription {
    param(
        [string]$Name,
        [switch]$Chinese
    )
    if ($Chinese) {
        if ($Name -eq 'bounded-search') { return (ConvertFrom-HouseUnicodeEscape -Text '\u4e0d\u8ba9\u4e00\u6b21\u641c\u904d\u6574\u4e2a\u5171\u4eab\u76d8') }
        if ($Name -eq 'share-delete-guard') { return (ConvertFrom-HouseUnicodeEscape -Text '\u4e0d\u8ba9\u5728\u5171\u4eab\u6587\u4ef6\u5939\u91cc\u5220\u4e1c\u897f') }
        if ($Name -eq 'windows-guard') { return (ConvertFrom-HouseUnicodeEscape -Text '\u62e6\u4e0b\u5e38\u89c1\u7684 Windows \u547d\u4ee4\u9519\u8bef') }
        return ''
    }
    if ($Name -eq 'bounded-search') { return 'stops searches of whole shared drives' }
    if ($Name -eq 'share-delete-guard') { return 'stops deleting on shared folders' }
    if ($Name -eq 'windows-guard') { return 'stops common Windows command mistakes' }
    return ''
}

function Format-HouseWelcomeHtml {
    # The Start here page on the guest desktop. Pure: same blueprint, same bytes, so the look check can hash it.
    # English and Chinese both live in the page; two radio buttons and CSS pick one, no script.
    param($Config)
    $p = Get-HouseLookPalette
    $house = Get-HousePropertyValue -Object $Config -Name 'House'
    $tools = Get-HousePropertyValue -Object $Config -Name 'Tools'
    $rules = Get-HousePropertyValue -Object $Config -Name 'Rules'
    $wantDesktop = Test-HouseBoolValue -Value (Get-HousePropertyValue -Object $tools -Name 'ClaudeDesktop')
    $locale = [string](Get-HousePropertyValue -Object $house -Name 'Locale')
    $chineseFirst = $locale -match '^(?i)zh(-|$)'
    $values = @{
        name   = (ConvertTo-HouseHtmlText -Value ([string](Get-HousePropertyValue -Object $house -Name 'Name')))
        user   = (ConvertTo-HouseHtmlText -Value ([string](Get-HousePropertyValue -Object $house -Name 'UserName')))
        tz     = (ConvertTo-HouseHtmlText -Value ([string](Get-HousePropertyValue -Object $house -Name 'TimeZone')))
        locale = (ConvertTo-HouseHtmlText -Value $locale)
    }
    # One pass, so a blueprint value that looks like a token is never expanded again.
    $fill = {
        param([string]$Text)
        return [regex]::Replace($Text, '\{(name|user|tz|locale)\}', { param($m) [string]$values[$m.Groups[1].Value] })
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $both = {
        param([string]$Tag, [string]$En, [string]$Zh, [string]$Class)
        $prefix = ''
        if ($Class) { $prefix = $Class + ' ' }
        $lines.Add('<' + $Tag + ' class="' + $prefix + 'en">' + (& $fill $En) + '</' + $Tag + '>')
        $lines.Add('<' + $Tag + ' class="' + $prefix + 'zh" lang="zh-CN">' + (& $fill (ConvertFrom-HouseUnicodeEscape -Text $Zh)) + '</' + $Tag + '>')
    }
    $span = {
        param([string]$En, [string]$Zh)
        return ('<span class="en">' + $En + '</span><span class="zh" lang="zh-CN">' + (ConvertFrom-HouseUnicodeEscape -Text $Zh) + '</span>')
    }

    $htmlLang = 'en'
    $title = & $fill 'Welcome to {name}'
    $enChecked = ' checked'
    $zhChecked = ''
    if ($chineseFirst) {
        $htmlLang = 'zh-CN'
        $title = & $fill (ConvertFrom-HouseUnicodeEscape -Text '\u6b22\u8fce\u6765\u5230 {name}')
        $enChecked = ''
        $zhChecked = ' checked'
    }

    $lines.Add('<!DOCTYPE html>')
    $lines.Add('<html lang="' + $htmlLang + '">')
    $lines.Add('<head>')
    $lines.Add('<meta charset="utf-8">')
    $lines.Add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $lines.Add('<title>' + $title + '</title>')
    $lines.Add('<style>')
    $lines.Add(':root { --bg: ' + $p['background'] + '; --surface: ' + $p['surface'] + '; --text: ' + $p['text'] + '; --muted: ' + $p['muted text'] + '; --accent: ' + $p['accent'] + '; }')
    $lines.Add('* { box-sizing: border-box; }')
    $lines.Add('body { margin: 0; background: var(--bg); color: var(--text); font-family: "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", system-ui, sans-serif; font-size: 17px; line-height: 1.6; }')
    $lines.Add(':lang(zh) { font-family: "Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", sans-serif; }')
    $lines.Add('.lang-pick { position: absolute; width: 1px; height: 1px; opacity: 0; margin: 0; }')
    $lines.Add('#lang-en:checked ~ .page .zh, #lang-zh:checked ~ .page .en { display: none; }')
    $lines.Add('main { max-width: 760px; margin: 0 auto; padding: 40px 32px 56px; }')
    $lines.Add('header { display: flex; flex-wrap: wrap; align-items: center; gap: 16px 24px; margin-bottom: 8px; }')
    $lines.Add('header img { width: 96px; height: 96px; flex: none; }')
    $lines.Add('.title { flex: 1 1 260px; }')
    $lines.Add('.switch { display: flex; gap: 4px; padding: 4px; background: var(--surface); border-radius: 999px; }')
    $lines.Add('.switch label { cursor: pointer; padding: 4px 14px; border-radius: 999px; font-size: 15px; font-weight: 600; }')
    $lines.Add('#lang-en:checked ~ .page label[for="lang-en"], #lang-zh:checked ~ .page label[for="lang-zh"] { background: var(--accent); color: var(--bg); }')
    $lines.Add('#lang-en:focus-visible ~ .page label[for="lang-en"], #lang-zh:focus-visible ~ .page label[for="lang-zh"] { outline: 2px solid var(--accent); outline-offset: 2px; }')
    $lines.Add('h1 { font-size: 34px; line-height: 1.2; margin: 0; }')
    $lines.Add('h2 { font-size: 21px; margin: 34px 0 12px; padding-bottom: 6px; border-bottom: 2px solid var(--surface); color: var(--accent); }')
    $lines.Add('p { margin: 10px 0; }')
    $lines.Add('p.lead { font-size: 19px; margin: 18px 0 0; }')
    $lines.Add('ul { margin: 0; padding-left: 22px; }')
    $lines.Add('li { margin: 6px 0; }')
    $lines.Add('code { font-family: "Cascadia Mono", Consolas, monospace; font-size: 15px; background: var(--surface); padding: 1px 6px; border-radius: 4px; }')
    $lines.Add('table { width: 100%; border-collapse: collapse; background: var(--surface); border-radius: 8px; overflow: hidden; margin-bottom: 12px; }')
    $lines.Add('th, td { text-align: left; padding: 10px 14px; vertical-align: top; overflow-wrap: anywhere; }')
    $lines.Add('th { font-size: 14px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }')
    $lines.Add('tr + tr td { border-top: 1px solid var(--bg); }')
    $lines.Add('footer { margin-top: 40px; padding-top: 14px; border-top: 2px solid var(--surface); font-size: 15px; color: var(--muted); }')
    $lines.Add('footer p { margin: 6px 0; }')
    $lines.Add('footer strong { color: var(--text); }')
    $lines.Add('footer code { font-size: 13px; }')
    $lines.Add('@media (max-width: 820px) { main { padding: 24px 16px 40px; } header img { width: 64px; height: 64px; } h1 { font-size: 27px; } th, td { padding: 8px 10px; } }')
    $lines.Add('</style>')
    $lines.Add('</head>')
    $lines.Add('<body>')
    $lines.Add('<input class="lang-pick" type="radio" name="lang" id="lang-en" aria-label="English"' + $enChecked + '>')
    $lines.Add('<input class="lang-pick" type="radio" name="lang" id="lang-zh" aria-label="' + (ConvertFrom-HouseUnicodeEscape -Text '\u4e2d\u6587') + '"' + $zhChecked + '>')
    $lines.Add('<div class="page">')
    $lines.Add('<main>')
    $lines.Add('<header>')
    $lines.Add('<img src="house.png" alt="">')
    $lines.Add('<div class="title">')
    & $both 'h1' 'Welcome to {name}' '\u6b22\u8fce\u6765\u5230 {name}'
    $lines.Add('</div>')
    $lines.Add('<div class="switch"><label for="lang-en">English</label><label for="lang-zh" lang="zh-CN">' + (ConvertFrom-HouseUnicodeEscape -Text '\u4e2d\u6587') + '</label></div>')
    $lines.Add('</header>')
    & $both 'p' 'This is a Windows computer just for Claude. It lives inside your PC and reaches the internet through one gate only: the proxy app on your PC.' '\u8fd9\u662f\u4e00\u53f0\u4e13\u95e8\u7ed9 Claude \u7528\u7684 Windows \u7535\u8111\u3002\u5b83\u4f4f\u5728\u4f60\u7684\u7535\u8111\u91cc\uff0c\u4e0a\u7f51\u53ea\u8d70\u4e00\u9053\u95e8\uff1a\u4f60\u7535\u8111\u4e0a\u7684\u4ee3\u7406\u8f6f\u4ef6\u3002' 'lead'

    & $both 'h2' 'Start Claude' '\u542f\u52a8 Claude'
    $lines.Add('<ul>')
    & $both 'li' '<strong>Claude Code:</strong> open <strong>Terminal</strong> and type <code>claude</code>. The first time, it opens a browser so you can sign in.' '<strong>Claude Code</strong>\uff1a\u6253\u5f00 <strong>Terminal</strong>\uff08\u7ec8\u7aef\uff09\uff0c\u8f93\u5165 <code>claude</code>\u3002\u7b2c\u4e00\u6b21\u4f1a\u6253\u5f00\u6d4f\u89c8\u5668\u8ba9\u4f60\u767b\u5f55\u3002'
    if ($wantDesktop) {
        & $both 'li' '<strong>Claude app:</strong> click <strong>Claude</strong> on the taskbar. It signs in on its own, so you sign in twice: once in Terminal, once in the app.' '<strong>Claude \u684c\u9762\u7248</strong>\uff1a\u70b9\u4efb\u52a1\u680f\u4e0a\u7684 <strong>Claude</strong>\u3002\u5b83\u8981\u5355\u72ec\u767b\u5f55\uff0c\u6240\u4ee5\u4e00\u5171\u767b\u5f55\u4e24\u6b21\uff1a\u7ec8\u7aef\u91cc\u4e00\u6b21\uff0c\u684c\u9762\u7248\u91cc\u4e00\u6b21\u3002'
    }
    $lines.Add('</ul>')

    & $both 'h2' 'Your folders' '\u4f60\u7684\u6587\u4ef6\u5939'
    $book = @(Get-HouseAddressBook -Config $Config)
    if ($book.Count -eq 0) {
        & $both 'p' 'No folders are shared with this house. Everything stays inside this VM.' '\u8fd9\u53f0\u865a\u62df\u673a\u6ca1\u6709\u5171\u4eab\u4efb\u4f55\u6587\u4ef6\u5939\uff0c\u6240\u6709\u4e1c\u897f\u90fd\u53ea\u7559\u5728\u865a\u62df\u673a\u91cc\u3002'
    }
    else {
        $lines.Add('<table>')
        $lines.Add('<tr><th>' + (& $span 'Folder' '\u6587\u4ef6\u5939') + '</th><th>' + (& $span 'On your PC' '\u5728\u4f60\u7684\u7535\u8111\u4e0a') + '</th><th>' + (& $span 'Path inside this VM' '\u5728\u865a\u62df\u673a\u91cc\u7684\u8def\u5f84') + '</th><th>' + (& $span 'Access' '\u6743\u9650') + '</th></tr>')
        foreach ($row in $book) {
            $access = & $span 'Read-only' '\u53ea\u8bfb'
            if ($row.Writable) { $access = & $span 'Writable' '\u53ef\u5199' }
            $lines.Add('<tr><td>' + (ConvertTo-HouseHtmlText -Value ([string]$row.Name)) + '</td><td><code>' + (ConvertTo-HouseHtmlText -Value ([string]$row.HostPath)) + '</code></td><td><code>' + (ConvertTo-HouseHtmlText -Value ([string]$row.VmPath)) + '</code></td><td>' + $access + '</td></tr>')
        }
        $lines.Add('</table>')
        $lines.Add('<ul>')
        & $both 'li' 'These are your real files, not copies. Claude can change or delete anything in a Writable folder, so keep that work in git or backed up.' '\u8fd9\u4e9b\u662f\u4f60\u7535\u8111\u4e0a\u7684\u771f\u6587\u4ef6\uff0c\u4e0d\u662f\u526f\u672c\u3002\u201c\u53ef\u5199\u201d\u6587\u4ef6\u5939\u91cc\u7684\u4e1c\u897f\uff0cClaude \u90fd\u80fd\u6539\uff0c\u4e5f\u80fd\u5220\uff0c\u6240\u4ee5\u91cc\u9762\u7684\u5de5\u4f5c\u8bf7\u7528 git \u7ba1\u8d77\u6765\uff0c\u6216\u8005\u53e6\u5916\u5907\u4efd\u3002'
        & $both 'li' 'Everything else stays inside this VM. To move files in or out, put them in one of these folders.' '\u9664\u6b64\u4e4b\u5916\u7684\u4e1c\u897f\u90fd\u53ea\u7559\u5728\u865a\u62df\u673a\u91cc\u3002\u60f3\u628a\u6587\u4ef6\u62ff\u8fdb\u6765\u6216\u62ff\u51fa\u53bb\uff0c\u5c31\u653e\u8fdb\u4e0a\u9762\u8fd9\u4e9b\u6587\u4ef6\u5939\u3002'
        $lines.Add('</ul>')
    }

    & $both 'h2' 'Internet' '\u4e0a\u7f51'
    $lines.Add('<ul>')
    & $both 'li' '"No internet" on the taskbar is normal. Windows checks with its own test, and that test does not use the gate.' '\u4efb\u52a1\u680f\u4e0a\u663e\u793a \u201cNo internet\u201d \u662f\u6b63\u5e38\u7684\u3002Windows \u7528\u81ea\u5df1\u7684\u65b9\u6cd5\u68c0\u6d4b\u7f51\u7edc\uff0c\u8fd9\u4e2a\u68c0\u6d4b\u4e0d\u8d70\u90a3\u9053\u95e8\uff0c\u6240\u4ee5\u5b83\u4ee5\u4e3a\u6ca1\u7f51\u3002'
    & $both 'li' 'If nothing loads, make sure the proxy app is running on your PC, then run <code>house doctor</code> there.' '\u5982\u679c\u7f51\u9875\u90fd\u6253\u4e0d\u5f00\uff0c\u5148\u786e\u8ba4\u4f60\u7535\u8111\u4e0a\u7684\u4ee3\u7406\u8f6f\u4ef6\u5f00\u7740\uff0c\u518d\u5728\u4f60\u7535\u8111\u4e0a\u8fd0\u884c <code>house doctor</code>\u3002'
    & $both 'li' 'Programs that ignore proxy settings cannot get online here. That is by design.' '\u4e0d\u8ba4\u4ee3\u7406\u8bbe\u7f6e\u7684\u7a0b\u5e8f\u5728\u8fd9\u91cc\u4e0a\u4e0d\u4e86\u7f51\uff0c\u8fd9\u662f\u6709\u610f\u8fd9\u6837\u8bbe\u8ba1\u7684\u3002'
    $lines.Add('</ul>')

    & $both 'h2' 'Every day' '\u65e5\u5e38\u4f7f\u7528'
    $lines.Add('<ul>')
    & $both 'li' 'Sign in to Windows as <code>{user}</code>. The first password is <code>123456</code>. Change it soon: on your PC, follow "Change the VM password" in <code>runbook/daily.md</code>, so the house learns the new one too.' '\u767b\u5f55 Windows \u7684\u7528\u6237\u540d\u662f <code>{user}</code>\uff0c\u521d\u59cb\u5bc6\u7801\u662f <code>123456</code>\u3002\u8bf7\u5c3d\u5feb\u6539\u6389\uff1a\u5728\u4f60\u7684\u7535\u8111\u4e0a\u6309 <code>runbook/daily.md</code> \u91cc \u201cChange the VM password\u201d \u4e00\u8282\u6765\u6539\uff0c\u8fd9\u6837 house \u4e5f\u4f1a\u8bb0\u4f4f\u65b0\u5bc6\u7801\u3002'
    & $both 'li' 'To turn it off, use Start &gt; Power &gt; Shut down. Closing the console window does not turn the VM off.' '\u5173\u673a\u8bf7\u70b9 Start &gt; Power &gt; Shut down\uff08\u5f00\u59cb &gt; \u7535\u6e90 &gt; \u5173\u673a\uff09\u3002\u53ea\u5173\u6389\u865a\u62df\u673a\u7a97\u53e3\uff0c\u865a\u62df\u673a\u5e76\u4e0d\u4f1a\u5173\u673a\u3002'
    & $both 'li' 'To update Claude Code, run <code>claude update</code> in Terminal.' '\u66f4\u65b0 Claude Code\uff1a\u5728\u7ec8\u7aef\u91cc\u8fd0\u884c <code>claude update</code>\u3002'
    & $both 'li' 'Windows here is not activated. The watermark in the bottom-right corner is normal and does not affect Claude. To remove it, add your own licence in Settings &gt; System &gt; Activation.' '\u8fd9\u91cc\u7684 Windows \u6ca1\u6709\u6fc0\u6d3b\uff0c\u53f3\u4e0b\u89d2\u7684\u6c34\u5370\u662f\u6b63\u5e38\u7684\uff0c\u4e0d\u5f71\u54cd Claude\u3002\u60f3\u53bb\u6389\u6c34\u5370\uff0c\u53ef\u4ee5\u5728 Settings &gt; System &gt; Activation \u91cc\u586b\u4e0a\u4f60\u81ea\u5df1\u7684\u8bb8\u53ef\u8bc1\u3002'
    & $both 'li' 'This VM uses the time zone <code>{tz}</code> and the language <code>{locale}</code> from your blueprint. To type Chinese, add a keyboard in Settings &gt; Time &amp; language &gt; Language &amp; region, then switch with Win+Space.' '\u8fd9\u53f0\u865a\u62df\u673a\u7684\u65f6\u533a\u662f <code>{tz}</code>\uff0c\u8bed\u8a00\u662f <code>{locale}</code>\uff0c\u90fd\u6765\u81ea\u4f60\u7684\u914d\u7f6e\u6587\u4ef6\uff08blueprint\uff09\u3002\u8981\u6253\u4e2d\u6587\uff0c\u5728 Settings &gt; Time &amp; language &gt; Language &amp; region \u91cc\u6dfb\u52a0\u4e2d\u6587\u952e\u76d8\uff0c\u7136\u540e\u6309 Win+\u7a7a\u683c \u5207\u6362\u3002'
    $lines.Add('</ul>')

    & $both 'h2' 'Something wrong?' '\u51fa\u95ee\u9898\u4e86\uff1f'
    $lines.Add('<ul>')
    & $both 'li' 'On your PC, in the claude-house folder, run <code>house doctor</code>, then <code>house next</code>.' '\u5728\u4f60\u7535\u8111\u4e0a\u7684 claude-house \u6587\u4ef6\u5939\u91cc\uff0c\u5148\u8fd0\u884c <code>house doctor</code>\uff0c\u518d\u8fd0\u884c <code>house next</code>\u3002'
    & $both 'li' 'Or ask the Claude on your PC to do it for you.' '\u4e5f\u53ef\u4ee5\u76f4\u63a5\u8ba9\u4f60\u7535\u8111\u4e0a\u7684 Claude \u5e2e\u4f60\u505a\u3002'
    $lines.Add('</ul>')

    $toolNames = New-Object System.Collections.Generic.List[string]
    $toolNames.Add('Git')
    $toolNames.Add('Claude Code')
    $optionalTools = @(
        @{ Key = 'Python'; Label = 'Python' },
        @{ Key = 'Node'; Label = 'Node.js' },
        @{ Key = 'ClaudeDesktop'; Label = 'Claude desktop' },
        @{ Key = 'GitHubCli'; Label = 'GitHub CLI' },
        @{ Key = 'VSCode'; Label = 'VS Code' }
    )
    foreach ($tool in $optionalTools) {
        if (Test-HouseBoolValue -Value (Get-HousePropertyValue -Object $tools -Name $tool.Key)) { $toolNames.Add($tool.Label) }
    }
    $listComma = ConvertFrom-HouseUnicodeEscape -Text '\u3001'
    $hookEn = New-Object System.Collections.Generic.List[string]
    $hookZh = New-Object System.Collections.Generic.List[string]
    foreach ($hook in @(Get-HousePropertyValue -Object $rules -Name 'Hooks')) {
        if ($null -eq $hook) { continue }
        $hookName = [string]$hook
        if (-not $hookName) { continue }
        $code = '<code>' + (ConvertTo-HouseHtmlText -Value $hookName) + '</code>'
        $en = $code
        $zh = $code
        $description = Get-HouseHookDescription -Name $hookName
        if ($description) { $en += ' (' + $description + ')' }
        $descriptionZh = Get-HouseHookDescription -Name $hookName -Chinese
        if ($descriptionZh) { $zh += (ConvertFrom-HouseUnicodeEscape -Text '\uff08') + $descriptionZh + (ConvertFrom-HouseUnicodeEscape -Text '\uff09') }
        $hookEn.Add($en)
        $hookZh.Add($zh)
    }

    $lines.Add('<footer>')
    $lines.Add('<p class="en"><strong>Installed:</strong> ' + ($toolNames.ToArray() -join ', ') + '.</p>')
    $lines.Add('<p class="zh" lang="zh-CN"><strong>' + (ConvertFrom-HouseUnicodeEscape -Text '\u5df2\u5b89\u88c5\uff1a') + '</strong>' + ($toolNames.ToArray() -join $listComma) + (ConvertFrom-HouseUnicodeEscape -Text '\u3002') + '</p>')
    if ($hookEn.Count -eq 0) {
        & $both 'p' '<strong>House rules:</strong> none are switched on.' '<strong>\u9632\u62a4\u89c4\u5219\uff1a</strong>\u4e00\u6761\u90fd\u6ca1\u5f00\u3002'
    }
    else {
        $lines.Add('<p class="en"><strong>House rules:</strong> ' + ($hookEn.ToArray() -join ', ') + '.</p>')
        $lines.Add('<p class="zh" lang="zh-CN"><strong>' + (ConvertFrom-HouseUnicodeEscape -Text '\u9632\u62a4\u89c4\u5219\uff1a') + '</strong>' + ($hookZh.ToArray() -join $listComma) + (ConvertFrom-HouseUnicodeEscape -Text '\u3002') + '</p>')
    }
    $lines.Add('</footer>')
    $lines.Add('</main>')
    $lines.Add('</div>')
    $lines.Add('</body>')
    $lines.Add('</html>')
    return (($lines.ToArray() -join "`n") + "`n")
}

function Format-HousePage {
    param(
        [string]$Content,
        $Config
    )
    if ($null -eq $Config) { return $Content }
    $map = @{
        '{{House.Name}}'           = [string]$Config.House.Name
        '{{House.Path}}'           = [string]$Config.House.Path
        '{{House.IsoPath}}'        = [string]$Config.House.IsoPath
        '{{House.ImageName}}'      = [string]$Config.House.ImageName
        '{{House.CpuCount}}'       = [string]$Config.House.CpuCount
        '{{House.MemoryGB}}'       = [string]$Config.House.MemoryGB
        '{{House.DiskGB}}'         = [string]$Config.House.DiskGB
        '{{House.Locale}}'         = [string]$Config.House.Locale
        '{{House.TimeZone}}'       = [string]$Config.House.TimeZone
        '{{House.ComputerName}}'   = [string](Get-HouseComputerName -Config $Config)
        '{{Network.HostIP}}'       = [string]$Config.Network.HostIP
        '{{Network.VmIP}}'         = [string]$Config.Network.VmIP
        '{{Network.Subnet}}'       = [string]$Config.Network.Subnet
        '{{Network.PrefixLength}}' = [string](([string]$Config.Network.Subnet -split '/')[-1])
        '{{Network.GatePort}}'     = [string]$Config.Network.GatePort
        '{{Network.ProxyAppPort}}' = [string]$Config.Network.ProxyAppPort
        '{{Network.SwitchName}}'   = [string]$Config.Network.SwitchName
        '{{House.UserName}}'       = [string]$Config.House.UserName
        '{{Look.Theme}}'           = [string](Get-HouseLookTheme -Config $Config)
    }
    foreach ($key in @($map.Keys)) {
        $Content = $Content.Replace($key, [string]$map[$key])
    }
    $Content = $Content.Replace('{{Tools.Python}}', (Format-HouseBoolToken -Config $Config -Section 'Tools' -Name 'Python'))
    $Content = $Content.Replace('{{Tools.Node}}', (Format-HouseBoolToken -Config $Config -Section 'Tools' -Name 'Node'))
    $Content = $Content.Replace('{{Shares.Literal}}', (Format-HouseShareLiteral -Config $Config))
    return $Content
}

function Get-HouseComputerName {
    param($Config)
    # NetBIOS computer name: letters, digits and hyphen, cut to 15 characters.
    $raw = ''
    if ($null -ne $Config) {
        $house = $null
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains('House')) { $house = $Config['House'] }
        }
        else {
            $houseProp = $Config.PSObject.Properties['House']
            if ($null -ne $houseProp) { $house = $houseProp.Value }
        }
        if ($house -is [System.Collections.IDictionary]) {
            if ($house.Contains('Name')) { $raw = [string]$house['Name'] }
        }
        elseif ($null -ne $house) {
            $nameProp = $house.PSObject.Properties['Name']
            if ($null -ne $nameProp) { $raw = [string]$nameProp.Value }
        }
    }
    $clean = [regex]::Replace([string]$raw, '[^A-Za-z0-9-]', '')
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15) }
    if ($clean.Length -eq 0) { throw 'computer name is empty' }
    return $clean
}

function Get-HouseDesktopShortcutPath {
    param($Config)
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $name = [string]$Config.House.Name
    return (Join-Path $desktop ($name + '.lnk'))
}

function Test-HouseShortcutRunAsAdmin {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -le 0x15) { return $false }
    return (($Bytes[0x15] -band 0x20) -eq 0x20)
}

function Set-HouseShortcutRunAsAdmin {
    param([byte[]]$Bytes)
    # vmconnect needs administrator rights; the flag makes Windows ask for elevation
    # instead of failing with "you do not have permission".
    if ($null -eq $Bytes -or $Bytes.Length -le 0x15) { throw 'shortcut is too small' }
    $copy = New-Object byte[] $Bytes.Length
    [System.Array]::Copy($Bytes, $copy, $Bytes.Length)
    $copy[0x15] = $copy[0x15] -bor 0x20
    return ,$copy
}

function New-HouseShellLink {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    # CreateShortcut on an existing path without Save() is read-only.
    return $shell.CreateShortcut($Path)
}

function Save-HouseShellLink {
    param(
        $Link,
        [string]$Path
    )
    $Link.Save()
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bytes = Set-HouseShortcutRunAsAdmin -Bytes $bytes
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-HouseShortcutIconLocation {
    param(
        $Config,
        [string]$RepoRoot
    )
    $vmconnect = Join-Path $env:WINDIR 'System32\vmconnect.exe'
    $fallback = $vmconnect + ',0'
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-HouseRepoRoot }
    $source = Join-Path (Join-Path (Join-Path $RepoRoot 'assets') 'icons') 'house.ico'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $fallback }
    $house = Get-HousePropertyValue -Object $Config -Name 'House'
    $name = [string](Get-HousePropertyValue -Object $house -Name 'Name')
    if (-not $name) { return $fallback }
    # A copy, so moving or deleting the repo does not break the icon.
    $destDir = Join-Path (Join-Path $env:ProgramData 'claude-house') $name
    if (-not [System.IO.Directory]::Exists($destDir)) {
        [void][System.IO.Directory]::CreateDirectory($destDir)
    }
    $dest = Join-Path $destDir 'house.ico'
    [System.IO.File]::Copy($source, $dest, $true)
    return ($dest + ',0')
}

function Get-HouseDesktopShortcut {
    param($Config)
    $path = Get-HouseDesktopShortcutPath -Config $Config
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $target = ''
    $arguments = ''
    $runAsAdmin = $false
    $icon = ''
    if ($exists) {
        $link = New-HouseShellLink -Path $path
        $target = [string]$link.TargetPath
        $arguments = [string]$link.Arguments
        $icon = [string]$link.IconLocation
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $runAsAdmin = Test-HouseShortcutRunAsAdmin -Bytes $bytes
    }
    return [pscustomobject]@{
        exists     = [bool]$exists
        target     = $target
        arguments  = $arguments
        runAsAdmin = [bool]$runAsAdmin
        icon       = $icon
    }
}

# Writer: step 6 and daily use create the public desktop shortcut. The vm-online check only reads it.
function New-HouseDesktopShortcut {
    param(
        $Config,
        [string]$RepoRoot
    )
    $path = Get-HouseDesktopShortcutPath -Config $Config
    $link = New-HouseShellLink -Path $path
    $vmconnect = Join-Path $env:WINDIR 'System32\vmconnect.exe'
    $houseName = [string]$Config.House.Name
    $link.TargetPath = $vmconnect
    $link.Arguments = 'localhost "' + $houseName + '"'
    $link.WorkingDirectory = Join-Path $env:WINDIR 'System32'
    $link.IconLocation = Get-HouseShortcutIconLocation -Config $Config -RepoRoot $RepoRoot
    $link.Description = 'Open the ' + $houseName + ' virtual machine'
    Save-HouseShellLink -Link $link -Path $path
    New-HouseConsoleSettings -Config $Config | Out-Null
    return $path
}

function Get-HouseConsoleSize {
    param(
        [Parameter(Mandatory = $true)][int]$ScreenWidth,
        [Parameter(Mandatory = $true)][int]$ScreenHeight
    )
    # 80 percent of the primary screen, rounded down to a multiple of 8, never below 1366x768.
    $width = [int]([Math]::Floor(($ScreenWidth * 0.8) / 8) * 8)
    $height = [int]([Math]::Floor(($ScreenHeight * 0.8) / 8) * 8)
    if ($width -lt 1366) { $width = 1366 }
    if ($height -lt 768) { $height = 768 }
    return [pscustomobject]@{
        Width  = $width
        Height = $height
    }
}

function Format-HouseConsoleSettingsXml {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $settings = @(
        @{ Name = 'AudioCaptureRedirectionMode'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'EnablePrinterRedirection'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'FullScreen'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'SmartCardsRedirection'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'RedirectedPnpDevices'; Type = 'System.String'; Value = '' },
        @{ Name = 'ClipboardRedirection'; Type = 'System.Boolean'; Value = 'True' },
        @{ Name = 'DesktopSize'; Type = 'System.Drawing.Size'; Value = ('{0}, {1}' -f $Width, $Height) },
        @{ Name = 'VmServerName'; Type = 'System.String'; Value = $HostName },
        @{ Name = 'RedirectedUsbDevices'; Type = 'System.String'; Value = '' },
        @{ Name = 'SavedConfigExists'; Type = 'System.Boolean'; Value = 'True' },
        @{ Name = 'UseAllMonitors'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'AudioPlaybackRedirectionMode'; Type = 'Microsoft.Virtualization.Client.RdpOptions+AudioPlaybackRedirectionType'; Value = 'AUDIO_MODE_REDIRECT' },
        @{ Name = 'PrinterRedirection'; Type = 'System.Boolean'; Value = 'False' },
        @{ Name = 'RedirectedDrives'; Type = 'System.String'; Value = '' },
        @{ Name = 'VmName'; Type = 'System.String'; Value = $VmName },
        @{ Name = 'SaveButtonChecked'; Type = 'System.Boolean'; Value = 'True' }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<configuration>')
    $lines.Add('    <Microsoft.Virtualization.Client.RdpOptions>')
    foreach ($setting in $settings) {
        $value = [string]$setting.Value
        if ($value -eq '') {
            $valueXml = '<value />'
        }
        else {
            $valueXml = '<value>' + [System.Security.SecurityElement]::Escape($value) + '</value>'
        }
        $lines.Add('        <setting name="' + $setting.Name + '" type="' + $setting.Type + '">' + $valueXml + '</setting>')
    }
    $lines.Add('    </Microsoft.Virtualization.Client.RdpOptions>')
    $lines.Add('</configuration>')
    return (($lines.ToArray() -join "`n") + "`n")
}

function Get-HouseConsoleSettingsPath {
    param($Config)
    $house = Get-HousePropertyValue -Object $Config -Name 'House'
    $name = [string](Get-HousePropertyValue -Object $house -Name 'Name')
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $vm -or $null -eq $vm.Id) { return '' }
    $id = $vm.Id.ToString().ToUpperInvariant()
    $folder = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Hyper-V\Client\1.0'
    return (Join-Path $folder ('vmconnect.rdp.' + $id + '.config'))
}

function Get-HouseConsoleSettings {
    param($Config)
    $path = [string](Get-HouseConsoleSettingsPath -Config $Config)
    $exists = $false
    $saved = $false
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        $exists = $true
        $text = [System.IO.File]::ReadAllText($path)
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.LoadXml($text)
            foreach ($node in @($xml.GetElementsByTagName('setting'))) {
                if ($node.GetAttribute('name') -ne 'SavedConfigExists') { continue }
                $valueNode = @($node.GetElementsByTagName('value')) | Select-Object -First 1
                if ($null -ne $valueNode -and [string]$valueNode.InnerText.Trim() -eq 'True') { $saved = $true }
            }
        }
        catch {
            $saved = $false
        }
    }
    return [pscustomobject]@{
        exists             = [bool]$exists
        path               = $path
        savedConfigExists = [bool]$saved
    }
}

function Set-HouseConsoleSettingsText {
    param(
        [string]$Path,
        [string]$Text
    )
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($folder)
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

# Writer: step 6 stores the vmconnect choice for the user running the block. The check only reads it.
function New-HouseConsoleSettings {
    param($Config)
    $house = Get-HousePropertyValue -Object $Config -Name 'House'
    $name = [string](Get-HousePropertyValue -Object $house -Name 'Name')
    $path = [string](Get-HouseConsoleSettingsPath -Config $Config)
    if (-not $path) { throw 'console settings need a virtual machine id' }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $size = Get-HouseConsoleSize -ScreenWidth ([int]$bounds.Width) -ScreenHeight ([int]$bounds.Height)
    $xml = Format-HouseConsoleSettingsXml -Width $size.Width -Height $size.Height -HostName ([string]$env:COMPUTERNAME) -VmName $name
    Set-HouseConsoleSettingsText -Path $path -Text $xml
    return $path
}

function Get-HouseVmCredentialPath {
    param($Config)
    $name = [string]$Config.House.Name
    $stateRoot = Join-Path (Join-Path $env:ProgramData 'claude-house') $name
    return (Join-Path $stateRoot 'vm-user.cred.xml')
}

# Writer: records a password the human already changed inside Windows, in vm-user.cred.xml. Checks only test that the file exists.
# The house never changes the guest password itself: an administrator reset makes Windows discard the
# user's saved credentials (the step 11 share credential among them), and PowerShell Direct is refused a
# real old -> new change. Changing it in Windows Settings keeps everything.
function Sync-HouseVmPassword {
    param(
        $Config,
        [System.Security.SecureString]$Password
    )
    $name = [string]$Config.House.Name
    $credPath = Get-HouseVmCredentialPath -Config $Config
    $stored = Import-Clixml -LiteralPath $credPath
    # Keep the previous file bytes so a UTF-16 CLIXML can be restored unchanged.
    $oldBytes = [System.IO.File]::ReadAllBytes($credPath)
    $updated = New-Object System.Management.Automation.PSCredential($stored.UserName, $Password)
    Export-Clixml -LiteralPath $credPath -InputObject $updated
    try {
        $proofCred = Import-Clixml -LiteralPath $credPath
        $proven = Invoke-Command -VMName $name -Credential $proofCred -ScriptBlock { $env:USERNAME } -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$proven)) {
            throw 'empty user name'
        }
    }
    catch {
        [System.IO.File]::WriteAllBytes($credPath, $oldBytes)
        throw 'that password does not open the VM; the stored credential was restored'
    }
    return [pscustomobject]@{
        stored = $true
    }
}

function New-HouseContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$ConfigPath
    )
    if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'house.config.psd1' }
    $ctx = @{
        RepoRoot     = $RepoRoot
        ConfigPath   = $ConfigPath
        Config       = $null
        ConfigError  = $null
        InvokeGuest  = $null
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $ctx['Config'] = Import-HouseConfig -Path $ConfigPath
            $ctx['ConfigError'] = $null
        }
        catch {
            $ctx['Config'] = $null
            $ctx['ConfigError'] = $_.Exception.Message
        }
    }
    $ctx['InvokeGuest'] = {
        param(
            [scriptblock]$ScriptBlock,
            [object[]]$ArgumentList
        )
        $name = $null
        if ($ctx.Config -and $ctx.Config['House'] -and $ctx.Config['House']['Name']) {
            $name = [string]$ctx.Config['House']['Name']
        }
        if (-not $name) { throw 'guest credential not set up yet' }
        $stateRoot = Join-Path (Join-Path $env:ProgramData 'claude-house') $name
        $credPath = Join-Path $stateRoot 'vm-user.cred.xml'
        if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
            throw 'guest credential not set up yet'
        }
        $cred = Import-Clixml -LiteralPath $credPath
        $params = @{
            VMName      = $name
            Credential  = $cred
            ScriptBlock = $ScriptBlock
        }
        if ($ArgumentList -and @($ArgumentList).Count -gt 0) {
            $params['ArgumentList'] = $ArgumentList
        }
        return Invoke-Command @params
    }.GetNewClosure()
    return $ctx
}

Export-ModuleMember -Function @(
    'Get-HouseRepoRoot',
    'Get-HouseComputerName',
    'ConvertFrom-HouseFrontMatter',
    'Get-HouseSteps',
    'Import-HouseConfig',
    'Invoke-HouseCheck',
    'Invoke-HouseStepStatus',
    'New-HouseContext',
    'Test-HouseElevation',
    'Get-HouseHyperVSkus',
    'Test-HouseHyperVEdition',
    'Test-HouseHomeEdition',
    'Test-HouseNestedComputer',
    'Get-HouseHostFacts',
    'New-HousePreflightResult',
    'ConvertTo-HouseIpv4UInt64',
    'Test-HouseIpv4InCidr',
    'Test-HouseCidrOverlap',
    'Get-HouseVolumeMediaType',
    'ConvertFrom-HousePortProxyTable',
    'Get-HousePortProxyText',
    'Get-HouseFirewallAddressFilter',
    'Get-HouseFirewallPortFilter',
    'Get-HousePropertyValue',
    'ConvertTo-HouseItemList',
    'Test-HouseAdapterLoopback',
    'Get-HouseUpAdapters',
    'Test-HouseWinHttpProxy',
    'Test-HouseSameGateUrl',
    'Test-HouseListToken',
    'ConvertTo-HouseTcpProbeOutcome',
    'ConvertTo-HouseDnsProbeOutcome',
    'ConvertTo-HouseGateProbeOutcome',
    'ConvertTo-HouseWriteProbeOutcome',
    'Test-HouseForbiddenMirrorPath',
    'Format-HousePage',
    'Get-HouseAddressBook',
    'Get-HouseShareRoots',
    'Format-HouseRulesBlock',
    'Format-HouseRootsJson',
    'ConvertTo-HouseRulesHash',
    'Get-HouseKnownHookNames',
    'Get-HouseHookMatcher',
    'Get-HouseHookSelection',
    'Get-HouseHookCommandLine',
    'Get-HouseLookPalette',
    'Get-HouseLookTheme',
    'Get-HouseLookAccentPalette',
    'ConvertTo-HouseAbgrDword',
    'ConvertTo-HouseBytesHash',
    'ConvertTo-HouseTextHash',
    'New-HouseWallpaper',
    'New-HouseAvatar',
    'ConvertTo-HouseScaledPng',
    'Get-HouseLookBytes',
    'Get-HouseStartPinsJson',
    'Format-HouseTaskbarLayoutXml',
    'Test-HouseShortcutRunAsAdmin',
    'Set-HouseShortcutRunAsAdmin',
    'Get-HouseDesktopShortcut',
    'New-HouseDesktopShortcut',
    'Get-HouseConsoleSize',
    'Format-HouseConsoleSettingsXml',
    'Get-HouseConsoleSettings',
    'New-HouseConsoleSettings',
    'Sync-HouseVmPassword',
    'Get-HouseCursorRoleNames',
    'Get-HouseCursorGuestPath',
    'Get-HouseCursorScheme',
    'Format-HouseCursorSchemeValue',
    'Get-HouseTerminalArtPaths',
    'Get-HouseShareShortcutPlan',
    'Format-HouseTerminalFragment',
    'Format-HouseWelcomeHtml',
    'New-HouseShellLink',
    'Save-HouseShellLink',
    'Get-HouseShortcutIconLocation',
    'Get-HouseGuestNetworkProbe',
    'Get-HouseOneWayOutProbe'
)

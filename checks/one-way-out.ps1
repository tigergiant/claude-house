param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/08-one-way-out.md#if-it-fails'
$itemNames = @('notcp', 'nodns', 'noroute', 'gate')

function ConvertTo-OneWayResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'one-way-out'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-OneWayEvidence {
    param(
        [bool]$NoTcp,
        [bool]$NoDns,
        [bool]$NoRoute,
        [bool]$Gate,
        $Tcp,
        $Dns,
        $GateStatus
    )
    return [pscustomobject]@{
        notcp      = $NoTcp
        nodns      = $NoDns
        noroute    = $NoRoute
        gate       = $Gate
        tcp        = @($Tcp)
        dns        = @($Dns)
        gateStatus = $GateStatus
    }
}

$emptyEvidence = ConvertTo-OneWayEvidence -NoTcp $false -NoDns $false -NoRoute $false -Gate $false -Tcp @() -Dns @() -GateStatus $null
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-OneWayResult -Ok $false -Detail 'blueprint not loaded' -Evidence $emptyEvidence)
}

$network = $config.Network
$hostIp = [string]$network.HostIP
$gatePort = [int]$network.GatePort
$gateUrl = 'http://' + $hostIp + ':' + [string]$gatePort

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-HouseOneWayOutProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @($gateUrl)
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$notcp = $false
$nodns = $false
$noroute = $false
$gate = $false
$gateStatus = $null
$tcpEvidence = New-Object System.Collections.Generic.List[object]
$dnsEvidence = New-Object System.Collections.Generic.List[object]
$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add($guestError) }

if ($null -ne $guest) {
    $observedError = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observedError) { $notes.Add($observedError) }

    $tcpRows = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'tcp')
    $tcpOk = $true
    # Port 443 to public resolvers is filtered by some national networks, so a timeout there proves nothing on its own; port 53 is the second witness.
    foreach ($target in @('1.1.1.1:443', '9.9.9.9:443', '1.1.1.1:53', '9.9.9.9:53')) {
        $match = $null
        foreach ($row in $tcpRows) {
            if ([string](Get-HousePropertyValue -Object $row -Name 'target') -eq $target) { $match = $row; break }
        }
        $outcome = ''
        $errorText = ''
        if ($null -ne $match) {
            $outcome = [string](Get-HousePropertyValue -Object $match -Name 'outcome')
            $errorText = [string](Get-HousePropertyValue -Object $match -Name 'error')
        }
        if ($outcome -ne 'blocked') { $tcpOk = $false }
        if ($outcome -eq 'probe-error' -and $errorText) { $notes.Add($target + ' ' + $errorText) }
        $tcpEvidence.Add([pscustomobject]@{ target = $target; outcome = $outcome; error = $errorText })
    }
    $notcp = $tcpOk

    $dnsRows = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'dns')
    $dnsOk = $true
    foreach ($target in @('example.com', 'example.com@1.1.1.1')) {
        $match = $null
        foreach ($row in $dnsRows) {
            if ([string](Get-HousePropertyValue -Object $row -Name 'target') -eq $target) { $match = $row; break }
        }
        $outcome = ''
        $errorText = ''
        $category = ''
        if ($null -ne $match) {
            $outcome = [string](Get-HousePropertyValue -Object $match -Name 'outcome')
            $errorText = [string](Get-HousePropertyValue -Object $match -Name 'error')
            $category = [string](Get-HousePropertyValue -Object $match -Name 'category')
        }
        if ($outcome -ne 'blocked') { $dnsOk = $false }
        if ($outcome -eq 'probe-error' -and $errorText) { $notes.Add($target + ' ' + $errorText) }
        $dnsEvidence.Add([pscustomobject]@{
            target   = $target
            outcome  = $outcome
            error    = $errorText
            category = $category
        })
    }
    $nodns = $dnsOk

    $adapters = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'adapters')
    $up = Get-HouseUpAdapters -Adapters $adapters
    $routes = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'routes')
    $viaHost = 0
    $otherHop = $false
    foreach ($route in $routes) {
        $dest = [string](Get-HousePropertyValue -Object $route -Name 'DestinationPrefix')
        if ($dest -ne '0.0.0.0/0') { continue }
        $hop = [string](Get-HousePropertyValue -Object $route -Name 'NextHop')
        if ($hop -eq $hostIp) { $viaHost++ }
        else { $otherHop = $true }
    }
    $noroute = (-not $otherHop) -and ($viaHost -eq 1) -and ($up.Count -eq 1)

    $gateRow = Get-HousePropertyValue -Object $guest -Name 'gate'
    $reachedValue = Get-HousePropertyValue -Object $gateRow -Name 'reached'
    $reached = ($reachedValue -eq $true) -or ([string]$reachedValue -eq 'True')
    $rawStatus = Get-HousePropertyValue -Object $gateRow -Name 'status'
    if ($null -ne $rawStatus -and [string]$rawStatus -ne '') {
        $parsedStatus = 0
        if ([int]::TryParse([string]$rawStatus, [ref]$parsedStatus)) { $gateStatus = $parsedStatus }
    }
    $gate = $reached -and ($null -ne $gateStatus)
}

$flags = @{
    notcp   = [bool]$notcp
    nodns   = [bool]$nodns
    noroute = [bool]$noroute
    gate    = [bool]$gate
}
$failing = New-Object System.Collections.Generic.List[string]
foreach ($name in $itemNames) {
    if (-not $flags[$name]) { $failing.Add($name) }
}
$detail = 'one way out'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
$cleanNotes = New-Object System.Collections.Generic.List[string]
foreach ($note in @($notes.ToArray())) {
    if ($note) { $cleanNotes.Add([string]$note) }
}
if ($cleanNotes.Count -gt 0) {
    $suffix = ($cleanNotes.ToArray() -join '; ')
    if ($failing.Count -eq 0) { $detail = $suffix }
    else { $detail = $detail + '; ' + $suffix }
}
$evidence = ConvertTo-OneWayEvidence -NoTcp $notcp -NoDns $nodns -NoRoute $noroute -Gate $gate -Tcp @($tcpEvidence.ToArray()) -Dns @($dnsEvidence.ToArray()) -GateStatus $gateStatus
$ok = ($failing.Count -eq 0)
return (ConvertTo-OneWayResult -Ok $ok -Detail $detail -Evidence $evidence)

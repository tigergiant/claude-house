param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/02-host-network.md#if-it-fails'

function ConvertTo-HostNetworkResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'host-network'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-HostNetworkEvidence {
    param(
        [bool]$SwitchFound,
        $SwitchType,
        [bool]$HostIp,
        [bool]$PrefixOk,
        [bool]$NoNat,
        [string[]]$NatNames,
        [bool]$NoForward = $false,
        [string[]]$ForwardingFamilies = @()
    )
    $stored = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($NatNames)) {
        if ([string]::IsNullOrEmpty([string]$name)) { continue }
        $stored.Add([string]$name)
    }
    return [pscustomobject]@{
        switch     = $SwitchFound
        switchType = $SwitchType
        hostip     = $HostIp
        prefixOk   = $PrefixOk
        nonat      = $NoNat
        natNames   = [string[]]$stored.ToArray()
        noforward  = $NoForward
        forwarding = [string[]]@($ForwardingFamilies | Where-Object { $_ })
    }
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-HostNetworkResult -Ok $false -Detail 'blueprint not loaded' -Evidence (ConvertTo-HostNetworkEvidence -SwitchFound $false -SwitchType $null -HostIp $false -PrefixOk $false -NoNat $false -NatNames @() -NoForward $false -ForwardingFamilies @()))
}

$network = $config.Network
$switchName = [string]$network.SwitchName
$subnet = [string]$network.Subnet
$expectedHost = [string]$network.HostIP

$switches = @(Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$switchFound = $false
$switchType = $null
if ($switches.Count -eq 1) {
    $switchFound = $true
    $switchType = [string]$switches[0].SwitchType
}
$switchInternal = $switchFound -and ($switchType -eq 'Internal')

$wantPrefix = -1
if ($subnet -match '/(\d{1,2})$') { $wantPrefix = [int]$Matches[1] }
$alias = 'vEthernet (' + $switchName + ')'
$addresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $alias -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$hostip = $false
$prefixOk = $false
foreach ($address in $addresses) {
    if ([string]$address.IPAddress -ne $expectedHost) { continue }
    $hostip = $true
    if ([int]$address.PrefixLength -eq $wantPrefix) { $prefixOk = $true }
}

$natNameList = New-Object System.Collections.Generic.List[string]
$nats = @(Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
foreach ($nat in $nats) {
    $prefixText = ([string]$nat.InternalIPInterfaceAddressPrefix).Trim()
    if ($prefixText -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { continue }
    $rightIp = $Matches[1]
    $rightPrefix = [int]$Matches[2]
    if (Test-HouseCidrOverlap -LeftCidr $subnet -RightIp $rightIp -RightPrefix $rightPrefix) {
        $natNameList.Add([string]$nat.Name)
    }
}
$nonat = ($natNameList.Count -eq 0)
$natNames = @([string[]]$natNameList.ToArray())

# A host that routes for this interface hands the house a second way out, NAT or not.
$ipInterfaces = @(Get-NetIPInterface -InterfaceAlias $alias -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$forwardingList = New-Object System.Collections.Generic.List[string]
foreach ($ipInterface in $ipInterfaces) {
    if ([string]$ipInterface.Forwarding -eq 'Enabled') { $forwardingList.Add([string]$ipInterface.AddressFamily) }
}
$noforward = ($ipInterfaces.Count -gt 0) -and ($forwardingList.Count -eq 0)
$forwardingFamilies = @([string[]]$forwardingList.ToArray())

$failing = New-Object System.Collections.Generic.List[string]
if (-not $switchFound) { $failing.Add('switch') }
elseif (-not $switchInternal) { $failing.Add('switchType') }
if (-not $hostip) { $failing.Add('hostip') }
elseif (-not $prefixOk) { $failing.Add('prefixOk') }
if (-not $nonat) { $failing.Add(('nonat: ' + ($natNames -join ', '))) }
if ($switchFound -and -not $noforward) { $failing.Add('noforward') }

$detail = 'house network ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }

return (ConvertTo-HostNetworkResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-HostNetworkEvidence -SwitchFound $switchFound -SwitchType $switchType -HostIp $hostip -PrefixOk $prefixOk -NoNat $nonat -NatNames $natNames -NoForward $noforward -ForwardingFamilies $forwardingFamilies))

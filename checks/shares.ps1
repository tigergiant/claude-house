param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/10-shares.md#if-it-fails'

function ConvertTo-SharesResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'shares'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-SharesEvidence {
    param(
        [bool]$Account,
        [bool]$Credential,
        [bool]$SharesOk,
        [bool]$SmbFirewall,
        [string[]]$ShareNames
    )
    return [pscustomobject]@{
        account     = $Account
        credential  = $Credential
        shares      = $SharesOk
        smbfirewall = $SmbFirewall
        shareNames  = @($ShareNames)
    }
}

function Test-SharesAccountName {
    param([string]$Account, [string]$Expected)
    if (-not $Account -or -not $Expected) { return $false }
    if ($Account -eq $Expected) { return $true }
    return $Account -match ('(?i)(^|\\)' + [regex]::Escape($Expected) + '$')
}

function ConvertTo-SharesPathKey {
    param([string]$Path)
    if (-not $Path) { return '' }
    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Test-SharesFlag {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ([string]$Value -eq 'True') { return $true }
    return $false
}

$empty = ConvertTo-SharesEvidence -Account $false -Credential $false -SharesOk $false -SmbFirewall $false -ShareNames @()
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-SharesResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$house = Get-HousePropertyValue -Object $config -Name 'House'
$network = Get-HousePropertyValue -Object $config -Name 'Network'
$houseName = [string](Get-HousePropertyValue -Object $house -Name 'Name')
$vmIp = [string](Get-HousePropertyValue -Object $network -Name 'VmIP')
$shareRows = @(Get-HousePropertyValue -Object $config -Name 'Shares')

$accountOk = $false
$accountNote = ''
try {
    $user = Get-LocalUser -Name 'house-share' -ErrorAction SilentlyContinue
    $exists = $null -ne $user
    $enabled = $false
    if ($exists) {
        $enabledValue = Get-HousePropertyValue -Object $user -Name 'Enabled'
        $enabled = ($enabledValue -eq $true) -or ([string]$enabledValue -eq 'True')
    }
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    $admin = $false
    foreach ($member in $members) {
        if ($null -eq $member) { continue }
        $memberName = [string](Get-HousePropertyValue -Object $member -Name 'Name')
        if (Test-SharesAccountName -Account $memberName -Expected 'house-share') { $admin = $true }
    }
    $accountOk = $exists -and $enabled -and -not $admin
    if (-not $exists) { $accountNote = 'house-share is missing' }
    elseif (-not $enabled) { $accountNote = 'house-share is disabled' }
    elseif ($admin) { $accountNote = 'house-share is a member of Administrators' }
}
catch {
    $accountOk = $false
    $accountNote = [string]$_.Exception.Message
    if (-not $accountNote) { $accountNote = [string]$_ }
}

$stateRoot = Join-Path (Join-Path $env:ProgramData 'claude-house') $houseName
$credPath = Join-Path $stateRoot 'share-user.cred.xml'
$credentialOk = Test-Path -LiteralPath $credPath -PathType Leaf

$badShares = New-Object System.Collections.Generic.List[string]
$shareNames = New-Object System.Collections.Generic.List[string]
foreach ($share in $shareRows) {
    if ($null -eq $share) { continue }
    $name = [string](Get-HousePropertyValue -Object $share -Name 'Name')
    $hostPath = [string](Get-HousePropertyValue -Object $share -Name 'HostPath')
    $writable = Test-SharesFlag -Value (Get-HousePropertyValue -Object $share -Name 'Writable')
    if ($name) { $shareNames.Add($name) }
    $found = @(Get-SmbShare -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
    if ($found.Count -ne 1) {
        $badShares.Add($name)
        continue
    }
    $actualPath = [string](Get-HousePropertyValue -Object $found[0] -Name 'Path')
    if ((ConvertTo-SharesPathKey -Path $actualPath) -ne (ConvertTo-SharesPathKey -Path $hostPath)) {
        $badShares.Add($name)
        continue
    }
    $aces = @(Get-SmbShareAccess -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
    $everyone = $false
    $hasRead = $false
    $hasChange = $false
    foreach ($ace in $aces) {
        $accountName = [string](Get-HousePropertyValue -Object $ace -Name 'AccountName')
        $right = [string](Get-HousePropertyValue -Object $ace -Name 'AccessRight')
        if (Test-SharesAccountName -Account $accountName -Expected 'Everyone') { $everyone = $true }
        if (-not (Test-SharesAccountName -Account $accountName -Expected 'house-share')) { continue }
        if ($right -eq 'Read' -or $right -eq '2') { $hasRead = $true }
        if ($right -eq 'Change' -or $right -eq 'Full' -or $right -eq '1' -or $right -eq '0') { $hasChange = $true }
    }
    $accessOk = $false
    if ($writable) { $accessOk = $hasChange }
    else { $accessOk = $hasRead -and -not $hasChange }
    if ($everyone -or -not $accessOk) { $badShares.Add($name) }
}
$sharesOk = ($badShares.Count -eq 0)

$firewall = $false
$rules = @(Get-NetFirewallRule -DisplayName "claude-house SMB" -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
foreach ($rule in $rules) {
    if ([string](Get-HousePropertyValue -Object $rule -Name 'DisplayName') -ne "claude-house SMB") { continue }
    $enabledValue = Get-HousePropertyValue -Object $rule -Name 'Enabled'
    $enabled = ($enabledValue -eq $true) -or ([string]$enabledValue -eq 'True')
    if (-not $enabled) { continue }
    if ([string](Get-HousePropertyValue -Object $rule -Name 'Direction') -ne 'Inbound') { continue }
    if ([string](Get-HousePropertyValue -Object $rule -Name 'Action') -ne 'Allow') { continue }
    $addressFilters = @(Get-HouseFirewallAddressFilter -Rule $rule | Where-Object { $null -ne $_ })
    $portFilters = @(Get-HouseFirewallPortFilter -Rule $rule | Where-Object { $null -ne $_ })
    foreach ($addressFilter in $addressFilters) {
        $remote = [string](Get-HousePropertyValue -Object $addressFilter -Name 'RemoteAddress')
        if ($remote.Trim() -ne $vmIp) { continue }
        foreach ($portFilter in $portFilters) {
            $protocol = [string](Get-HousePropertyValue -Object $portFilter -Name 'Protocol')
            $protocolOk = ($protocol -eq 'TCP') -or ($protocol -eq '6')
            if (-not $protocolOk) { continue }
            $port = [string](Get-HousePropertyValue -Object $portFilter -Name 'LocalPort')
            if ($port.Trim() -ne '445') { continue }
            $firewall = $true
        }
    }
}

$failing = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
if (-not $accountOk) {
    $failing.Add('account')
    if ($accountNote) { $notes.Add($accountNote) }
}
if (-not $credentialOk) { $failing.Add('credential') }
if (-not $sharesOk) { $failing.Add('shares: ' + ($badShares.ToArray() -join ', ')) }
if (-not $firewall) { $failing.Add('smbfirewall') }
$detail = 'shares ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
if ($notes.Count -gt 0) { $detail = $detail + '; ' + ($notes.ToArray() -join '; ') }
return (ConvertTo-SharesResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-SharesEvidence -Account $accountOk -Credential $credentialOk -SharesOk $sharesOk -SmbFirewall $firewall -ShareNames @($shareNames.ToArray())))

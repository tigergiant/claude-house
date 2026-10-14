param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/11-guest-shares.md#if-it-fails'

function ConvertTo-GuestSharesResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'guest-shares'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-GuestSharesEvidence {
    param(
        [bool]$Hostname,
        [bool]$Credential,
        [bool]$Reach,
        [bool]$Mirror,
        [bool]$ReadOnly,
        [bool]$Writable,
        [bool]$Linked,
        $Shares
    )
    return [pscustomobject]@{
        hostname   = $Hostname
        credential = $Credential
        reach      = $Reach
        mirror     = $Mirror
        readonly   = $ReadOnly
        writable   = $Writable
        linked     = $Linked
        shares     = @($Shares)
    }
}

function Test-GuestShareFlag {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ([string]$Value -eq 'True') { return $true }
    return $false
}

function Get-GuestShareLetter {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):[\\/]') { return $Matches[1].ToUpperInvariant() }
    return ''
}

function ConvertTo-GuestShareTarget {
    param([string]$Target)
    if (-not $Target) { return '' }
    $text = $Target.Trim()
    # A UNC link may report its NT form (\??\UNC\server\share or UNC\server\share).
    if ($text.StartsWith('\??\')) { $text = $text.Substring(4) }
    if ($text -match '^(?i)UNC\\') { $text = '\\' + $text.Substring(4) }
    while ($text.Length -gt 2 -and $text.EndsWith('\')) { $text = $text.Substring(0, $text.Length - 1) }
    return $text
}

function Get-GuestShareProbe {
    $classifier = ${function:ConvertTo-HouseWriteProbeOutcome}.ToString()
    $body = @'
$ErrorActionPreference = 'Stop'

function Invoke-HouseShareDirection {
    param([string]$WriteRoot, [string]$ReadRoot)
    $stamp = [guid]::NewGuid().ToString('n')
    $token = 'ok'
    try {
        [System.IO.File]::WriteAllText(($WriteRoot.TrimEnd('\') + '\' + ('.house-probe-' + $stamp)), $token, [System.Text.Encoding]::ASCII)
        $got = [System.IO.File]::ReadAllText($ReadRoot.TrimEnd('\') + '\' + ('.house-probe-' + $stamp))
        if ($got.Trim() -ne $token) {
            return [pscustomobject]@{ outcome = 'fail'; error = 'marker text did not match' }
        }
        return [pscustomobject]@{ outcome = 'ok'; error = '' }
    }
    catch {
        $classified = ConvertTo-HouseWriteProbeOutcome -Succeeded $false -ErrorRecord $_
        $outcome = 'fail'
        if ([string]$classified.outcome -eq 'probe-error') { $outcome = 'probe-error' }
        return [pscustomobject]@{ outcome = $outcome; error = [string]$classified.error }
    }
    finally {
        Remove-Item -LiteralPath ($WriteRoot.TrimEnd('\') + '\' + ('.house-probe-' + $stamp)) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($ReadRoot.TrimEnd('\') + '\' + ('.house-probe-' + $stamp)) -Force -ErrorAction SilentlyContinue
    }
}

$resolved = ''
$hostsError = ''
try {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsText = ''
    if (Test-Path -LiteralPath $hostsPath) { $hostsText = [System.IO.File]::ReadAllText($hostsPath) }
    foreach ($line in ($hostsText -split "`r?`n")) {
        $hash = $line.IndexOf('#')
        $text = $line
        if ($hash -ge 0) { $text = $line.Substring(0, $hash) }
        $text = $text.Trim()
        if (-not $text) { continue }
        $parts = @($text -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 2) { continue }
        $aliasIndex = 1
        while ($aliasIndex -lt $parts.Count) {
            if ([string]$parts[$aliasIndex] -eq 'house-host') { $resolved = [string]$parts[0] }
            $aliasIndex++
        }
    }
}
catch {
    $hostsError = [string]$_.Exception.Message
}

$cmdkey = $false
$cmdkeyError = ''
try {
    $cmdkeyText = @(& cmdkey.exe /list | ForEach-Object { "$_" }) -join "`n"
    # The "Target:" label is localized; the target value is not.
    if ($cmdkeyText -match '(?im)[:=\s]house-host\s*$') { $cmdkey = $true }
}
catch {
    $cmdkeyError = [string]$_.Exception.Message
}

$linked = 0
$linkedError = ''
try {
    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $policyItem = Get-ItemProperty -LiteralPath $policy -Name 'EnableLinkedConnections' -ErrorAction Stop
    if ([int]$policyItem.EnableLinkedConnections -eq 1) { $linked = 1 }
}
catch {
    $linkedError = [string]$_.Exception.Message
}

$parsed = $null
if ($ShareJson) { $parsed = ConvertFrom-Json -InputObject $ShareJson }
$shareRows = New-Object System.Collections.Generic.List[object]
if ($null -ne $parsed) {
    foreach ($row in @($parsed)) {
        if ($null -ne $row) { $shareRows.Add($row) }
    }
}
$shareResults = New-Object System.Collections.Generic.List[object]
foreach ($row in $shareRows) {
    $name = [string]$row.name
    $hostPath = [string]$row.hostPath
    $writable = ($row.writable -eq $true)
    $mirror = ($row.mirror -eq $true)
    $letter = ''
    if ($hostPath -match '^([A-Za-z]):[\\/]') { $letter = $Matches[1].ToUpperInvariant() }
    $unc = '\\house-host\' + $name
    $reach = 'fail'
    $reachError = ''
    try {
        $null = @(Get-ChildItem -LiteralPath $unc -Force -ErrorAction Stop)
        $reach = 'ok'
    }
    catch {
        $reachError = [string]$_.Exception.Message
        if (-not $reachError) { $reach = 'probe-error'; $reachError = 'list failed' }
        else { $reach = 'fail' }
    }
    $exists = $false
    $linkType = ''
    $target = ''
    $listed = $false
    $listError = ''
    $dos = ''
    $dosError = ''
    if ($mirror) {
        try {
            if (Test-Path -LiteralPath $hostPath) {
                $item = Get-Item -LiteralPath $hostPath -Force
                $exists = $true
                $linkType = [string]$item.LinkType
                $targets = @($item.Target)
                if ($targets.Count -gt 0 -and $null -ne $targets[0]) { $target = [string]$targets[0] }
            }
        }
        catch {
            $listError = [string]$_.Exception.Message
        }
        if ($exists) {
            try {
                $null = @(Get-ChildItem -LiteralPath $hostPath -Force -ErrorAction Stop)
                $listed = $true
            }
            catch {
                $listed = $false
                if (-not $listError) { $listError = [string]$_.Exception.Message }
            }
        }
        if ($letter -and $letter -ne 'C') {
            try {
                $dosKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices'
                $valueName = $letter + ':'
                $dosItem = Get-ItemProperty -LiteralPath $dosKey -Name $valueName -ErrorAction Stop
                $dosProp = $dosItem.PSObject.Properties[$valueName]
                if ($null -ne $dosProp) { $dos = [string]$dosProp.Value }
            }
            catch {
                $dosError = [string]$_.Exception.Message
            }
        }
    }
    $write = 'skipped'
    $writeError = ''
    $forward = 'skipped'
    $forwardError = ''
    $reverse = 'skipped'
    $reverseError = ''
    if (-not $writable) {
        $stamp = [guid]::NewGuid().ToString('n')
        $succeeded = $false
        $failure = $null
        try {
            [System.IO.File]::WriteAllText(($unc.TrimEnd('\') + '\' + ('.house-probe-' + $stamp)), 'ok', [System.Text.Encoding]::ASCII)
            $succeeded = $true
        }
        catch {
            $failure = $_
        }
        finally {
            Remove-Item -LiteralPath ($unc.TrimEnd('\') + '\' + ('.house-probe-' + $stamp)) -Force -ErrorAction SilentlyContinue
        }
        $classified = ConvertTo-HouseWriteProbeOutcome -Succeeded $succeeded -ErrorRecord $failure
        $write = [string]$classified.outcome
        $writeError = [string]$classified.error
    }
    else {
        $forwardRoot = $unc
        $forwardRead = $unc
        $reverseRoot = $unc
        $reverseRead = $unc
        if ($mirror -and $hostPath) {
            $forwardRoot = $hostPath
            $forwardRead = $unc
            $reverseRoot = $unc
            $reverseRead = $hostPath
        }
        $forwardResult = Invoke-HouseShareDirection -WriteRoot $forwardRoot -ReadRoot $forwardRead
        $reverseResult = Invoke-HouseShareDirection -WriteRoot $reverseRoot -ReadRoot $reverseRead
        $forward = [string]$forwardResult.outcome
        $forwardError = [string]$forwardResult.error
        $reverse = [string]$reverseResult.outcome
        $reverseError = [string]$reverseResult.error
    }
    $shareResults.Add([pscustomobject]@{
        name = $name
        reach = $reach
        reachError = $reachError
        exists = $exists
        linkType = $linkType
        target = $target
        listed = $listed
        listError = $listError
        dos = $dos
        dosError = $dosError
        write = $write
        writeError = $writeError
        forward = $forward
        forwardError = $forwardError
        reverse = $reverse
        reverseError = $reverseError
    })
}

[pscustomobject]@{
    hosts = [string]$resolved
    hostsError = [string]$hostsError
    cmdkey = [bool]$cmdkey
    cmdkeyError = [string]$cmdkeyError
    linked = [int]$linked
    linkedError = [string]$linkedError
    shares = @($shareResults.ToArray())
    error = $null
}
'@
    $text = "param([string]`$HostIp, [string]`$UserName, [string]`$ShareJson)`r`n"
    $text += "function ConvertTo-HouseWriteProbeOutcome {`r`n" + $classifier + "`r`n}`r`n"
    $text += $body
    return [scriptblock]::Create($text)
}

$empty = ConvertTo-GuestSharesEvidence -Hostname $false -Credential $false -Reach $false -Mirror $false -ReadOnly $false -Writable $false -Linked $false -Shares @()
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-GuestSharesResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$house = Get-HousePropertyValue -Object $config -Name 'House'
$network = Get-HousePropertyValue -Object $config -Name 'Network'
$hostIp = [string](Get-HousePropertyValue -Object $network -Name 'HostIP')
$userName = [string](Get-HousePropertyValue -Object $house -Name 'UserName')
$blueprint = New-Object System.Collections.Generic.List[object]
foreach ($share in @(Get-HousePropertyValue -Object $config -Name 'Shares')) {
    if ($null -eq $share) { continue }
    $blueprint.Add([pscustomobject]@{
        name     = [string](Get-HousePropertyValue -Object $share -Name 'Name')
        hostPath = [string](Get-HousePropertyValue -Object $share -Name 'HostPath')
        writable = (Test-GuestShareFlag -Value (Get-HousePropertyValue -Object $share -Name 'Writable'))
        mirror   = (Test-GuestShareFlag -Value (Get-HousePropertyValue -Object $share -Name 'Mirror'))
    })
}

$refusals = New-Object System.Collections.Generic.List[string]
foreach ($share in $blueprint) {
    if (-not $share.mirror) { continue }
    $reason = Test-HouseForbiddenMirrorPath -HostPath $share.hostPath -UserName $userName
    if ($reason) { $refusals.Add([string]$reason) }
}

$json = '[]'
if ($blueprint.Count -eq 1) {
    $json = '[' + (ConvertTo-Json -InputObject $blueprint[0] -Compress -Depth 4) + ']'
}
elseif ($blueprint.Count -gt 1) {
    $json = ConvertTo-Json -InputObject @($blueprint.ToArray()) -Compress -Depth 4
}

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-GuestShareProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @($hostIp, $userName, $json)
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$notes = New-Object System.Collections.Generic.List[string]
if ($guestError) { $notes.Add($guestError) }
$guestShares = @()
$resolved = ''
$hostsError = ''
$cmdkey = $false
$cmdkeyError = ''
$linkedValue = ''
$linkedError = ''
if ($null -ne $guest) {
    $observed = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observed) { $notes.Add($observed) }
    $resolved = [string](Get-HousePropertyValue -Object $guest -Name 'hosts')
    $hostsError = [string](Get-HousePropertyValue -Object $guest -Name 'hostsError')
    $cmdkeyValue = Get-HousePropertyValue -Object $guest -Name 'cmdkey'
    $cmdkey = ($cmdkeyValue -eq $true) -or ([string]$cmdkeyValue -eq 'True')
    $cmdkeyError = [string](Get-HousePropertyValue -Object $guest -Name 'cmdkeyError')
    $linkedValue = [string](Get-HousePropertyValue -Object $guest -Name 'linked')
    $linkedError = [string](Get-HousePropertyValue -Object $guest -Name 'linkedError')
    $guestShares = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'shares')
}

function Find-GuestShareRow {
    param($Rows, [string]$Name)
    foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        $rowName = [string](Get-HousePropertyValue -Object $row -Name 'name')
        if ($rowName -eq $Name) { return $row }
    }
    return $null
}

$hostnameOk = [string]::Equals($resolved.Trim(), $hostIp, [System.StringComparison]::OrdinalIgnoreCase) -and -not $hostsError
if ($hostsError) { $notes.Add($hostsError) }
$credentialOk = $cmdkey -and -not $cmdkeyError
if ($cmdkeyError) { $notes.Add($cmdkeyError) }
$linkedOk = ($linkedValue -eq '1') -and -not $linkedError
if ($linkedError) { $notes.Add($linkedError) }

$reachOk = $true
$mirrorOk = ($refusals.Count -eq 0)
$readOnlyOk = $true
$writableOk = $true
$shareEvidence = New-Object System.Collections.Generic.List[object]
foreach ($reason in $refusals) { $notes.Add($reason) }

foreach ($share in $blueprint) {
    $row = Find-GuestShareRow -Rows $guestShares -Name $share.name
    $reachOutcome = ''
    $target = ''
    $writeOutcome = ''
    $forwardOutcome = ''
    $reverseOutcome = ''
    if ($null -eq $row) {
        $reachOk = $false
        $notes.Add($share.name + ' reach missing')
        if ($share.mirror) { $mirrorOk = $false }
        if ($share.writable) { $writableOk = $false }
        else { $readOnlyOk = $false }
    }
    else {
        $reachOutcome = [string](Get-HousePropertyValue -Object $row -Name 'reach')
        $reachError = [string](Get-HousePropertyValue -Object $row -Name 'reachError')
        if ($reachOutcome -ne 'ok') {
            $reachOk = $false
            if ($reachOutcome -eq 'probe-error') { $notes.Add($share.name + ' reach probe-error ' + $reachError) }
            elseif ($reachError) { $notes.Add($share.name + ' reach ' + $reachError) }
        }
        $target = ConvertTo-GuestShareTarget -Target ([string](Get-HousePropertyValue -Object $row -Name 'target'))
        $writeOutcome = [string](Get-HousePropertyValue -Object $row -Name 'write')
        $writeError = [string](Get-HousePropertyValue -Object $row -Name 'writeError')
        $forwardOutcome = [string](Get-HousePropertyValue -Object $row -Name 'forward')
        $forwardError = [string](Get-HousePropertyValue -Object $row -Name 'forwardError')
        $reverseOutcome = [string](Get-HousePropertyValue -Object $row -Name 'reverse')
        $reverseError = [string](Get-HousePropertyValue -Object $row -Name 'reverseError')
        if ($share.mirror -and $refusals.Count -eq 0) {
            $existsValue = Get-HousePropertyValue -Object $row -Name 'exists'
            $exists = ($existsValue -eq $true) -or ([string]$existsValue -eq 'True')
            $linkType = [string](Get-HousePropertyValue -Object $row -Name 'linkType')
            $listedValue = Get-HousePropertyValue -Object $row -Name 'listed'
            $listed = ($listedValue -eq $true) -or ([string]$listedValue -eq 'True')
            $expected = '\\house-host\' + $share.name
            $targetOk = [string]::Equals($target, $expected, [System.StringComparison]::OrdinalIgnoreCase)
            $linkOk = $exists -and ($linkType -eq 'SymbolicLink') -and $targetOk -and $listed
            $letter = Get-GuestShareLetter -Path $share.hostPath
            $dosOk = $true
            if ($letter -and $letter -ne 'C') {
                $dos = [string](Get-HousePropertyValue -Object $row -Name 'dos')
                $dosOk = ($dos -eq ('\??\C:\HouseMirror\' + $letter))
            }
            if (-not $linkOk -or -not $dosOk) {
                $mirrorOk = $false
                if (-not $targetOk) { $notes.Add($share.name + ' mirror target ' + $target) }
                elseif (-not $dosOk) { $notes.Add($share.name + ' mirror dos') }
                else { $notes.Add($share.name + ' mirror') }
            }
        }
        if (-not $share.writable) {
            $readPass = $false
            if ($writeOutcome -eq 'access-denied') { $readPass = $true }
            elseif ($writeOutcome -eq 'success') { $readPass = $false }
            elseif ($writeOutcome -eq 'probe-error') { $readPass = $false }
            else { $readPass = $false }
            if (-not $readPass) {
                $readOnlyOk = $false
                $note = $share.name + ' readonly ' + $writeOutcome
                if (-not $writeOutcome -or $writeOutcome -eq 'probe-error') { $note = $share.name + ' readonly probe-error' }
                if ($writeError) { $note = $note + ' ' + $writeError }
                $notes.Add($note)
            }
        }
        else {
            if ($forwardOutcome -ne 'ok' -or $reverseOutcome -ne 'ok') {
                $writableOk = $false
                $notes.Add($share.name + ' writable ' + $forwardOutcome + '/' + $reverseOutcome)
                if ($forwardError) { $notes.Add($forwardError) }
                if ($reverseError) { $notes.Add($reverseError) }
            }
        }
    }
    $shareEvidence.Add([pscustomobject]@{
        name     = [string]$share.name
        reach    = [string]$reachOutcome
        target   = [string]$target
        write    = [string]$writeOutcome
        forward  = [string]$forwardOutcome
        reverse  = [string]$reverseOutcome
    })
}

if ($blueprint.Count -eq 0) {
    $reachOk = $true
    $mirrorOk = ($refusals.Count -eq 0)
    $readOnlyOk = $true
    $writableOk = $true
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $hostnameOk) { $failing.Add('hostname') }
if (-not $credentialOk) { $failing.Add('credential') }
if (-not $reachOk) { $failing.Add('reach') }
if (-not $mirrorOk) { $failing.Add('mirror') }
if (-not $readOnlyOk) { $failing.Add('readonly') }
if (-not $writableOk) { $failing.Add('writable') }
if (-not $linkedOk) { $failing.Add('linked') }

$detail = 'guest shares ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
$clean = New-Object System.Collections.Generic.List[string]
foreach ($note in @($notes.ToArray())) {
    if ($note) { $clean.Add([string]$note) }
}
if ($clean.Count -gt 0) {
    $suffix = ($clean.ToArray() -join '; ')
    if ($suffix.Length -gt 1500) { $suffix = $suffix.Substring(0, 1500) }
    if ($failing.Count -eq 0) { $detail = $suffix }
    else { $detail = $detail + '; ' + $suffix }
}
$evidence = ConvertTo-GuestSharesEvidence -Hostname $hostnameOk -Credential $credentialOk -Reach $reachOk -Mirror $mirrorOk -ReadOnly $readOnlyOk -Writable $writableOk -Linked $linkedOk -Shares @($shareEvidence.ToArray())
return (ConvertTo-GuestSharesResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence $evidence)

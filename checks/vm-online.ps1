param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/06-vm-online.md#if-it-fails'

function ConvertTo-VmOnlineResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'vm-online'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-VmOnlineEvidence {
    param(
        [bool]$Running,
        [bool]$Heartbeat,
        [bool]$PsDirect,
        [bool]$Build,
        [bool]$Name,
        [bool]$UnattendGone,
        [bool]$AutologonGone,
        [bool]$Shortcut,
        [bool]$ConsoleSettings,
        [bool]$PasswordNoExpiry,
        [bool]$Clock
    )
    return [pscustomobject]@{
        running          = $Running
        heartbeat        = $Heartbeat
        psdirect         = $PsDirect
        build            = $Build
        name             = $Name
        unattendGone     = $UnattendGone
        autologonGone    = $AutologonGone
        shortcut         = $Shortcut
        consoleSettings  = $ConsoleSettings
        passwordNoExpiry = $PasswordNoExpiry
        clock            = $Clock
    }
}

function Test-VmOnlineShortcut {
    param(
        $Shortcut,
        [string]$HouseName
    )
    if ($null -eq $Shortcut) { return $false }
    $exists = $false
    $target = ''
    $arguments = ''
    $runAsAdmin = $false
    if ($Shortcut -is [System.Collections.IDictionary]) {
        if ($Shortcut.Contains('exists')) { $exists = [bool]$Shortcut['exists'] }
        if ($Shortcut.Contains('target')) { $target = [string]$Shortcut['target'] }
        if ($Shortcut.Contains('arguments')) { $arguments = [string]$Shortcut['arguments'] }
        if ($Shortcut.Contains('runAsAdmin')) { $runAsAdmin = [bool]$Shortcut['runAsAdmin'] }
    }
    else {
        $exists = [bool]$Shortcut.exists
        $target = [string]$Shortcut.target
        $arguments = [string]$Shortcut.arguments
        $runAsAdmin = [bool]$Shortcut.runAsAdmin
    }
    if (-not $exists) { return $false }
    $targetOk = $target.EndsWith('\vmconnect.exe', [System.StringComparison]::OrdinalIgnoreCase)
    $argsOk = ($arguments.IndexOf($HouseName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    return ($targetOk -and $argsOk -and $runAsAdmin)
}

function Test-VmOnlineConsoleSettings {
    param($Settings)
    if ($null -eq $Settings) { return $false }
    $exists = $false
    $saved = $false
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains('exists')) { $exists = [bool]$Settings['exists'] }
        if ($Settings.Contains('savedConfigExists')) { $saved = [bool]$Settings['savedConfigExists'] }
    }
    else {
        $exists = [bool]$Settings.exists
        $saved = [bool]$Settings.savedConfigExists
    }
    return ($exists -and $saved)
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-VmOnlineResult -Ok $false -Detail 'blueprint not loaded' -Evidence (ConvertTo-VmOnlineEvidence -Running $false -Heartbeat $false -PsDirect $false -Build $false -Name $false -UnattendGone $false -AutologonGone $false -Shortcut $false -ConsoleSettings $false -PasswordNoExpiry $false -Clock $false))
}

$name = [string]$config.House.Name
$shortcutInfo = $null
if ($null -ne $Context -and $Context.ContainsKey('DesktopShortcut')) {
    $shortcutInfo = $Context['DesktopShortcut']
}
else {
    $shortcutInfo = Get-HouseDesktopShortcut -Config $config
}
$shortcutOk = Test-VmOnlineShortcut -Shortcut $shortcutInfo -HouseName $name
$consoleOk = $false
try {
    $consoleInfo = Get-HouseConsoleSettings -Config $config
    $consoleOk = Test-VmOnlineConsoleSettings -Settings $consoleInfo
}
catch {
    $consoleOk = $false
}

$vms = @(Get-VM -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$vm = $null
if ($vms.Count -eq 1) { $vm = $vms[0] }
$running = ($null -ne $vm -and [string]$vm.State -eq 'Running')

$services = @(Get-VMIntegrationService -VMName $name -Name 'Heartbeat' -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
$heartbeat = $false
foreach ($service in $services) {
    # PrimaryStatusDescription is localized ('OK' on an English host, a translated word elsewhere);
    # PrimaryOperationalStatus is an enum and reads 'Ok' in every language.
    if ([string]$service.PrimaryOperationalStatus -eq 'Ok' -or [string]$service.PrimaryStatusDescription -eq 'OK') { $heartbeat = $true }
}

$guestError = $null
$guest = $null
$psdirect = $false
$build = $false
$nameOk = $false
$unattendGone = $false
$autologonGone = $false
$passwordNoExpiry = $false
$clockOk = $false
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $guest = & $Context.InvokeGuest { [pscustomobject]@{ name = $env:COMPUTERNAME; build = [Environment]::OSVersion.Version.Build; unattend = (Test-Path 'C:\Windows\Panther\Unattend.xml') -or (Test-Path 'C:\Windows\System32\Sysprep\Unattend.xml'); autologon = $(
        # First logon must leave no autologon password behind in the Winlogon key.
        $winlogon = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
        ($null -ne $winlogon) -and (($null -ne $winlogon.PSObject.Properties['DefaultPassword']) -or ([string]$winlogon.AutoAdminLogon -eq '1'))
    ); passwordExpires = $(
        try { (Get-LocalUser -Name $env:USERNAME).PasswordExpires }
        catch { Get-Date }
    ); timeService = [string](Get-Service -Name w32time).StartType; utc = (Get-Date).ToUniversalTime().ToString('o') } }
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
    $psdirect = $true
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $psdirect = $false
    $guest = $null
}

if ($psdirect) {
    $buildValue = $null
    $guestName = ''
    $unattendFlag = $null
    $autologonFlag = $null
    $passwordExpiresPresent = $false
    $passwordExpiresValue = $null
    if ($guest -is [System.Collections.IDictionary]) {
        if ($guest.Contains('build')) { $buildValue = $guest['build'] }
        if ($guest.Contains('name')) { $guestName = [string]$guest['name'] }
        if ($guest.Contains('unattend')) { $unattendFlag = $guest['unattend'] }
        if ($guest.Contains('autologon')) { $autologonFlag = $guest['autologon'] }
        if ($guest.Contains('passwordExpires')) {
            $passwordExpiresPresent = $true
            $passwordExpiresValue = $guest['passwordExpires']
        }
    }
    else {
        $buildValue = $guest.build
        $guestName = [string]$guest.name
        $unattendFlag = $guest.unattend
        $autologonFlag = $guest.autologon
        $expiresProp = $guest.PSObject.Properties['passwordExpires']
        if ($null -ne $expiresProp) {
            $passwordExpiresPresent = $true
            $passwordExpiresValue = $expiresProp.Value
        }
    }
    $buildNumber = 0
    $buildParsed = [int]::TryParse([string]$buildValue, [ref]$buildNumber)
    $build = $buildParsed -and ($buildNumber -ge 22000)
    try {
        $nameOk = ($guestName -eq (Get-HouseComputerName -Config $config))
    }
    catch {
        $nameOk = $false
        if (-not $guestError) { $guestError = [string]$_.Exception.Message }
    }
    $unattendGone = ($unattendFlag -eq $false)
    $autologonGone = ($autologonFlag -eq $false)
    # (Get-LocalUser -Name $env:USERNAME).PasswordExpires -eq $null
    $passwordNoExpiry = $passwordExpiresPresent -and ($null -eq $passwordExpiresValue)
    # Hyper-V starts the guest clock from the host's local clock; the time service must run to correct it.
    $timeService = ''
    $guestUtc = ''
    if ($guest -is [System.Collections.IDictionary]) {
        if ($guest.Contains('timeService')) { $timeService = [string]$guest['timeService'] }
        if ($guest.Contains('utc')) { $guestUtc = [string]$guest['utc'] }
    }
    else {
        $timeService = [string]$guest.timeService
        $guestUtc = [string]$guest.utc
    }
    $parsedUtc = [DateTime]::MinValue
    $utcParsed = [DateTime]::TryParse($guestUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedUtc)
    $skew = [double]::MaxValue
    if ($utcParsed) { $skew = [Math]::Abs(([DateTime]::UtcNow - $parsedUtc.ToUniversalTime()).TotalSeconds) }
    $clockOk = $timeService.StartsWith('Automatic', [System.StringComparison]::OrdinalIgnoreCase) -and ($skew -le 300)
}

$failing = New-Object System.Collections.Generic.List[string]
if (-not $running) { $failing.Add('running') }
if (-not $heartbeat) { $failing.Add('heartbeat') }
if (-not $psdirect) { $failing.Add('psdirect') }
if (-not $build) { $failing.Add('build') }
if (-not $nameOk) { $failing.Add('name') }
if (-not $unattendGone) { $failing.Add('unattendGone') }
if (-not $autologonGone) { $failing.Add('autologonGone') }
if (-not $shortcutOk) { $failing.Add('shortcut') }
if (-not $consoleOk) { $failing.Add('consoleSettings') }
if (-not $passwordNoExpiry) { $failing.Add('passwordNoExpiry') }
if (-not $clockOk) { $failing.Add('clock') }

$detail = 'vm online'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
if ($guestError) { $detail = $detail + '; ' + $guestError }

return (ConvertTo-VmOnlineResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence (ConvertTo-VmOnlineEvidence -Running $running -Heartbeat $heartbeat -PsDirect $psdirect -Build $build -Name $nameOk -UnattendGone $unattendGone -AutologonGone $autologonGone -Shortcut $shortcutOk -ConsoleSettings $consoleOk -PasswordNoExpiry $passwordNoExpiry -Clock $clockOk))

param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/10-persona.md#if-it-fails'

function ConvertTo-PersonaResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'persona'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function Get-PersonaProbe {
    return {
        param([string]$Locale, [string]$TimeZone, [int]$ExpectedGeo)
        $ErrorActionPreference = 'Stop'

        function Read-HouseSwitch {
            param([string]$Name)
            $value = [string][Environment]::GetEnvironmentVariable($Name, 'Machine')
            return [pscustomobject]@{ name = $Name; value = $value; ok = ($value -eq '1') }
        }

        $switches = @(
            (Read-HouseSwitch -Name 'DISABLE_TELEMETRY'),
            (Read-HouseSwitch -Name 'DISABLE_ERROR_REPORTING'),
            (Read-HouseSwitch -Name 'DO_NOT_TRACK'),
            (Read-HouseSwitch -Name 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')
        )
        $culture = ''
        try { $culture = [string](Get-Culture).Name } catch { $culture = '' }
        $geoId = $null
        try { $geoId = [int](Get-WinHomeLocation).GeoId } catch { $geoId = $null }
        $zone = ''
        try { $zone = [string](Get-TimeZone).Id } catch { $zone = '' }
        return [pscustomobject]@{
            switches = $switches
            culture  = $culture
            geoId    = $geoId
            timezone = $zone
            error    = $null
        }
    }.GetNewClosure()
}

$empty = [ordered]@{
    telemetry     = $false
    errorReporting = $false
    doNotTrack    = $false
    nonessential  = $false
    culture       = ''
    cultureOk     = $false
    geoId         = $null
    geoOk         = $false
    timezone      = ''
    timezoneOk    = $false
}

$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-PersonaResult -Ok $false -Detail 'blueprint not loaded' -Evidence ([pscustomobject]$empty))
}

$house = $config.House
$locale = [string](Get-HousePropertyValue -Object $house -Name 'Locale')
if (-not $locale) { $locale = 'en-US' }
$timeZone = [string](Get-HousePropertyValue -Object $house -Name 'TimeZone')
if (-not $timeZone) { $timeZone = 'Pacific Standard Time' }
$expectedGeo = $null
try { $expectedGeo = [int](New-Object System.Globalization.RegionInfo($locale)).GeoId } catch { $expectedGeo = $null }

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-PersonaProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @($locale, $timeZone, $(if ($null -ne $expectedGeo) { $expectedGeo } else { 0 }))
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$switchStates = @{}
$culture = ''
$geoId = $null
$zone = ''
if ($null -ne $guest) {
    $observed = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observed) { $guestError = $observed }
    $rows = Get-HousePropertyValue -Object $guest -Name 'switches'
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        $name = [string](Get-HousePropertyValue -Object $row -Name 'name')
        $okValue = Get-HousePropertyValue -Object $row -Name 'ok'
        $switchStates[$name] = ($okValue -eq $true) -or ([string]$okValue -eq 'True')
    }
    $culture = [string](Get-HousePropertyValue -Object $guest -Name 'culture')
    $geoValue = Get-HousePropertyValue -Object $guest -Name 'geoId'
    if ($null -ne $geoValue -and "$geoValue" -ne '') { $geoId = [int]$geoValue }
    $zone = [string](Get-HousePropertyValue -Object $guest -Name 'timezone')
}

$telemetry = $false
if ($switchStates.ContainsKey('DISABLE_TELEMETRY')) { $telemetry = $switchStates['DISABLE_TELEMETRY'] }
$errorReporting = $false
if ($switchStates.ContainsKey('DISABLE_ERROR_REPORTING')) { $errorReporting = $switchStates['DISABLE_ERROR_REPORTING'] }
$doNotTrack = $false
if ($switchStates.ContainsKey('DO_NOT_TRACK')) { $doNotTrack = $switchStates['DO_NOT_TRACK'] }
$nonessential = $false
if ($switchStates.ContainsKey('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')) { $nonessential = $switchStates['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] }

$cultureOk = ($culture -eq $locale)
$timezoneOk = ($zone -eq $timeZone)
$geoOk = $true
if ($null -ne $expectedGeo) { $geoOk = ($null -ne $geoId -and $geoId -eq $expectedGeo) }

$failing = New-Object System.Collections.Generic.List[string]
if (-not $telemetry) { $failing.Add('telemetry') }
if (-not $errorReporting) { $failing.Add('errorReporting') }
if (-not $doNotTrack) { $failing.Add('doNotTrack') }
if (-not $nonessential) { $failing.Add('nonessential') }
if (-not $cultureOk) { $failing.Add('culture') }
if (-not $geoOk) { $failing.Add('geo') }
if (-not $timezoneOk) { $failing.Add('timezone') }

$detail = 'persona aligned'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
if ($guestError) {
    if ($failing.Count -eq 0) { $detail = $guestError } else { $detail = $detail + '; ' + $guestError }
}

$evidence = [ordered]@{
    telemetry      = [bool]$telemetry
    errorReporting = [bool]$errorReporting
    doNotTrack     = [bool]$doNotTrack
    nonessential   = [bool]$nonessential
    culture        = [string]$culture
    cultureOk      = [bool]$cultureOk
    geoId          = $geoId
    geoOk          = [bool]$geoOk
    timezone       = [string]$zone
    timezoneOk     = [bool]$timezoneOk
}
return (ConvertTo-PersonaResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence ([pscustomobject]$evidence))

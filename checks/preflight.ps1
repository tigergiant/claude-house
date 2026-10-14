param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$diskGB = 80
$housePath = ''

if ($null -ne $Context -and ($Context -is [System.Collections.IDictionary]) -and $Context.ContainsKey('Config') -and $null -ne $Context['Config']) {
    $config = $Context['Config']
    $house = $null
    if ($config -is [System.Collections.IDictionary]) {
        if ($config.ContainsKey('House') -or $config.Contains('House')) { $house = $config['House'] }
    }
    else {
        $houseProp = $config.PSObject.Properties['House']
        if ($null -ne $houseProp) { $house = $houseProp.Value }
    }
    if ($null -ne $house) {
        $pathValue = $null
        $diskValue = $null
        if ($house -is [System.Collections.IDictionary]) {
            if ($house.ContainsKey('Path') -or $house.Contains('Path')) { $pathValue = $house['Path'] }
            if ($house.ContainsKey('DiskGB') -or $house.Contains('DiskGB')) { $diskValue = $house['DiskGB'] }
        }
        else {
            $pathProp = $house.PSObject.Properties['Path']
            if ($null -ne $pathProp) { $pathValue = $pathProp.Value }
            $diskProp = $house.PSObject.Properties['DiskGB']
            if ($null -ne $diskProp) { $diskValue = $diskProp.Value }
        }
        if ($null -ne $pathValue) { $housePath = [string]$pathValue }
        if ($null -ne $diskValue -and [string]$diskValue -ne '') {
            $parsedDisk = 0
            if ([int]::TryParse([string]$diskValue, [ref]$parsedDisk)) { $diskGB = $parsedDisk }
        }
    }
}

$facts = Get-HouseHostFacts
$sw.Stop()
New-HousePreflightResult -Facts $facts -DiskGB $diskGB -HousePath $housePath -Milliseconds ([int]$sw.Elapsed.TotalMilliseconds)

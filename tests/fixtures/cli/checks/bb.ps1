param([hashtable]$Context)
$ErrorActionPreference = 'Stop'
$id = 'bb'
$markerDir = $env:HOUSE_MARKER_DIR
if ($markerDir) {
    [System.IO.File]::WriteAllText((Join-Path $markerDir ($id + '.ran')), 'ran')
}
$mode = 'pass'
$spec = $env:HOUSE_CHECK_SPEC
if ($spec) {
    foreach ($part in ($spec -split ';')) {
        $pair = $part -split '=', 2
        if ($pair.Length -eq 2 -and $pair[0] -eq $id) { $mode = $pair[1] }
    }
}
if ($mode -eq 'throw') { throw "boom-$id" }
if ($mode -eq 'invalid') { return [pscustomobject]@{ nope = $true } }
$ok = ($mode -eq 'pass')
[pscustomobject]@{
    id     = $id
    ok     = [bool]$ok
    detail = "detail-$id-$mode"
}

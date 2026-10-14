param([hashtable]$Context)
$ErrorActionPreference = 'Stop'

$fix = 'runbook/13-look.md#if-it-fails'
$itemNames = @('theme', 'accent', 'wallpaper', 'explorer', 'quiet', 'terminal', 'spotlightOff', 'signinScreen', 'avatar', 'taskbar', 'startPins', 'smooth', 'cursors', 'terminalArt', 'shareShortcuts', 'welcome')

function ConvertTo-LookResult {
    param(
        [bool]$Ok,
        [string]$Detail,
        $Evidence
    )
    return [pscustomobject]@{
        id       = 'look'
        ok       = $Ok
        detail   = $Detail
        fix      = $fix
        evidence = $Evidence
    }
}

function ConvertTo-LookEvidence {
    param(
        [bool]$Theme,
        [bool]$Accent,
        [bool]$Wallpaper,
        [bool]$Explorer,
        [bool]$Quiet,
        [bool]$Terminal,
        [bool]$SpotlightOff,
        [bool]$SigninScreen,
        [bool]$Avatar,
        [bool]$Taskbar,
        [bool]$StartPins,
        [bool]$Smooth,
        $Cursors,
        $TerminalArt,
        $ShareShortcuts,
        [bool]$Welcome,
        [string]$LookTheme
    )
    return [pscustomobject]@{
        theme          = $Theme
        accent         = $Accent
        wallpaper      = $Wallpaper
        explorer       = $Explorer
        quiet          = $Quiet
        terminal       = $Terminal
        spotlightOff   = $SpotlightOff
        signinScreen   = $SigninScreen
        avatar         = $Avatar
        taskbar        = $Taskbar
        startPins      = $StartPins
        smooth         = $Smooth
        cursors        = $Cursors
        terminalArt    = $TerminalArt
        shareShortcuts = $ShareShortcuts
        welcome        = $Welcome
        lookTheme      = $LookTheme
    }
}

function Test-LookFlag {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ([string]$Value -eq 'True') { return $true }
    return $false
}

function ConvertTo-LookDword {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    try {
        $n = [int64]$Value
        if ($n -lt 0) { $n = $n + [int64]4294967296 }
        if ($n -lt 0 -or $n -gt [int64]4294967295) { return $null }
        return [uint32]$n
    }
    catch {
        return $null
    }
}

function ConvertTo-LookBytes {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) { return $Value }
    if ($Value -is [string]) {
        $text = ([string]$Value).Trim()
        if ($text -eq '') { return $null }
        if (($text.Length % 2) -ne 0) { return $null }
        try {
            $out = New-Object byte[] ($text.Length / 2)
            for ($i = 0; $i -lt $out.Length; $i++) {
                $out[$i] = [Convert]::ToByte($text.Substring($i * 2, 2), 16)
            }
            return $out
        }
        catch {
            return $null
        }
    }
    $list = New-Object System.Collections.Generic.List[byte]
    foreach ($item in (ConvertTo-HouseItemList -Value $Value)) {
        try { $list.Add([byte][int]$item) }
        catch { return $null }
    }
    return [byte[]]$list.ToArray()
}

function Test-LookBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

function Test-LookIconPath {
    param(
        [string]$Actual,
        [string]$ExpectedPath
    )
    if (-not $Actual -or -not $ExpectedPath) { return $false }
    if ($Actual -eq $ExpectedPath) { return $true }
    if ($Actual -eq ($ExpectedPath + ',0')) { return $true }
    return $false
}

function Test-LookTerminalArtText {
    param(
        [string]$Text,
        [string]$IconPath,
        [string]$BackgroundPath
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $Text }
    catch { return $false }
    $profiles = @($parsed.profiles)
    if ($profiles.Count -lt 1) { return $false }
    foreach ($profile in $profiles) {
        if ($IconPath) {
            $icon = [string](Get-HousePropertyValue -Object $profile -Name 'icon')
            if ($icon -ne $IconPath) { return $false }
        }
        if ($BackgroundPath) {
            $background = [string](Get-HousePropertyValue -Object $profile -Name 'backgroundImage')
            $stretch = [string](Get-HousePropertyValue -Object $profile -Name 'backgroundImageStretchMode')
            $align = [string](Get-HousePropertyValue -Object $profile -Name 'backgroundImageAlignment')
            $opacity = Get-HousePropertyValue -Object $profile -Name 'backgroundImageOpacity'
            if ($background -ne $BackgroundPath) { return $false }
            if ($stretch -ne 'uniformToFill') { return $false }
            if ($align -ne 'bottomRight') { return $false }
            $opacityOk = $false
            try { if ([math]::Round([double]$opacity, 2) -eq 0.08) { $opacityOk = $true } }
            catch { $opacityOk = $false }
            if (-not $opacityOk) { return $false }
        }
    }
    return $true
}

function Test-LookValue {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    if ($Expected -is [string]) {
        return ([string]$Actual).Equals([string]$Expected, [System.StringComparison]::Ordinal)
    }
    return ($Actual -eq $Expected)
}

function Get-LookProbe {
    $body = @'
$ErrorActionPreference = 'Stop'

function Read-HouseRegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $prop = $item.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-HouseProbeHashBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) { [void]$builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function Get-HouseProbeHashText {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $normal = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding $false
    return (Get-HouseProbeHashBytes -Bytes $utf8.GetBytes($normal))
}

$wallpaperExpected = Join-Path (Join-Path $env:USERPROFILE 'Pictures') 'claude-house-wallpaper.png'
$wallpaperPath = [string](Read-HouseRegValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper')
$wallpaperExists = $false
$wallpaperHash = ''
if (Test-Path -LiteralPath $wallpaperExpected -PathType Leaf) {
    $wallpaperExists = $true
    $wallpaperHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($wallpaperExpected))
}
$wallpaperStale = $false
$transcoded = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
if ($wallpaperExists -and (Test-Path -LiteralPath $transcoded -PathType Leaf)) {
    $wallpaperStale = (Get-Item -LiteralPath $transcoded).LastWriteTimeUtc -lt (Get-Item -LiteralPath $wallpaperExpected).LastWriteTimeUtc
}

$lockscreenPath = 'C:\ProgramData\claude-house\look\lockscreen.png'
$lockscreenExists = $false
$lockscreenHash = ''
if (Test-Path -LiteralPath $lockscreenPath -PathType Leaf) {
    $lockscreenExists = $true
    $lockscreenHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($lockscreenPath))
}
$taskbarLayoutPath = 'C:\ProgramData\claude-house\look\taskbar.xml'
$taskbarExists = $false
$taskbarHash = ''
if (Test-Path -LiteralPath $taskbarLayoutPath -PathType Leaf) {
    $taskbarExists = $true
    $taskbarHash = Get-HouseProbeHashText -Text ([System.IO.File]::ReadAllText($taskbarLayoutPath))
}
$userTilePath = 'C:\ProgramData\Microsoft\User Account Pictures\user.png'
$userTileExists = $false
$userTileHash = ''
if (Test-Path -LiteralPath $userTilePath -PathType Leaf) {
    $userTileExists = $true
    $userTileHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($userTilePath))
}

$terminalPath = Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft') 'Windows Terminal') 'Fragments\claude-house') 'claude-house.json'
$terminalExists = Test-Path -LiteralPath $terminalPath -PathType Leaf
$terminalParseOk = $false
$terminalHash = ''
$terminalText = ''
if ($terminalExists) {
    $terminalText = [System.IO.File]::ReadAllText($terminalPath)
    $terminalHash = Get-HouseProbeHashText -Text $terminalText
    try {
        $null = ConvertFrom-Json -InputObject $terminalText
        $terminalParseOk = $true
    }
    catch {
        $terminalParseOk = $false
    }
}

$terminalIconPath = 'C:\ProgramData\claude-house\look\terminal.png'
$terminalIconExists = $false
$terminalIconHash = ''
if (Test-Path -LiteralPath $terminalIconPath -PathType Leaf) {
    $terminalIconExists = $true
    $terminalIconHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($terminalIconPath))
}
$terminalBackgroundPath = 'C:\ProgramData\claude-house\look\terminal-background.png'
$terminalBackgroundExists = $false
$terminalBackgroundHash = ''
if (Test-Path -LiteralPath $terminalBackgroundPath -PathType Leaf) {
    $terminalBackgroundExists = $true
    $terminalBackgroundHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($terminalBackgroundPath))
}

$cursorRoles = @('Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No', 'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person')
$cursorValues = @{}
$cursorHashes = @{}
foreach ($cursorRole in $cursorRoles) {
    $cursorValue = [string](Read-HouseRegValue -Path 'HKCU:\Control Panel\Cursors' -Name $cursorRole)
    $cursorValues[$cursorRole] = $cursorValue
    $cursorHash = ''
    if ($cursorValue -and (Test-Path -LiteralPath $cursorValue -PathType Leaf)) {
        $cursorHash = Get-HouseProbeHashBytes -Bytes ([System.IO.File]::ReadAllBytes($cursorValue))
    }
    $cursorHashes[$cursorRole] = $cursorHash
}
$cursorSchemeSource = Read-HouseRegValue -Path 'HKCU:\Control Panel\Cursors' -Name 'Scheme Source'

$shareShortcutRows = New-Object System.Collections.Generic.List[object]
$desktopPath = [Environment]::GetFolderPath('Desktop')
if ($desktopPath -and (Test-Path -LiteralPath $desktopPath -PathType Container)) {
    # Shell.Application reads Unicode targets; WScript.Shell turns characters outside the ANSI code page into question marks.
    $desktopFolder = (New-Object -ComObject Shell.Application).NameSpace($desktopPath)
    foreach ($shortcutFile in @(Get-ChildItem -LiteralPath $desktopPath -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
        $shortcutLink = $desktopFolder.ParseName($shortcutFile.Name).GetLink
        $shortcutIcon = ''
        $shortcutIconIndex = $shortcutLink.GetIconLocation([ref]$shortcutIcon)
        $shareShortcutRows.Add([pscustomobject]@{
            name   = [System.IO.Path]::GetFileNameWithoutExtension($shortcutFile.Name)
            target = [string]$shortcutLink.Path
            icon   = [string]$shortcutIcon + ',' + [string]$shortcutIconIndex
        })
    }
}

$welcomePagePath = 'C:\ProgramData\claude-house\welcome\index.html'
$welcomeExists = $false
$welcomeHash = ''
if (Test-Path -LiteralPath $welcomePagePath -PathType Leaf) {
    $welcomeExists = $true
    $welcomeHash = Get-HouseProbeHashText -Text ([System.IO.File]::ReadAllText($welcomePagePath))
}
$welcomeShortcutExists = $false
$welcomeShortcutTarget = ''
if ($desktopPath) {
    $welcomeShortcutPath = Join-Path $desktopPath 'Start here.lnk'
    if (Test-Path -LiteralPath $welcomeShortcutPath -PathType Leaf) {
        $welcomeShortcutExists = $true
        $welcomeShortcutTarget = [string]((New-Object -ComObject WScript.Shell).CreateShortcut($welcomeShortcutPath).TargetPath)
    }
}

return [pscustomobject]@{
    appsUseLightTheme          = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme')
    systemUsesLightTheme       = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme')
    personalizeColorPrevalence = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence')
    accentColor                = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor')
    colorizationColor          = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor')
    dwmColorPrevalence         = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorPrevalence')
    accentColorMenu            = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu')
    startColorMenu             = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu')
    accentPalette              = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette')
    wallpaper                  = $wallpaperPath
    wallpaperExpected          = $wallpaperExpected
    wallpaperExists            = [bool]$wallpaperExists
    wallpaperHash              = [string]$wallpaperHash
    wallpaperStale             = [bool]$wallpaperStale
    hideFileExt                = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt')
    launchTo                   = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo')
    startIrisRecommendations   = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations')
    showTaskViewButton         = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton')
    searchboxTaskbarMode       = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode')
    allowNewsAndInterests      = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests')
    widgetsInstalled           = [bool](Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.WebExperience' -ErrorAction SilentlyContinue)
    hideFirstRunExperience     = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience')
    edgeStartupBoost           = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled')
    edgeBackgroundMode         = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled')
    oneDriveDisabled           = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC')
    enableFirstLogonAnimation  = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation')
    enableTransparency         = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency')
    taskbarAnimations          = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations')
    minAnimate                 = (Read-HouseRegValue -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate')
    spotlightEnabledState      = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings' -Name 'EnabledState')
    backgroundType             = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -Name 'BackgroundType')
    disableSpotlightCollection = (Read-HouseRegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableSpotlightCollectionOnDesktop')
    disableWindowsSpotlight    = (Read-HouseRegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsSpotlightFeatures')
    rotatingLockScreenEnabled  = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled')
    rotatingLockScreenOverlay  = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenOverlayEnabled')
    subscribedContent338387    = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338387Enabled')
    systemPaneSuggestionsEnabled = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled')
    silentInstalledAppsEnabled = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled')
    lockScreenImagePath        = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImagePath')
    lockScreenImageUrl         = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageUrl')
    lockScreenImageStatus      = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageStatus')
    disableAcrylicBackgroundOnLogon = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DisableAcrylicBackgroundOnLogon')
    lockscreenExists           = [bool]$lockscreenExists
    lockscreenHash             = [string]$lockscreenHash
    useDefaultTile             = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'UseDefaultTile')
    userTileExists             = [bool]$userTileExists
    userTileHash               = [string]$userTileHash
    turnOffWindowsCopilot      = (Read-HouseRegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot')
    showCopilotButton          = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton')
    searchOnTaskbarMode        = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'SearchOnTaskbarMode')
    startLayoutFile            = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile')
    lockedStartLayout          = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'LockedStartLayout')
    taskbarExists              = [bool]$taskbarExists
    taskbarHash                = [string]$taskbarHash
    configureStartPins         = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins')
    configureStartPinsProviderSet = (Read-HouseRegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins_ProviderSet')
    startTrackDocs             = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackDocs')
    startAccountNotifications  = (Read-HouseRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_AccountNotifications')
    terminalExists             = [bool]$terminalExists
    terminalParseOk            = [bool]$terminalParseOk
    terminalHash               = [string]$terminalHash
    terminalText               = [string]$terminalText
    terminalIconExists         = [bool]$terminalIconExists
    terminalIconHash           = [string]$terminalIconHash
    terminalBackgroundExists   = [bool]$terminalBackgroundExists
    terminalBackgroundHash     = [string]$terminalBackgroundHash
    cursorSchemeSource         = $cursorSchemeSource
    cursorValues               = $cursorValues
    cursorHashes               = $cursorHashes
    shareShortcuts             = @($shareShortcutRows.ToArray())
    welcomeExists              = [bool]$welcomeExists
    welcomeHash                = [string]$welcomeHash
    welcomeShortcutExists      = [bool]$welcomeShortcutExists
    welcomeShortcutTarget      = [string]$welcomeShortcutTarget
    error                      = $null
}
'@
    return [scriptblock]::Create($body)
}

$empty = ConvertTo-LookEvidence -Theme $false -Accent $false -Wallpaper $false -Explorer $false -Quiet $false -Terminal $false -SpotlightOff $false -SigninScreen $false -Avatar $false -Taskbar $false -StartPins $false -Smooth $false -Cursors $false -TerminalArt $false -ShareShortcuts $false -Welcome $false -LookTheme ''
$config = $null
if ($null -ne $Context -and $Context.ContainsKey('Config')) { $config = $Context['Config'] }
if ($null -eq $config) {
    return (ConvertTo-LookResult -Ok $false -Detail 'blueprint not loaded' -Evidence $empty)
}

$lookTheme = Get-HouseLookTheme -Config $config
if ($lookTheme -eq 'none') {
    $skipped = ConvertTo-LookEvidence -Theme $true -Accent $true -Wallpaper $true -Explorer $true -Quiet $true -Terminal $true -SpotlightOff $true -SigninScreen $true -Avatar $true -Taskbar $true -StartPins $true -Smooth $true -Cursors $true -TerminalArt $true -ShareShortcuts $true -Welcome $true -LookTheme 'none'
    return (ConvertTo-LookResult -Ok $true -Detail 'look skipped' -Evidence $skipped)
}

$expectedAccent = ConvertTo-HouseAbgrDword -Hex '#C96442'
$expectedColorization = [Convert]::ToUInt32('C4C96442', 16)
$expectedStartMenu = [Convert]::ToUInt32('FF2C4387', 16)
$expectedPalette = Get-HouseLookAccentPalette
$repoRoot = ''
if ($null -ne $Context -and $Context.ContainsKey('RepoRoot') -and $Context['RepoRoot']) {
    $repoRoot = [string]$Context['RepoRoot']
}
$expectedWallpaperHash = ConvertTo-HouseBytesHash -Bytes (Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'wallpaper.png' -Generate { New-HouseWallpaper })
$expectedLockscreenHash = ConvertTo-HouseBytesHash -Bytes (Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'lockscreen.png' -Generate { New-HouseWallpaper })
$avatarSource = Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'avatar.png' -Generate { New-HouseAvatar -Size 448 }
$expectedUserTileHash = ConvertTo-HouseBytesHash -Bytes (ConvertTo-HouseScaledPng -Bytes $avatarSource -Size 448)
$expectedTaskbarHash = ConvertTo-HouseTextHash -Text (Format-HouseTaskbarLayoutXml)
$expectedStartPins = Get-HouseStartPinsJson
$terminalArtPaths = Get-HouseTerminalArtPaths -RepoRoot $repoRoot
$expectedTerminalHash = ConvertTo-HouseTextHash -Text (Format-HouseTerminalFragment -IconPath $terminalArtPaths.IconPath -BackgroundPath $terminalArtPaths.BackgroundPath)
$cursorScheme = Get-HouseCursorScheme -RepoRoot $repoRoot
$shortcutPlans = @(Get-HouseShareShortcutPlan -Config $config -RepoRoot $repoRoot)
$expectedWelcomeHash = ConvertTo-HouseTextHash -Text (Format-HouseWelcomeHtml -Config $config)
$welcomePath = 'C:\ProgramData\claude-house\welcome\index.html'
$lockscreenPath = 'C:\ProgramData\claude-house\look\lockscreen.png'
$taskbarLayoutPath = 'C:\ProgramData\claude-house\look\taskbar.xml'

$guestError = $null
$guest = $null
try {
    if ($null -eq $Context -or -not $Context.ContainsKey('InvokeGuest') -or $null -eq $Context['InvokeGuest']) {
        throw 'InvokeGuest is not available'
    }
    $probe = Get-LookProbe
    $guest = & $Context.InvokeGuest -ScriptBlock $probe -ArgumentList @()
    if ($null -eq $guest) { throw 'PowerShell Direct returned no result' }
}
catch {
    $guestError = [string]$_.Exception.Message
    if (-not $guestError) { $guestError = [string]$_ }
    $guest = $null
}

$notes = New-Object System.Collections.Generic.List[string]
$themeOk = $false
$accentOk = $false
$wallpaperOk = $false
$explorerOk = $false
$quietOk = $false
$terminalOk = $false
$spotlightOk = $false
$signinOk = $false
$avatarOk = $false
$taskbarOk = $false
$startPinsOk = $false
$smoothOk = $false
$accentDiff = ''
$explorerDiff = ''
$quietDiff = ''
$spotlightDiff = ''
$signinDiff = ''
$avatarDiff = ''
$taskbarDiff = ''
$startPinsDiff = ''
$smoothDiff = ''

if ($guestError) { $notes.Add($guestError) }
if ($null -ne $guest) {
    $observed = [string](Get-HousePropertyValue -Object $guest -Name 'error')
    if ($observed) {
        $notes.Add($observed)
        $guest = $null
    }
}

if ($null -ne $guest) {
    $apps = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'appsUseLightTheme')
    $system = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'systemUsesLightTheme')
    $personalizePrev = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'personalizeColorPrevalence')
    $themeOk = ($apps -eq [uint32]1) -and ($system -eq [uint32]1) -and ($personalizePrev -eq [uint32]0)

    $accentPairs = @(
        @{ Name = 'AccentColor'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'accentColor')); Expected = $expectedAccent },
        @{ Name = 'ColorizationColor'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'colorizationColor')); Expected = $expectedColorization },
        @{ Name = 'ColorPrevalence'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'dwmColorPrevalence')); Expected = [uint32]1 },
        @{ Name = 'AccentColorMenu'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'accentColorMenu')); Expected = $expectedAccent },
        @{ Name = 'StartColorMenu'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'startColorMenu')); Expected = $expectedStartMenu }
    )
    $accentOk = $true
    foreach ($pair in $accentPairs) {
        if ($null -eq $pair.Actual -or $pair.Actual -ne $pair.Expected) {
            $accentOk = $false
            if (-not $accentDiff) { $accentDiff = [string]$pair.Name }
        }
    }
    $palette = ConvertTo-LookBytes -Value (Get-HousePropertyValue -Object $guest -Name 'accentPalette')
    if (-not (Test-LookBytesEqual -Left $palette -Right $expectedPalette)) {
        $accentOk = $false
        if (-not $accentDiff) { $accentDiff = 'AccentPalette' }
    }

    $wallpaperPath = [string](Get-HousePropertyValue -Object $guest -Name 'wallpaper')
    $wallpaperExpected = [string](Get-HousePropertyValue -Object $guest -Name 'wallpaperExpected')
    $wallpaperExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'wallpaperExists')
    $wallpaperHash = [string](Get-HousePropertyValue -Object $guest -Name 'wallpaperHash')
    $pathOk = $wallpaperExpected -and ($wallpaperPath -eq $wallpaperExpected)
    # A cached copy older than the file means the desktop still shows the previous picture.
    $wallpaperStale = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'wallpaperStale')
    $wallpaperOk = $pathOk -and $wallpaperExists -and ($wallpaperHash -eq $expectedWallpaperHash) -and ($wallpaperHash -ne '') -and (-not $wallpaperStale)

    $explorerPairs = @(
        @{ Name = 'HideFileExt'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'hideFileExt')); Expected = [uint32]0 },
        @{ Name = 'LaunchTo'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'launchTo')); Expected = [uint32]1 },
        @{ Name = 'Start_IrisRecommendations'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'startIrisRecommendations')); Expected = [uint32]0 },
        @{ Name = 'ShowTaskViewButton'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'showTaskViewButton')); Expected = [uint32]0 },
        @{ Name = 'SearchboxTaskbarMode'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'searchboxTaskbarMode')); Expected = [uint32]1 }
    )
    $explorerOk = $true
    foreach ($pair in $explorerPairs) {
        if ($null -eq $pair.Actual -or $pair.Actual -ne $pair.Expected) {
            $explorerOk = $false
            if (-not $explorerDiff) { $explorerDiff = [string]$pair.Name }
        }
    }

    $newsActual = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'allowNewsAndInterests')
    # Where Windows refuses the news policy, step 13 removes the Widgets app; no app means no news either.
    if ((Get-HousePropertyValue -Object $guest -Name 'widgetsInstalled') -eq $false) { $newsActual = [uint32]0 }
    $quietPairs = @(
        @{ Name = 'AllowNewsAndInterests'; Actual = $newsActual; Expected = [uint32]0 },
        @{ Name = 'HideFirstRunExperience'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'hideFirstRunExperience')); Expected = [uint32]1 },
        @{ Name = 'StartupBoostEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'edgeStartupBoost')); Expected = [uint32]0 },
        @{ Name = 'BackgroundModeEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'edgeBackgroundMode')); Expected = [uint32]0 },
        @{ Name = 'DisableFileSyncNGSC'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'oneDriveDisabled')); Expected = [uint32]1 }
    )
    $quietOk = $true
    foreach ($pair in $quietPairs) {
        if ($null -eq $pair.Actual -or $pair.Actual -ne $pair.Expected) {
            $quietOk = $false
            if (-not $quietDiff) { $quietDiff = [string]$pair.Name }
        }
    }

    $terminalExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'terminalExists')
    $terminalParseOk = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'terminalParseOk')
    $terminalHash = [string](Get-HousePropertyValue -Object $guest -Name 'terminalHash')
    $terminalOk = $terminalExists -and $terminalParseOk -and ($terminalHash -eq $expectedTerminalHash) -and ($terminalHash -ne '')

    $spotlightPairs = @(
        @{ Name = 'EnabledState'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'spotlightEnabledState')); Expected = [uint32]0 },
        @{ Name = 'BackgroundType'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'backgroundType')); Expected = [uint32]0 },
        @{ Name = 'DisableSpotlightCollectionOnDesktop'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'disableSpotlightCollection')); Expected = [uint32]1 },
        @{ Name = 'DisableWindowsSpotlightFeatures'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'disableWindowsSpotlight')); Expected = [uint32]1 },
        @{ Name = 'RotatingLockScreenEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'rotatingLockScreenEnabled')); Expected = [uint32]0 },
        @{ Name = 'RotatingLockScreenOverlayEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'rotatingLockScreenOverlay')); Expected = [uint32]0 },
        @{ Name = 'SubscribedContent-338387Enabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'subscribedContent338387')); Expected = [uint32]0 },
        @{ Name = 'SystemPaneSuggestionsEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'systemPaneSuggestionsEnabled')); Expected = [uint32]0 },
        @{ Name = 'SilentInstalledAppsEnabled'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'silentInstalledAppsEnabled')); Expected = [uint32]0 }
    )
    $spotlightOk = $true
    $spotlightDiff = ''
    foreach ($pair in $spotlightPairs) {
        if (-not (Test-LookValue -Actual $pair.Actual -Expected $pair.Expected)) {
            $spotlightOk = $false
            if (-not $spotlightDiff) { $spotlightDiff = [string]$pair.Name }
        }
    }

    $lockPathActual = Get-HousePropertyValue -Object $guest -Name 'lockScreenImagePath'
    $lockUrlActual = Get-HousePropertyValue -Object $guest -Name 'lockScreenImageUrl'
    $lockStatus = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'lockScreenImageStatus')
    $acrylic = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'disableAcrylicBackgroundOnLogon')
    $lockExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'lockscreenExists')
    $lockHash = [string](Get-HousePropertyValue -Object $guest -Name 'lockscreenHash')
    $signinOk = (Test-LookValue -Actual $lockPathActual -Expected $lockscreenPath) -and (Test-LookValue -Actual $lockUrlActual -Expected $lockscreenPath) -and ($lockStatus -eq [uint32]1) -and ($acrylic -eq [uint32]1) -and $lockExists -and ($lockHash -eq $expectedLockscreenHash) -and ($lockHash -ne '')
    $signinDiff = ''
    if (-not $signinOk) {
        if (-not (Test-LookValue -Actual $lockPathActual -Expected $lockscreenPath)) { $signinDiff = 'LockScreenImagePath' }
        elseif (-not (Test-LookValue -Actual $lockUrlActual -Expected $lockscreenPath)) { $signinDiff = 'LockScreenImageUrl' }
        elseif ($lockStatus -ne [uint32]1) { $signinDiff = 'LockScreenImageStatus' }
        elseif ($acrylic -ne [uint32]1) { $signinDiff = 'DisableAcrylicBackgroundOnLogon' }
        else { $signinDiff = 'lockscreen.png' }
    }

    $useDefaultTile = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'useDefaultTile')
    $userTileExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'userTileExists')
    $userTileHash = [string](Get-HousePropertyValue -Object $guest -Name 'userTileHash')
    $avatarOk = ($useDefaultTile -eq [uint32]1) -and $userTileExists -and ($userTileHash -eq $expectedUserTileHash) -and ($userTileHash -ne '')
    $avatarDiff = ''
    if (-not $avatarOk) {
        if ($useDefaultTile -ne [uint32]1) { $avatarDiff = 'UseDefaultTile' }
        else { $avatarDiff = 'user.png' }
    }

    $taskbarPairs = @(
        @{ Name = 'TurnOffWindowsCopilot'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'turnOffWindowsCopilot')); Expected = [uint32]1 },
        @{ Name = 'ShowCopilotButton'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'showCopilotButton')); Expected = [uint32]0 },
        @{ Name = 'SearchboxTaskbarMode'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'searchboxTaskbarMode')); Expected = [uint32]1 },
        @{ Name = 'SearchOnTaskbarMode'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'searchOnTaskbarMode')); Expected = [uint32]1 },
        @{ Name = 'ShowTaskViewButton'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'showTaskViewButton')); Expected = [uint32]0 },
        @{ Name = 'LockedStartLayout'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'lockedStartLayout')); Expected = [uint32]1 }
    )
    $taskbarOk = $true
    $taskbarDiff = ''
    foreach ($pair in $taskbarPairs) {
        if (-not (Test-LookValue -Actual $pair.Actual -Expected $pair.Expected)) {
            $taskbarOk = $false
            if (-not $taskbarDiff) { $taskbarDiff = [string]$pair.Name }
        }
    }
    $startLayoutFile = Get-HousePropertyValue -Object $guest -Name 'startLayoutFile'
    if (-not (Test-LookValue -Actual $startLayoutFile -Expected $taskbarLayoutPath)) {
        $taskbarOk = $false
        if (-not $taskbarDiff) { $taskbarDiff = 'StartLayoutFile' }
    }
    $taskbarExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'taskbarExists')
    $taskbarHash = [string](Get-HousePropertyValue -Object $guest -Name 'taskbarHash')
    if (-not $taskbarExists -or $taskbarHash -ne $expectedTaskbarHash -or $taskbarHash -eq '') {
        $taskbarOk = $false
        if (-not $taskbarDiff) { $taskbarDiff = 'taskbar.xml' }
    }

    $startPinsActual = Get-HousePropertyValue -Object $guest -Name 'configureStartPins'
    $startProvider = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'configureStartPinsProviderSet')
    $startTrack = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'startTrackDocs')
    $startIris = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'startIrisRecommendations')
    $startAccount = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'startAccountNotifications')
    $startPinsOk = (Test-LookValue -Actual $startPinsActual -Expected $expectedStartPins) -and ($startProvider -eq [uint32]1) -and ($startTrack -eq [uint32]0) -and ($startIris -eq [uint32]0) -and ($startAccount -eq [uint32]0)
    $startPinsDiff = ''
    if (-not $startPinsOk) {
        if (-not (Test-LookValue -Actual $startPinsActual -Expected $expectedStartPins)) { $startPinsDiff = 'ConfigureStartPins' }
        elseif ($startProvider -ne [uint32]1) { $startPinsDiff = 'ConfigureStartPins_ProviderSet' }
        elseif ($startTrack -ne [uint32]0) { $startPinsDiff = 'Start_TrackDocs' }
        elseif ($startIris -ne [uint32]0) { $startPinsDiff = 'Start_IrisRecommendations' }
        else { $startPinsDiff = 'Start_AccountNotifications' }
    }

    $smoothPairs = @(
        @{ Name = 'EnableFirstLogonAnimation'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'enableFirstLogonAnimation')); Expected = [uint32]0 },
        @{ Name = 'EnableTransparency'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'enableTransparency')); Expected = [uint32]0 },
        @{ Name = 'TaskbarAnimations'; Actual = (ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'taskbarAnimations')); Expected = [uint32]0 },
        @{ Name = 'MinAnimate'; Actual = (Get-HousePropertyValue -Object $guest -Name 'minAnimate'); Expected = '0' }
    )
    $smoothOk = $true
    $smoothDiff = ''
    foreach ($pair in $smoothPairs) {
        if (-not (Test-LookValue -Actual $pair.Actual -Expected $pair.Expected)) {
            $smoothOk = $false
            if (-not $smoothDiff) { $smoothDiff = [string]$pair.Name }
        }
    }
}

$cursorsOk = $true
$cursorsEvidence = 'skipped'
if ($null -ne $cursorScheme) {
    $cursorsEvidence = $false
    $cursorsOk = $false
    if ($null -ne $guest) {
        $cursorsOk = $true
        $schemeSource = ConvertTo-LookDword -Value (Get-HousePropertyValue -Object $guest -Name 'cursorSchemeSource')
        if ($schemeSource -ne [uint32]1) { $cursorsOk = $false }
        $cursorValues = Get-HousePropertyValue -Object $guest -Name 'cursorValues'
        $cursorHashes = Get-HousePropertyValue -Object $guest -Name 'cursorHashes'
        foreach ($pair in @($cursorScheme)) {
            $expectedPath = Get-HouseCursorGuestPath -FileName ([string]$pair.File)
            $actualPath = [string](Get-HousePropertyValue -Object $cursorValues -Name $pair.Role)
            if ($actualPath -ne $expectedPath) { $cursorsOk = $false }
            $expectedHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$pair.SourcePath))
            $actualHash = [string](Get-HousePropertyValue -Object $cursorHashes -Name $pair.Role)
            if ($actualHash -ne $expectedHash -or $actualHash -eq '') { $cursorsOk = $false }
        }
        if ($cursorsOk) { $cursorsEvidence = $true }
    }
}

$terminalArtOk = $true
$terminalArtEvidence = 'skipped'
$wantsTerminalIcon = -not [string]::IsNullOrWhiteSpace([string]$terminalArtPaths.IconSource)
$wantsTerminalBackground = -not [string]::IsNullOrWhiteSpace([string]$terminalArtPaths.BackgroundSource)
if ($wantsTerminalIcon -or $wantsTerminalBackground) {
    $terminalArtEvidence = $false
    $terminalArtOk = $false
    if ($null -ne $guest) {
        $terminalArtOk = $true
        $terminalText = [string](Get-HousePropertyValue -Object $guest -Name 'terminalText')
        if ($wantsTerminalIcon) {
            $expectedIconHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$terminalArtPaths.IconSource))
            $iconExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'terminalIconExists')
            $iconHash = [string](Get-HousePropertyValue -Object $guest -Name 'terminalIconHash')
            if (-not $iconExists -or $iconHash -ne $expectedIconHash -or $iconHash -eq '') { $terminalArtOk = $false }
        }
        if ($wantsTerminalBackground) {
            $expectedBackgroundHash = ConvertTo-HouseBytesHash -Bytes ([System.IO.File]::ReadAllBytes([string]$terminalArtPaths.BackgroundSource))
            $backgroundExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'terminalBackgroundExists')
            $backgroundHash = [string](Get-HousePropertyValue -Object $guest -Name 'terminalBackgroundHash')
            if (-not $backgroundExists -or $backgroundHash -ne $expectedBackgroundHash -or $backgroundHash -eq '') { $terminalArtOk = $false }
        }
        if (-not (Test-LookTerminalArtText -Text $terminalText -IconPath $terminalArtPaths.IconPath -BackgroundPath $terminalArtPaths.BackgroundPath)) {
            $terminalArtOk = $false
        }
        if ($terminalArtOk) { $terminalArtEvidence = $true }
    }
}

$shareShortcutsOk = $true
$shareShortcutsEvidence = $true
if ($shortcutPlans.Count -gt 0) {
    $shareShortcutsEvidence = $false
    $shareShortcutsOk = $false
    if ($null -ne $guest) {
        $shareShortcutsOk = $true
        $shortcutRows = ConvertTo-HouseItemList -Value (Get-HousePropertyValue -Object $guest -Name 'shareShortcuts')
        foreach ($plan in $shortcutPlans) {
            $found = $null
            foreach ($shortcutRow in $shortcutRows) {
                $rowName = [string](Get-HousePropertyValue -Object $shortcutRow -Name 'name')
                if ($rowName -eq [string]$plan.Name) { $found = $shortcutRow }
            }
            if ($null -eq $found) {
                $shareShortcutsOk = $false
                continue
            }
            $target = [string](Get-HousePropertyValue -Object $found -Name 'target')
            $icon = [string](Get-HousePropertyValue -Object $found -Name 'icon')
            if ($target -ne [string]$plan.Target) { $shareShortcutsOk = $false }
            if (-not (Test-LookIconPath -Actual $icon -ExpectedPath ([string]$plan.IconPath))) { $shareShortcutsOk = $false }
        }
        if ($shareShortcutsOk) { $shareShortcutsEvidence = $true }
    }
}

$welcomeOk = $false
if ($null -ne $guest) {
    $welcomeExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'welcomeExists')
    $welcomeHash = [string](Get-HousePropertyValue -Object $guest -Name 'welcomeHash')
    $welcomeShortcutExists = Test-LookFlag -Value (Get-HousePropertyValue -Object $guest -Name 'welcomeShortcutExists')
    $welcomeShortcutTarget = [string](Get-HousePropertyValue -Object $guest -Name 'welcomeShortcutTarget')
    $welcomeOk = $welcomeExists -and ($welcomeHash -eq $expectedWelcomeHash) -and ($welcomeHash -ne '') -and $welcomeShortcutExists -and ($welcomeShortcutTarget -eq $welcomePath)
}

$flags = @{
    theme     = $themeOk
    accent    = $accentOk
    wallpaper = $wallpaperOk
    explorer  = $explorerOk
    quiet         = $quietOk
    terminal      = $terminalOk
    spotlightOff  = $spotlightOk
    signinScreen  = $signinOk
    avatar        = $avatarOk
    taskbar       = $taskbarOk
    startPins      = $startPinsOk
    smooth         = $smoothOk
    cursors        = $cursorsOk
    terminalArt    = $terminalArtOk
    shareShortcuts = $shareShortcutsOk
    welcome        = $welcomeOk
}
$failing = New-Object System.Collections.Generic.List[string]
foreach ($name in $itemNames) {
    if (-not $flags[$name]) { $failing.Add($name) }
}
$detail = 'look ready'
if ($failing.Count -gt 0) { $detail = ($failing.ToArray() -join ', ') }
if ($accentDiff) { $notes.Add($accentDiff) }
if ($explorerDiff) { $notes.Add($explorerDiff) }
if ($quietDiff) { $notes.Add($quietDiff) }
if ($spotlightDiff) { $notes.Add($spotlightDiff) }
if ($signinDiff) { $notes.Add($signinDiff) }
if ($avatarDiff) { $notes.Add($avatarDiff) }
if ($taskbarDiff) { $notes.Add($taskbarDiff) }
if ($startPinsDiff) { $notes.Add($startPinsDiff) }
if ($smoothDiff) { $notes.Add($smoothDiff) }
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

$evidence = ConvertTo-LookEvidence -Theme $themeOk -Accent $accentOk -Wallpaper $wallpaperOk -Explorer $explorerOk -Quiet $quietOk -Terminal $terminalOk -SpotlightOff $spotlightOk -SigninScreen $signinOk -Avatar $avatarOk -Taskbar $taskbarOk -StartPins $startPinsOk -Smooth $smoothOk -Cursors $cursorsEvidence -TerminalArt $terminalArtEvidence -ShareShortcuts $shareShortcutsEvidence -Welcome $welcomeOk -LookTheme $lookTheme
return (ConvertTo-LookResult -Ok ($failing.Count -eq 0) -Detail $detail -Evidence $evidence)

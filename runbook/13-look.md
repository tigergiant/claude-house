---
id: look
title: Give the guest a warm light theme
order: 13
requires: [house-rules]
runs_on: guest
admin: false
reboot: true
human: false
---

## Purpose

Give the guest a warm light theme, a calm desktop and a terminal colour scheme. Also set the pointer scheme, terminal icon and background, desktop shortcuts to the shares, a **Start here** shortcut to a welcome page built from the blueprint, the sign-in screen, the account picture, the taskbar and Start, and turn Spotlight off. The VM user is signed in once by the step itself before anything is written, because Windows resets the look at a profile's first sign-in. Settings apply at the next sign-in. If the human already signed in, they sign out and in again.

## Before you start

The house-rules check must already pass. Run the script from the repository root. Current Look.Theme is `{{Look.Theme}}`.

## Do

If `{{Look.Theme}}` is `none`, stop. Do not run any command in this section. The check passes with `look skipped`.

First, make sure the VM user has reached the desktop once. PowerShell Direct creates the user's profile without a desktop sign-in, and Windows finishes that profile at its first real sign-in by applying its own default theme: wallpaper, accent colour, pointers and taskbar settings written before that moment are reset (seen on a real drill). Windows records that finishing work under the user's `Active Setup\Installed Components`, which PowerShell Direct never fills. When it is empty, the block signs the user in once by itself: it turns on automatic sign-in for exactly one boot, restarts the VM, waits for the desktop, then removes the automatic sign-in values. The password travels in `-ArgumentList` and is never printed; `house check vm-online` proves afterwards that no automatic sign-in value is left. When the user has already signed in, the block does nothing.

```powershell
$vmName = '{{House.Name}}'
$credential = Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml"
$finished = Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
    @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Active Setup\Installed Components' -ErrorAction SilentlyContinue).Count -gt 0
}
if (-not $finished) {
    Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
        param($Secret)
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -LiteralPath $key -Name 'DefaultUserName' -Value $env:USERNAME
        Set-ItemProperty -LiteralPath $key -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
        Set-ItemProperty -LiteralPath $key -Name 'DefaultPassword' -Value $Secret
        Set-ItemProperty -LiteralPath $key -Name 'AutoLogonCount' -Type DWord -Value 1
        Set-ItemProperty -LiteralPath $key -Name 'AutoAdminLogon' -Value '1'
    } -ArgumentList $credential.GetNetworkCredential().Password
    try {
        Restart-VM -Name $vmName -Type Reboot -Force -Wait -For Heartbeat -Timeout 600
        $deadline = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 10
            $finished = $false
            try {
                $finished = Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ScriptBlock {
                    $desktop = @(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like ('*\' + $env:USERNAME) }).Count -gt 0
                    $desktop -and (@(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Active Setup\Installed Components' -ErrorAction SilentlyContinue).Count -gt 0)
                }
            }
            catch { $finished = $false }
        } while (-not $finished -and (Get-Date) -lt $deadline)
    }
    finally {
        # Windows keeps AutoAdminLogon at 1 after the one counted sign-in, so clear it in every case.
        Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Remove-ItemProperty -LiteralPath $key -Name 'DefaultPassword' -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $key -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $key -Name 'AutoAdminLogon' -Value '0'
        }
    }
    if (-not $finished) { throw 'the VM user did not reach the desktop within 15 minutes' }
    # Let the first sign-in finish writing its defaults before step 13 writes over them.
    Start-Sleep -Seconds 60
}
```

Then build the wallpaper on the host and apply the look in the guest with one PowerShell Direct call. If `assets/look/wallpaper.png`, `assets/look/lockscreen.png` or `assets/look/avatar.png` exists, that file is used. Otherwise the step draws one. Wallpaper bytes, cursor files, the terminal icon, the terminal background, share-folder icons, the terminal fragment and the welcome page travel in `-ArgumentList`. The script block stays ASCII. Do not restart Explorer. Do not sign anyone out. Every picture comes from `assets/`, and replacing a file there and running Do again changes it.

The welcome page comes from `Format-HouseWelcomeHtml`: it lists this house's shares, tools and rules. Do writes it as `C:\ProgramData\claude-house\welcome\index.html` next to `house.png` (from `assets/icons/house-256.png`), and puts `Start here.lnk` on the VM user's desktop, pointed at that page, with `house.ico` under `C:\ProgramData\claude-house\look` as its icon.

Start pins come from `Get-HouseStartPinsJson`, which builds them with `ConvertTo-Json -Compress`. The taskbar layout comes from `Format-HouseTaskbarLayoutXml` and replaces the pins with File Explorer, Windows Terminal, Microsoft Edge and the Claude desktop app (skipped by Windows when step 9 did not install it).

```powershell
Import-Module (Join-Path (Get-Location) 'lib\House.psm1') -Force
$config = Import-HouseConfig -Path (Join-Path (Get-Location) 'house.config.psd1')
$vmName = '{{House.Name}}'
$repoRoot = Get-Location
$wallpaperBytes = Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'wallpaper.png' -Generate { New-HouseWallpaper }
$lockscreenBytes = Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'lockscreen.png' -Generate { New-HouseWallpaper }
$avatarBytes = Get-HouseLookBytes -RepoRoot $repoRoot -FileName 'avatar.png' -Generate { New-HouseAvatar -Size 448 }
$wallpaperB64 = [Convert]::ToBase64String($wallpaperBytes)
$lockscreenB64 = [Convert]::ToBase64String($lockscreenBytes)
$avatar448B64 = [Convert]::ToBase64String((ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 448))
$avatar192B64 = [Convert]::ToBase64String((ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 192))
$avatar48B64 = [Convert]::ToBase64String((ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 48))
$avatar40B64 = [Convert]::ToBase64String((ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 40))
$avatar32B64 = [Convert]::ToBase64String((ConvertTo-HouseScaledPng -Bytes $avatarBytes -Size 32))
$cursorScheme = Get-HouseCursorScheme -RepoRoot $repoRoot
$cursorJson = '[]'
if ($null -ne $cursorScheme) {
    $cursorRows = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @($cursorScheme)) {
        $cursorRows.Add([pscustomobject]@{
            role = [string]$pair.Role
            name = [string]$pair.File
            b64  = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$pair.SourcePath))
        })
    }
    if ($cursorRows.Count -eq 1) {
        $cursorJson = '[' + (ConvertTo-Json -InputObject $cursorRows[0] -Compress -Depth 4) + ']'
    }
    else {
        $cursorJson = ConvertTo-Json -InputObject @($cursorRows.ToArray()) -Compress -Depth 4
    }
}
$terminalArt = Get-HouseTerminalArtPaths -RepoRoot $repoRoot
$fragment = Format-HouseTerminalFragment -IconPath $terminalArt.IconPath -BackgroundPath $terminalArt.BackgroundPath
$terminalIconB64 = ''
$terminalBackgroundB64 = ''
if ($terminalArt.IconSource) {
    $terminalIconB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$terminalArt.IconSource))
}
if ($terminalArt.BackgroundSource) {
    $terminalBackgroundB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$terminalArt.BackgroundSource))
}
$shortcutPlans = @(Get-HouseShareShortcutPlan -Config $config -RepoRoot $repoRoot)
$shortcutJson = '[]'
if ($shortcutPlans.Count -gt 0) {
    $shortcutRows = New-Object System.Collections.Generic.List[object]
    foreach ($plan in $shortcutPlans) {
        $shortcutRows.Add([pscustomobject]@{
            name    = [string]$plan.Name
            target  = [string]$plan.Target
            icon    = [string]$plan.IconName
            iconB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$plan.SourcePath))
        })
    }
    if ($shortcutRows.Count -eq 1) {
        $shortcutJson = '[' + (ConvertTo-Json -InputObject $shortcutRows[0] -Compress -Depth 4) + ']'
    }
    else {
        $shortcutJson = ConvertTo-Json -InputObject @($shortcutRows.ToArray()) -Compress -Depth 4
    }
}
$welcomeUtf8 = New-Object System.Text.UTF8Encoding $false
$welcomeHtmlB64 = [Convert]::ToBase64String($welcomeUtf8.GetBytes((Format-HouseWelcomeHtml -Config $config)))
$welcomePngB64 = ''
$welcomePngSource = Join-Path $repoRoot 'assets\icons\house-256.png'
if (Test-Path -LiteralPath $welcomePngSource -PathType Leaf) {
    $welcomePngB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($welcomePngSource))
}
$welcomeIconB64 = ''
$welcomeIconSource = Join-Path $repoRoot 'assets\icons\house.ico'
if (Test-Path -LiteralPath $welcomeIconSource -PathType Leaf) {
    $welcomeIconB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($welcomeIconSource))
}
$paletteB64 = [Convert]::ToBase64String((Get-HouseLookAccentPalette))
$accentColor = ConvertTo-HouseAbgrDword -Hex '#C96442'
$colorizationColor = [Convert]::ToUInt32('C4C96442', 16)
$startColorMenu = [Convert]::ToUInt32('FF2C4387', 16)
$taskbarXml = Format-HouseTaskbarLayoutXml
$startPinsJson = Get-HouseStartPinsJson
Invoke-Command -VMName $vmName -Credential (Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml") -ScriptBlock {
    param($WallpaperB64, $Fragment, $PaletteB64, $AccentColor, $ColorizationColor, $StartColorMenu, $LockscreenB64, $Avatar448B64, $Avatar192B64, $Avatar48B64, $Avatar40B64, $Avatar32B64, $TaskbarXml, $StartPinsJson, $CursorJson, $TerminalIconB64, $TerminalBackgroundB64, $ShortcutJson, $WelcomeHtmlB64, $WelcomePngB64, $WelcomeIconB64)
    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $pictures = Join-Path $env:USERPROFILE 'Pictures'
    if (-not (Test-Path -LiteralPath $pictures)) { New-Item -ItemType Directory -Path $pictures -Force | Out-Null }
    $wallpaperPath = Join-Path $pictures 'claude-house-wallpaper.png'
    [System.IO.File]::WriteAllBytes($wallpaperPath, [Convert]::FromBase64String($WallpaperB64))
    # Windows keeps showing its own transcoded copy while the path stays the same; drop it so the next sign-in reads the new file.
    $themesDir = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
    Remove-Item -LiteralPath (Join-Path $themesDir 'TranscodedWallpaper') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $themesDir 'CachedFiles') -Recurse -Force -ErrorAction SilentlyContinue
    $lookDir = 'C:\ProgramData\claude-house\look'
    $tileDir = 'C:\ProgramData\Microsoft\User Account Pictures'
    $backupDir = 'C:\ProgramData\claude-house\look\original-tiles'
    if (-not (Test-Path -LiteralPath $lookDir)) { New-Item -ItemType Directory -Path $lookDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $tileDir)) { New-Item -ItemType Directory -Path $tileDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes((Join-Path $lookDir 'lockscreen.png'), [Convert]::FromBase64String($LockscreenB64))
    [System.IO.File]::WriteAllText((Join-Path $lookDir 'taskbar.xml'), $TaskbarXml, $utf8)
    $tileNames = @('user.png', 'user-192.png', 'user-48.png', 'user-40.png', 'user-32.png')
    foreach ($tileName in $tileNames) {
        $tileSource = Join-Path $tileDir $tileName
        $tileBackup = Join-Path $backupDir $tileName
        if ((Test-Path -LiteralPath $tileSource -PathType Leaf) -and -not (Test-Path -LiteralPath $tileBackup -PathType Leaf)) {
            Copy-Item -LiteralPath $tileSource -Destination $tileBackup
        }
    }
    $tiles = @{
        'user.png' = [Convert]::FromBase64String($Avatar448B64)
        'user-192.png' = [Convert]::FromBase64String($Avatar192B64)
        'user-48.png' = [Convert]::FromBase64String($Avatar48B64)
        'user-40.png' = [Convert]::FromBase64String($Avatar40B64)
        'user-32.png' = [Convert]::FromBase64String($Avatar32B64)
    }
    foreach ($tileName in $tileNames) {
        [System.IO.File]::WriteAllBytes((Join-Path $tileDir $tileName), $tiles[$tileName])
    }
    $regPaths = @(
        'HKCU:\Control Panel\Cursors',
        'HKCU:\Control Panel\Cursors\Schemes',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
        'HKCU:\Software\Microsoft\Windows\DWM',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent',
        'HKCU:\Control Panel\Desktop',
        'HKCU:\Control Panel\Desktop\WindowMetrics',
        'HKCU:\Control Panel\Colors',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers',
        'HKCU:\Software\Policies\Microsoft\Windows\CloudContent',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
        'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot',
        'HKLM:\SOFTWARE\Policies\Microsoft\Dsh',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
    )
    foreach ($regPath in $regPaths) {
        if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    }
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Type DWord -Value $AccentColor
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Type DWord -Value $ColorizationColor
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorPrevalence' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Type DWord -Value $AccentColor
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Type DWord -Value $StartColorMenu
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -Type Binary -Value ([Convert]::FromBase64String($PaletteB64))
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Type String -Value $wallpaperPath
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle' -Type String -Value '10'
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'TileWallpaper' -Type String -Value '0'
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Colors' -Name 'Background' -Type String -Value '240 238 230'
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type DWord -Value 1
    # Newer builds let the User Choice Protection Driver refuse this policy write; then remove the Widgets app instead.
    try {
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Type DWord -Value 0 -ErrorAction Stop
    }
    catch {
        if (-not ($_.Exception -is [System.UnauthorizedAccessException])) { throw }
        Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.WebExperience' | Remove-AppxPackage -AllUsers
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MicrosoftWindows.Client.WebExperience' } | Remove-AppxProvisionedPackage -Online | Out-Null
    }
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -Type DWord -Value 1
    # Nothing extra starts at sign-in: OneDrive and the Edge startup boost each read the disk while the desktop loads.
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type DWord -Value 1
    # The console is a remote-desktop stream; transparency and animations make it feel laggy.
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Type String -Value '0'
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings' -Name 'EnabledState' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -Name 'BackgroundType' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableSpotlightCollectionOnDesktop' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsSpotlightFeatures' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenOverlayEnabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338387Enabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Type DWord -Value 0
    $lockPath = 'C:\ProgramData\claude-house\look\lockscreen.png'
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImagePath' -Type String -Value $lockPath
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageUrl' -Type String -Value $lockPath
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageStatus' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DisableAcrylicBackgroundOnLogon' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'UseDefaultTile' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'SearchOnTaskbarMode' -Type DWord -Value 1
    $taskbarPath = 'C:\ProgramData\claude-house\look\taskbar.xml'
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile' -Type ExpandString -Value $taskbarPath
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'LockedStartLayout' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins' -Type String -Value $StartPinsJson
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins_ProviderSet' -Type DWord -Value 1
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackDocs' -Type DWord -Value 0
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_AccountNotifications' -Type DWord -Value 0
    # Windows loads the pointer scheme at sign-in. The step 13 restart plus the first sign-in applies it.
    if ($CursorJson -and $CursorJson -ne '[]') {
        $cursorDir = 'C:\ProgramData\claude-house\look\cursors'
        if (-not (Test-Path -LiteralPath $cursorDir)) { New-Item -ItemType Directory -Path $cursorDir -Force | Out-Null }
        $cursorPaths = New-Object System.Collections.Generic.List[string]
        foreach ($cursorRow in (ConvertFrom-Json -InputObject $CursorJson)) {
            if ($null -eq $cursorRow) { continue }
            $cursorPath = Join-Path $cursorDir ([string]$cursorRow.name)
            [System.IO.File]::WriteAllBytes($cursorPath, [Convert]::FromBase64String([string]$cursorRow.b64))
            New-ItemProperty -LiteralPath 'HKCU:\Control Panel\Cursors' -Name ([string]$cursorRow.role) -PropertyType ExpandString -Value $cursorPath -Force | Out-Null
            $cursorPaths.Add($cursorPath)
        }
        Set-Item -LiteralPath 'HKCU:\Control Panel\Cursors' -Value 'claude-house'
        New-ItemProperty -LiteralPath 'HKCU:\Control Panel\Cursors' -Name 'Scheme Source' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -LiteralPath 'HKCU:\Control Panel\Cursors' -Name 'CursorBaseSize' -PropertyType DWord -Value 48 -Force | Out-Null
        New-ItemProperty -LiteralPath 'HKCU:\Control Panel\Cursors\Schemes' -Name 'claude-house' -PropertyType ExpandString -Value (($cursorPaths.ToArray() -join ',')) -Force | Out-Null
    }
    if ($TerminalIconB64) {
        [System.IO.File]::WriteAllBytes('C:\ProgramData\claude-house\look\terminal.png', [Convert]::FromBase64String($TerminalIconB64))
    }
    if ($TerminalBackgroundB64) {
        [System.IO.File]::WriteAllBytes('C:\ProgramData\claude-house\look\terminal-background.png', [Convert]::FromBase64String($TerminalBackgroundB64))
    }
    if ($ShortcutJson -and $ShortcutJson -ne '[]') {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not (Test-Path -LiteralPath $desktop)) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
        # WScript.Shell refuses a target outside the ANSI code page (a Chinese folder name on an English guest),
        # so it only creates the file with a plain target; Shell.Application, which is Unicode, sets the real one.
        $shortcutShell = New-Object -ComObject WScript.Shell
        $shellApp = New-Object -ComObject Shell.Application
        foreach ($shortcutRow in (ConvertFrom-Json -InputObject $ShortcutJson)) {
            if ($null -eq $shortcutRow) { continue }
            $iconPath = Join-Path 'C:\ProgramData\claude-house\look' ([string]$shortcutRow.icon)
            [System.IO.File]::WriteAllBytes($iconPath, [Convert]::FromBase64String([string]$shortcutRow.iconB64))
            $lnkName = [string]$shortcutRow.name + '.lnk'
            $seed = $shortcutShell.CreateShortcut((Join-Path $desktop $lnkName))
            $seed.TargetPath = $env:SystemRoot
            $seed.Save()
            $lnk = $shellApp.NameSpace($desktop).ParseName($lnkName).GetLink
            $lnk.Path = [string]$shortcutRow.target
            $lnk.SetIconLocation($iconPath, 0)
            $lnk.Save()
        }
    }
    # The Start here page: a local welcome page built from the blueprint, opened by a desktop shortcut.
    $welcomeDir = 'C:\ProgramData\claude-house\welcome'
    if (-not (Test-Path -LiteralPath $welcomeDir)) { New-Item -ItemType Directory -Path $welcomeDir -Force | Out-Null }
    $welcomePage = Join-Path $welcomeDir 'index.html'
    [System.IO.File]::WriteAllBytes($welcomePage, [Convert]::FromBase64String($WelcomeHtmlB64))
    if ($WelcomePngB64) {
        [System.IO.File]::WriteAllBytes((Join-Path $welcomeDir 'house.png'), [Convert]::FromBase64String($WelcomePngB64))
    }
    $welcomeDesktop = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path -LiteralPath $welcomeDesktop)) { New-Item -ItemType Directory -Path $welcomeDesktop -Force | Out-Null }
    $welcomeShell = New-Object -ComObject WScript.Shell
    $welcomeLnk = $welcomeShell.CreateShortcut((Join-Path $welcomeDesktop 'Start here.lnk'))
    $welcomeLnk.TargetPath = $welcomePage
    if ($WelcomeIconB64) {
        $welcomeIcon = 'C:\ProgramData\claude-house\look\house.ico'
        [System.IO.File]::WriteAllBytes($welcomeIcon, [Convert]::FromBase64String($WelcomeIconB64))
        $welcomeLnk.IconLocation = $welcomeIcon + ',0'
    }
    $welcomeLnk.Save()
    $fragDir = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft') 'Windows Terminal') 'Fragments\claude-house'
    if (-not (Test-Path -LiteralPath $fragDir)) { New-Item -ItemType Directory -Path $fragDir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $fragDir 'claude-house.json'), $Fragment, $utf8)
} -ArgumentList $wallpaperB64, $fragment, $paletteB64, $accentColor, $colorizationColor, $startColorMenu, $lockscreenB64, $avatar448B64, $avatar192B64, $avatar48B64, $avatar40B64, $avatar32B64, $taskbarXml, $startPinsJson, $cursorJson, $terminalIconB64, $terminalBackgroundB64, $shortcutJson, $welcomeHtmlB64, $welcomePngB64, $welcomeIconB64
```

Restart the VM once. The sign-in screen image is read at boot: without a restart the human's first sign-in still shows the stock blue background (seen on a real drill). The only session is the one the first block opened, so this loses nothing; it also ends that session, and the human's sign-in in step 14 shows the new look.

```powershell
Restart-VM -Name '{{House.Name}}' -Type Reboot -Force -Wait -For Heartbeat -Timeout 600
```

Prove the step.

```powershell
house check look
```

## Verify

Run:

```powershell
house check look
```

A pass looks like `PASS look: look ready`.

## If it fails

- **theme:** `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Type DWord -Value 0`. Run Do again.
- **accent:** `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Type DWord -Value $AccentColor`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Type DWord -Value $ColorizationColor`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorPrevalence' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Type DWord -Value $AccentColor`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Type DWord -Value $StartColorMenu`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -Type Binary -Value ([Convert]::FromBase64String($PaletteB64))`. Run Do again.
- **wallpaper:** `[System.IO.File]::WriteAllBytes($wallpaperPath, [Convert]::FromBase64String($WallpaperB64))`, `Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Type String -Value $wallpaperPath`, `Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle' -Type String -Value '10'`, `Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'TileWallpaper' -Type String -Value '0'`, `Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Colors' -Name 'Background' -Type String -Value '240 238 230'`. Run Do again. If only the cached copy is stale (the desktop still shows the old picture), Do clears `%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper`; sign out and back in.
- **explorer:** `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type DWord -Value 1`. Run Do again.
- **quiet:** `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Type DWord -Value 0` (when Windows answers access denied, remove the Widgets app instead: `Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.WebExperience' | Remove-AppxPackage -AllUsers`), `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type DWord -Value 1`. Run Do again.
- **terminal:** `[System.IO.File]::WriteAllText((Join-Path $fragDir 'claude-house.json'), $Fragment, $utf8)`. Run Do again.
- **spotlightOff:** `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings' -Name 'EnabledState' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -Name 'BackgroundType' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableSpotlightCollectionOnDesktop' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsSpotlightFeatures' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenOverlayEnabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338387Enabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Type DWord -Value 0`. Run Do again.
- **signinScreen:** `[System.IO.File]::WriteAllBytes('C:\ProgramData\claude-house\look\lockscreen.png', [Convert]::FromBase64String($LockscreenB64))`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImagePath' -Type String -Value 'C:\ProgramData\claude-house\look\lockscreen.png'`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageUrl' -Type String -Value 'C:\ProgramData\claude-house\look\lockscreen.png'`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageStatus' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DisableAcrylicBackgroundOnLogon' -Type DWord -Value 1`. Run Do again.
- **avatar:** `[System.IO.File]::WriteAllBytes('C:\ProgramData\Microsoft\User Account Pictures\user.png', [Convert]::FromBase64String($Avatar448B64))`, `[System.IO.File]::WriteAllBytes('C:\ProgramData\Microsoft\User Account Pictures\user-192.png', [Convert]::FromBase64String($Avatar192B64))`, `[System.IO.File]::WriteAllBytes('C:\ProgramData\Microsoft\User Account Pictures\user-48.png', [Convert]::FromBase64String($Avatar48B64))`, `[System.IO.File]::WriteAllBytes('C:\ProgramData\Microsoft\User Account Pictures\user-40.png', [Convert]::FromBase64String($Avatar40B64))`, `[System.IO.File]::WriteAllBytes('C:\ProgramData\Microsoft\User Account Pictures\user-32.png', [Convert]::FromBase64String($Avatar32B64))`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'UseDefaultTile' -Type DWord -Value 1`. Back up each original tile once to `C:\ProgramData\claude-house\look\original-tiles` before the first overwrite. Leave `guest*.png` untouched. Run Do again.
- **taskbar:** `[System.IO.File]::WriteAllText('C:\ProgramData\claude-house\look\taskbar.xml', $TaskbarXml, $utf8)`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'SearchOnTaskbarMode' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile' -Type ExpandString -Value 'C:\ProgramData\claude-house\look\taskbar.xml'`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'LockedStartLayout' -Type DWord -Value 1`. Run Do again.
- **startPins:** `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins' -Type String -Value $StartPinsJson`, `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins_ProviderSet' -Type DWord -Value 1`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackDocs' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_AccountNotifications' -Type DWord -Value 0`. Run Do again.
- **smooth:** `Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Type DWord -Value 0`, `Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Type String -Value '0'`. Run Do again.
- **cursors:** Copy each file named in `assets/cursors/scheme.json` to `C:\ProgramData\claude-house\look\cursors`, set every `HKCU:\Control Panel\Cursors` role to that full path as ExpandString, set `(default)` to `claude-house`, set `Scheme Source` to 1, set `CursorBaseSize` to 48, and set `HKCU:\Control Panel\Cursors\Schemes` value `claude-house` to the 17 paths joined by commas. Run Do again.
- **terminalArt:** Copy `assets/icons/terminal.png` to `C:\ProgramData\claude-house\look\terminal.png` and `assets/terminal/background.png` to `C:\ProgramData\claude-house\look\terminal-background.png` when each source exists, and write the terminal fragment that names those paths. Run Do again.
- **shareShortcuts:** Put `<Share.Name>.lnk` on the VM user's desktop, pointed at the in-guest share path from the address book, with `folder-projects.ico` for a writable share or `folder-docs.ico` for a read-only share under `C:\ProgramData\claude-house\look`. Run Do again.
- **welcome:** `[System.IO.File]::WriteAllBytes('C:\ProgramData\claude-house\welcome\index.html', [Convert]::FromBase64String($WelcomeHtmlB64))`, then put `Start here.lnk` on the VM user's desktop, pointed at `C:\ProgramData\claude-house\welcome\index.html`, with `C:\ProgramData\claude-house\look\house.ico` as its icon. A changed blueprint changes the page; run Do again.

Settings show only after the next sign-in; a pass with the old look on screen means the human must sign out and in.

The Widgets policy needs Windows 11 Pro or higher; Home ignores it.

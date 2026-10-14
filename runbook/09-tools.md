---
id: tools
title: Install the starter tools through the gate
order: 9
requires: [one-way-out]
runs_on: guest
admin: true
reboot: false
human: false
---

## Purpose

Install Git for Windows, Claude Code, Claude desktop, Python, Node.js LTS, GitHub CLI, and VS Code inside the VM, using only the gate that step 7 already turned on. Python, Node, Claude desktop, GitHub CLI, and VS Code are installed only when their blueprint flags are True. The check records the versions it sees. It does not look for updates and it does not open a network connection of its own.

## Before you start

The one-way-out check must already pass. Open PowerShell as Administrator from the repository root. Show the script in Do to the human and wait for approval before running it. PowerShell Direct runs as the VM user `{{House.UserName}}`, who is a local administrator from step 5.

Blueprint flags: Python is `{{Tools.Python}}`, Node is `{{Tools.Node}}`. The Do block reads `ClaudeDesktop`, `GitHubCli`, and `VSCode` from `house.config.psd1`; a missing key means False so older blueprints still work. The gate URL is `http://{{Network.HostIP}}:{{Network.GatePort}}`. Run a tool block only when its flag is True.

## Do

1. Install through PowerShell Direct. Values are set outside the script block and passed in `-ArgumentList`, so the block itself stays ASCII. Git comes from the official Git for Windows release. Claude Code is the official Windows installer at `https://claude.ai/install.ps1`, run as the VM user. Python and Node use the official per-machine installers. Claude desktop, GitHub CLI, and VS Code use the official download endpoints below. Each optional tool runs only when its flag is True.

```powershell
$vmName = '{{House.Name}}'
$gateUrl = 'http://{{Network.HostIP}}:{{Network.GatePort}}'
$wantPython = '{{Tools.Python}}'
$wantNode = '{{Tools.Node}}'
Import-Module (Join-Path (Get-Location) 'lib\House.psm1') -Force
$blueprint = Import-HouseConfig -Path (Join-Path (Get-Location) 'house.config.psd1')
$toolFlags = $blueprint['Tools']
$wantClaudeDesktop = 'False'
$wantGitHubCli = 'False'
$wantVSCode = 'False'
if ($toolFlags -is [System.Collections.IDictionary]) {
    if ($toolFlags.Contains('ClaudeDesktop') -and [string]$toolFlags['ClaudeDesktop'] -eq 'True') { $wantClaudeDesktop = 'True' }
    if ($toolFlags.Contains('GitHubCli') -and [string]$toolFlags['GitHubCli'] -eq 'True') { $wantGitHubCli = 'True' }
    if ($toolFlags.Contains('VSCode') -and [string]$toolFlags['VSCode'] -eq 'True') { $wantVSCode = 'True' }
}
Invoke-Command -VMName $vmName -Credential (Import-Clixml "$env:ProgramData\claude-house\$vmName\vm-user.cred.xml") -ScriptBlock {
    param($GateUrl, $WantPython, $WantNode, $WantClaudeDesktop, $WantGitHubCli, $WantVSCode)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $env:HTTP_PROXY = $GateUrl
    $env:HTTPS_PROXY = $GateUrl
    $env:NO_PROXY = 'localhost,127.0.0.1'
    # The Claude Code installer downloads with plain Invoke-RestMethod; in a PowerShell Direct session that ignores the user proxy, so point .NET at the gate.
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($GateUrl, $true)

    function Save-HouseInstaller {
        param([string]$Uri, [string]$Destination)
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -Proxy $GateUrl -UseBasicParsing
    }

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Proxy $GateUrl
    $gitAsset = $null
    foreach ($asset in @($release.assets)) {
        if ([string]$asset.name -match '^Git-.+-64-bit\.exe$') { $gitAsset = $asset; break }
    }
    if ($null -eq $gitAsset) { throw 'Git for Windows 64-bit installer was not on the latest release' }
    $gitSetup = Join-Path $env:TEMP 'house-git-setup.exe'
    Save-HouseInstaller -Uri ([string]$gitAsset.browser_download_url) -Destination $gitSetup
    Start-Process -FilePath $gitSetup -ArgumentList '/VERYSILENT /NORESTART' -Wait

    Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -Proxy $GateUrl | Invoke-Expression
    $claudeBin = Join-Path $env:USERPROFILE '.local\bin'
    $userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
    if (-not ($entries -contains $claudeBin)) {
        [Environment]::SetEnvironmentVariable('Path', ((@($entries) + $claudeBin) -join ';'), 'User')
    }

    if ($WantPython -eq 'True') {
        $page = Invoke-WebRequest -Uri 'https://www.python.org/downloads/windows/' -Proxy $GateUrl -UseBasicParsing
        $match = [regex]::Match([string]$page.Content, 'python-(\d+\.\d+\.\d+)-amd64\.exe')
        if (-not $match.Success) { throw 'official Python amd64 installer was not listed' }
        $pythonVersion = [string]$match.Groups[1].Value
        $pythonUrl = 'https://www.python.org/ftp/python/' + $pythonVersion + '/python-' + $pythonVersion + '-amd64.exe'
        $pythonSetup = Join-Path $env:TEMP 'house-python-setup.exe'
        Save-HouseInstaller -Uri $pythonUrl -Destination $pythonSetup
        Start-Process -FilePath $pythonSetup -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0' -Wait
    }

    if ($WantNode -eq 'True') {
        $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -Proxy $GateUrl
        $chosen = $null
        foreach ($row in $index) {
            $lts = $row.lts
            $isLts = $false
            if ($lts -eq $true) { $isLts = $true }
            elseif (($lts -is [string]) -and $lts -and ($lts -ne 'False')) { $isLts = $true }
            if ($isLts) { $chosen = $row; break }
        }
        if ($null -eq $chosen) { throw 'official Node.js LTS build was not listed' }
        $nodeVersion = [string]$chosen.version
        $nodeUrl = 'https://nodejs.org/dist/' + $nodeVersion + '/node-' + $nodeVersion + '-x64.msi'
        $nodeSetup = Join-Path $env:TEMP 'house-node-setup.msi'
        Save-HouseInstaller -Uri $nodeUrl -Destination $nodeSetup
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', $nodeSetup, '/qn', 'ALLUSERS=1', 'REBOOT=ReallySuppress') -Wait
    }

    if ($WantClaudeDesktop -eq 'True') {
        $redirectRequest = [System.Net.HttpWebRequest]::Create('https://claude.ai/api/desktop/win32/x64/msix/latest/redirect')
        $redirectRequest.AllowAutoRedirect = $false
        $redirectRequest.Proxy = New-Object System.Net.WebProxy($GateUrl)
        $redirectResponse = $null
        try {
            $redirectResponse = $redirectRequest.GetResponse()
        }
        catch [System.Net.WebException] {
            $redirectResponse = $_.Exception.Response
            if ($null -eq $redirectResponse) { throw }
        }
        try {
            $desktopLocation = [string]$redirectResponse.Headers['Location']
            if (-not $desktopLocation) { throw 'Claude desktop redirect did not include a Location' }
            $desktopUri = [uri]$desktopLocation
            if (-not $desktopUri.IsAbsoluteUri -or $desktopUri.Scheme -ne 'https' -or $desktopUri.Host -ne 'downloads.claude.ai') {
                throw 'Claude desktop redirect host was not downloads.claude.ai'
            }
        }
        finally {
            if ($null -ne $redirectResponse) { $redirectResponse.Close() }
        }

        $desktopSetup = Join-Path $env:TEMP 'house-claude-desktop.msix'
        try {
            Save-HouseInstaller -Uri $desktopUri.AbsoluteUri -Destination $desktopSetup
            $desktopSignature = Get-AuthenticodeSignature -FilePath $desktopSetup
            if ($desktopSignature.Status -ne 'Valid') { throw 'Claude desktop MSIX signature was not valid' }
            if ([string]$desktopSignature.SignerCertificate.Subject -notlike '*O="Anthropic, PBC"*') {
                throw 'Claude desktop signer was not Anthropic, PBC'
            }
            Add-AppxPackage -Path $desktopSetup
        }
        finally {
            Remove-Item -LiteralPath $desktopSetup -Force -ErrorAction SilentlyContinue
        }
    }

    if ($WantGitHubCli -eq 'True') {
        $ghRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Proxy $GateUrl
        $ghAsset = $null
        foreach ($asset in @($ghRelease.assets)) {
            if ([string]$asset.name -match '^gh_.+_windows_amd64\.msi$') { $ghAsset = $asset; break }
        }
        if ($null -eq $ghAsset) { throw 'GitHub CLI Windows amd64 installer was not on the latest release' }
        $ghSetup = Join-Path $env:TEMP 'house-gh-setup.msi'
        try {
            Save-HouseInstaller -Uri ([string]$ghAsset.browser_download_url) -Destination $ghSetup
            $ghArguments = '/i "' + $ghSetup + '" /qn ALLUSERS=1 REBOOT=ReallySuppress'
            $ghInstall = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $ghArguments -Wait -PassThru
            if ($ghInstall.ExitCode -ne 0 -and $ghInstall.ExitCode -ne 3010) { throw ('GitHub CLI installer exited ' + [string]$ghInstall.ExitCode) }
        }
        finally {
            Remove-Item -LiteralPath $ghSetup -Force -ErrorAction SilentlyContinue
        }
    }

    if ($WantVSCode -eq 'True') {
        $vscodeSetup = Join-Path $env:TEMP 'house-vscode-setup.exe'
        try {
            Save-HouseInstaller -Uri 'https://update.code.visualstudio.com/latest/win32-x64/stable' -Destination $vscodeSetup
            $vscodeInstall = Start-Process -FilePath $vscodeSetup -ArgumentList '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addtopath' -Wait -PassThru
            if ($vscodeInstall.ExitCode -ne 0) { throw ('VS Code installer exited ' + [string]$vscodeInstall.ExitCode) }
        }
        finally {
            Remove-Item -LiteralPath $vscodeSetup -Force -ErrorAction SilentlyContinue
        }
    }
} -ArgumentList $gateUrl, $wantPython, $wantNode, $wantClaudeDesktop, $wantGitHubCli, $wantVSCode
```

## Verify

Run:

```powershell
house check tools
```

A pass looks like `PASS tools: tools ready`. Evidence includes the `git` and `claude` version strings, plus the version of each enabled optional tool.

## If it fails

- **git:** `git --version` did not return a version for the VM user. Run the Git installer in Do again. The check starts a new PowerShell Direct session, so a machine PATH change from the installer is visible without a reboot.
- **claude:** `claude --version` did not return a version. The official installer puts the command under `%USERPROFILE%\.local\bin\claude.exe`. Run the Claude installer in Do again as the VM user. Do not install a different build. If the detail says `Failed to get latest version` or a name could not be resolved, the installer tried to go around the gate; keep the `DefaultWebProxy` line in Do.
- **claudePath:** `claude.exe` exists but `%USERPROFILE%\.local\bin` is not on the saved User or Machine PATH, so `claude` in a new terminal would not be found. Run the Do block again; its PATH lines add the folder once.
- **python:** Shown only when Python is True. `python --version` did not return a version. Run the Python block in Do again. The installer must be per-machine (`InstallAllUsers=1`) and must prepend PATH.
- **node:** Shown only when Node is True. `node --version` did not return a version. Run the Node block in Do again with `ALLUSERS=1`.
- **desktop:** Shown only when `Tools.ClaudeDesktop` is True. The Claude Appx package or its version was not found. Run the Claude desktop block in Do again and confirm the MSIX signature is valid and its signer is Anthropic, PBC.
- **gh:** Shown only when `Tools.GitHubCli` is True. `gh --version` did not return a version. Run the GitHub CLI block in Do again through the gate.
- **vscode:** Shown only when `Tools.VSCode` is True. `code --version` did not return a version. Run the VS Code block in Do again through the gate.

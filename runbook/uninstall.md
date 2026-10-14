# Uninstall

This page removes what the runbook made on the host, newest step first. It is a plain page, not a step: `house next` and `house doctor` never point here, and after an uninstall they report the removed steps as failing.

This page has not yet been run end to end on a real house; the guardian block (5) in particular is untested. Read each block before running it, and report anything that does not match.

Rules for the agent:

- Run each block in an administrator PowerShell on the host, from the repository root, in the order below. Show each block to the human and wait for a yes before running it.
- Every block can be run again. Anything already gone is skipped.
- Your shared folders and the files in them are never deleted. Only the share, the `house-share` permission entry on the folder, and the `house-share` account go away.
- Block 4 deletes the VM and its disk for good. Anything saved only inside the VM, and not in a shared folder, is lost. Copy it out first.

## 0. Read the blueprint

Every later block uses these values. Run this block again in any new PowerShell window.

```powershell
Import-Module (Join-Path (Get-Location) 'lib\House.psm1') -Force
$config = Import-HouseConfig -Path (Join-Path (Get-Location) 'house.config.psd1')
$houseName = [string]$config.House.Name
$housePath = [string]$config.House.Path
$switchName = [string]$config.Network.SwitchName
$hostIp = [string]$config.Network.HostIP
$gatePort = [string]$config.Network.GatePort
$shares = $config.Shares
```

## 1. Shut down the VM

```powershell
$vm = Get-VM -Name $houseName -ErrorAction SilentlyContinue
if ($null -ne $vm -and [string]$vm.State -ne 'Off') { Stop-VM -Name $houseName -Force }
```

`Stop-VM` asks Windows in the VM to shut down. If it never reaches Off, ask the human before `Stop-VM -Name $houseName -TurnOff`, which is like pulling the plug.

## 2. Shares (step 10)

Removes the SMB firewall rule, each blueprint share whose path still matches the blueprint, the `house-share` entry on each shared folder, and the `house-share` account. The folders and their files stay.

```powershell
Get-NetFirewallRule -DisplayName 'claude-house SMB' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($share in $shares) {
    $smb = Get-SmbShare -Name ([string]$share.Name) -ErrorAction SilentlyContinue
    if ($null -ne $smb -and [string]$smb.Path -eq [string]$share.HostPath) {
        Remove-SmbShare -Name ([string]$share.Name) -Force
    }
}
$account = Get-LocalUser -Name 'house-share' -ErrorAction SilentlyContinue
if ($null -ne $account) {
    foreach ($share in $shares) {
        $folder = [string]$share.HostPath
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $acl = Get-Acl -LiteralPath $folder
        $acl.PurgeAccessRules($account.SID)
        Set-Acl -LiteralPath $folder -AclObject $acl
    }
    Remove-LocalUser -Name 'house-share'
}
```

Remove the folder permission entries before the account. Once the account is gone, its entries show only as an unknown SID; remove those by hand in the folder's Properties > Security.

## 3. Console shortcut (step 6)

The console settings file is named after the VM id, so remove it while the VM still exists. It belongs to the Windows user who ran step 6; run this block as that user.

```powershell
$desktopLink = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) ($houseName + '.lnk')
Remove-Item -LiteralPath $desktopLink -Force -ErrorAction SilentlyContinue
$vm = Get-VM -Name $houseName -ErrorAction SilentlyContinue
if ($null -ne $vm) {
    $consoleFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) ('Microsoft\Windows\Hyper-V\Client\1.0\vmconnect.rdp.' + $vm.Id.ToString().ToUpperInvariant() + '.config')
    Remove-Item -LiteralPath $consoleFile -Force -ErrorAction SilentlyContinue
}
```

## 4. The VM and its disk (steps 4 and 5)

First list what will be deleted and show it to the human:

```powershell
$vmRoot = Join-Path $housePath $houseName
Get-VM -Name $houseName -ErrorAction SilentlyContinue | Select-Object Name, State, Path
if (Test-Path -LiteralPath $vmRoot) { Get-ChildItem -LiteralPath $vmRoot -Recurse -Force | Select-Object FullName, Length }
```

`$vmRoot` is the folder step 4 created for this VM. Only after the human agrees that everything listed may go:

```powershell
$vmRoot = Join-Path $housePath $houseName
if ($null -ne (Get-VM -Name $houseName -ErrorAction SilentlyContinue)) { Remove-VM -Name $houseName -Force }
if (Test-Path -LiteralPath $vmRoot) { Remove-Item -LiteralPath $vmRoot -Recurse -Force }
```

`Remove-VM` removes only the VM's registration. The second line deletes its disk and files.

## 5. The guardian and its certificates (step 4)

Every house on this PC shares the guardian `claude-house-guardian`. A VM whose guardian is gone never starts again. If `Get-VM` still lists another VM built with this runbook, skip this block.

```powershell
Remove-HgsGuardian -Name 'claude-house-guardian' -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath 'Cert:\LocalMachine\Shielded VM Local Certificates' -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -like '*(claude-house-guardian)*' } |
    Remove-Item -Force
```

## 6. House state on the host (steps 5, 6 and 10)

Deletes `C:\ProgramData\claude-house\<House.Name>`: the two credential files, `windows-applied.json` and the shortcut icon. The parent folder goes too when it is empty.

```powershell
$stateParent = Join-Path $env:ProgramData 'claude-house'
$stateRoot = Join-Path $stateParent $houseName
if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
if ((Test-Path -LiteralPath $stateParent) -and $null -eq (Get-ChildItem -LiteralPath $stateParent -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $stateParent -Force
}
```

## 7. The gate (step 3)

```powershell
Get-NetFirewallRule -DisplayName 'claude-house gate' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$portproxyRows = (netsh interface portproxy show v4tov4) -join "`n"
if ($portproxyRows -match ('(?m)^\s*' + [regex]::Escape($hostIp) + '\s+' + $gatePort + '\s')) {
    netsh interface portproxy delete v4tov4 listenaddress=$hostIp listenport=$gatePort
}
```

The IP Helper service stays as it is. Automatic is its Windows default, and other Windows features use it. Your proxy app is yours; uninstall does not touch it.

## 8. The house network (step 2)

Removing the switch also removes its host adapter `vEthernet (<SwitchName>)` and the host address on it. The block refuses while any VM is still attached.

```powershell
$attached = @(Get-VM | Get-VMNetworkAdapter | Where-Object { $_.SwitchName -eq $switchName })
if ($attached.Count -gt 0) {
    'Still attached to ' + $switchName + ': ' + (($attached | ForEach-Object { $_.VMName }) -join ', ')
}
elseif ($null -ne (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    Remove-VMSwitch -Name $switchName -Force
}
```

If step 2 removed an overlapping NAT with your yes, uninstall does not bring it back. The program that created it creates it again if it still needs it.

## 9. Blueprint and Hyper-V (steps 1 and 0), optional

- `house.config.psd1` is a file in your clone. Delete the clone when you no longer need it. Your Windows ISO is never touched.
- Hyper-V stays on. Turn it off only if no other virtual machine on this PC needs it. This one asks for a reboot; ask the human first:

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

## Verify

Each line prints nothing, or `False`, when the house is gone:

```powershell
Get-VM -Name $houseName -ErrorAction SilentlyContinue
Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'claude-house gate', 'claude-house SMB' -ErrorAction SilentlyContinue
Get-LocalUser -Name 'house-share' -ErrorAction SilentlyContinue
Get-SmbShare -Name ($shares | ForEach-Object { [string]$_.Name }) -ErrorAction SilentlyContinue
Get-HgsGuardian -Name 'claude-house-guardian' -ErrorAction SilentlyContinue
Test-Path -LiteralPath (Join-Path $env:ProgramData 'claude-house')
Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) ($houseName + '.lnk'))
```

Also run `netsh interface portproxy show v4tov4` and confirm no row listens on the house gate address and port.

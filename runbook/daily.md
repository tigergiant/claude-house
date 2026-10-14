# Daily use

Commands take their values from the blueprint (`house.config.psd1`).

## Start the house

Double-click **{{House.Name}}** on the desktop. If the shortcut is gone, `house check vm-online` reports `shortcut` and Do 2 of step 6 recreates it.

```powershell
Start-VM -Name '{{House.Name}}'
```

Sign in to Windows as `{{House.UserName}}` if the console asks.

## Check it

On the host, from the repository root, run `house doctor`. When a line is red, run `house next` and follow that page.

## After host or VM restarts

The proxy app on the host must be running. The gate portproxy must still map `{{Network.HostIP}}:{{Network.GatePort}}` to it. If the house cannot reach the network, run `house doctor` on the host and follow `house next`. Do not add NAT, a VPN, or another adapter. The runbook keeps Hyper-V's default automatic actions: when the host shuts down, Hyper-V saves the VM's state, and when the host starts, it resumes the VM if it was running. `Get-VM -Name '{{House.Name}}' | Select-Object AutomaticStartAction, AutomaticStopAction` shows them.

## Stop it

```powershell
Stop-VM -Name '{{House.Name}}'
```

The stop is graceful. Inside the VM, Start > Power > Shut down does the same. Closing the console window does not stop the VM; it keeps running. Wait until the VM state is Off before the next start.

## Change the VM password

Two steps, both by the human. The house keeps a copy of the password for its checks, so it must learn the new one.

1. In the VM: Settings > Accounts > Sign-in options > Password > Change. This is a normal Windows change and keeps everything Windows has saved for you, including the share credential from step 11. Do not reset the password from an administrator tool: a reset makes Windows throw those saved credentials away.
2. On the host, tell the house the new password. It proves the password opens the VM before it keeps it; a wrong one changes nothing.

```text
HUMAN ONLY - run in your own administrator PowerShell on the host, from the repository root:
Import-Module .\lib\House.psm1
Sync-HouseVmPassword -Config (Import-HouseConfig -Path .\house.config.psd1) -Password (Read-Host 'The new VM password' -AsSecureString)
```

The agent may then run `house check vm-online` to prove PowerShell Direct still works. If every guest check suddenly fails with "the credential is invalid", the password was changed in the VM without step 2.

## Where things are

The share address book is in the VM at `%USERPROFILE%\.claude\CLAUDE.md`, between the house begin and end markers.

## Good to know

- **Checkpoints:** step 4 turns automatic checkpoints off. Before a risky change, on the host: `Checkpoint-VM -Name '{{House.Name}}' -SnapshotName 'before-change'`. To go back: `Restore-VMCheckpoint -VMName '{{House.Name}}' -Name 'before-change' -Confirm:$false`, then start the VM if it is Off. A restore also brings back the VM password of that moment; if it differs, repeat step 2 of "Change the VM password". Checkpoints together with the house's virtual TPM are not verified yet.
- **Update Claude Code:** in the VM, run `claude update`. It downloads through the gate like everything else.
- **Driving the VM from the host:** work in the VM console. A host agent reaches the VM only through PowerShell Direct, the way the runbook does: `Invoke-Command -VMName '{{House.Name}}' -Credential (Import-Clixml "$env:ProgramData\claude-house\{{House.Name}}\vm-user.cred.xml") -ScriptBlock { ... }` from an administrator shell. Do not turn on Remote Desktop or add a network path for this.
- **Your host Claude setup stays on the host:** the VM has its own `%USERPROFILE%\.claude`. Host settings, MCP servers, skills and your own CLAUDE.md are not copied in; step 12 writes only the house block and the hooks. Copy what you need through a shared folder.
- **Heavy builds:** building on a shared folder is slow, because every file goes over SMB. Clone the repository into a local folder in the VM, for example `%USERPROFILE%\src`, and keep only results in a shared folder.
- **Chinese keyboard:** in the VM, Settings > Time & language > Language & region > Add a language > Chinese (Simplified, China). Leave "Set as my Windows display language" off to keep the current interface language. Switch keyboards with Win+Space.

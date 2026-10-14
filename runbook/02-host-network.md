---
id: host-network
title: Create the house network on the host
order: 2
requires: [blueprint]
runs_on: host
admin: true
reboot: false
human: false
---

## Purpose

Create an internal Hyper-V switch for the house and give the host its gate address on that switch. The house subnet must not sit behind a NAT, because a NAT would give the house a second way to the internet.

## Before you start

The blueprint must already pass. Open PowerShell as Administrator. Show every command in Do to the human and wait for approval before running it.

## Do

1. Create the internal switch. Do not create a NAT. A NAT would give the house a second way to the internet.

```powershell
New-VMSwitch -Name '{{Network.SwitchName}}' -SwitchType Internal
```

2. Assign the host address on the switch (the prefix length comes from `Subnet` in the blueprint):

```powershell
New-NetIPAddress -InterfaceAlias 'vEthernet ({{Network.SwitchName}})' -IPAddress {{Network.HostIP}} -PrefixLength {{Network.PrefixLength}}
```

3. Turn off routing on the house interface. Some hosts route between interfaces already (an existing NAT or Internet Connection Sharing turns it on), and then the house reaches the internet straight through the host without any NAT of its own. The gate still works, because it listens on the host address itself.

```powershell
Set-NetIPInterface -InterfaceAlias 'vEthernet ({{Network.SwitchName}})' -Forwarding Disabled
```

4. If `house check host-network` reports an overlapping NAT, show the human the NAT name from the check detail and ask before running `Remove-NetNat -Name <name>`. Do not remove it without that yes.

## Verify

Run:

```powershell
house check host-network
```

A pass looks like `PASS host-network: house network ready`.

## If it fails

- **switch:** No switch named `{{Network.SwitchName}}` exists. Run the `New-VMSwitch` command in Do.
- **switchType:** The switch exists but it is not Internal. Remove it only after the human agrees, then create it again as Internal. Do not attach the house to an External switch.
- **hostip:** `{{Network.HostIP}}` is not assigned on `vEthernet ({{Network.SwitchName}})`. Run the `New-NetIPAddress` command in Do.
- **prefixOk:** The host address is present but its prefix length does not match `Subnet` in the blueprint. Read the number after the slash and assign that prefix.
- **nonat:** A `Get-NetNat` prefix overlaps the house subnet. The check detail names every overlapping NAT. Show the human that name and ask before running `Remove-NetNat -Name <name>`.
- **noforward:** The host routes packets for `vEthernet ({{Network.SwitchName}})`; evidence `forwarding` lists the address families (IPv4, IPv6). Run the `Set-NetIPInterface ... -Forwarding Disabled` command in Do. If the interface cannot be read at all, `forwarding` is empty; check that the switch and host address exist first.
- **natNames:** These are the overlapping NAT names recorded in evidence. Use those names when you ask the human. An empty list means no overlap was found.

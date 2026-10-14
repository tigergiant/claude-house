---
id: blueprint
title: Write the house blueprint
order: 1
requires: [host-ready]
runs_on: host
admin: false
reboot: false
human: true
---

## Purpose

Record the VM name, storage path, ISO, size, shares and proxy choices in house.config.psd1 so later steps stay parameterised.

## Before you start

The agent asks the human for:

- the VM name (`{{House.Name}}`);
- where to store the VM files;
- the Windows 11 ISO path, and how to download one from Microsoft at https://www.microsoft.com/software-download/windows11 ;
- the ISO's language. `House.Locale` and `House.ImageName` must match the ISO: an English ISO uses `Locale = 'en-US'` and `ImageName = 'Windows 11 Pro'`; a Chinese (Simplified) ISO ships only `zh-CN`, so it needs `Locale = 'zh-CN'` and the Chinese edition name, for example `ImageName = 'Windows 11 专业版'`. Step 5 lists the edition names it finds in the ISO if the name does not match;
- the time zone of the VM;
- CPU count, RAM in GB and disk in GB;
- which folders to share, and whether each is writable;
- which proxy app runs on the host, its loopback port, and the mode. The port is in the proxy app's own settings (often called "port" or "mixed port"); `7890` in the example is only an example.

The example defaults to an English interface (`Locale = 'en-US'`) and Los Angeles time (`TimeZone = 'Pacific Standard Time'`), so that, with a proxy exit on the US west coast, the VM's language and clock agree with the one stable exit location that Global mode gives. If your exit is elsewhere, or you prefer your own clock, choose another zone, for example `'China Standard Time'`. `Get-TimeZone -ListAvailable` lists every valid id; use the `Id` column.

Recommend Global. Global sends every connection from the house through one upstream, so Claude sees one stable exit location.

## Do

1. Copy `house.config.example.psd1` to `house.config.psd1`.
2. Fill in the values the human chose. The host address is `{{Network.HostIP}}`, the VM address is `{{Network.VmIP}}`, the gate port is `{{Network.GatePort}}`, the proxy app port is `{{Network.ProxyAppPort}}`, the switch is `{{Network.SwitchName}}`, and the VM user is `{{House.UserName}}`.
3. Never write passwords, tokens or keys into `house.config.psd1` or any other file in this repo.

## Verify

Run:

```powershell
house check blueprint
```

A pass looks like `PASS blueprint: blueprint ready`.

## If it fails

- **config:** house.config.psd1 is missing or invalid. Copy the example and fix every problem named in the check detail. Do not add secret keys. Look.Theme must be light or none; omit Look to use light.
- **iso:** House.IsoPath is not a file. Download a Windows 11 ISO from Microsoft and point House.IsoPath at that file.
- **disk:** The volume that will hold House.Path does not have DiskGB + 10 GB free. Free space or choose a larger volume. The folder itself does not need to exist yet.
- **ssd:** House.Path is on a spinning hard disk (HDD). A Windows 11 VM there takes minutes to boot and to reach the desktop. Point House.Path at a folder on an SSD; `house check blueprint --json` shows the disk type in diskMedia.
- **ram:** Host RAM is under MemoryGB + 4 GB. Lower House.MemoryGB or use a machine with more RAM.
- **subnet:** Network.Subnet overlaps an existing host IPv4 network. Pick a free subnet. The house switch vEthernet ({{Network.SwitchName}}) is ignored once {{Network.HostIP}} is already assigned on it.

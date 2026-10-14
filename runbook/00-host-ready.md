---
id: host-ready
title: Make the host ready for Hyper-V
order: 0
requires: []
runs_on: host
admin: true
reboot: true
human: false
---

## Purpose

Prove this PC can host the house: Windows 11 Pro, Enterprise or Education, an elevated shell, Hyper-V enabled, hardware virtualization, and at least 16 GB of RAM.

## Before you start

You need Windows 11 Pro, Enterprise or Education. Windows Home cannot run Hyper-V and is not supported. Show every administrator command to the human and wait for approval before running it.

## Do

1. Open PowerShell as Administrator.
2. Enable Hyper-V. Ask the human before rebooting the PC:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

3. After the reboot, open PowerShell as Administrator again and continue with Verify.

## Verify

Run:

```powershell
house check host-ready
```

A pass looks like `PASS host-ready: host ready`.

## If it fails

- **edition:** The check decides by Windows SKU and build (≥ 22000), so localized Windows is fine. The SKU must be a Windows 11 Pro, Enterprise or Education family that can run Hyper-V. Windows Home is not supported. Install a supported edition.
- **elevated:** This shell is not running as Administrator. Open PowerShell as Administrator and run the check again.
- **hyper-v:** Microsoft-Hyper-V-All is not enabled. Run the command in Do, ask the human, then reboot. If the shell is not elevated the check reports Hyper-V as unknown and does not query it.
- **virtualization:** Firmware virtualization is off and no hypervisor is running. Turn on Intel VT-x or AMD-V in firmware, then reboot. When Hyper-V is already running, VirtualizationFirmwareEnabled reads false; HypervisorPresent true is enough.
- **ram:** The host has less than 16 GB of RAM. Use a machine with at least 16 GB.

---
id: claude-login
title: Sign in to Claude Code inside the house
order: 14
requires: [look]
runs_on: guest
admin: false
reboot: false
human: true
---

## Purpose

A person signs in to Claude Code as the VM user. The check only proves that a sign-in exists. It never reads the credential file or the API key, and it never puts either value in the result.

## Before you start

The look check must already pass. This step needs the human. The agent opens the console and stops.

## Do

1. The human double-clicks the **{{House.Name}}** shortcut on the desktop. The agent may instead open the console and stop:

```powershell
vmconnect.exe localhost '{{House.Name}}'
```

2. Sign in to Windows as `{{House.UserName}}` with the default password `123456`. After signing in, look at the sign-in screen, the desktop wallpaper, the taskbar and Start. Anything that still looks like stock Windows is a defect, not a preference. Report it. Then change the password right away with the procedure in `runbook/daily.md` ("Change the VM password"). The default is tolerable because the VM is on an internal switch, the house firewall blocks inbound traffic, and the console and PowerShell Direct both need a host administrator; never enable Remote Desktop or an external switch while it is still `123456`.

3. In the VM, open PowerShell as `{{House.UserName}}` and run `claude`. Complete the sign-in in the browser inside the VM. That browser uses the proxy from step 7. An API key is an alternative: set the user environment variable `ANTHROPIC_API_KEY` yourself. A provider with an Anthropic-compatible endpoint works too: set the user variables `ANTHROPIC_BASE_URL` (the provider's endpoint) and `ANTHROPIC_AUTH_TOKEN` (your key for that provider). Do not tell the agent any key.

```powershell
claude
```

4. On the host, prove the step:

```powershell
house check claude-login
```

## Verify

Run:

```powershell
house check claude-login
```

A pass looks like `PASS claude-login: claude login ready`. Evidence reports only true or false for the credential file and the API key variable, plus the `claude` version string.

## If it fails

- **signedin:** `%USERPROFILE%\.claude\.credentials.json` is missing or empty, and the user-scope `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` variables are both missing or empty. Sign in again inside the VM, or set the variable yourself. Do not paste the key into the repo or into chat.
- **claude:** `claude --version` did not return a version for the VM user. The official installer puts it under `%USERPROFILE%\.local\bin\claude.exe`. Repeat step 9 as the VM user. Do not install a different build.

# Contributing

Thanks for helping. Issues and pull requests are welcome, in English or Chinese.

## How the repository fits together

- `runbook/` says what each step does, `checks/` proves it is done, `lib/House.psm1` holds the shared code, and `house.ps1` is the read-only CLI the agent drives. See [ARCHITECTURE.md](ARCHITECTURE.md).
- Agents follow [AGENTS.md](AGENTS.md). Checks are read-only; please keep it that way.

## Before you open a pull request

Run the same two things CI runs, in Windows PowerShell 5.1:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester -Path .\tests
.\tools\Invoke-SecretScan.ps1 -History
```

- Add or update a test for any change to a check, a runbook step or the CLI.
- Never commit secrets, real host paths, account names or addresses from your own machine. The secret scan catches common patterns, not everything.
- If you changed a step, say in the pull request whether you ran it on a real PC.

## Reporting a problem

Use the **Something went wrong** issue form and paste `house doctor --json`. Security problems go through [SECURITY.md](SECURITY.md) instead.

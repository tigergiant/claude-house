# Agent protocol

Run `preflight` first, before step 0. On any blocker: stop, show the human the blocker lines verbatim, and do not try to work around them. Do not change anything on the machine before preflight passes.

Follow this loop. Do not improvise a different one.

`house` means `powershell -NoProfile -ExecutionPolicy Bypass -File .\house.ps1` run from the repository root in PowerShell. Do not call `.\house.ps1` directly: the default execution policy, and the download mark Windows puts on files from the internet, can block it.

1. Loop: `house next --json`, then `house step <id>`, then do the step, then `house check <id> --json`.
2. Show every admin command to the human before running it.
3. Never edit `checks/`, `runbook/`, `lib/` or `house.ps1` to make a check pass.
4. After 3 consecutive failures of the same step, stop and report.
5. Never write secrets into any file in this repo.
6. The house's internet access goes only through the gate; never add NAT, VPN or a second adapter.
7. Checks are read-only. The one exception is `checks/guest-shares.ps1`: it may create and delete a marker whose name starts with `.house-probe-`, and it must delete that marker in `finally`. No other check may write.

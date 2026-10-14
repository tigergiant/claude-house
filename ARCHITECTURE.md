# claude-house — Architecture (v2)

> Status: pre-alpha design. Nothing here is released.

claude-house gives Claude Code a dedicated Windows home on your own PC:

- a Hyper-V virtual machine with **exactly one network exit**;
- selected host folders shared into it;
- house rules installed for Claude.

**There is no installer and no app.** The product is a runbook that the user's own
coding agent follows step by step, plus a small CLI that lets the agent read the
runbook and **prove** each step is done.

## 1. Principles

1. **The agent does the work; the repo supplies the instructions and the proof.**
   - Every step has a runbook page and a read-only check.
   - A step is done only when `house check <id>` passes, never because the agent says so.
2. **One way to the internet.** The VM reaches the internet only through a single gate on the host. This is enforced by topology:
   - an internal switch with no NAT;
   - no second network adapter;
   - no public DNS.

   The VM firewall blocks inbound by default but leaves outbound open. Agents can therefore reach services on the host without a new firewall rule each time, and what the host exposes is governed by the host's own inbound firewall.
3. **Checks never change anything.** Changing the system is the agent's job, done visibly and with human approval for admin commands.
4. **Windows only.** Windows 11 host with Hyper-V, Windows 11 guest. Nothing else is in scope.
5. **No secrets anywhere in the repo, config, check output or logs.**

## 2. Repository layout

```
AGENTS.md                 operating protocol for the user's agent (also linked from CLAUDE.md)
house.ps1                 CLI entry (Windows PowerShell 5.1 compatible)
house.config.example.psd1 blueprint template; the real house.config.psd1 is git-ignored
runbook/NN-<id>.md        one page per step, fixed front matter + fixed sections
checks/<id>.ps1           one read-only check per step
lib/                      shared helpers for the CLI and checks (config, PowerShell Direct, output)
rules/                    house rules installed into the VM: CLAUDE.md template, hooks, settings
schemas/check.schema.json contract of one check result
tests/                    Pester tests: CLI, checks (mocked), repo consistency
tools/Invoke-SecretScan.ps1
```

## 3. Runbook page contract

Front matter (YAML):

```yaml
id: gate                 # stable, kebab-case, never reused
title: Open the network gate on the host
order: 3                 # strict total order
requires: [host-network] # ids that must pass first
runs_on: host            # host | guest (guest commands go through PowerShell Direct from the host)
admin: true              # agent must show each admin command to the human before running it
reboot: false            # the step may reboot the host or VM
human: false             # true when a person must act (e.g. sign in to Claude)
```

Sections, always in this order:

1. **Purpose:** one paragraph.
2. **Before you start:** preconditions and what to ask the human.
3. **Do:** numbered commands, copy-paste ready, parameterised only from `house.config.psd1`.
4. **Verify:** always `house check <id>`, plus what a pass looks like.
5. **If it fails:** known failure → cause → fix. The agent must not invent other fixes without telling the human.

## 4. Check contract

`checks/<id>.ps1` is a script that returns exactly one object matching `schemas/check.schema.json`:

```json
{ "id": "gate", "ok": false, "detail": "nothing listens on 127.0.0.1:7890", "fix": "runbook/03-gate.md#if-it-fails", "evidence": { "listen": false } }
```

Rules:

- **Read-only.** A repository test fails the build if a check contains a mutating command, for example:
  - `New-*`, `Set-*`, `Remove-*`, `Add-*`, `Enable-*`, `Disable-*`, `Start-*`, `Stop-*`, `Install-*`;
  - `netsh ... add|delete|set`, `reg add`, `icacls /grant`.
- **Deterministic and fast:** ≤ 30 s, with no network calls except the explicit gate probes.
- **Negative proofs are first-class.** The network checks must prove what is blocked, not only what works.

## 5. CLI

| Command | Output | Exit code |
|---|---|---|
| `house guide` | the plan, read from front matter only: order, id, title, runs_on, admin, human, requires. Runs no checks | 0 |
| `house step <id>` | the runbook page, rendered with values from the blueprint | 0, or 2 for an unknown id |
| `house check <id>` | one check result; refuses to run (blocked) if a `requires` step fails | 0 pass, 1 fail, 3 blocked |
| `house next` | the first step in order that does not pass, with its page path | 0 when all pass, 1 otherwise |
| `house doctor` | every check, never stops early, summary at the end | 0 when all pass, 1 otherwise |
| `house preflight` | whether this PC can host the house at all, before step 0: one line per item (BLOCKER, FIXABLE, OK or INFO) and a verdict. Changes nothing | 0 when compatible, 1 otherwise |

- Every command accepts `--json`; agents should always use it.
- The CLI only reads the blueprint and runs checks. It never changes the system.

## 6. Steps (v1)

| # | id | Runs on | Proves |
|---|---|---|---|
| 0 | `host-ready` | host | Windows 11 Pro/Enterprise/Education; Hyper-V feature enabled; elevated shell; virtualization firmware on; host RAM ≥ 16 GB |
| 1 | `blueprint` | host | `house.config.psd1` exists and is valid; has no secret-looking keys; ISO exists; the `House.Path` volume has `DiskGB + 10` GB free; host RAM ≥ `MemoryGB + 4` GB; `Subnet` does not overlap any existing host IPv4 network |
| 2 | `host-network` | host | internal switch `HouseNet` exists; host vNIC has the gate IP; **no `NetNat` covers the house subnet** |
| 3 | `gate` | host | the user's proxy app listens on loopback; a portproxy maps `gateIP:gatePort` to it; host inbound firewall allows only the VM IP on the gate port (port 445 for shares is proven in step 10) |
| 4 | `vm` | host | Gen 2 VM, Secure Boot, vTPM, CPU/RAM/disk as in the blueprint, **exactly one network adapter**, on `HouseNet` |
| 5 | `windows` | host | Windows is applied to the VHDX and an unattended local user is set up |
| 6 | `vm-online` | host | the VM runs and answers PowerShell Direct |
| 7 | `guest-network` | guest | static IP (gateway = host IP, with no NAT behind it); firewall inbound default **Block**, outbound default **Allow**; no public DNS servers; proxy set the same in env vars, WinHTTP and user settings, with the host IP in `NO_PROXY` |
| 8 | `one-way-out` | guest | **negative proof:** <br>• direct TCP to a public IP fails; <br>• DNS lookup of a public name fails; <br>• no second adapter (VPN, Tailscale, Wi-Fi passthrough) exists; <br>**positive proof:** HTTPS to `api.anthropic.com` through the gate returns an HTTP status |
| 9 | `tools` | guest | Git, Claude Code (official installer) and optional Python/Node, installed through the gate |
| 10 | `shares` | host | for each shared folder: SMB share, a dedicated non-admin account, read-only unless marked writable; host inbound firewall allows SMB (445) only from the VM IP |
| 11 | `guest-shares` | guest | each share is reachable as the VM user through the host name `house-host`; mirrored host paths resolve inside the VM; read-only shares refuse writes |
| 12 | `house-rules` | guest | CLAUDE.md with the share address book and rules, plus selected hooks, installed |
| 13 | `look` | guest | warm light theme, wallpaper, accent, quiet desktop and Windows Terminal scheme (or skipped when `Look.Theme` is `none`) |
| 14 | `claude-login` | guest | `human: true`. The person signs in to Claude Code inside the VM, and the check confirms it |

Daily use and removal are pages, not steps:

- `runbook/daily.md`: start the VM, open the console, run `house doctor`.
- If a check fails, follow `house next`.
- `runbook/uninstall.md`: removes what the runbook made on the host, newest step first.

## 7. Network design: one gate

```
 VM (house subnet .2)                    Host (house subnet .1)                      Internet
 ─────────────────────                   ──────────────────────                      ────────
 apps ── HTTP(S)_PROXY ──► gateIP:gatePort ── portproxy ──► 127.0.0.1:<proxy app> ──► internet (global by default)
 Explorer ──────────────► gateIP:445 (SMB shares)
 other host services ───► gateIP:<port>  (VM outbound open; host inbound firewall decides)
 anything else ──X  no route: no NAT, no second adapter, no public DNS
```

- **House subnet:** `172.31.250.0/24` by default <!-- secretscan:allow --> (configurable). The host is `.1`, the VM is `.2`, both static.
- **Gate target:** a proxy app the user runs on the host, listening on loopback, for example a Clash or mihomo compatible client. The user chooses how it connects. `ProxyMode` in the blueprint records the choice:
  - **`Global` (recommended default):** every connection from the house leaves through the same upstream node.
    - Claude sees one stable exit location.
    - Rule-based splitting can send some Claude endpoints direct and others through a node, which is a common cause of region and login errors.
  - **`Rule`:** the user's own rule set. Supported, but the runbook warns about the point above.
  - **`Direct`:** the proxy app connects straight out. Use this where no upstream is needed. The runbook ships a minimal example configuration.
- **What we tell users:**
  - Programs that ignore proxy settings cannot reach the internet from the house. This is by design.
  - Hooking such programs into the gate transparently is out of scope for v1.
- **The house never gets NAT, a second adapter, or a VPN client.** Step 8 fails if it does.

## 8. Shared folders and path mirroring

- Each shared folder in the blueprint becomes one SMB share on the host.
  - Access is granted only to a dedicated local account created for the house.
  - Read-only by default; `Writable = $true` must be explicit.
- Inside the VM, the share is mapped for the VM user.
  - When `Mirror = $true`, the original host path (for example `D:\projects`) also resolves inside the VM.
  - This lets paths in documents and prompts work unchanged.
- Recursive search at a share root over SMB is slow. The house rules and the optional `bounded-search` hook tell Claude to scope searches.

## 9. House rules (installed in the VM)

`rules/CLAUDE.md.template` is rendered with the address book (host path → VM path) and contains:

- network rules: one gate, do not try to bypass it;
- the SMB search contract;
- where deliverables go (a writable shared folder);
- "run `house doctor` before guessing".

Opt-in PreToolUse hooks:

- `bounded-search`: blocks unbounded recursive search at a share root and prints the scoped command.
- `share-delete-guard`: blocks recursive delete at a share root.
- `windows-guard`: blocks common Windows command mistakes and prints the correct form, for example cmd commands, `nul`, `/c`-style switches or Windows paths in Git Bash, `chcp`, PowerShell code that does not parse in Windows PowerShell 5.1, `2>&1` on a program, aliases such as `curl` and `where`, reading and rewriting one file in a 5.1 pipeline, writing a reserved file name or a non-ASCII `.ps1`, and recursive delete of a folder that holds a junction or symbolic link. Unlike the other two (Grep, Glob, Bash, PowerShell), it watches Bash, PowerShell, Write and Edit.

## 10. Agent operating protocol (AGENTS.md, summary)

1. Run `house next --json`. Read `house step <id>`.
2. Ask the human the questions listed in "Before you start".
3. For every command with `admin: true`, show the exact command to the human and wait for approval.
4. Run the commands, then `house check <id> --json`. Move on only when `ok` is true.
5. The same step failing 3 times in a row: stop and report the check output and what was tried.
6. Never edit files under `checks/` or `runbook/` to make a check pass.

## 11. Quality gates

- **Pester tests:**
  - CLI behaviour, including exit codes and blocked status;
  - every check against mocked cmdlets, with at least one passing and one failing case;
  - repository consistency:
    - every runbook page has a check and vice versa;
    - `requires` ids exist and the order has no cycles;
    - no check contains a mutating command.
- PSScriptAnalyzer: zero errors.
- Secret scan: generic patterns in the repo; the private deny-list path comes from `HOUSE_PRIVATE_DENYLIST` and is never committed.
- **Manual acceptance on a real Hyper-V host:**
  - an agent follows the runbook from step 0 to 14 on a throwaway VM;
  - `house doctor` reports all green;
  - step 8's negative proofs are re-run after deliberately adding a NAT, and must turn red.

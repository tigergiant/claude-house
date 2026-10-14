<p align="center">
  <img src="assets/brand/banner.png" alt="Hermi the hermit crab reading a book in its little house on a sunny desk" width="100%">
</p>

<h1 align="center">claude-house</h1>

<p align="center">
  <b>A separate Windows computer for Claude Code, living inside your PC.</b><br>
  Your own agent builds it step by step. One way out to the internet. Your folders, shared in.
</p>

<p align="center">
  <a href="../../actions/workflows/tests.yml"><img src="../../actions/workflows/tests.yml/badge.svg" alt="tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-C96442" alt="MIT licence"></a>
  <img src="https://img.shields.io/badge/host-Windows%2011%20Pro%20%7C%20Enterprise%20%7C%20Education-3D3929" alt="Windows 11 Pro, Enterprise or Education">
  <img src="https://img.shields.io/badge/Hyper--V-Gen%202%20%2B%20vTPM-3D3929" alt="Hyper-V Generation 2 with a virtual TPM">
  <img src="https://img.shields.io/badge/PowerShell-5.1-3D3929" alt="Windows PowerShell 5.1">
  <img src="https://img.shields.io/badge/built%20by-Claude%20Code-C96442?logo=claude&logoColor=white" alt="Built by Claude Code">
  <img src="https://img.shields.io/badge/status-early%20preview-F0B429" alt="Status: early preview">
</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

You do not install anything from us. Your coding agent reads the runbook and builds the
house step by step. Every step has a check that proves it is done.

> **Status: early preview.** Built and checked end to end on a real PC, in English and Chinese Windows, but still young: expect rough edges and tell us about them in Issues.
> Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic, PBC.

## What you get

- 🏠 **A whole Windows 11 desktop for Claude.** Claude Code, the Claude app, Git, Python, Node.js, GitHub CLI and VS Code are installed for you, and Claude is pinned to the taskbar.
- 🚪 **One way out.** The VM has no route to the internet of its own. Everything leaves through one gate: the proxy app you already run on your PC.
- 📁 **Your folders, same paths.** Pick host folders to share; inside the house they appear under the very same paths, read-only or writable as you choose.
- 🛡️ **House rules.** Hooks stop the classic slips: searching a whole shared drive, deleting on a share, common Windows command mistakes.
- ✅ **Every step proves itself.** `house check` and `house doctor` tell you exactly what is done and what is not, and point to the fix.
- 🦀 **A warm place to work.** Wallpaper, pointers, icons and a bilingual **Start here** page, starring Hermi the hermit crab.

## A look inside

<table>
  <tr>
    <td width="50%"><img src="assets/preview/welcome-en.png" alt="The Start here welcome page in English"></td>
    <td width="50%"><img src="assets/preview/welcome-zh.png" alt="The same welcome page switched to Chinese"></td>
  </tr>
  <tr>
    <td align="center"><b>Start here</b>: the first page on the house desktop</td>
    <td align="center">One click switches it to 中文</td>
  </tr>
</table>

<p align="center">
  <img src="assets/preview/overview.png" alt="Hermi art collection: mascot, day and evening wallpapers, sign-in screen, icons and wordmark" width="90%"><br>
  <sub>Every picture in the house. See <a href="assets/ART.md">assets/ART.md</a> for where they came from.</sub>
</p>

## Requirements

A physical Windows 11 Pro, Enterprise or Education PC (x64), 16 GB of RAM, hardware virtualization turned on, and about 100 GB free on an NTFS or ReFS drive. Windows Home, ARM, and a PC that is itself a virtual machine cannot host the house.

The VM runs its own copy of Windows 11 and needs its own Windows licence. This project sets no product key. Until you activate it, Windows in the VM shows an "Activate Windows" watermark and greys out some Personalization settings. That does not affect Claude.

Before changing anything, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\house.ps1 preflight
```

## How it works

1. Clone this repo on a Windows 11 Pro/Enterprise/Education PC with Hyper-V.
2. Start your coding agent from an **administrator** terminal. We build and test with Claude Code; any agent that can read AGENTS.md and run PowerShell on your PC (Codex, for example) should work. Step 0 checks that the shell is elevated, and most steps change Hyper-V, the network or the firewall, which needs an administrator. Open Start, right-click **Terminal**, choose **Run as administrator**, then:

   ```powershell
   cd <path to your clone>
   claude   # or codex, or your agent's own command
   ```

   Running as administrator does not let the agent skip you: AGENTS.md tells it to show every admin command and wait for your yes.
3. Tell your agent: *"Build claude-house by following AGENTS.md."*
4. The agent loops through the runbook:
   - `house next` finds the step to do;
   - `house step <id>` shows how to do it;
   - it runs the commands, asking you before any admin command;
   - `house check <id>` proves the step is done.

`house doctor` checks the whole house at any time.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## What this changes on your PC

Names in `code` are what the runbook creates; values in brackets come from your blueprint (`house.config.psd1`), with the example defaults after "default". Everything inside the VM lives on the VM's own disk and goes away with it.

| Step | Change on the host |
|---|---|
| 0 | The Windows feature `Microsoft-Hyper-V` (with all its parts) is turned on. This needs a reboot. |
| 1 | `house.config.psd1` is written in your clone of this repo. |
| 2 | An internal Hyper-V virtual switch [`Network.SwitchName`] (default `HouseNet`). Its host adapter `vEthernet (HouseNet)` gets the address [`Network.HostIP`] (the `.1` of the house subnet), and IP forwarding is turned off on that adapter. If the check found a NAT that overlaps the house subnet and you agreed, that NAT was removed. |
| 3 | The IP Helper service (`iphlpsvc`) is set to start automatically and started. A portproxy rule (`netsh interface portproxy`, v4tov4) forwards [`HostIP`]:[`Network.GatePort`] (default 3128) to `127.0.0.1`:[`Network.ProxyAppPort`]. A Windows Firewall inbound rule `claude-house gate` allows TCP to the gate port from the VM address only. |
| 4 | A Generation 2 virtual machine [`House.Name`] (default `claude-house`) with Secure Boot and a virtual TPM. Its files and its disk `<House.Name>.vhdx` live in `<House.Path>\<House.Name>`. A Host Guardian Service guardian `claude-house-guardian` protects the virtual TPM; creating it also creates its self-signed signing and encryption certificates in the local machine certificate store (`Shielded VM Local Certificates`). Every house on this PC shares that one guardian. |
| 5 | Windows is applied to the VM disk. `C:\ProgramData\claude-house\<House.Name>\` gets `vm-user.cred.xml` (the VM password, encrypted for your Windows account) and `windows-applied.json`. |
| 6 | A shortcut `<House.Name>.lnk` on the public desktop (`C:\Users\Public\Desktop`) that opens the VM console, its icon copied to `C:\ProgramData\claude-house\<House.Name>\house.ico`, and a console settings file `%APPDATA%\Microsoft\Windows\Hyper-V\Client\1.0\vmconnect.rdp.<VM id>.config` for the user who ran the step. |
| 10 | A local Windows account `house-share` (not an administrator, password never expires); its password is kept only in `C:\ProgramData\claude-house\<House.Name>\share-user.cred.xml`. One SMB share per entry in `Shares`, named as its `Name`, with `Everyone` removed and `house-share` given Read or Change. On each shared folder, an NTFS entry for `house-share` (Read & execute, or Modify when writable) that subfolders inherit. A shared folder that did not exist is created. A Windows Firewall inbound rule `claude-house SMB` allows TCP 445 from the VM address only. |

Steps 7–9 and 11–14 change only the inside of the VM. To remove everything again, follow [runbook/uninstall.md](runbook/uninstall.md).

## First sign-in

Double-click the **claude-house** shortcut on the desktop (the name is your `House.Name`). Windows asks for administrator approval (UAC) every time: the shortcut is marked to run as administrator because the Hyper-V console needs it. That prompt is normal. Sign in as `claude`, or your `House.UserName`, with password `123456`. Change it with the procedure in [runbook/daily.md](runbook/daily.md).

On the guest desktop, double-click **Start here**: a local welcome page that lists this house's shared folders, tools and rules, and what to do if something breaks.

The VM sits on an internal switch only, the house firewall blocks inbound traffic, and both the console and PowerShell Direct need a host administrator. The password protects nothing that the host administrator could not already reach, and it becomes unsafe the moment someone enables Remote Desktop in the VM or moves it to an external switch.

## Compared to other sandboxes

There are good ways to run Claude Code in a sandbox. Pick by what you need:

- **You want a Linux environment:** use Docker Sandboxes or one of the Linux/macOS VM tools (for example trailofbits/coop, or the QEMU and Nix based `claude-vm` projects that start a fresh VM per session). They are lighter than a full Windows VM.
- **You want a throwaway Windows session:** look at Hyper-V based disposable sandboxes such as agent-sandbox-vm.
- **You want a long-lived Windows workstation for Claude** where your host paths work unchanged inside, the only way out is one gate to the proxy app you already run, and your own agent builds and checks every step: that is claude-house.

Claude Code's documentation recommends a container, VM or WSL2 for sandboxing on native Windows; this repo is one way to do the VM option.

## License

MIT. See [LICENSE](LICENSE).

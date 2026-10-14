---
id: one-way-out
title: Prove the gate is the only way out
order: 8
requires: [guest-network]
runs_on: guest
admin: false
reboot: false
human: false
---

## Purpose

Prove the VM cannot reach the internet except through the gate at `http://{{Network.HostIP}}:{{Network.GatePort}}`. Direct TCP and DNS must fail, a second adapter or a second default route must be absent, and HTTPS to `api.anthropic.com` through the gate must return an HTTP status. A dead network stack is not a pass: the gate request is the control.

## Before you start

The guest-network check must already pass. Nothing on the host or in the VM should be changed for this step. Keep the PowerShell window elevated from the earlier steps, because the check asks the VM through PowerShell Direct. Do not print the VM credential.

## Do

Nothing to do. This step only proves.

## Verify

Run:

```powershell
house check one-way-out
```

A pass looks like `PASS one-way-out: one way out`. The check stays under 30 seconds: four TCP probes of 3 seconds each, two DNS lookups, and one HTTPS request of at most 15 seconds.

## If it fails

Never "fix" a failing negative proof by weakening the check or by adding an exception. A negative item passes only when the probe saw a recognised block. An unexpected error fails the item.

- **notcp:** A direct TCP connection from the guest to `1.1.1.1` or `9.9.9.9` on port 443 or 53 connected. Port 53 is probed too because some national networks filter 443 to these addresses, which would hide a leak. The usual causes are a NAT on the host or the host routing for the house interface. Run `house check host-network`: `nonat` names the NAT (ask the human before `Remove-NetNat`), `noforward` means routing is on and step 2 shows the command that turns it off. If the detail says `probe-error`, the probe itself broke; report that text and do not treat it as blocked.
- **nodns:** `example.com` resolved, either with the default resolver or with server `1.1.1.1`. If only the default resolver answered, DHCP or a DNS server is still set on the adapter; clear it with the script in `runbook/07-guest-network.md`. If server `1.1.1.1` answered, packets leave the house without the gate: run `house check host-network` and fix `nonat` or `noforward`. The firewall allows outbound, so a failed lookup here means there is no route, not merely a missing server setting.
- **noroute:** An IPv4 default route points somewhere other than `{{Network.HostIP}}`, or a second Up adapter exists. Tailscale, another VPN, or a Wi-Fi passthrough does this. Hidden adapters count. Remove the extra adapter or route. Do not add an allow rule for it.
- **gate:** `https://api.anthropic.com` through `http://{{Network.HostIP}}:{{Network.GatePort}}` did not return an HTTP status. Any status, including 401, 403 and 404, counts. A connection failure does not, even when every negative probe says blocked. The usual cause is the proxy app not running, or running in the wrong mode. Start it and confirm `{{Network.ProxyMode}}`.

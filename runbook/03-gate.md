---
id: gate
title: Open the network gate on the host
order: 3
requires: [host-network]
runs_on: host
admin: true
reboot: false
human: true
---

## Purpose

Open the one gate from the house to the internet: the person's proxy app listens on the host, portproxy forwards the house gate to that app, and the host firewall allows only the VM address to connect.

## Before you start

The person must start their proxy app and choose its mode. Ask:

- which proxy app they run (any Clash or mihomo-compatible client, or another HTTP proxy);
- its local port (it must equal `{{Network.ProxyAppPort}}`);
- which mode they want: **Global (recommended)**, Rule, or Direct.

Global means every connection from the house leaves through one upstream, so Claude sees one stable location. Rule-based splitting can send some Claude domains direct and others through a node.

For Direct without any proxy app, point them at `examples/mihomo-direct.yaml`. They download mihomo themselves from its official GitHub releases. Do not download binaries unless the human approves.

Show every command in Do to the human and wait for approval before running it.

## Do

1. Ask the human to start the proxy app on `127.0.0.1:{{Network.ProxyAppPort}}` in the mode they chose.
2. Make sure IP Helper starts automatically, then start it. Portproxy depends on that service.

```powershell
Set-Service iphlpsvc -StartupType Automatic
Start-Service iphlpsvc
```

3. Delete a stale portproxy row with the same listen address and port before adding it again. If the delete says the row is already gone, continue with the add.

```powershell
netsh interface portproxy delete v4tov4 listenaddress={{Network.HostIP}} listenport={{Network.GatePort}}
netsh interface portproxy add v4tov4 listenaddress={{Network.HostIP}} listenport={{Network.GatePort}} connectaddress=127.0.0.1 connectport={{Network.ProxyAppPort}}
```

4. Allow only the VM to reach the gate:

```powershell
New-NetFirewallRule -DisplayName "claude-house gate" -Direction Inbound -Action Allow -Protocol TCP -LocalAddress {{Network.HostIP}} -LocalPort {{Network.GatePort}} -RemoteAddress {{Network.VmIP}} -Profile Any
```

## Verify

Run:

```powershell
house check gate
```

A pass looks like `PASS gate: gate open`.

Connecting from the host itself to `{{Network.HostIP}}:{{Network.GatePort}}` succeeds through Windows loopback even when the VM could not reach it. Do not use a host-side connection to that address as proof. The VM-side proof comes in step 8.

## If it fails

- **proxyapp:** Nothing acceptable is listening on `{{Network.ProxyAppPort}}`. The listener must be on `127.0.0.1`, `0.0.0.0`, `::` or `::1`. Start the proxy app and set its port to `{{Network.ProxyAppPort}}`.
- **proxyProcess:** This is the process that owns the listener. Use it to see which app is bound to the port. A missing name means the owner process was already gone.
- **lanExposed:** The proxy app listens on all interfaces (`0.0.0.0` or `::`). This is not a failure. The check adds a warning. Prefer loopback when the app allows it.
- **iphlpsvc:** The IP Helper service is not running. Run the `Set-Service` and `Start-Service` commands in Do. Portproxy depends on it.
- **portproxy:** No v4tov4 row listens on `{{Network.HostIP}}` port `{{Network.GatePort}}` and connects to `127.0.0.1` port `{{Network.ProxyAppPort}}`. Delete the stale row, then add it again with the commands in Do.
- **firewall:** No enabled inbound Allow rule named `claude-house gate` matches TCP, local address `{{Network.HostIP}}`, local port `{{Network.GatePort}}` and remote address `{{Network.VmIP}}`. Create the rule in Do.
- **upstream:** The proxy app did not return any HTTP response for `https://api.anthropic.com`. A 4xx or 5xx still counts as reached. A timeout, connection refused or DNS failure does not. Start the app and confirm its upstream.
- **upstreamStatus:** The HTTP status the proxy returned, or empty when there was no response. Any status counts as reached.

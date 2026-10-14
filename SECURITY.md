# Security

claude-house builds a VM whose only way to the internet is one gate on your PC, and shares host folders into it. If you find a way around that design, for example a path from the VM to the network that skips the gate, a share that is writable when the blueprint says read-only, or a secret that ends up in a file or log, please tell us privately.

## How to report

Use **Report a vulnerability** on the repository's **Security** tab. Please do not open a public issue for security problems.

Include the step id, what you did, and what you saw. We will answer as soon as we can.

## What is not a vulnerability

The default VM password `123456` is documented in the README. It protects nothing the host administrator cannot already reach, as long as the VM stays on its internal switch and Remote Desktop stays off. See README, "First sign-in".

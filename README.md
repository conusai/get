# ConusAI Cloud — Installer & Releases

This repository hosts the public install script, landing page
([get.conusai.com](https://get.conusai.com)), and release binaries for
**ConusAI Cloud** — the sovereign cloud platform by
[Conus AI, UAB](https://www.conusai.com).

```bash
curl -sSL https://get.conusai.com/install.sh | sh
```

- **Mode A** — public server: everything runs on one machine with a public IP.
- **Mode B** — private origin: your server stays off the public internet; a
  tiny anchor on any cheap VPS forwards traffic over WireGuard, with TLS
  terminating on your origin.

The setup wizard (`conusai setup --interactive`) walks you through either
mode. Headless Mode A: `conusai setup --auto`. Channels: append
`--channel beta` or `--channel nightly` to the install command.

Currently supported: **Linux x86_64**. Docker is required at runtime.

Downloads are SHA-256-verified; releases may additionally carry a minisign
signature (`.minisig`) verified against the Conus AI release key. Set
`CONUSAI_INSTALL_REQUIRE_SIG=1` to make signature verification mandatory.

The platform source code is proprietary (© Conus AI, UAB — all rights
reserved). This repository contains only the installer, the landing page,
and compiled release artifacts.

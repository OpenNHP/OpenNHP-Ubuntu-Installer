# CLAUDE.md

This file guides Claude Code (and other AI agents) when working in this repository. It is a companion to [CONTRIBUTING.md](CONTRIBUTING.md); read both.

## Project Overview

OpenNHP-Ubuntu-Installer installs [OpenNHP](https://github.com/OpenNHP/opennhp) on a single Ubuntu 24.04 server so it can be tried quickly. It is **not** a production install.

The project is two Bash scripts, not a Go program. There is no compiler, no module system, and no unit-test suite here — the real build (Go, eBPF, plugins) happens inside the upstream OpenNHP source that `opennhp-ubuntu-installer.sh` clones and compiles on the target host.

- `opennhp-ubuntu-installer.sh` — installs or updates OpenNHP (server, access controller, agent, example plugin) and an optional NGINX demo site on one host.
- `opennhp-manage-agents.sh` — adds, lists, and removes trusted device keys after install.

Both scripts share one version number and target **supported Ubuntu LTS releases, x86_64 only** — 24.04 (primary baseline), 26.04 (supported), and 22.04 (deprecated, works with a warning). Other Ubuntu versions are rejected unless `ALLOW_UNSUPPORTED_UBUNTU=1` is set; other operating systems and ARM are always rejected. The installer runs these as a `preflight` system/compatibility summary at startup — keep the supported-version list in `ubuntu_support_status()` in sync with the policy table in [README.md](README.md).

## Repository Layout

```
OpenNHP-Ubuntu-Installer/
├── opennhp-ubuntu-installer.sh   # Main installer / updater / uninstaller
├── opennhp-manage-agents.sh     # Trusted-device key management
├── README.md                # User-facing docs + Changelog (source of truth)
├── CONTRIBUTING.md          # Contributor guide
├── CLAUDE.md                # This file
├── .gitattributes
└── .gitignore
```

## Versioning — IMPORTANT

Both scripts carry `INSTALLER_VERSION` and **must always match**.

```bash
grep -n '^INSTALLER_VERSION=' opennhp-ubuntu-installer.sh opennhp-manage-agents.sh
```

Whenever you change the behavior of **either** script:

1. Raise `INSTALLER_VERSION` in **both** `opennhp-ubuntu-installer.sh` and `opennhp-manage-agents.sh` to the same value.
2. Update the version and date in the header of [README.md](README.md).
3. Add a `### <version> — <YYYY-MM-DD>` entry to the [Changelog](README.md#changelog) describing what changed.

Never ship a behavior change without all three. The version is printed at startup and written to `/opt/opennhp/installer.env`.

## Common Commands

```bash
# Print the version each script reports
bash opennhp-ubuntu-installer.sh --version
bash opennhp-manage-agents.sh --version

# Lint the scripts before committing (install shellcheck if missing)
shellcheck opennhp-ubuntu-installer.sh opennhp-manage-agents.sh

# Check formatting / parse without running
bash -n opennhp-ubuntu-installer.sh
bash -n opennhp-manage-agents.sh
```

The installer itself must run as root on the target Ubuntu host, in an **interactive** SSH session (it reads prompts from the terminal), and is not meant to run on a developer laptop:

```bash
sudo bash opennhp-ubuntu-installer.sh
sudo bash opennhp-manage-agents.sh
```

## Testing

There is no local test harness. A real change must be verified on a fresh **supported Ubuntu LTS x86_64** host — 24.04 is the baseline; verify version-support changes on each release they claim to add (an EC2 instance is the documented path — see [README.md](README.md)). Do not claim the installer works unless it has been run end-to-end on such a host.

Before any run, lint with `shellcheck` and parse-check with `bash -n`. These catch most regressions without a server.

Because the installer changes the firewall, the services, and `/opt/opennhp`, test on a disposable host, never on one you cannot afford to lose access to. When testing the firewall step, keep a second way in (EC2 Session Manager or the serial console).

## Code Style

- `#!/usr/bin/env bash` and `set -euo pipefail` conventions already in the scripts — keep them.
- Quote variable expansions; prefer `"$var"` and `"${arr[@]}"`.
- Keep the scripts POSIX-friendly where practical, but Bash features are fine (this is a Bash installer).
- Match the surrounding naming, prompt wording, and comment density. User-facing prompts and summary text in the scripts should stay consistent with the wording in README.md.
- Keep installer output quiet: package, git, and compiler logs stay hidden unless a command fails.
- Run `shellcheck` and resolve warnings (or justify them inline) before committing.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/), matching the upstream OpenNHP repo:

- `feat:` — new behavior
- `fix:` — bug fixes
- `docs:` — README / docs only
- `refactor:`, `ci:`, `build:`, `chore:`

A version bump that accompanies a behavior change rides with that change's commit; a docs-only touch to the README does not need a version bump.

## Safety Notes

- The uninstall path (choice 2 when OpenNHP is already present) stops services, removes the TCP/80 firewall rules, and **deletes `/opt/opennhp`, including private keys and trusted devices**. Treat it as destructive.
- Never commit private keys, `secrets/`, or anything from `/opt/opennhp` into the repo.
- The installer opens only TCP port 80 in the host firewall; it never touches SSH or the knock port. Preserve that invariant.
- Re-running the installer rewrites config files (and drops any manually added SMTP settings). Keep that documented behavior intact or update the README if you change it.

## Protocol Context

OpenNHP is a Zero Trust toolkit: a device sends an encrypted "knock" (UDP 62206) to `nhp-serverd`; on success `nhp-acd` opens a short window in the firewall for that device to reach the protected resource (the demo `web` site on TCP 80). This installer wires up that flow with the upstream `example` plugin. For protocol internals, see the [upstream repository](https://github.com/OpenNHP/opennhp).

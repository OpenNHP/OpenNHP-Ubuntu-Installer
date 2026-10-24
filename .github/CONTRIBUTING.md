# Contributing to OpenNHP-Ubuntu-Installer

Thank you for your interest in contributing! This document provides guidelines for contributing to the OpenNHP Ubuntu installer. It is part of the [OpenNHP](https://github.com/OpenNHP/opennhp) project, and follows the same workflow and conventions.

## Code of Conduct

Please read and follow the OpenNHP [Code of Conduct](https://github.com/OpenNHP/opennhp/blob/main/CODE_OF_CONDUCT.md) to maintain a welcoming and inclusive community.

## Getting Started

### Prerequisites

This repository is two Bash scripts that install OpenNHP on a host. To develop and test them you need:

- **A supported Ubuntu LTS (x86_64)** - 24.04 is the baseline; 22.04 and 26.04 are also supported (see [Supported Ubuntu versions](README.md#supported-ubuntu-versions)). An EC2 instance is the documented path (see [README.md](README.md)).
- **Bash** - The scripts use `#!/usr/bin/env bash`.
- **Git** - Version control.
- **ShellCheck** (recommended) - For linting the scripts.

You do not need Go, Make, or a compiler to work on this repo. Those are only needed on the target host, where the installer clones and builds the upstream OpenNHP source for you.

### Clone

```bash
# Clone the repository
git clone https://github.com/OpenNHP/OpenNHP-Ubuntu-Installer.git
cd OpenNHP-Ubuntu-Installer
```

### Project Structure

```
OpenNHP-Ubuntu-Installer/
├── opennhp-ubuntu-installer.sh   # Installs / updates / uninstalls OpenNHP on one host
├── opennhp-manage-agents.sh     # Adds, lists, and removes trusted device keys
├── README.md                # User docs and Changelog (source of truth)
├── CONTRIBUTING.md          # This file
└── CLAUDE.md                # Guidance for AI coding agents
```

### Checking Your Changes

There is no unit-test suite in this repo. Validate changes with linting, a parse check, and a real run:

```bash
# Lint both scripts
shellcheck opennhp-ubuntu-installer.sh opennhp-manage-agents.sh

# Parse-check without executing
bash -n opennhp-ubuntu-installer.sh
bash -n opennhp-manage-agents.sh

# Confirm the reported version
bash opennhp-ubuntu-installer.sh --version
bash opennhp-manage-agents.sh --version
```

A behavior change must also be run end-to-end on a fresh **supported Ubuntu LTS x86_64** host before it is considered tested (and on each release a version-support change claims to add). The installer modifies services, the firewall, and `/opt/opennhp`, so use a disposable host and keep a second way in (EC2 Session Manager or the serial console) when testing the firewall step.

### Code Style

- Keep the existing `set -euo pipefail` conventions and quote variable expansions (`"$var"`).
- Resolve `shellcheck` warnings, or justify any you suppress inline.
- Match the surrounding wording for prompts and summary output, and keep it consistent with [README.md](README.md).
- Write clear, descriptive commit messages.
- Update the README (and its Changelog) when you change behavior.

## Versioning

Both scripts carry a shared `INSTALLER_VERSION`. When you change the behavior of **either** script:

1. Raise `INSTALLER_VERSION` to the same value in **both** `opennhp-ubuntu-installer.sh` and `opennhp-manage-agents.sh`.
2. Update the version and date in the [README.md](README.md) header.
3. Add a Changelog entry to [README.md](README.md#changelog).

A docs-only change does not need a version bump.

## Development Workflow

### Making Changes

1. **Fork** the repository on GitHub
2. **Clone** your fork locally
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** and commit them
5. **Check** your changes:
   ```bash
   shellcheck opennhp-ubuntu-installer.sh opennhp-manage-agents.sh
   bash -n opennhp-ubuntu-installer.sh opennhp-manage-agents.sh
   ```
6. **Push** to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```
7. **Open a Pull Request** on GitHub

### Commit Messages

Write clear, concise commit messages that explain the "why" behind your changes:

```
feat(installer): ask whether to install the demo NGINX site

Skip NGINX when the host already serves a site, while still
letting OpenNHP guard TCP port 80.
```

Use conventional commit prefixes:
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `ci:` - CI/CD changes
- `build:` - Build system changes
- `chore:` - Maintenance

### Pull Request Guidelines

- Keep PRs focused on a single change
- Bump `INSTALLER_VERSION` in both scripts and add a Changelog entry when behavior changes
- Update documentation if needed
- Describe how you tested the change (host, Ubuntu version, what you ran)
- Request review from maintainers

## Reporting Issues

### Bug Reports

When reporting bugs, please include:

- The installer version (`bash opennhp-ubuntu-installer.sh --version`)
- Ubuntu version and architecture (`lsb_release -a`, `uname -m`)
- The OpenNHP release you tried to build (`OPENNHP_REF` or the menu choice)
- Steps to reproduce the issue
- Expected vs actual behavior
- Relevant logs or error messages (redact keys and OTP codes)

### Feature Requests

For feature requests, please:

- Check existing issues to avoid duplicates
- Clearly describe the use case
- Explain the proposed solution

## Security Issues

For security vulnerabilities, please follow the OpenNHP [Security Policy](https://github.com/OpenNHP/opennhp/blob/main/SECURITY.md) and report issues privately. Do not open a public issue for a vulnerability, and never include private keys or OTP codes in a report.

## Getting Help

- **GitHub Issues** - For bugs and feature requests
- **Discussions** - For questions and community support
- **Documentation** - See [README.md](README.md) and the upstream [docs/](https://github.com/OpenNHP/opennhp/tree/main/docs) directory

## License

By contributing to OpenNHP-Ubuntu-Installer, you agree that your contributions will be licensed under the [Apache 2.0 License](https://github.com/OpenNHP/opennhp/blob/main/LICENSE), the same license as the OpenNHP project.

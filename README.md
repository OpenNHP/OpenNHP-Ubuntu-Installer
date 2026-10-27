# OpenNHP Ubuntu installer

**Version 1.0.8** (2026-10-24)

[OpenNHP](https://github.com/OpenNHP/opennhp) hides your services behind an encrypted network "knock": the TCP ports you choose stay closed to everyone until a trusted device authenticates. This installer sets up and configures OpenNHP on a supported Ubuntu server for you, so you can try it - or protect an existing service - without building and wiring the components by hand.

## What you get

- Installs an official OpenNHP release and runs it as system services.
- Protects the TCP ports you choose. SSH and the knock port stay open, and a 180-second rollback guards against accidental lockouts.
- Works alongside an existing website, or installs an optional NGINX demo page for testing.
- Generates the security keys and prints the connection details your clients need. A helper script adds or removes trusted devices, with optional one-time registration by 6-digit code.
- Exports server connection settings as JSON and a shareable QR code with `opennhp-share-config.sh`, using QuickChart without an API key. See [Share server connection settings with agents](#share-server-connection-settings-with-agents).
- Checks compatibility before making changes, and can be re-run to update OpenNHP or change protected ports without losing keys or trusted devices.

## Quickstart

> [!WARNING]  
> Installing directly on a production server is highly discouraged. Stand up a disposable copy of your environment, run the installer there, confirm the knock flow and firewall behave as you expect, and only then plan a production rollout.

You need a **supported Ubuntu LTS server, x86_64** (24.04 recommended) where these inbound rules are allowed: **TCP 22** from your IP, **UDP 62206** for the knock, and the **TCP ports you want to protect**. On AWS, see [Setting up an AWS EC2 instance](#setting-up-an-aws-ec2-instance).

From the server, update packages, install git, download the installer, and run it:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/OpenNHP/OpenNHP-Ubuntu-Installer.git
cd OpenNHP-Ubuntu-Installer
sudo bash opennhp-ubuntu-installer.sh
```

The installer first prints a compatibility summary and stops if a required check fails. It then asks a few questions: demo site, one-time registration, which ports to protect, and whether to turn the firewall on, and when it finishes it prints the **NHP Server public key** and the knock address. Use those to [connect a client](#connect-a-client).

See [What the installer asks](#what-the-installer-asks) for a walk-through of the prompts, and [Configuration](#configuration) for non-interactive options.

### Setting up an AWS EC2 instance

Skip this if you already have a supported Ubuntu host.

1. In the EC2 console, choose **Launch instance**.
2. Name the instance, then pick a supported **Ubuntu Server LTS** AMI (24.04 recommended; 22.04 or 26.04 also work), 64-bit (x86).
3. Choose an appropriate instance type.
4. Create or select a key pair.
5. Use a subnet that assigns a public IPv4 address. Leave public IPv6 off. The installer stops if the host has a global IPv6 address.
6. Create a security group with the inbound rules below.
7. Leave the disk at the default size and launch the instance.
8. Wait until the instance is **Running** and the status checks pass, then copy the public IPv4 address.

**Security group inbound rules:**

| Type            | Port                                     | Source             |
| --------------- | ---------------------------------------- | ------------------ |
| SSH             | TCP 22                                   | Your IP only       |
| Custom UDP      | 62206                                    | OpenNHP knock      |
| Protected ports | TCP (the ports you choose, e.g. 80, 443) | Those same clients |

Before you turn the firewall on later, keep another way back in - such as EC2 Session Manager or the serial console - in case the SSH session drops while protection is on. The server also needs outbound HTTPS during install to download packages, Go, this installer, and the OpenNHP source.

### What the installer asks

Before it changes anything, the installer prints a **system and compatibility summary**: the host's OS, kernel, architecture, CPU, memory, and free disk; the listening ports and whether each is public, private, or internal; and a pass, warn, or fail mark for each check - architecture, Ubuntu version, IPv4-only networking, and systemd. Memory, disk, and outbound-HTTPS shortfalls only warn. If a required check fails, the installer stops before touching the system.

Answer `y` at the first prompt to install on this host. Any other answer exits before the install changes the system. If OpenNHP is already on the host, the script asks you to choose:

1. Install or update, and keep existing keys.
2. Remove the OpenNHP configuration, then optionally install again from scratch.

Choice 2 stops the OpenNHP services, removes the OpenNHP firewall rules, and deletes `/opt/opennhp`, including private keys and trusted devices. NGINX, Go, and the Ubuntu packages stay installed. SSH rules are left in place.

You will also be asked:

- Whether to install the demo website. Press Enter to install NGINX and a sample page. Answer `n` to leave an existing site alone. OpenNHP can still guard TCP port 80.
- Whether to enable one-time registration. Press Enter to allow a device to register itself with a 6-digit code. Answer `n` to trust only keys you add. The example plugin is rebuilt so registration requests are rejected.
- Which build to install. Press Enter for the latest release, pick an older release, or choose **nightly** to build from the `main` branch (latest development).
- Whether to generate an agent key on the server or paste a public key you already have.
- The public address clients should use. The script suggests the address reported by AWS. Confirm it or type a hostname.
- Whether to turn on the website firewall now.

If you turn the firewall on, a 180-second timer removes that protection unless you confirm that SSH still works and you want to keep it. Answer that question before the timer runs out.

When the script finishes, it prints the server public key and the knock address (`PUBLIC_IP` UDP `62206`). The demo site URL is included when that site was installed. Copy the **NHP Server public key** into the client, and leave private keys on the server. If the script stops with an error, the keys already written are kept - run the same command again to continue, or choose uninstall if you want those keys deleted.

## Connect a client

For a React Native app on iOS or Android, use [react-native-opennhp](https://github.com/justingreerbbi/react-native-opennhp).

Give the client these values:

| Setting | Value |
| --- | --- |
| Server public key | The **NHP Server public key** printed at the end of install |
| Host | The public address you confirmed |
| Knock | UDP port `62206` |
| Auth service | `example` |
| Resource | `web` |

No separate username or password is required - a trusted device is allowed through. The client should be on a different network from the server; a test started on the server itself uses the private address, so it does not prove the public path works.

### Add a trusted device by hand

Run this from the same directory as the installer:

```bash
sudo bash opennhp-manage-agents.sh
```

The script asks whether to add or remove a device, then walks through that choice. The server reloads the trusted list without a restart. You can also pass arguments directly:

```bash
sudo bash opennhp-manage-agents.sh --name "Pixel" --public-key 'BASE64_PUBLIC_KEY'
sudo bash opennhp-manage-agents.sh --list
sudo bash opennhp-manage-agents.sh --remove "Pixel"
```

### Share server connection settings with agents

After installing OpenNHP, run `opennhp-share-config.sh` on the server from the same directory as the installer:

```bash
sudo bash opennhp-share-config.sh
# Also download the QR image now:
sudo bash opennhp-share-config.sh --download-qr
```

It reads the installed server's `Hostname`, `ListenPort`, and server public key,
then writes `connection.json` and `qr-link.txt` into a new, root-only directory
under `/opt/opennhp/shares/`. It prints a shareable QuickChart QR image link.
Opening that link generates a QR containing the JSON string directly; no JSON
hosting, account, or API key is needed. `--download-qr` also saves `qr.png`.
Without that flag the script makes no network requests.

Share the JSON file, QR image, or printed link with trusted users. The JSON has
`schemaVersion`, `host`, `port` (UDP knock port), `serverPublicKey`,
`authServiceId` (default `example`), and `resourceId` (default `web`). These are
server connection settings only: no private keys, passwords, or registration
codes are exported. An agent must support this JSON format to import it
automatically; otherwise enter the values manually. Each device still needs
its own key and must be added by the administrator or register with a one-time
code before it can knock successfully.

[QuickChart's documented QR endpoint](https://quickchart.io/documentation/qr-codes/)
provides the image. Opening the link or downloading the QR sends its JSON
contents to QuickChart. Its [privacy policy](https://quickchart.io/privacy/)
describes request logging; treat the link as disclosing the server's address
and public connection settings to that service. The link has no built-in expiry
or access restriction. To avoid depending on the service when sharing, download
and share the PNG or share the JSON directly.

For example, the generated JSON looks like this (the public key below is a placeholder):

```json
{
  "schemaVersion": 1,
  "host": "vpn.example.com",
  "port": 62206,
  "serverPublicKey": "BASE64_SERVER_PUBLIC_KEY",
  "authServiceId": "example",
  "resourceId": "web"
}
```

The host, port, and public key come from the installed server rather than these
example values. Generate a new export after changing those server settings.

| Option | What it does |
| --- | --- |
| `--download-qr` | Downloads the QR image as `qr.png`; requires outbound HTTPS to QuickChart. |
| `--output-dir PATH` | Saves the files in a new directory at `PATH`. |
| `--root PATH` | Reads another OpenNHP install directory instead of `/opt/opennhp`. |
| `--auth-service ID` | Sets the auth service ID; defaults to `example`. |
| `--resource ID` | Sets the resource ID; defaults to `web`. |
| `--help` | Prints usage and available options. |

To save all three files in a specific directory:

```bash
sudo bash opennhp-share-config.sh --download-qr --output-dir /root/team-connection
```

For a server using custom auth service and resource IDs:

```bash
sudo bash opennhp-share-config.sh --auth-service my-service --resource my-resource
```

The output directory must be new and its parent must exist. Existing exports
are never overwritten. `--root PATH` (or `NHP_ROOT`) selects another install
location. The helper requires Python 3, already installed by the installer.

### Register with a one-time code

If you enabled one-time registration, a device can register itself: the app asks the server for a 6-digit code, the user enters that code, and the app sends it back. The private key stays on the device. The user id and the email address must be the same. The code expires in 5 minutes, and it only works for the device that requested it. If you left registration off, add keys by hand instead; the server rejects registration requests.

This install does not set up email, so until you add a mail server the code is written to the NHP server log (the file name uses the UTC date):

```bash
sudo grep 'OTP CODE' /opt/opennhp/source/release/nhp-server/logs/server-$(date -u +%F).log
```

To watch for a new code:

```bash
sudo tail -f /opt/opennhp/source/release/nhp-server/logs/server-$(date -u +%F).log | grep --line-buffered 'OTP CODE'
```

The line looks like `OTP CODE for user@example.com: 123456`. See [Deliver one-time codes by email](#deliver-one-time-codes-by-email) to send them over SMTP instead.

## Choose which ports to protect

The installer asks which TCP ports OpenNHP should guard. Enter one or more ports, separated by spaces or commas. Press Enter to accept the default of **80**.

```text
TCP ports to protect, space or comma separated [80]: 80,443,8080
```

| Rule | Behavior |
| --- | --- |
| Default | TCP 80 when nothing else is given. |
| Multiple ports | Any mix, e.g. `80,443,8080` (up to 15). Duplicates are ignored. |
| Reserved | SSH (22) and the knock port (62206 by default, or `KNOCK_PORT`) are rejected, so you cannot lock yourself out. |
| Demo site | When the demo website is installed, TCP 80 is added automatically. |
| Scope | TCP only for now. UDP application ports may come later. |

Each guarded port drops new connections until a successful knock opens it for the knocking device. SSH, the knock port, and any host firewall or cloud security group rules you set yourself are left untouched - those decide which ports are *reachable*, while OpenNHP decides which reachable ports open only after a knock.

**Reconfigure later.** Run the installer again and choose option 1 (install or update). Your saved ports are offered as the default; enter a new set to change them. Keys and trusted devices are kept, and firewall rules for ports you drop are removed automatically. The same 180-second rollback protects the change: if you do not confirm that SSH still works, the guard is removed.

## Configuration

### Environment variables

Set any of these on the same command to skip a prompt or change a default:

| Variable | Default | What it does |
| --- | --- | --- |
| `PROTECTED_PORTS` | Asked during install | Skip the port prompt. A space- or comma-separated TCP port list, e.g. `PROTECTED_PORTS=80,443`. SSH (22) and the knock port are rejected. |
| `KNOCK_PORT` | `62206` (or the installed server's value) | UDP port the NHP server listens on for knocks. Feeds the server config and the reserved set. Example: `KNOCK_PORT=62207`. |
| `PUBLIC_IP` | Detected from `https://checkip.amazonaws.com` | Address clients should knock. You still confirm it. A DNS name is allowed. |
| `OPENNHP_REF` | Asked during install | Skip the build menu. A release tag, e.g. `OPENNHP_REF=v1.0.2`, or `OPENNHP_REF=nightly` (equivalently `main`) to build the `main` branch. |
| `GO_VERSION` | `1.26.0` | Go release installed under `/usr/local/go` when that exact version is missing. |
| `ALLOW_UNSUPPORTED_UBUNTU` | `0` | Set to `1` to bypass the Ubuntu version check and install on an unsupported release at your own risk. The other checks still apply. |

```bash
sudo PROTECTED_PORTS=80,443 PUBLIC_IP=203.0.113.10 OPENNHP_REF=v1.0.2 bash opennhp-ubuntu-installer.sh
```

### Supported Ubuntu versions

The installer checks the host's release at startup and installs only on a supported Ubuntu LTS version. Unsupported releases are rejected rather than attempted without validation.

| Ubuntu LTS | Status | Standard support ends | Notes |
| --- | --- | --- | --- |
| 22.04 | Deprecated | May 2027 | Still works, but standard security maintenance ends soon. Prefer 24.04 for new deployments. |
| 24.04 | Primary | May 2029 | Development and testing baseline. Recommended. |
| 26.04 | Supported | May 2031 | Newest LTS, with the longest support window. |

Only 64-bit x86 (`x86_64`) is supported. ARM, non-LTS releases, and other operating systems are rejected.

**Retirement policy.** A release is retired once it reaches the end of its standard security maintenance. While a version is deprecated, the installer still runs but warns you to move to a maintained release.

To install on an unsupported release at your own risk, set `ALLOW_UNSUPPORTED_UBUNTU=1`. This bypasses only the version check; the architecture, IPv6, and systemd checks still apply.

```bash
sudo ALLOW_UNSUPPORTED_UBUNTU=1 bash opennhp-ubuntu-installer.sh
```

### Deliver one-time codes by email

The example plugin can send the registration code through an SMTP server you already have, such as Amazon SES or your company mail host. You do not install a mail server on the EC2 instance. Add the mail settings to `/opt/opennhp/source/release/nhp-server/plugins/example/etc/config.toml`:

```toml
ExampleUsername = "unused"
ExamplePassword = "unused"
require_email_match = true

smtp_host = "email-smtp.us-east-1.amazonaws.com"
smtp_port = "587"
smtp_username = "your-smtp-username"
smtp_password = "your-smtp-password"
smtp_from = "OpenNHP <noreply@your-domain.com>"
smtp_subject = "Your OpenNHP verification code"
```

The plugin reloads this file on its own. After `smtp_host` is set, the next registration emails the code instead of only printing `OTP CODE`. The message body contains `Your verification code is:` followed by the 6 digits, and says the code expires in 5 minutes. The subject includes the code as well. Set `smtp_code_in_subject = false` if the code should stay in the message body only.

`smtp_port` defaults to `587` when it is omitted. If `smtp_username` is set, the plugin signs in with that username and password. The server log still records the send, including the code, on a line like `RequestOTP: otp[123456] sent to user@example.com` - treat that log as private.

Running the installer again rewrites this config file and removes the SMTP settings. Put them back after a re-run, or they will not be used.

### Open window and trust duration

Each successful knock opens a protected port to that device for **60 seconds**. When the time is up, the next new connection is dropped until the device knocks again. A download or page load that already started is not cut off.

That 60 seconds is not how long the device remains trusted:

- A key added with `opennhp-manage-agents.sh`, or generated during install, stays trusted until 2030-12-31.
- A key registered with the one-time code stays trusted for 24 hours. After that, the next knock is rejected until the device registers again.

**Change the open window.** Edit `OpenTime` in `/opt/opennhp/source/release/nhp-server/plugins/example/etc/resource.toml`:

```toml
["web"]
SkipAuth = true
OpenTime = 60
```

Use the number of seconds the next knock should keep a protected port open. The plugin reloads this file on its own. The largest value ipset accepts is `2147483` seconds. A value of `0` means that opening does not expire. Running the installer again sets `OpenTime` back to `60`.

**Change how long a one-time registration lasts.** Set `AgentKeyTTLSeconds` in `/opt/opennhp/source/release/nhp-server/etc/config.toml` to the lifetime in seconds, then restart:

```bash
sudo systemctl restart nhp-server
```

Keys already stored keep the expiry they were given; the new lifetime applies to the next registration. To change a key already written into `agent.toml`, edit that entry's `ExpireTime` (a Unix timestamp in seconds; `opennhp-manage-agents.sh` writes `1924991999`). The server reloads `agent.toml` when the file changes.

## How it works

Two programs run on the same host. A demo website is optional.

| Piece | Program | Job |
| --- | --- | --- |
| NHP server | `nhp-serverd` | Listens on UDP port 62206. A device "knocks" here. The server decides whether that device may open the site. |
| Access controller | `nhp-acd` | Turns an approved knock into a short opening in the firewall. |
| Demo website | NGINX | Optional. Serves a sample page on TCP port 80. Skip it when the host already has a site. |

A knock is a small encrypted packet from a trusted device. Until that knock succeeds, new visitors cannot reach the protected ports. SSH (TCP port 22) and the knock port stay open. The installer does not flush the rest of the firewall.

## Installation steps in detail

The script asks about the demo site and one-time registration, then installs OpenNHP. Command output from apt, git, and the compiler stays off the screen unless a command fails.

1. **Packages.** Installs anything missing from git, curl, ca-certificates, make, gcc, build-essential, iptables, ipset, python3, and openssl. NGINX is included only when you install the demo website.
2. **Go.** Installs Go 1.26.0 under `/usr/local/go` when that version is not already there.
3. **OpenNHP source.** Clones `https://github.com/OpenNHP/opennhp.git` into `/opt/opennhp/source`. The default checkout is the latest published release. Older releases are listed if you want one of those. Releases before v1.0.0 use an older layout. If the checkout has local edits, the script stops. It first removes a registration patch it added itself.
4. **Build.** Compiles `nhp-serverd`, `nhp-acd`, `nhp-agentd`, and the `example` plugin. It creates `/opt/confidential-containers/kbs/repository` first, because key generation needs that directory. If one-time registration is off, the example plugin is built so a registration request returns an error.
5. **Server and access-controller keys.** Keeps `/opt/opennhp/secrets/server.json` and `ac.json` when they already exist. Otherwise it generates a Curve25519 key pair. Key generation also prints log text, so the installer extracts the key from that output and checks that it is 32 bytes.
6. **Agent key.** Reuses a saved agent public key, generates a new pair in `secrets/agent.json`, or accepts a public key you paste. Choosing a new key removes the previous local `agent.json`.
7. **Configuration.** Detects the private IPv4 address, asks you to confirm the public address, and writes the TOML files. `agent.toml` is the exception: trusted keys already there are kept. The installer deletes the upstream `remote.toml` file. If that file is left in place, the access controller tries to reach a lab etcd server and exits.
8. **Services.** When you asked for the demo website, writes the sample page and starts NGINX. The page is mode `644`. `/var/www` and `/var/www/html` are mode `755`, so NGINX (user `www-data`) can read them. Otherwise the existing site is left alone. Private keys stay root-only. It installs and enables the three OpenNHP services, and starts only the NHP server.
9. **Firewall, optional.** Asks whether to protect your chosen ports, with the 180-second rollback described above.
10. **Summary.** Prints the public keys, the knock address, and whether the demo site and one-time registration are on.

The firewall allows an existing connection to finish, allows a device that just knocked, and drops every other new connection to the protected ports. It does not change SSH or the knock port.

## Day-to-day commands

```bash
systemctl status nhp-server nhp-ac nhp-firewall
journalctl -u nhp-server -u nhp-ac -f

# Hide the website behind OpenNHP. This also starts the access controller.
sudo systemctl enable --now nhp-firewall nhp-ac

# Stop hiding the website. The protected ports follow the security group again.
sudo systemctl disable --now nhp-ac nhp-firewall

# See who currently has an opening
sudo ipset list defaultset
sudo iptables -L OPENNHP -n -v
```

Running `sudo bash opennhp-ubuntu-installer.sh` again keeps existing keys, asks about the demo site, one-time registration, and the agent public key again, rewrites configuration from the addresses you enter, and walks through the firewall question again. Press Enter at the demo and registration questions to keep the choice saved last time.

## Files on the server

```text
/opt/opennhp/
  installer.env          version, agent public key, chosen revision, demo site, registration
  shares/                exported connection JSON, QR links, and optional QR images
  secrets/               server, access controller, and optional agent keys
  source/                OpenNHP source and built programs

/usr/local/sbin/nhp-firewall-rules
/etc/systemd/system/nhp-server.service
/etc/systemd/system/nhp-ac.service
/etc/systemd/system/nhp-firewall.service
/etc/systemd/system/nginx.service.d/nhp.conf
/var/www/html/index.html
/usr/local/go/
```

`/opt/opennhp` and `secrets/` are readable by root only. Do not copy private keys into the mobile app or into git. `nginx.service.d/nhp.conf` and `/var/www/html/index.html` are written only when the demo website is installed.

## Limits

- This is not a production install out of the box. 
- The installer does not configure the EC2 security group, IAM, or Session Manager.
- It guards only the TCP ports you choose; it does not open SSH, the knock port, or any other port in the host firewall.
- A trusted device is allowed to open the `web` resource without a separate password.
- A normal re-run keeps keys in `/opt/opennhp/secrets`. Choose uninstall at the start when those keys, trusted devices, and firewall rules should be deleted.
- It does not build for ARM, for non-LTS or otherwise unsupported Ubuntu versions, or for hosts that have a global IPv6 address.

## Todos

- Add a plugin to create an NHP-to-web-app authentication API. The example plugin is used today; it would be useful if NHP could read web-app data for legitimate user verification. Worth exploring.

## Changelog

`INSTALLER_VERSION` is printed at startup and stored in `/opt/opennhp/installer.env`.

### 1.0.8 - 2026-10-24

- You can now choose which TCP ports OpenNHP protects, instead of only TCP 80. Enter one or more ports at install time (default 80); SSH (22) and the knock port are rejected. Set `PROTECTED_PORTS` to skip the prompt. See [Choose which ports to protect](#choose-which-ports-to-protect).
- Added a **nightly** build option that compiles from the OpenNHP `main` branch, alongside the published releases. Choose it from the build menu or set `OPENNHP_REF=nightly`. A re-run rebuilds when `main` has advanced.
- The knock port is no longer hard-coded. It comes from the installed server's config (or `KNOCK_PORT`, default 62206) and feeds both the server configuration and the reserved-port set, so the reserved port always matches the port knocks actually arrive on.
- Re-running the installer can change the protected ports without resetting keys or trusted devices. Firewall rules for ports no longer protected are removed automatically, and the 180-second rollback still applies.
- The generated firewall rules now use a single multiport rule and reconcile themselves on each start/stop, so stale port rules are cleaned up.
- Refreshed the command-line interface of both scripts: a ruled banner, consistent section headers, aligned status lines, and a cleaner summary. Set `NO_COLOR=1` for plain output.
- The startup system summary now lists the listening ports (TCP and UDP, with protocol shown), the service on each, and whether each is exposed (public - all interfaces or a routable address), private (a LAN/VPC address), or internal (loopback only), so you can see what is already running before choosing which ports to protect. Exposure reflects the bind address; the firewall and security group still decide reachability.

### 1.0.7 - 2026-10-24

- Expanded Ubuntu support beyond 24.04. Supported LTS releases are now 22.04 (deprecated), 24.04 (primary baseline), and 26.04. Unsupported releases are rejected unless `ALLOW_UNSUPPORTED_UBUNTU=1` is set. See [Supported Ubuntu versions](#supported-ubuntu-versions).
- The installer prints a system and compatibility summary at startup (OS, kernel, architecture, CPU, memory, free disk) with a pass/warn/fail line for each check. Required checks (architecture, Ubuntu version, IPv4-only networking, systemd) stop the install when they fail; resource and connectivity shortfalls only warn.

### 1.0.6 - 2026-10-23

- Renamed the scripts to match the OpenNHP project: `nhp-linux-installer.sh` is now `opennhp-ubuntu-installer.sh`, and `nhp-manage-agents.sh` is now `opennhp-manage-agents.sh`. Update any saved commands, `scp` copies, or automation that referenced the old names.
- Added `CLAUDE.md` and `CONTRIBUTING.md` to align the repository workflow with the upstream OpenNHP repo.

### 1.0.5 - 2026-10-22

- Installer output is shorter. Package, git, and compiler logs stay hidden unless a command fails.
- Asks whether to enable one-time registration before building the example plugin. Answering no makes registration requests fail.
- Asks whether to install the demo NGINX site. Answering no leaves an existing web server in place.

### 1.0.4 - 2026-10-22

- The default OpenNHP revision is the latest published release. Press Enter at the release menu to install it.

### 1.0.3 - 2026-10-22

- The protected page and its directories are given modes NGINX can read. The page is mode `644`. `/var/www` and `/var/www/html` are mode `755`. The installer umask stays `077`.

### 1.0.2 - 2026-10-22

- Fixes the trusted-device list writer, which stopped at step 7 because of a Python indentation error.

### 1.0.1 - 2026-10-22

- Reads key files without putting `open()` on the shell command line. That call was parsed as a shell syntax error while changing the agent key.
- Choosing a new agent key removes the previous local `agent.json` before a replacement is generated.

### 1.0.0 - 2026-10-22

First tracked release.

- Installs the OpenNHP server, access controller, and NGINX on Ubuntu 24.04 x86_64, and protects only TCP port 80.
- Asks which OpenNHP revision to build. The default is commit `3c78548d30eead779cb17dd9c37072d9e2e6be5d`. Published release tags are listed too.
- Reads noisy key-generation output and keeps the key.
- Removes the upstream `remote.toml` so the access controller uses the local configuration.
- Keeps trusted device keys when the installer runs again.
- Adds `opennhp-manage-agents.sh`.
- Offers uninstall when OpenNHP is already configured.
- Records the installer version in the banner, the summary, and `installer.env`.

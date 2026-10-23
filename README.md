# OpenNHP Ubuntu installer

**Version 1.0.5** (2026-10-22)

`nhp-linux-installer.sh` installs [OpenNHP](https://github.com/OpenNHP/opennhp) on one Ubuntu 24.04 server. `nhp-manage-agents.sh` adds or removes trusted devices after install. Both scripts use the same version number. When either script changes, raise `INSTALLER_VERSION` in both files and add a [Changelog](#changelog) entry.

```bash
bash nhp-linux-installer.sh --version
bash nhp-manage-agents.sh --version
```

## Not a production install

This installer gets OpenNHP running so you can try it. It is not ready for production out of the box. Before you depend on it, configure production separately. That includes how registration codes are delivered, how long device keys stay trusted, who is allowed to register, and the EC2 security group.

A pull request that adds a production install of OpenNHP is welcome.

## What you get

Two programs run on the same host. A demo website is optional.

| Piece | Program | Job |
| --- | --- | --- |
| NHP server | `nhp-serverd` | Listens on UDP port 62206. A device "knocks" here. The server decides whether that device may open the site. |
| Access controller | `nhp-acd` | Turns an approved knock into a short opening in the firewall. |
| Demo website | NGINX | Optional. Serves a sample page on TCP port 80. This is the only port the installer hides. Skip it when the host already has a site. |

A knock is a small encrypted packet from a trusted device. Until that knock succeeds, new visitors cannot open the website. SSH (TCP port 22) and the knock port stay open. The installer does not flush the rest of the firewall.

The installer asks which OpenNHP release to build. Press Enter to use the latest published release. Older releases are listed too. Use [react-native-opennhp](https://github.com/justingreerbbi/react-native-opennhp) for an iOS or Android app.

The phone or other client should be on a different network from the EC2 instance. A test started on the instance itself uses the private address, so it does not prove the public path works.

## Start the EC2 instance

1. In the EC2 console, choose **Launch instance**.
2. Name the instance, then pick the AMI **Ubuntu Server 24.04 LTS**, 64-bit (x86). The installer rejects other operating systems and rejects ARM.
3. Choose an instance type such as `t3.small`.
4. Create or select a key pair. Download the private key. You need it to sign in.
5. Use a subnet that assigns a public IPv4 address. Leave public IPv6 off. The installer stops if the host has a global IPv6 address.
6. Create a security group with these inbound rules:
   | Type | Port | Source |
    | --- | --- | --- |
    | SSH | TCP 22 | Your IP only |
    | Custom UDP | 62206 | The phones or networks that will knock |
    | HTTP | TCP 80 | Those same clients |

    The installer cannot change this security group. If these ports are closed in AWS, the instance never sees the traffic.
7. Leave the disk at the default size and launch the instance.
8. Wait until the instance is **Running** and the status checks pass. Copy the public IPv4 address.

Before you turn the website firewall on later, have another way back in, such as EC2 Session Manager or the EC2 serial console. That matters if the SSH session drops while protection is on.

The server also needs outbound HTTPS during install, so it can download packages, Go, and the OpenNHP source.

## Sign in

On your computer, restrict the key file, then connect. Replace the key path and the public address.

```bash
chmod 600 /path/to/your-key.pem
ssh -i /path/to/your-key.pem ubuntu@PUBLIC_IP
```

The Ubuntu AMI signs you in as the user `ubuntu`.

## Copy the installer to the server

From the project directory on your computer, with the SSH session closed or from a second terminal:

```bash
scp -i /path/to/your-key.pem nhp-linux-installer.sh nhp-manage-agents.sh ubuntu@PUBLIC_IP:
```

The files land in `/home/ubuntu/`.

## Run the installer

Sign in again and start the installer from that home directory. It must be an interactive SSH session. Prompts are read from the terminal, so a piped or non-interactive run exits immediately.

```bash
ssh -i /path/to/your-key.pem ubuntu@PUBLIC_IP
sudo bash nhp-linux-installer.sh
```

Answer `y` at the first prompt to install on this host. Any other answer exits before the install changes the system.

If OpenNHP is already on the host, the script asks you to choose:

1. Install or update, and keep existing keys.
2. Remove the OpenNHP configuration, then optionally install again from scratch.

Choice 2 stops the OpenNHP services, removes the TCP/80 firewall rules, and deletes `/opt/opennhp`, including private keys and trusted devices. NGINX, Go, and the Ubuntu packages stay installed. SSH rules are left in place.

You will also be asked:

- Whether to install the demo website. Press Enter to install NGINX and a sample page. Answer `n` to leave an existing site alone. OpenNHP can still guard TCP port 80.
- Whether to enable one-time registration. Press Enter to allow a device to register itself with a 6-digit code. Answer `n` to trust only keys you add. The example plugin is rebuilt so registration requests are rejected.
- Which OpenNHP release to build. Press Enter to install the latest release.
- Whether to generate an agent key on the server or paste a public key you already have.
- The public address clients should use. The script suggests the address reported by AWS. Confirm it or type a hostname.
- Whether to turn on the website firewall now.

If you turn the firewall on, a 180-second timer removes that protection unless you confirm that SSH still works and you want to keep it. Answer that question before the timer runs out.

When the script finishes, it prints the server public key and the knock address (`PUBLIC_IP` UDP `62206`). The demo site URL is included when that site was installed. Copy the **NHP Server public key** into the client. Leave private keys on the server.

If the script stops with an error, the keys already written are kept. Run the same command again to continue, or choose uninstall if you want those keys deleted.

Optional settings, placed on the same command:

| Variable | Default | What it does |
| --- | --- | --- |
| `GO_VERSION` | `1.26.0` | Go release installed under `/usr/local/go` when that exact version is missing. |
| `PUBLIC_IP` | Detected from `https://checkip.amazonaws.com` | Address clients should knock. You still confirm it. A DNS name is allowed. |
| `OPENNHP_REF` | Asked during install | Skip the release menu. Example: `OPENNHP_REF=v1.0.2`. |

```bash
sudo PUBLIC_IP=203.0.113.10 OPENNHP_REF=v1.0.2 bash nhp-linux-installer.sh
```

## Connect a phone or other client

For a React Native app on iOS or Android, use [react-native-opennhp](https://github.com/justingreerbbi/react-native-opennhp).

Give the client these values:

| Setting | Value |
| --- | --- |
| Server public key | The **NHP Server public key** printed at the end of install |
| Host | The public address you confirmed |
| Knock | UDP port `62206` |
| Auth service | `example` |
| Resource | `web` |

No separate username or password is required. A trusted device is allowed through.

If you enabled one-time registration, a device can register itself. The app asks the server for a 6-digit code, the user enters that code, and the app sends it back. The private key stays on the device. The user id and the email address must be the same. The code expires in 5 minutes, and it only works for the device that requested it. If you left registration off, add keys with `nhp-manage-agents.sh` instead. The server rejects registration requests.

This install does not set up email. Until you add a mail server, the code is written to the NHP server log. The file name uses the UTC date:

```bash
sudo grep 'OTP CODE' /opt/opennhp/source/release/nhp-server/logs/server-$(date -u +%F).log
```

To watch for a new code:

```bash
sudo tail -f /opt/opennhp/source/release/nhp-server/logs/server-$(date -u +%F).log | grep --line-buffered 'OTP CODE'
```

The line looks like `OTP CODE for user@example.com: 123456`.

### Send the code by email

The example plugin can send the code through an SMTP server you already have, such as Amazon SES or your company mail host. You do not install a mail server on the EC2 instance. Add the mail settings to `/opt/opennhp/source/release/nhp-server/plugins/example/etc/config.toml`:

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

`smtp_port` defaults to `587` when it is omitted. If `smtp_username` is set, the plugin signs in with that username and password.

The server log still records the send, including the code, on a line like `RequestOTP: otp[123456] sent to user@example.com`. Treat that log as private.

Running the installer again rewrites this config file and removes the SMTP settings. Put them back after a re-run, or they will not be used.

You can also add a public key by hand:

```bash
sudo bash nhp-manage-agents.sh
```

The script asks whether to add or remove a device, then walks through that choice. The server reloads the trusted list without a restart.

```bash
sudo bash nhp-manage-agents.sh --name "Pixel" --public-key 'BASE64_PUBLIC_KEY'
sudo bash nhp-manage-agents.sh --list
sudo bash nhp-manage-agents.sh --remove "Pixel"
```

## How long the site stays open

Each successful knock opens the website to that device for **60 seconds**. When the time is up, the next new connection is dropped until the device knocks again. A download or page load that already started is not cut off.

That 60 seconds is not how long the device remains trusted:

- A key added with `nhp-manage-agents.sh`, or generated during install, stays trusted until 2030-12-31.
- A key registered with the one-time code stays trusted for 24 hours. After that, the next knock is rejected until the device registers again.

### Change the 60-second window

Edit `OpenTime` in `/opt/opennhp/source/release/nhp-server/plugins/example/etc/resource.toml`:

```toml
["web"]
SkipAuth = true
OpenTime = 60
```

Use the number of seconds the next knock should keep TCP port 80 open. The plugin reloads this file on its own. The largest value ipset accepts is `2147483` seconds. A value of `0` means that opening does not expire.

Running the installer again sets `OpenTime` back to `60`.

### Change how long a one-time registration lasts

Set `AgentKeyTTLSeconds` in `/opt/opennhp/source/release/nhp-server/etc/config.toml` to the lifetime in seconds, then restart:

```bash
sudo systemctl restart nhp-server
```

Keys already stored keep the expiry they were given. The new lifetime applies to the next registration.

To change a key that was written into `agent.toml`, edit that entry's `ExpireTime`. The value is a Unix timestamp in seconds. `nhp-manage-agents.sh` writes `1924991999`. The server reloads `agent.toml` when the file changes.

## Day-to-day commands

```bash
systemctl status nhp-server nhp-ac nhp-firewall
journalctl -u nhp-server -u nhp-ac -f

# Hide the website behind OpenNHP. This also starts the access controller.
sudo systemctl enable --now nhp-firewall nhp-ac

# Stop hiding the website. TCP port 80 follows the security group again.
sudo systemctl disable --now nhp-ac nhp-firewall

# See who currently has an opening
sudo ipset list defaultset
sudo iptables -L OPENNHP -n -v
```

Running `sudo bash nhp-linux-installer.sh` again keeps existing keys, asks about the demo site, one-time registration, and the agent public key again, rewrites configuration from the addresses you enter, and walks through the firewall question again. Press Enter at the demo and registration questions to keep the choice saved last time.

## What the installer does

The script asks about the demo site and one-time registration, then installs OpenNHP. Command output from apt, git, and the compiler stays off the screen unless a command fails.

1. **Packages.** Installs anything missing from git, curl, ca-certificates, make, gcc, build-essential, iptables, ipset, python3, and openssl. NGINX is included only when you install the demo website.
2. **Go.** Installs Go 1.26.0 under `/usr/local/go` when that version is not already there.
3. **OpenNHP source.** Clones `https://github.com/OpenNHP/opennhp.git` into `/opt/opennhp/source`. The default checkout is the latest published release. Older releases are listed if you want one of those. Releases before v1.0.0 use an older layout. If the checkout has local edits, the script stops. It first removes a registration patch it added itself.
4. **Build.** Compiles `nhp-serverd`, `nhp-acd`, `nhp-agentd`, and the `example` plugin. It creates `/opt/confidential-containers/kbs/repository` first, because key generation needs that directory. If one-time registration is off, the example plugin is built so a registration request returns an error.
5. **Server and access-controller keys.** Keeps `/opt/opennhp/secrets/server.json` and `ac.json` when they already exist. Otherwise it generates a Curve25519 key pair. Key generation also prints log text, so the installer extracts the key from that output and checks that it is 32 bytes.
6. **Agent key.** Reuses a saved agent public key, generates a new pair in `secrets/agent.json`, or accepts a public key you paste. Choosing a new key removes the previous local `agent.json`.
7. **Configuration.** Detects the private IPv4 address, asks you to confirm the public address, and writes the TOML files. `agent.toml` is the exception: trusted keys already there are kept. The installer deletes the upstream `remote.toml` file. If that file is left in place, the access controller tries to reach a lab etcd server and exits.
8. **Services.** When you asked for the demo website, writes the sample page and starts NGINX. The page is mode `644`. `/var/www` and `/var/www/html` are mode `755`, so NGINX (user `www-data`) can read them. Otherwise the existing site is left alone. Private keys stay root-only. It installs and enables the three OpenNHP services, and starts only the NHP server.
9. **Firewall, optional.** Asks whether to protect TCP port 80, with the 180-second rollback described above.
10. **Summary.** Prints the public keys, the knock address, and whether the demo site and one-time registration are on.

The firewall allows an existing connection to finish, allows a device that just knocked, and drops every other new connection to TCP port 80. It does not change SSH or the knock port.

## Files on the server

```text
/opt/opennhp/
  installer.env          version, agent public key, chosen revision, demo site, registration
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

`/opt/opennhp` and `secrets/` are readable by root only. Do not copy private keys into the mobile app or into git.

`nginx.service.d/nhp.conf` and `/var/www/html/index.html` are written only when the demo website is installed.

## Changelog

`INSTALLER_VERSION` is printed at startup and stored in `/opt/opennhp/installer.env`.

### 1.0.5 — 2026-10-22

- Installer output is shorter. Package, git, and compiler logs stay hidden unless a command fails.
- Asks whether to enable one-time registration before building the example plugin. Answering no makes registration requests fail.
- Asks whether to install the demo NGINX site. Answering no leaves an existing web server in place.

### 1.0.4 — 2026-10-22

- The default OpenNHP revision is the latest published release. Press Enter at the release menu to install it.

### 1.0.3 — 2026-10-22

- The protected page and its directories are given modes NGINX can read. The page is mode `644`. `/var/www` and `/var/www/html` are mode `755`. The installer umask stays `077`.

### 1.0.2 — 2026-10-22

- Fixes the trusted-device list writer, which stopped at step 7 because of a Python indentation error.

### 1.0.1 — 2026-10-22

- Reads key files without putting `open()` on the shell command line. That call was parsed as a shell syntax error while changing the agent key.
- Choosing a new agent key removes the previous local `agent.json` before a replacement is generated.

### 1.0.0 — 2026-10-22

First tracked release.

- Installs the OpenNHP server, access controller, and NGINX on Ubuntu 24.04 x86_64, and protects only TCP port 80.
- Asks which OpenNHP revision to build. The default is commit `3c78548d30eead779cb17dd9c37072d9e2e6be5d`. Published release tags are listed too.
- Reads noisy key-generation output and keeps the key.
- Removes the upstream `remote.toml` so the access controller uses the local configuration.
- Keeps trusted device keys when the installer runs again.
- Adds `nhp-manage-agents.sh`.
- Offers uninstall when OpenNHP is already configured.
- Records the installer version in the banner, the summary, and `installer.env`.

## Todos

- Look into tracking trusted devices so an inactive device can be removed from the trusted list.
- Update the documentaiton to use the GitHub repo to install instead of scp tranfer.
- Add a production install path. Pull requests are welcome.

## Limits

- This is not a production install out of the box. Configure production separately, or open a pull request that adds that path.
- The installer does not configure the EC2 security group, IAM, or Session Manager.
- It does not open SSH, the knock port, or any port other than TCP 80 in the host firewall.
- A trusted device is allowed to open the `web` resource without a separate password.
- A normal re-run keeps keys in `/opt/opennhp/secrets`. Choose uninstall at the start when those keys, trusted devices, and firewall rules should be deleted.
- It does not build for ARM, for Ubuntu versions other than 24.04, or for hosts that have a global IPv6 address.

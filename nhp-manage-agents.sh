#!/usr/bin/env bash
# Add or remove a trusted agent public key on the OpenNHP server on this host.
# The private key stays on the agent. Only the public key is stored here.
set -Eeuo pipefail
umask 077

# Keep this in sync with nhp-linux-installer.sh and the changelog in README.md.
INSTALLER_VERSION=1.0.5
if [[ ${1:-} == --version || ${1:-} == -V ]]; then
  printf 'nhp-manage-agents.sh %s\n' "$INSTALLER_VERSION"
  exit 0
fi

ROOT=${NHP_ROOT:-/opt/opennhp}
AGENT_TOML="$ROOT/source/release/nhp-server/etc/agent.toml"
REGISTRY="$ROOT/clients.json"
SECRETS="$ROOT/secrets"
SERVER_CONFIG="$ROOT/source/release/nhp-server/etc/config.toml"
TTL=1924991999

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok(){ printf '  \033[32m[COMPLETE]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[NOTE]\033[0m %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
ask(){ local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }
confirm(){ local v; v=$(ask "$1 [y/N]: "); [[ ${v,,} == y || ${v,,} == yes ]]; }

[[ $EUID == 0 ]] || die 'Run with sudo: sudo bash nhp-manage-agents.sh'
[[ -f $AGENT_TOML ]] || die "No server agent list at $AGENT_TOML. Run nhp-linux-installer.sh first."

worker=$(mktemp "$ROOT/.manage-agents.XXXXXX")
cat >"$worker" <<'PY'
import base64, json, os, sys

agent_toml, registry_path, secrets, server_config, ttl = sys.argv[1:6]
ttl = int(ttl)
command = sys.argv[6]
args = sys.argv[7:]

def decode(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise SystemExit(f'Invalid public key: {exc}')
    if len(raw) != 32:
        raise SystemExit('Expected a 32-byte Curve25519 public key')
    return raw

def canonical(value):
    return base64.b64encode(decode(value)).decode()

def load_agents():
    import tomllib
    if not os.path.isfile(agent_toml) or os.path.getsize(agent_toml) == 0:
        rows = []
    else:
        with open(agent_toml, 'rb') as handle:
            data = tomllib.load(handle)
        rows = data.get('Agents') or []
    names = {}
    if os.path.isfile(registry_path):
        with open(registry_path, encoding='utf-8') as handle:
            saved = json.load(handle)
        for row in saved.get('clients') or []:
            if row.get('publicKey') and row.get('name'):
                names[decode(row['publicKey'])] = row['name']
    agents = []
    seen = set()
    for row in rows:
        pub = (row.get('PubKeyBase64') or '').strip()
        if not pub:
            continue
        raw = decode(pub)
        if raw in seen:
            continue
        seen.add(raw)
        agents.append({'name': names.get(raw, ''), 'publicKey': canonical(pub)})
    return agents

def write_agents(agents):
    lines = []
    named = []
    for entry in agents:
        if entry['name']:
            lines.append(f"# {entry['name']}")
            named.append({'name': entry['name'], 'publicKey': entry['publicKey']})
        lines.append('[[Agents]]')
        lines.append(f'PubKeyBase64 = "{entry["publicKey"]}"')
        lines.append(f'ExpireTime = {ttl}')
        lines.append('')
    text = '\n'.join(lines) if lines else ''
    with open(agent_toml, 'r+', encoding='utf-8') as handle:
        handle.seek(0)
        handle.write(text)
        handle.truncate()
    os.chmod(agent_toml, 0o600)
    temporary = registry_path + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as handle:
        json.dump({'clients': named}, handle, indent=2)
        handle.write('\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, registry_path)

def server_pubkey():
    path = os.path.join(secrets, 'server.json')
    if not os.path.isfile(path):
        return ''
    with open(path, encoding='utf-8') as handle:
        return json.load(handle).get('publicKey') or ''

def other_identity_keys():
    found = []
    for name in ('server.json', 'ac.json'):
        path = os.path.join(secrets, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding='utf-8') as handle:
            data = json.load(handle)
        for field in ('publicKey', 'privateKey'):
            if data.get(field):
                found.append(decode(data[field]))
    return found

def hostname():
    if not os.path.isfile(server_config):
        return ''
    import tomllib
    with open(server_config, 'rb') as handle:
        data = tomllib.load(handle)
    return data.get('Hostname') or ''

def public_key_from_user_text(text):
    text = text.strip()
    if text.startswith('{'):
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SystemExit(f'Invalid key JSON: {exc}')
        if data.get('privateKey'):
            print('Ignored a private key in the pasted JSON. Only the public key is stored.', file=sys.stderr)
        pub = (data.get('publicKey') or '').strip()
        if not pub:
            raise SystemExit('The pasted JSON has no publicKey field.')
        return pub
    return ''.join(text.split())

def cmd_list():
    agents = load_agents()
    if not agents:
        print('No trusted clients.')
        return
    for entry in agents:
        label = entry['name'] or '(unnamed)'
        print(f"{label}\t{entry['publicKey']}")

def cmd_add(name, public_key):
    name = name.strip()
    if not name or len(name) > 64:
        raise SystemExit('Client name must be 1 to 64 characters.')
    if any(ch in name for ch in '\n\r#'):
        raise SystemExit('Client name cannot contain a new line or #.')
    public_key = canonical(public_key_from_user_text(public_key))
    raw = decode(public_key)
    if raw in other_identity_keys():
        raise SystemExit('That value is the server or access-controller key, not a client public key.')
    agents = load_agents()
    for entry in agents:
        if entry['name'] == name:
            raise SystemExit(f'A client named {name!r} is already registered. Choose another name or remove it first.')
        if decode(entry['publicKey']) == raw:
            label = entry['name'] or 'an unnamed client'
            raise SystemExit(f'That public key is already trusted ({label}).')
    agents.append({'name': name, 'publicKey': public_key})
    write_agents(agents)
    print(f'ADDED\t{name}\t{public_key}')
    server_key = server_pubkey()
    host = hostname()
    if server_key:
        print(f'SERVER_PUB\t{server_key}')
    if host:
        print(f'KNOCK\t{host} UDP/62206')
    print('RESOURCE\texample\tweb')

def cmd_remove(selector):
    selector = selector.strip()
    agents = load_agents()
    kept = []
    removed = None
    selector_raw = None
    try:
        selector_raw = decode(public_key_from_user_text(selector))
    except SystemExit:
        selector_raw = None
    for entry in agents:
        match = entry['name'] == selector or (selector_raw is not None and decode(entry['publicKey']) == selector_raw)
        if match and removed is None:
            removed = entry
            continue
        kept.append(entry)
    if removed is None:
        raise SystemExit(f'No trusted client matches {selector!r}.')
    write_agents(kept)
    label = removed['name'] or '(unnamed)'
    print(f"REMOVED\t{label}\t{removed['publicKey']}")

if command == 'list':
    cmd_list()
elif command == 'add':
    if len(args) != 2:
        raise SystemExit('add requires a name and a public key')
    cmd_add(args[0], args[1])
elif command == 'remove':
    if len(args) != 1:
        raise SystemExit('remove requires a client name or public key')
    cmd_remove(args[0])
else:
    raise SystemExit(f'Unknown command {command}')
PY
chmod 700 "$worker"
cleanup(){ rm -f "$worker"; }
trap cleanup EXIT

usage(){
  cat <<EOF
nhp-manage-agents.sh ${INSTALLER_VERSION}

Usage:
  sudo bash nhp-manage-agents.sh
  sudo bash nhp-manage-agents.sh --name NAME --public-key PUBLIC_KEY
  sudo bash nhp-manage-agents.sh --list
  sudo bash nhp-manage-agents.sh --remove NAME_OR_PUBLIC_KEY
  bash nhp-manage-agents.sh --version

With no arguments, the script asks whether to add or remove an agent and walks through that choice.
The public key is the base64 Curve25519 key from the agent.
A JSON object with a publicKey field is also accepted. Private keys are not stored.
EOF
}

name=''
public_key=''
action=''
selector=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die '--name needs a value'
      name=$2
      shift 2
      ;;
    --public-key)
      [[ $# -ge 2 ]] || die '--public-key needs a value'
      public_key=$2
      shift 2
      ;;
    --list) action='list'; shift ;;
    --remove)
      [[ $# -ge 2 ]] || die '--remove needs a client name or public key'
      action='remove'
      selector=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ -n $name || -n $public_key ]]; then
  [[ $action == remove ]] && die '--name and --public-key cannot be combined with --remove.'
  action=add
fi

if [[ $action == list ]]; then
  python3 "$worker" "$AGENT_TOML" "$REGISTRY" "$SECRETS" "$SERVER_CONFIG" "$TTL" list
  exit 0
fi

if [[ -z $action ]]; then
  [[ -t 0 && -e /dev/tty ]] || die 'Run interactively, or pass --name and --public-key, --list, or --remove.'
  say 'Manage trusted agents'
  printf '  1) Add an agent\n  2) Remove an agent\n'
  while [[ -z $action ]]; do
    choice=$(ask 'Choose 1 or 2: ')
    case ${choice,,} in
      1|a|add) action=add ;;
      2|r|remove) action=remove ;;
      *) warn 'Enter 1 to add an agent, or 2 to remove an agent.' ;;
    esac
  done
fi

if [[ $action == remove ]]; then
  say 'Remove an agent'
  say 'Step 1 — Choose the agent'
  printf '  These public keys are trusted now:\n\n'
  python3 "$worker" "$AGENT_TOML" "$REGISTRY" "$SECRETS" "$SERVER_CONFIG" "$TTL" list
  printf '\n'
  if [[ -z $selector ]]; then
    selector=$(ask 'Agent name or public key to remove: ')
  fi
  [[ -n $selector ]] || die 'No agent selected.'
  say 'Step 2 — Confirm'
  confirm "Remove trusted agent '$selector'?" || exit 0
  python3 "$worker" "$AGENT_TOML" "$REGISTRY" "$SECRETS" "$SERVER_CONFIG" "$TTL" remove "$selector"
  ok 'Agent removed. The NHP server reloads agent.toml on its own.'
  exit 0
fi

say 'Add an agent'
printf '  The agent keeps its private key. This server stores only the public key.\n'
if [[ -z $name ]]; then
  [[ -t 0 && -e /dev/tty ]] || die 'Pass --name and --public-key, or run the script in a terminal.'
  say 'Step 1 — Name the agent'
  printf '  Use a short label you will recognize later, such as the device name.\n'
  name=$(ask 'Agent name: ')
fi
if [[ -z $public_key ]]; then
  [[ -t 0 && -e /dev/tty ]] || die 'Pass --public-key, or run the script in a terminal.'
  say 'Step 2 — Paste the public key'
  printf '  Paste the base64 public key from the agent.\n'
  printf '  A JSON object with a publicKey field is also accepted. A private key in that JSON is ignored.\n'
  public_key=$(ask 'Public key: ')
fi
[[ -n $name && -n $public_key ]] || die 'An agent name and public key are required.'
if [[ -t 0 && -e /dev/tty ]]; then
  say 'Step 3 — Confirm'
  confirm "Add agent '$name'?" || exit 0
fi

python3 "$worker" "$AGENT_TOML" "$REGISTRY" "$SECRETS" "$SERVER_CONFIG" "$TTL" add "$name" "$public_key"
if systemctl is-active --quiet nhp-server 2>/dev/null; then
  sleep 1
  if journalctl -u nhp-server --since '30 seconds ago' --no-pager | grep -q 'agent peer config'; then
    ok 'NHP server reloaded the trusted agent list'
  else
    ok 'Trusted agent saved. The NHP server watches agent.toml and reloads it after the file changes.'
  fi
else
  warn 'nhp-server is not running. The agent is saved and will be trusted on the next start.'
fi

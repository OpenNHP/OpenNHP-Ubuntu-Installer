#!/usr/bin/env bash
# Install the OpenNHP server, access controller, and protected website
# on one Ubuntu host. The default OpenNHP revision is the latest
# published release.
set -Eeuo pipefail
umask 077

# Keep this in sync with opennhp-manage-agents.sh and the changelog in README.md.
INSTALLER_VERSION=1.0.8
if [[ ${1:-} == --version || ${1:-} == -V ]]; then
  printf 'opennhp-ubuntu-installer.sh %s\n' "$INSTALLER_VERSION"
  exit 0
fi

GO_VERSION=${GO_VERSION:-1.26.0}
ROOT=/opt/opennhp
SRC="$ROOT/source"
SECRETS="$ROOT/secrets"
SERVER="$SRC/release/nhp-server"
AC="$SRC/release/nhp-ac"
AGENT="$SRC/release/nhp-agent"
STATE="$ROOT/installer.env"
TTL=1924991999

# ---- Interface -------------------------------------------------------------
# Everything below is presentation only. Colors fall back to plain text when
# output is not a terminal or NO_COLOR is set.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi
# Terminal width, clamped so rules stay tidy on wide or tiny terminals.
_cols(){ local w; w=$(tput cols 2>/dev/null || echo 72); (( w > 72 )) && w=72 || true; (( w < 40 )) && w=40 || true; printf '%s' "$w"; }
_rule(){ local w; w=$(_cols); printf '%s' "$1"; printf '─%.0s' $(seq "$w"); printf '%s\n' "$RESET"; }
# Ruled banner: bold title with an optional dimmed subtitle.
header(){
  printf '\n'; _rule "$CYAN"
  printf ' %s%s%s' "$BOLD" "$1" "$RESET"
  [[ -n ${2:-} ]] && printf '  %s%s%s' "$DIM" "$2" "$RESET"
  printf '\n'; _rule "$CYAN"
}
# Section heading, underlined to the width of its title.
say(){ printf '\n%s%s%s\n%s' "${BOLD}${CYAN}" "$1" "$RESET" "$DIM"; printf '─%.0s' $(seq "${#1}"); printf '%s\n' "$RESET"; }
info(){ printf '  %s\n' "$*"; }
ok(){ printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die(){ printf '\n  %s✗ Error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
kv(){ printf '  %s%-16s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }
ask(){ local v; read -r -p "  ${CYAN}❯${RESET} $1" v </dev/tty; printf '%s' "$v"; }
pause(){ read -r -p "  ${CYAN}❯${RESET} $1" _ </dev/tty; printf '\n'; }
confirm(){ local v; v=$(ask "$1 [y/N]: "); [[ ${v,,} == y || ${v,,} == yes ]]; }
# Empty input keeps the saved choice. 1 means yes.
prompt_bool(){
  local label=$1 default=$2 v hint
  if [[ $default == 1 ]]; then hint='Y/n'; else hint='y/N'; fi
  v=$(ask "$label [$hint]: ")
  if [[ -z $v ]]; then
    [[ $default == 1 ]]
    return
  fi
  [[ ${v,,} == y || ${v,,} == yes ]]
}
# Ports that must never be placed behind NHP: SSH and the knock port.
# Guarding either would risk locking the operator out or breaking knocks.
RESERVED_PORTS='22 62206'
MAX_PORTS=15
# Validate and normalize a TCP port list. Accepts a space- or comma-separated
# string. On success prints a comma-separated, de-duplicated list (order
# preserved). On failure prints nothing and writes the reason to stderr.
normalize_ports(){
  local raw=${1//,/ } tok p seen=' ' out=()
  for tok in $raw; do
    [[ $tok =~ ^[0-9]+$ ]] || { echo "Not a number: '$tok'" >&2; return 1; }
    p=$((10#$tok))
    (( p >= 1 && p <= 65535 )) || { echo "Port out of range (1-65535): $tok" >&2; return 1; }
    [[ " $RESERVED_PORTS " == *" $p "* ]] && { echo "Port $p is reserved; SSH (22) and the knock port (${KNOCK_PORT:-62206}) must stay reachable" >&2; return 1; }
    [[ $seen == *" $p "* ]] && continue
    seen+="$p "
    out+=("$p")
  done
  (( ${#out[@]} > 0 )) || { echo 'No valid ports given' >&2; return 1; }
  (( ${#out[@]} <= MAX_PORTS )) || { echo "Too many ports (max $MAX_PORTS)" >&2; return 1; }
  local IFS=,
  echo "${out[*]}"
}
# True when $2 (comma list) contains port $1.
ports_include(){ [[ ",$2," == *",$1,"* ]]; }
# Ask for the TCP ports to protect, re-prompting until the entry is valid.
# Sets PROTECTED_PORTS to the normalized list.
choose_ports(){
  local default=$1 raw norm
  while true; do
    raw=$(ask "TCP ports to protect, space or comma separated [$default]: ")
    raw=${raw:-$default}
    if norm=$(normalize_ports "$raw"); then
      PROTECTED_PORTS=$norm
      return 0
    fi
    info "Enter one or more TCP ports (1-65535). 22 and the knock port (${KNOCK_PORT:-62206}) are not allowed."
  done
}
# Hide a long command. On failure, show the tail of its output and stop.
run_quiet(){
  local label=$1 log
  shift
  log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  printf '\n\033[31m%s failed.\033[0m Last output:\n' "$label" >&2
  tail -n 40 "$log" >&2 || true
  rm -f "$log"
  exit 1
}
# A previous run may have patched the example plugin. Put that file back
# before checking the tree, then patch again only if this run turns codes off.
restore_plugin_source(){
  local plugin_src=$SRC/examples/server_plugin/basic/main.go
  [[ -f $plugin_src && -d $SRC/.git ]] || return 0
  if grep -q 'opennhp-installer otp gate' "$plugin_src"; then
    git -C "$SRC" checkout --quiet -- examples/server_plugin/basic/main.go
  fi
}
disable_plugin_otp(){
  local status=0
  python3 - "$SRC/examples/server_plugin/basic/main.go" <<'PY' || status=$?
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "opennhp-installer otp gate" in text:
    raise SystemExit(0)

def insert(text, signature, block):
    start = text.find(signature)
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0 or brace - start > 500:
        raise SystemExit(f"Could not patch {signature}")
    return text[: brace + 1] + "\n" + block + text[brace + 1 :]

request_block = '\treturn fmt.Errorf("RequestOTP: one-time registration is disabled") // opennhp-installer otp gate\n'
register_block = (
    "\tif req.Ack != nil {\n"
    "\t\treq.Ack.ErrCode = common.ErrAgentKeyStoreError.ErrorCode()\n"
    '\t\treq.Ack.ErrMsg = "one-time registration is disabled"\n'
    "\t}\n"
    '\treturn req.Ack, fmt.Errorf("RegisterAgent: one-time registration is disabled") // opennhp-installer otp gate\n'
)
patched = insert(text, "func RequestOTP(", request_block)
if patched is None:
    raise SystemExit(2)
text = insert(patched, "func RegisterAgent(", register_block)
if text is None:
    raise SystemExit("Could not find func RegisterAgent( in the example plugin")
path.write_text(text)
PY
  if [[ $status == 2 ]]; then
    warn 'This OpenNHP release has no one-time registration handlers.'
    return 0
  fi
  [[ $status == 0 ]] || die 'Could not turn off one-time registration in the example plugin.'
}
# Read one JSON string field. The shell command itself must not contain open(),
# because an unquoted parenthesis there is a bash syntax error.
json_field(){
  python3 -c 'import json,sys; sys.stdout.write(str(json.load(sys.stdin)[sys.argv[1]]))' "$2" < "$1"
}
opennhp_configured(){
  [[ -f $STATE || -d $SECRETS || -d $SRC \
    || -f /etc/systemd/system/nhp-server.service \
    || -f /etc/systemd/system/nhp-ac.service \
    || -f /etc/systemd/system/nhp-firewall.service \
    || -f /usr/local/sbin/nhp-firewall-rules ]]
}
uninstall_opennhp(){
  say 'Uninstall OpenNHP configuration'
  systemctl stop nhp-rollback.timer nhp-rollback.service 2>/dev/null || true
  systemctl disable --now nhp-ac.service 2>/dev/null || true
  systemctl disable --now nhp-firewall.service 2>/dev/null || true
  systemctl disable --now nhp-server.service 2>/dev/null || true
  if [[ -x /usr/local/sbin/nhp-firewall-rules ]]; then
    /usr/local/sbin/nhp-firewall-rules stop || true
  fi
  # Remove every INPUT jump into OPENNHP, whatever ports it covered, in case
  # the firewall-rules helper is missing (partial install).
  iptables -S INPUT 2>/dev/null | awk '/-j OPENNHP$/{$1="-D"; print}' | while read -r spec; do
    iptables $spec 2>/dev/null || true
  done
  iptables -F OPENNHP 2>/dev/null || true
  iptables -X OPENNHP 2>/dev/null || true
  # A failed access controller can insert a host-wide accept on the way out.
  while iptables -C INPUT -d 0.0.0.0/0 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -d 0.0.0.0/0 -j ACCEPT
  done
  while iptables -C FORWARD -d 0.0.0.0/0 -j ACCEPT >/dev/null 2>&1; do
    iptables -D FORWARD -d 0.0.0.0/0 -j ACCEPT
  done
  local setname
  for setname in defaultset defaultset_down tempset; do
    ipset destroy "$setname" 2>/dev/null || true
  done
  rm -f /usr/local/sbin/nhp-firewall-rules \
    /etc/systemd/system/nhp-server.service \
    /etc/systemd/system/nhp-ac.service \
    /etc/systemd/system/nhp-firewall.service \
    /etc/systemd/system/nginx.service.d/nhp.conf
  rmdir /etc/systemd/system/nginx.service.d 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed nhp-server.service nhp-ac.service nhp-firewall.service nhp-rollback.service 2>/dev/null || true
  if [[ -f /var/www/html/index.html ]] && grep -q 'OpenNHP access granted' /var/www/html/index.html; then
    rm -f /var/www/html/index.html
  fi
  rm -rf /opt/confidential-containers/kbs/repository
  rmdir /opt/confidential-containers/kbs /opt/confidential-containers 2>/dev/null || true
  rm -rf "$ROOT"
  ok 'OpenNHP services, firewall rules, keys, and configuration removed'
}
save_state(){
  {
    printf 'INSTALLER_VERSION=%q\n' "$INSTALLER_VERSION"
    [[ -n ${AGENT_PUB:-} ]] && printf 'AGENT_PUB=%q\n' "$AGENT_PUB"
    [[ -n ${OPENNHP_REF:-} ]] && printf 'OPENNHP_REF=%q\n' "$OPENNHP_REF"
    [[ -n ${BUILT_COMMIT:-} ]] && printf 'BUILT_COMMIT=%q\n' "$BUILT_COMMIT"
    [[ -n ${ENABLE_OTP:-} ]] && printf 'ENABLE_OTP=%q\n' "$ENABLE_OTP"
    [[ -n ${INSTALL_DEMO:-} ]] && printf 'INSTALL_DEMO=%q\n' "$INSTALL_DEMO"
    [[ -n ${PROTECTED_PORTS:-} ]] && printf 'PROTECTED_PORTS=%q\n' "$PROTECTED_PORTS"
    [[ -n ${KNOCK_PORT:-} ]] && printf 'KNOCK_PORT=%q\n' "$KNOCK_PORT"
  } > "$STATE"
  chmod 600 "$STATE"
}
# Ubuntu LTS releases this installer supports. See the support policy in
# README.md. Status values:
#   primary     development and testing baseline
#   supported   verified to work
#   deprecated  still works, but standard security maintenance ends soon
ubuntu_support_status(){
  case $1 in
    24.04) printf 'primary' ;;
    26.04) printf 'supported' ;;
    22.04) printf 'deprecated' ;;
    *)     printf 'unsupported' ;;
  esac
}
# Classify a listening socket's bind address by how exposed it is:
#   internal  loopback only (reachable just from this host)
#   private   a specific LAN/VPC address (RFC1918, link-local, or IPv6 ULA)
#   public    all interfaces (0.0.0.0 / ::) or a routable address
_bind_scope(){
  local h=$1
  h=${h#\[}; h=${h%\]}; h=${h%%\%*}
  case $h in
    0.0.0.0|'*'|''|::) echo public ;;
    127.*|::1) echo internal ;;
    10.*|192.168.*|169.254.*) echo private ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) echo private ;;
    fe80:*|fc[0-9a-f][0-9a-f]:*|fd[0-9a-f][0-9a-f]:*) echo private ;;
    *) echo public ;;
  esac
}
# List listening TCP ports with the service and exposure of each, so the
# operator can see what is already running, and how reachable it is, before
# choosing which ports to protect. Needs root (already checked) for names.
list_open_ports(){
  command -v ss >/dev/null 2>&1 || { info 'ss is not available; skipping the open-port list.'; return 0; }
  declare -A proc_of=() scope_of=()
  local proto state rq sq laddr peer rest port proc host scope rank oldrank key k tag color
  # Scan TCP and UDP listeners separately; the knock arrives on UDP, so a
  # UDP-only service (nhp-serverd) must not be hidden behind a TCP entry.
  for proto in tcp udp; do
    while read -r state rq sq laddr peer rest; do
      [[ -n $laddr ]] || continue
      port=${laddr##*:}
      [[ $port =~ ^[0-9]+$ ]] || continue
      host=${laddr%:*}
      scope=$(_bind_scope "$host")
      proc=$(sed -n 's/.*users:((\"\([^"]*\)\".*/\1/p' <<<"$rest")
      [[ -n $proc ]] || proc='-'
      key="$port/$proto"
      [[ -n ${proc_of[$key]:-} ]] || proc_of[$key]=$proc
      # Keep the most-exposed scope seen for a port (public > private > internal).
      case $scope in public) rank=3 ;; private) rank=2 ;; *) rank=1 ;; esac
      case ${scope_of[$key]:-} in public) oldrank=3 ;; private) oldrank=2 ;; internal) oldrank=1 ;; *) oldrank=0 ;; esac
      if (( rank > oldrank )); then scope_of[$key]=$scope; fi
    done < <(if [[ $proto == tcp ]]; then ss -H -tlnp 2>/dev/null; else ss -H -ulnp 2>/dev/null; fi)
  done
  if (( ${#proc_of[@]} == 0 )); then
    info 'No listening ports detected.'
    return 0
  fi
  for k in $(printf '%s\n' "${!proc_of[@]}" | sort -t/ -k1,1n -k2,2); do
    port=${k%/*}; proto=${k#*/}
    scope=${scope_of[$k]}
    case $scope in
      public)  color=$YELLOW; tag='public' ;;
      private) color=$CYAN;   tag='private' ;;
      *)       color=$DIM;    tag='internal' ;;
    esac
    printf '  %s%-11s%s %s%-8s%s %s\n' "$DIM" "${port}/${proto}" "$RESET" "$color" "$tag" "$RESET" "${proc_of[$k]}"
  done
}
# Gather host facts, print a system summary, then run the compatibility
# checks. Hard requirements (architecture, a supported Ubuntu release,
# IPv4-only networking, systemd) stop the installer; resource and
# connectivity shortfalls only warn. A version mismatch can be overridden
# with ALLOW_UNSUPPORTED_UBUNTU=1.
preflight(){
  local fails=0 arch kern pretty cores mem_kib mem_gib target disk_avail status
  arch=$(uname -m)
  kern=$(uname -r)
  pretty=${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}
  cores=$(nproc 2>/dev/null || echo '?')
  mem_kib=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_gib=$(awk -v k="${mem_kib:-0}" 'BEGIN{ if (k+0>0) printf "%.1f", k/1048576; else printf "?" }')
  target=/opt; [[ -d $target ]] || target=/
  disk_avail=$(df -BG --output=avail "$target" 2>/dev/null | awk 'NR==2{gsub(/[^0-9]/,"");print $1}')
  [[ -n $disk_avail ]] || disk_avail='?'
  status=$(ubuntu_support_status "${VERSION_ID:-}")

  say 'System Information'
  kv 'Hostname' "$(uname -n)"
  kv 'OS' "$pretty"
  kv 'Kernel' "$kern"
  kv 'Architecture' "$arch"
  kv 'CPU cores' "$cores"
  kv 'Memory' "${mem_gib} GiB"
  kv "Free disk ($target)" "${disk_avail} GiB"
  printf '\n'
  say 'Listening ports (port/proto, exposure, service):'
  list_open_ports
  printf '\n'

  say 'Compatibility checks'

  # Architecture -- hard requirement.
  if [[ $arch == x86_64 ]]; then
    ok 'Architecture x86_64 is supported'
  else
    warn "Architecture $arch is not supported (x86_64 only)"
    fails=$((fails + 1))
  fi

  # Distribution and version -- hard requirement.
  if [[ ${ID:-} != ubuntu ]]; then
    warn "Operating system is '${ID:-unknown}', not Ubuntu"
    fails=$((fails + 1))
  else
    case $status in
      primary)   ok "Ubuntu ${VERSION_ID} LTS is supported (development baseline)" ;;
      supported) ok "Ubuntu ${VERSION_ID} LTS is supported" ;;
      deprecated)
        warn "Ubuntu ${VERSION_ID} LTS works, but its standard security maintenance ends soon; 24.04 LTS is recommended" ;;
      *)
        if [[ ${ALLOW_UNSUPPORTED_UBUNTU:-0} == 1 ]]; then
          warn "Ubuntu ${VERSION_ID:-unknown} is not a supported release; continuing because ALLOW_UNSUPPORTED_UBUNTU=1"
        else
          warn "Ubuntu ${VERSION_ID:-unknown} is not a supported release (supported: 22.04, 24.04, 26.04)"
          fails=$((fails + 1))
        fi ;;
    esac
  fi

  # The firewall profile is intentionally IPv4-only -- refuse public IPv6.
  if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    warn 'Global IPv6 address detected; disable IPv6 or add matching IPv6 protections first'
    fails=$((fails + 1))
  else
    ok 'No global IPv6 address'
  fi

  # systemd -- the OpenNHP services are managed through it.
  if [[ -d /run/systemd/system ]]; then
    ok 'systemd is available'
  else
    warn 'systemd was not detected; the OpenNHP services require it'
    fails=$((fails + 1))
  fi

  # Soft checks -- resources and connectivity only warn.
  if [[ ${mem_kib:-0} -gt 0 && ${mem_kib:-0} -lt 1048576 ]]; then
    warn "Memory ${mem_gib} GiB is below the 1 GiB recommended for the build"
  fi
  if [[ $disk_avail != '?' && $disk_avail -lt 5 ]]; then
    warn "Free disk ${disk_avail} GiB on $target is below the 5 GiB the build needs"
  fi
  if timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/443' 2>/dev/null; then
    ok 'Outbound HTTPS to github.com is reachable'
  else
    warn 'Could not reach github.com:443; the installer needs outbound HTTPS'
  fi

  if [[ $fails -gt 0 ]]; then
    printf '\n'
    die "$fails compatibility check(s) failed. Resolve the items marked ! above. A version mismatch can be overridden with ALLOW_UNSUPPORTED_UBUNTU=1."
  fi
  ok 'All required checks passed'
}
trap 'warn "Installer exited at line $LINENO. Re-run it to resume; existing keys remain unchanged."' ERR

[[ -t 0 && -e /dev/tty ]] || die 'Run interactively from an SSH terminal: sudo bash opennhp-ubuntu-installer.sh'
[[ $EUID == 0 ]] || die 'Run with sudo: sudo bash opennhp-ubuntu-installer.sh'
source /etc/os-release

# Honor OPENNHP_REF and PROTECTED_PORTS from the command line. A value saved
# by a previous run is only the default, so a re-run still asks. Read them
# before an uninstall deletes installer.env.
PRESET_REF=${OPENNHP_REF-}
PRESET_PORTS=${PROTECTED_PORTS-}
PRESET_KNOCK=${KNOCK_PORT-}
PREV_OTP=1
PREV_DEMO=1
PREV_PORTS=80
PREV_KNOCK=62206
script_version=$INSTALLER_VERSION
if [[ -f $STATE ]]; then
  source "$STATE"
  PREV_OTP=${ENABLE_OTP:-1}
  PREV_DEMO=${INSTALL_DEMO:-1}
  PREV_PORTS=${PROTECTED_PORTS:-80}
  PREV_KNOCK=${KNOCK_PORT:-62206}
fi
# PROTECTED_PORTS is chosen below; the saved value is only the default.
PROTECTED_PORTS=''
# installer.env records the version that wrote it. Keep this script's version.
INSTALLER_VERSION=$script_version

# The knock port is not hard-coded. Take it from the server's own config when
# one is already installed, else a saved value, else the default; KNOCK_PORT in
# the environment overrides. It feeds the server config and the reserved set,
# so a protected port can never collide with the port knocks arrive on.
KNOCK_PORT=$PREV_KNOCK
if [[ -f "$SERVER/etc/config.toml" ]]; then
  cfg_knock=$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' "$SERVER/etc/config.toml" | head -n1)
  [[ -n ${cfg_knock:-} ]] && KNOCK_PORT=$cfg_knock
fi
[[ -n $PRESET_KNOCK ]] && KNOCK_PORT=$PRESET_KNOCK
if ! [[ $KNOCK_PORT =~ ^[0-9]+$ ]] || (( KNOCK_PORT < 1 || KNOCK_PORT > 65535 )); then
  die "KNOCK_PORT must be a port number between 1 and 65535 (got '${KNOCK_PORT}')."
fi
# SSH and the knock port must never be placed behind NHP.
RESERVED_PORTS="22 $KNOCK_PORT"

header 'OpenNHP Installer For Ubuntu' "v${INSTALLER_VERSION}"
preflight
printf '\n'

if opennhp_configured; then
  say 'This host already has OpenNHP'
  info '1  Install or update, and keep existing keys'
  info '2  Uninstall OpenNHP so you can start over'
  while true; do
    choice=$(ask 'Choose 1 or 2 [1]: ')
    choice=${choice:-1}
    case $choice in
      1) break ;;
      2)
        info 'This stops OpenNHP, deletes /opt/opennhp, and removes the NHP port guard.'
        info 'Private keys and trusted devices are deleted. This cannot be undone.'
        info 'NGINX, Go, and other firewall rules, including SSH, stay in place.'
        confirm 'Uninstall OpenNHP on this host?' || exit 0
        uninstall_opennhp
        confirm 'Install OpenNHP from scratch now?' || exit 0
        break
        ;;
      *) warn 'Enter 1 to keep this install, or 2 to remove it.' ;;
    esac
  done
else
  confirm 'Install OpenNHP on this host?' || exit 0
fi

say 'Demo website'
info 'NGINX serves a sample page on TCP 80. It replaces /var/www/html/index.html.'
info 'Skip it when this host already serves its own site; TCP 80 can still be guarded.'
if prompt_bool 'Install the demo website' "$PREV_DEMO"; then
  INSTALL_DEMO=1
  ok 'Demo website will be installed'
else
  INSTALL_DEMO=0
  ok 'Demo website will be skipped'
fi

say 'One-time registration'
info 'Lets a device request a 6-digit code and register its own key.'
info 'Until email is configured, the code is written to the server log.'
if prompt_bool 'Enable one-time registration' "$PREV_OTP"; then
  ENABLE_OTP=1
  ok 'One-time registration will be enabled'
else
  ENABLE_OTP=0
  ok 'One-time registration will be left off'
fi

say 'Protected ports'
info 'OpenNHP guards one or more TCP ports; new connections drop until a knock opens them.'
info "SSH (22) and the knock port (${KNOCK_PORT}) are never guarded. The default is TCP 80."
info 'Re-running the installer can change this set without touching keys or trusted agents.'
if [[ -n $PRESET_PORTS ]]; then
  if PROTECTED_PORTS=$(normalize_ports "$PRESET_PORTS"); then
    ok "Using PROTECTED_PORTS=$PROTECTED_PORTS from the environment"
  else
    die "Invalid PROTECTED_PORTS=$PRESET_PORTS"
  fi
else
  choose_ports "$PREV_PORTS"
fi
# The demo website binds TCP 80, so keep 80 guarded whenever it is installed.
if [[ $INSTALL_DEMO == 1 ]] && ! ports_include 80 "$PROTECTED_PORTS"; then
  PROTECTED_PORTS="80,$PROTECTED_PORTS"
  info 'Added TCP 80 to the protected set because the demo website is installed.'
fi
ok "Protecting TCP ${PROTECTED_PORTS}"

mkdir -p "$ROOT" "$SECRETS"
chmod 700 "$ROOT" "$SECRETS"

say 'Packages'
export DEBIAN_FRONTEND=noninteractive
pkgs=(git curl ca-certificates make gcc build-essential iptables ipset python3 openssl)
[[ $INSTALL_DEMO == 1 ]] && pkgs+=(nginx)
missing=()
for p in "${pkgs[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p"); done
if ((${#missing[@]})); then
  info "Installing ${missing[*]}"
  run_quiet 'Package update' apt-get update -qq
  run_quiet 'Package install' apt-get install -y -qq "${missing[@]}"
fi
ok 'Packages ready'

say 'Go'
if [[ -x /usr/local/go/bin/go ]] && /usr/local/go/bin/go version | grep -q "go${GO_VERSION}"; then
  ok "Go ${GO_VERSION} already installed"
else
  info "Downloading Go ${GO_VERSION}"
  tmp=$(mktemp -d)
  run_quiet "Go ${GO_VERSION} download" curl -fL --retry 3 --silent --show-error "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "$tmp/go.tar.gz"
  run_quiet "Go ${GO_VERSION} archive" tar -tzf "$tmp/go.tar.gz"
  rm -rf /usr/local/go
  run_quiet "Go ${GO_VERSION} install" tar -C /usr/local -xzf "$tmp/go.tar.gz"
  rm -rf "$tmp"
  ok "Go ${GO_VERSION} installed"
fi
export PATH=/usr/local/go/bin:$PATH

say 'Release'
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$ROOT"
  info 'Cloning OpenNHP'
  run_quiet 'Clone OpenNHP' git clone --quiet https://github.com/OpenNHP/opennhp.git "$SRC"
fi
cd "$SRC"
restore_plugin_source
run_quiet 'Fetch OpenNHP tags' git fetch --tags --quiet origin
mapfile -t release_tags < <(git tag -l 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 10 || true)
((${#release_tags[@]})) || die 'No OpenNHP release tags were found. Check network access to github.com.'
release_refs=("${release_tags[@]}")
if [[ -n $PRESET_REF ]]; then
  OPENNHP_REF=$PRESET_REF
  ok "Using OPENNHP_REF=$OPENNHP_REF from the environment"
else
  info "1  ${release_tags[0]}  (latest)"
  for i in "${!release_tags[@]}"; do
    (( i == 0 )) && continue
    info "$((i+1))  ${release_tags[$i]}"
  done
  info 'Releases before v1.0.0 use an older configuration layout.'
  default_choice=1
  if [[ -n ${OPENNHP_REF:-} ]]; then
    for i in "${!release_refs[@]}"; do
      if [[ ${release_refs[$i]} == "$OPENNHP_REF" ]]; then default_choice=$((i+1)); break; fi
    done
  fi
  while true; do
    choice=$(ask "Select a release [${default_choice}]: ")
    choice=${choice:-$default_choice}
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#release_refs[@]} )); then
      break
    fi
    warn "Enter a number from 1 to ${#release_refs[@]}."
  done
  OPENNHP_REF=${release_refs[$((choice-1))]}
fi
git rev-parse --verify --quiet "${OPENNHP_REF}^{commit}" >/dev/null || die "Unknown OpenNHP revision: $OPENNHP_REF"
target_commit=$(git rev-parse "${OPENNHP_REF}^{commit}")
if [[ $(git rev-parse HEAD) != "$target_commit" ]]; then
  git diff --quiet && git diff --cached --quiet || die 'Existing source has local changes. Not overwriting.'
  git checkout --quiet --detach "$OPENNHP_REF"
fi
ok "OpenNHP $OPENNHP_REF ($(git rev-parse --short HEAD))"

say 'Build'
# Upstream imports the KBS package on startup even for keygen; it creates this path.
mkdir -p /opt/confidential-containers/kbs/repository
chmod 700 /opt/confidential-containers/kbs/repository
head_now=$(git rev-parse HEAD)
rebuild=0
[[ ${BUILT_COMMIT:-} == "$head_now" ]] || rebuild=1
otp_changed=0
[[ ${PREV_OTP} == "$ENABLE_OTP" ]] || otp_changed=1
if [[ $rebuild == 1 ]]; then
  info 'Compiling. The first build can take a few minutes.'
elif [[ $otp_changed == 1 ]]; then
  info 'Rebuilding the example plugin for the registration choice.'
fi
for spec in 'serverd:release/nhp-server/nhp-serverd' 'acd:release/nhp-ac/nhp-acd' 'agentd:release/nhp-agent/nhp-agentd'; do
  target=${spec%%:*}; bin=${spec#*:}
  if [[ $rebuild == 0 && -x "$SRC/$bin" ]]; then
    ok "$target already built"
  else
    run_quiet "Build $target" make "$target"
    ok "$target built"
  fi
done
# The example plugin always exports registration handlers. Turning codes
# off makes those handlers return an error instead of issuing a code.
if [[ $ENABLE_OTP == 0 ]]; then
  disable_plugin_otp
fi
if [[ $rebuild == 0 && $otp_changed == 0 && -f "$SERVER/plugins/example/example.so" ]]; then
  ok 'Example plugin already built'
else
  run_quiet 'Build example plugin' make -C examples/server_plugin/basic
  ok 'Example plugin built'
fi
[[ -x "$SERVER/nhp-serverd" && -x "$AC/nhp-acd" && -x "$AGENT/nhp-agentd" && -f "$SERVER/plugins/example/example.so" ]] || die 'Missing required build output'
BUILT_COMMIT=$head_now
save_state

say 'Keys'
# nhp-serverd imports packages that write to stdout during startup, including
# the default logger (no log directory means stdout) and a short token ahead
# of the key JSON. json.load() then fails with "Extra data" at column 5.
# Pull the object out of that stream instead of requiring a pure document.
keypair(){
 local label=$1 binary=$2 file="$SECRETS/$1.json" scratch errf clean parser attempt
 if [[ -s $file ]]; then ok "Preserved $label identity"; return; fi
 parser=$(mktemp "$SECRETS/.parse.XXXXXX")
 cat >"$parser" <<'PY'
import json, sys, base64
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec = json.JSONDecoder()
obj = None
i = 0
n = len(raw)
while i < n:
    while i < n and raw[i].isspace():
        i += 1
    if i >= n:
        break
    try:
        val, end = dec.raw_decode(raw, i)
    except json.JSONDecodeError:
        i += 1
        continue
    if isinstance(val, dict) and "privateKey" in val and "publicKey" in val:
        obj = val
        break
    i = end
if obj is None:
    raise SystemExit(1)
for k in ("privateKey", "publicKey"):
    try:
        decoded = base64.b64decode(obj[k], validate=True)
    except Exception:
        raise SystemExit(1)
    if len(decoded) != 32:
        raise SystemExit(1)
json.dump({"privateKey": obj["privateKey"], "publicKey": obj["publicKey"]}, sys.stdout)
sys.stdout.write("\n")
PY
 chmod 700 "$parser"
 for attempt in 1 2 3; do
  scratch=$(mktemp "$SECRETS/.key.XXXXXX")
  errf=$(mktemp "$SECRETS/.keyerr.XXXXXX")
  clean=$(mktemp "$SECRETS/.key.XXXXXX")
  if ! "$binary" keygen --curve --json >"$scratch" 2>"$errf"; then
   cat "$errf" >&2 || true
   rm -f "$scratch" "$errf" "$clean" "$parser"
   die "$label key generation failed"
  fi
  if python3 "$parser" "$scratch" >"$clean"; then
   mv "$clean" "$file"
   chmod 600 "$file"
   rm -f "$scratch" "$errf" "$parser"
   ok "Generated $label Curve25519 identity"
   return
  fi
  warn "Could not read $label key from keygen output (attempt $attempt of 3)"
  rm -f "$scratch" "$errf" "$clean"
 done
 rm -f "$parser"
 die "Could not read a Curve25519 key from $label keygen output"
}
keypair server "$SERVER/nhp-serverd"
keypair ac "$AC/nhp-acd"
server_pub=$(json_field "$SECRETS/server.json" publicKey)
server_priv=$(json_field "$SECRETS/server.json" privateKey)
ac_pub=$(json_field "$SECRETS/ac.json" publicKey)
ac_priv=$(json_field "$SECRETS/ac.json" privateKey)

say 'Agent'
if [[ -n ${AGENT_PUB:-} ]]; then
  ok 'An agent public key is already saved'
  kv 'Agent key' "$AGENT_PUB"
  if confirm 'Replace that agent key?'; then
    unset AGENT_PUB
    rm -f "$SECRETS/agent.json"
  fi
fi
if [[ -z ${AGENT_PUB:-} ]]; then
  info '1  Generate an agent key pair on this server'
  info '2  Paste the public key of an existing agent'
  choice=$(ask 'Select 1 or 2 [1]: ')
  if [[ $choice == 2 ]]; then
    AGENT_PUB=$(ask 'Paste the agent public key: ')
  else
    keypair agent "$AGENT/nhp-agentd"
    AGENT_PUB=$(json_field "$SECRETS/agent.json" publicKey)
  fi
fi
python3 -c 'import sys,base64
try:
    b=base64.b64decode(sys.argv[1],validate=True)
except Exception:
    raise SystemExit("Invalid base64 agent public key")
if len(b)!=32:
    raise SystemExit("Expected 32-byte Curve25519 agent public key")' "$AGENT_PUB"
save_state
say 'Public keys'
kv 'Server' "$server_pub"
kv 'Access controller' "$ac_pub"
kv 'Agent' "$AGENT_PUB"
info 'These public keys are safe to copy into a client.'
if [[ -f "$SECRETS/agent.json" ]]; then
  warn "The agent private key is in $SECRETS/agent.json. Do not publish it."
fi
pause 'Press Enter to continue...'

say 'Address'
private_ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1);exit}}')
[[ $private_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Could not determine private IPv4'
public_ip=${PUBLIC_IP:-}
if [[ -z $public_ip ]]; then
  public_ip=$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)
fi
kv 'Private address' "$private_ip"
kv 'Public address' "${public_ip:-unknown}"
entered=$(ask "Public address clients should use [${public_ip}]: ")
public_ip=${entered:-$public_ip}
[[ -n $public_ip && $public_ip =~ ^[a-zA-Z0-9.-]+$ ]] || die 'Enter a valid IPv4 or DNS hostname (no URL scheme).'

# Files are overwritten intentionally on reruns, keys are not.
mkdir -p "$SERVER/etc" "$AC/etc" "$SERVER/plugins/example/etc" "$AGENT/etc"
cat > "$SERVER/etc/config.toml" <<EOF
PrivateKeyBase64 = "$server_priv"
DefaultCipherScheme = 0
ListenIp = "0.0.0.0"
ListenPort = $KNOCK_PORT
Hostname = "$public_ip"
LogLevel = 4
DisableAgentValidation = false
AllowPrivateRelaySource = false
ForceOverload = false
[Metrics]
Enabled = false
EOF
agent_writer=$(mktemp "$ROOT/.agents.XXXXXX")
cat >"$agent_writer" <<'PY'
import json, os, sys, base64
path, agent_pub, ttl, registry_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

def decode(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise SystemExit(f'Invalid agent public key: {exc}')
    if len(raw) != 32:
        raise SystemExit('Expected a 32-byte Curve25519 agent public key')
    return raw

def load_toml_keys(agent_path):
    if not os.path.isfile(agent_path) or os.path.getsize(agent_path) == 0:
        return []
    import tomllib
    with open(agent_path, 'rb') as handle:
        data = tomllib.load(handle)
    found = []
    for row in data.get('Agents') or []:
        pub = row.get('PubKeyBase64') or ''
        if pub:
            found.append(pub)
    return found

def load_registry(registry):
    if not os.path.isfile(registry):
        return []
    with open(registry, encoding='utf-8') as handle:
        data = json.load(handle)
    return data.get('clients') or []

by_key = {}
order = []

def add(pub, name=''):
    raw = decode(pub)
    current = by_key.get(raw)
    if current:
        if name and not current['name']:
            current['name'] = name
        return
    by_key[raw] = {'publicKey': pub.strip(), 'name': name}
    order.append(raw)

for row in load_registry(registry_path):
    if row.get('publicKey'):
        add(row['publicKey'], row.get('name') or '')
for pub in load_toml_keys(path):
    add(pub)
add(agent_pub)

lines = []
named = []
for raw in order:
    entry = by_key[raw]
    if entry['name']:
        lines.append(f"# {entry['name']}")
        named.append({'name': entry['name'], 'publicKey': entry['publicKey']})
    lines.append('[[Agents]]')
    lines.append('PubKeyBase64 = "%s"' % entry['publicKey'])
    lines.append(f'ExpireTime = {ttl}')
    lines.append('')
text = '\n'.join(lines)
if os.path.exists(path):
    with open(path, 'r+', encoding='utf-8') as handle:
        handle.seek(0)
        handle.write(text)
        handle.truncate()
else:
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)
os.chmod(path, 0o600)
if named or os.path.isfile(registry_path):
    temporary = registry_path + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as handle:
        json.dump({'clients': named}, handle, indent=2)
        handle.write('\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, registry_path)
PY
python3 "$agent_writer" "$SERVER/etc/agent.toml" "$AGENT_PUB" "$TTL" "$ROOT/clients.json"
rm -f "$agent_writer"
cat > "$SERVER/etc/ac.toml" <<EOF
[[ACs]]
PubKeyBase64 = "$ac_pub"
ExpireTime = $TTL
EOF
cat > "$SERVER/etc/resource.toml" <<'EOF'
["example"]
PluginPath = "example/example.so"
EOF
cat > "$SERVER/etc/http.toml" <<'EOF'
EnableHttp = false
EnableTLS = false
HttpListenIp = "127.0.0.1"
HttpListenPort = 443
TLSCertFile = "cert/cert.pem"
TLSKeyFile = "cert/cert.key"
EOF
# One backend per protected port, all under the "web" resource, so a single
# knock opens every port the operator chose.
web_backends=''
IFS=, read -ra _ports <<< "$PROTECTED_PORTS"
for _p in "${_ports[@]}"; do
  web_backends+="[\"web\".Resources.\"web${_p}\"]"$'\n'
  web_backends+="ACId = \"nhp-ac\""$'\n'
  web_backends+="Hostname = \"${public_ip}\""$'\n'
  web_backends+="Addr.Ip = \"${private_ip}\""$'\n'
  web_backends+="Addr.Port = ${_p}"$'\n'
  web_backends+="Addr.Protocol = \"tcp\""$'\n'
  web_backends+="PortSuffix = false"$'\n'
done
cat > "$SERVER/plugins/example/etc/resource.toml" <<EOF
["web"]
SkipAuth = true
OpenTime = 60
RedirectUrl = ""
RedirectWithParams = false
CookieDomain = ""
${web_backends}["web".ExInfo]
Title = "OpenNHP"
EOF
cat > "$SERVER/plugins/example/etc/config.toml" <<'EOF'
ExampleUsername = "unused"
ExamplePassword = "unused"
require_email_match = true
EOF
cat > "$AC/etc/config.toml" <<EOF
ACId = "nhp-ac"
DefaultIp = "$private_ip"
PrivateKeyBase64 = "$ac_priv"
DefaultCipherScheme = 0
IpPassMode = 0
LogLevel = 4
AuthServiceId = "example"
ResourceIds = ["web"]
FilterMode = 0
[Metrics]
Enabled = false
EOF
cat > "$AC/etc/server.toml" <<EOF
[[Servers]]
PubKeyBase64 = "$server_pub"
ExpireTime = $TTL
[[Servers.Instances]]
Ip = "$private_ip"
Port = $KNOCK_PORT
EOF
chmod 600 "$SERVER/etc/config.toml" "$AC/etc/config.toml"
# The upstream AC build ships etc/remote.toml aimed at a lab etcd
# (172.16.3.53:2379). If that file is present, nhp-acd ignores the local
# TOML, waits for etcd, and exits with "context deadline exceeded".
rm -f "$AC/etc/remote.toml" "$SERVER/etc/remote.toml" "$AGENT/etc/remote.toml"

if [[ -f "$SECRETS/agent.json" && "$AGENT_PUB" == "$(json_field "$SECRETS/agent.json" publicKey)" ]]; then
  agent_priv=$(json_field "$SECRETS/agent.json" privateKey)
  cat > "$AGENT/etc/config.toml" <<EOF
PrivateKeyBase64 = "$agent_priv"
DefaultCipherScheme = 0
UserId = "nhp-agent"
OrganizationId = "opennhp"
LogLevel = 4
EOF
  cat > "$AGENT/etc/server.toml" <<EOF
[[Servers]]
Name = "opennhp"
PubKeyBase64 = "$server_pub"
ExpireTime = $TTL
[[Servers.Instances]]
Ip = "$private_ip"
Port = $KNOCK_PORT
EOF
  cat > "$AGENT/etc/resource.toml" <<'EOF'
[[Resources]]
AuthServiceId = "example"
ResourceId = "web"
Cluster = "opennhp"
EOF
  chmod 600 "$AGENT/etc/config.toml"
fi
ok 'Configuration written'

say 'Services'
if [[ $INSTALL_DEMO == 1 ]]; then
  mkdir -p /var/www/html
  cat > /var/www/html/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>OpenNHP</title></head>
<body><h1>OpenNHP access granted</h1><p>Protected website reached after knock.</p></body></html>
EOF
  # umask 077 would leave this tree root-only. nginx runs as www-data.
  chmod 755 /var/www /var/www/html
  chmod 644 /var/www/html/index.html
fi

# These two units start natively. Firewall is separately and intentionally gated.
cat > /etc/systemd/system/nhp-server.service <<EOF
[Unit]
Description=OpenNHP server
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$SERVER
ExecStart=$SERVER/nhp-serverd run
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/nhp-ac.service <<EOF
[Unit]
Description=OpenNHP access controller
Wants=network-online.target nhp-server.service
After=network-online.target nhp-server.service nhp-firewall.service
Requires=nhp-firewall.service
[Service]
Type=simple
User=root
WorkingDirectory=$AC
ExecStart=$AC/nhp-acd run
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# Explicitly protect the website only; do not flush AWS/OS firewall policies.
# NHP AC's mode-0 source/destination/port matching uses these exact named sets.
cat > /usr/local/sbin/nhp-firewall-rules <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
# The TCP ports this host places behind a knock, as a multiport list.
PORTS="${PROTECTED_PORTS}"
# Remove every INPUT jump into the OPENNHP chain, whatever ports it covers
# (including a previous port set). start and stop both call this so the rules
# always reconcile to the current PORTS -- ports no longer protected are dropped.
drop_jumps(){
  iptables -S INPUT 2>/dev/null | awk '/-j OPENNHP\$/{\$1="-D"; print}' | while read -r spec; do
    iptables \$spec 2>/dev/null || true
  done
}
case "\${1:-}" in
 start)
  ipset create defaultset hash:ip,port,ip timeout 120 -exist
  ipset create defaultset_down hash:ip,port,ip timeout 121 -exist
  ipset create tempset hash:net,port timeout 5 -exist
  iptables -N OPENNHP 2>/dev/null || true
  iptables -F OPENNHP
  iptables -A OPENNHP -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OPENNHP -m set --match-set defaultset src,dst,dst -j ACCEPT
  iptables -A OPENNHP -m set --match-set tempset src,dst -j ACCEPT
  iptables -A OPENNHP -j DROP
  drop_jumps
  iptables -I INPUT 1 -p tcp -m multiport --dports "\$PORTS" -j OPENNHP
  ;;
 stop)
  drop_jumps
  iptables -F OPENNHP 2>/dev/null || true
  iptables -X OPENNHP 2>/dev/null || true
  ;;
 *) echo 'usage: nhp-firewall-rules start|stop' >&2; exit 2;;
esac
EOF
chmod 700 /usr/local/sbin/nhp-firewall-rules
cat > /etc/systemd/system/nhp-firewall.service <<'EOF'
[Unit]
Description=OpenNHP HTTP firewall
Before=nhp-ac.service nginx.service
After=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nhp-firewall-rules start
ExecStop=/usr/local/sbin/nhp-firewall-rules stop
[Install]
WantedBy=multi-user.target
EOF
if [[ $INSTALL_DEMO == 1 ]]; then
  mkdir -p /etc/systemd/system/nginx.service.d
  cat > /etc/systemd/system/nginx.service.d/nhp.conf <<'EOF'
[Unit]
After=nhp-firewall.service
EOF
fi
systemctl daemon-reload
systemctl enable nhp-firewall.service nhp-server.service nhp-ac.service >/dev/null
if [[ $INSTALL_DEMO == 1 ]]; then
  systemctl enable nginx >/dev/null
  systemctl restart nginx
  ok 'Demo website installed'
else
  ok 'Demo website skipped'
fi
# Do not start AC until the firewall is in place, and ensure errors are visible.
systemctl restart nhp-server.service
systemctl is-active --quiet nhp-server.service || die 'NHP server did not start. See journalctl -u nhp-server -n 80'
ok 'OpenNHP server is running'

say 'Firewall'
info "Only new connections to TCP ${PROTECTED_PORTS} are guarded. SSH and UDP ${KNOCK_PORT} are left as they are."
info 'Existing firewall rules are not flushed.'
info 'If you turn this on, it rolls back in 180 seconds unless you confirm SSH still works.'
if confirm "Protect TCP ${PROTECTED_PORTS} and start the access controller now?"; then
  # A temporary systemd timer removes the guarded rules if the SSH session drops.
  systemd-run --unit=nhp-rollback --on-active=180s /usr/local/sbin/nhp-firewall-rules stop >/dev/null
  systemctl restart nhp-firewall.service
  if ! systemctl restart nhp-ac.service; then
    systemctl stop nhp-firewall.service || true
    die "NHP AC failed; TCP ${PROTECTED_PORTS} firewall rolled back. Check journalctl -u nhp-ac -n 100."
  fi
  systemctl is-active --quiet nhp-ac.service || die 'NHP AC is not running.'
  warn "TCP ${PROTECTED_PORTS} is protected. The rules come off in 180 seconds unless you keep them."
  for unit in nhp-server nhp-ac nhp-firewall; do
    if systemctl is-active --quiet "$unit"; then
      ok "$unit is running"
    else
      warn "$unit is not running"
    fi
  done
  printf '\n'
  pause 'Press Enter after you confirm this SSH session still works...'
  if confirm "Keep TCP ${PROTECTED_PORTS} protected on boot?"; then
    systemctl stop nhp-rollback.timer 2>/dev/null || true
    systemctl reset-failed nhp-rollback.service 2>/dev/null || true
    ok "TCP ${PROTECTED_PORTS} stays protected across reboots"
  else
    systemctl stop nhp-ac.service nhp-firewall.service || true
    systemctl stop nhp-rollback.timer 2>/dev/null || true
    systemctl disable nhp-ac.service nhp-firewall.service || true
    warn "TCP ${PROTECTED_PORTS} is open again, including after a reboot."
  fi
else
  systemctl disable nhp-ac.service nhp-firewall.service || true
  warn "TCP ${PROTECTED_PORTS} was left open."
fi

header 'Installation summary'
kv 'Installer' "$INSTALLER_VERSION"
kv 'OpenNHP' "$OPENNHP_REF ($(git -C "$SRC" rev-parse --short HEAD))"
kv 'Server key' "$server_pub"
kv 'AC key' "$ac_pub"
kv 'Agent key' "$AGENT_PUB"
if [[ $INSTALL_DEMO == 1 ]]; then
  kv 'Demo site' "http://$public_ip/"
else
  kv 'Demo site' 'not installed'
fi
kv 'Knock' "$public_ip UDP ${KNOCK_PORT}"
kv 'Resource' 'example / web'
kv 'Protected ports' "tcp ${PROTECTED_PORTS}"
kv 'Open time' '60 seconds for new TCP connections'
if [[ $ENABLE_OTP == 1 ]]; then
  kv 'Registration' 'one-time codes, written to the server log'
else
  kv 'Registration' 'off'
fi
kv 'Secrets' "$SECRETS"
info "Allow UDP ${KNOCK_PORT} and TCP ${PROTECTED_PORTS} from clients. Limit SSH to your IP."
info 'Copy the server public key into the client. Leave private keys on this host.'
if [[ $ENABLE_OTP == 1 ]]; then
  info "Codes are logged in $SERVER/logs/server-YYYY-MM-DD.log as OTP CODE."
fi
info 'Test from a phone on another network. A client on this host is not a public-path test.'
ok 'Finished'

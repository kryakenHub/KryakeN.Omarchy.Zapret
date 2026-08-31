#!/bin/sh
# kryaken.omarchy.zapret backend: manage the zapret DPI-evasion daemon via systemd.
#
# Environment:
#   ZAPRET_SERVICE      systemd unit controlling zapret (default: zapret)
#   ZAPRET_CONFIG       force the live config path (default: auto-detect)
#   ZAPRET_CONFIGS_DIR  profile store (default: /opt/zapret/configs)
#   ZAPRET_PRIV         pkexec | sudo (default: sudo when run from a TTY,
#                       otherwise pkexec - i.e. when launched from the shell panel)
#   ZAPRET_FAKE_ROOT    skip self-elevation + run fs ops as the calling user
#                       (testing/containers)
#
# Config profiles: every profile is a complete zapret `config` file stored as
# <name>.config in /opt/zapret/configs (the profile store). zapret itself only
# ever reads /opt/zapret/config, so the single active profile is symlinked
# over that path; switching profiles just re-points the symlink and restarts
# the unit. Adding a profile copies the file into the store; the first added
# profile is activated automatically. A still-plain live config is preserved as
# the "default" profile only when it is about to be replaced (select/migrate),
# so the stock setup stays recoverable. On the first `serve` session with an
# empty store, a default profile is provisioned automatically: the existing
# live config is adopted if there is one, otherwise the bundled stock config
# (default.config next to this script, overridable with $ZAPRET_DEFAULT_CONFIG)
# is deployed.
#
# Commands:
#   status [unit]  JSON: installed/active/enabled/config/strategy/profile/profiles
#   installed      "yes"/"no"
#   start|stop|restart|toggle
#   enable|disable (autostart)
#   configs {list|add [<name>] <path-to-config>|select <name>|remove <name>|migrate}
#   logs [n]       last n journal lines (default 40)
set -u

SERVICE="${ZAPRET_SERVICE:-zapret}"
CONFIG="${ZAPRET_CONFIG:-}"
# Profile store lives next to the zapret install (/opt/zapret/configs):
# every profile is a <name>.config file here, and the single active one is
# symlinked over /opt/zapret/config (what zapret.service actually sources).
CONFIGS_DIR="${ZAPRET_CONFIGS_DIR:-/opt/zapret/configs}"
CONFIGS_PROFILES="$CONFIGS_DIR"
CONFIGS_ACTIVE="$CONFIGS_DIR/.active"
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
DEFAULT_BUNDLE="${ZAPRET_DEFAULT_CONFIG:-$SCRIPT_DIR/default.config}"

# Privilege wrapper: skip it when we are already root (pkexec launched us);
# otherwise prefer sudo from a TTY, pkexec from the shell panel.
if [ "$(id -u)" = 0 ]; then
  run() { systemctl "$@"; }
elif [ -t 0 ]; then
  run() { "${ZAPRET_PRIV:-sudo}" systemctl "$@"; }
else
  run() { "${ZAPRET_PRIV:-pkexec}" systemctl "$@"; }
fi

# Testing/container hook: treat elevated operations as allowed and let the fs
# code run over the directories given by the env vars (no real privileges).
am_root() { [ "$(id -u)" = 0 ] || [ "${ZAPRET_FAKE_ROOT:-}" = 1 ]; }

CONFIG_CANDIDATES="/etc/zapret/config /usr/local/etc/zapret/config /opt/zapret/config"

# The exact config path the zapret.service on this machine actually sources.
# Derived from the unit's ExecStart (a `{ path=...; argv[]=... }` property whose
# `path` points at <base>/init.d/sysv/zapret, which sources <base>/config).
configs_install_config() {
  [ -n "$CONFIG" ] && { printf '%s\n' "$CONFIG"; return 0; }
  local es path base
  es=$(command -v systemctl >/dev/null 2>&1 && systemctl show "$SERVICE" -p ExecStart --value 2>/dev/null || true)
  case "$es" in
    *path=*)
      path=${es#*path=}
      path=${path%% *}
      case "$path" in
        *init.d/sysv/zapret)
          base=$(dirname "$(dirname "$(dirname "$path")")" 2>/dev/null)
          [ -n "$base" ] && { printf '%s\n' "$base/config"; return 0; }
          ;;
      esac
      ;;
  esac
  for p in $CONFIG_CANDIDATES; do
    if [ -d "$(dirname "$p")" ]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

sysctl() {
  command -v systemctl >/dev/null 2>&1 || return 2
  systemctl "$@" 2>/dev/null
}

unit_known() {
  sysctl list-unit-files --no-legend "${SERVICE}*" 2>/dev/null | grep -q . || {
    # Transient: systemd can briefly report an empty list right after the
    # shell starts. Retry once before concluding the unit is unknown.
    sleep 1
    sysctl list-unit-files --no-legend "${SERVICE}*" 2>/dev/null | grep -q .
  }
}

unit_active() { [ "$(sysctl is-active "$SERVICE")" = "active" ]; }
unit_enabled() { [ "$(sysctl is-enabled "$SERVICE")" = "enabled" ]; }

os_is() {
  sed -n 's/^\(ID\|ID_LIKE\)=//p' /etc/os-release 2>/dev/null | tr -d '"' | tr ' ' '\n' | grep -qi "^$1$"
}

# Copy-pasteable install hint for a missing dependency.
install_hint() {
  case "${1:-}" in
    zapret)
      if command -v paru >/dev/null 2>&1; then printf '%s\n' "paru -S zapret"; return 0; fi
      if command -v yay >/dev/null 2>&1; then printf '%s\n' "yay -S zapret"; return 0; fi
      if os_is arch; then
        printf '%s\n' 'git clone https://aur.archlinux.org/zapret.git && cd zapret && makepkg -si'
        return 0
      fi
      printf '%s\n' "see https://github.com/bol-van/zapret for install instructions"
      ;;
    python)
      if os_is arch; then printf '%s\n' "sudo pacman -S python"; else printf '%s\n' "install python3 (https://www.python.org)"; fi
      ;;
    *) printf '%s\n' "" ;;
  esac
}

# Read-only dependency report (included in `status` so the panel can offer
# one-click setup against missing packages; no privilege needed).
deps_json() {
  sys_ok=false
  z_ok=false; z_h=""
  py_ok=false; py_h=""
  if command -v systemctl >/dev/null 2>&1; then
    sys_ok=true
    if unit_known; then z_ok=true; else z_h=$(install_hint zapret); fi
  else
    z_h=$(install_hint zapret)
  fi
  if command -v python3 >/dev/null 2>&1; then py_ok=true; else py_h=$(install_hint python); fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$sys_ok" "$z_ok" "$z_h" "$py_ok" "$py_h" <<'PYEOF'
import json, sys
def b(s): return s == "true"
sys_ok, z_ok, z_h, py_ok, py_h = sys.argv[1:]
deps = [
    {"n": "systemd", "ok": b(sys_ok), "h": "" if b(sys_ok) else "install systemd"},
    {"n": "zapret.service", "ok": b(z_ok), "h": z_h if not b(z_ok) else ""},
    {"n": "python3", "ok": b(py_ok), "h": py_h if not b(py_ok) else ""},
]
print(json.dumps(deps))
PYEOF
  else
    printf '[{"n":"systemd","ok":%s,"h":""},{"n":"zapret.service","ok":%s,"h":"%s"},{"n":"python3","ok":false,"h":"install python3"}]\n' \
      "$sys_ok" "$z_ok" "$(printf '%s' "$z_h" | tr -d '"')"
  fi
}

# Terminal-friendly setup validation (exit 0 when everything is in place).
doctor() {
  rc=0
  if command -v systemctl >/dev/null 2>&1; then
    if unit_known; then
      printf '%s\n' "ok     zapret.service"
    else
      printf '%s\n' "missing zapret.service — $(install_hint zapret)"
      rc=1
    fi
  else
    printf '%s\n' "missing systemd"
    rc=1
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "ok     python3"
  else
    printf '%s\n' "missing python3 — $(install_hint python)"
    rc=1
  fi
  [ "$rc" -eq 0 ] && printf '%s\n' "ok     all dependencies present"
  return "$rc"
}

# The live config path for status/reporting: the single install config path
# (from ExecStart), accepted only when actually readable. Kept in sync with
# configs_install_config so the panel reports the same path we manage (the
# service's real /opt/zapret/config), never a stale duplicate candidate.
find_config() {
  local p
  p=$(configs_install_config) || return 1
  [ -r "$p" ] || return 1
  printf '%s\n' "$p"
  return 0
}

# Where the zapret service sources its config from. A broken managed symlink
# (e.g. after the profile store was wiped) is skipped so bootstrap re-seeds it.
configs_live_path() {
  local p
  p=$(configs_install_config) || return 1
  if [ -L "$p" ]; then
    t=$(readlink -f "$p" 2>/dev/null) || return 1
    case "$t" in
      "$CONFIGS_PROFILES"*) [ -e "$t" ] || return 1 ;;
    esac
  fi
  printf '%s\n' "$p"
  return 0
}

sanitize_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

config_profiles_list() {
  [ -d "$CONFIGS_PROFILES" ] || return 0
  for f in "$CONFIGS_PROFILES"/*.config; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .config)
    sanitize_name "$n" && printf '%s\n' "$n"
  done
}

# Profile actually in effect: read through the live symlink (root not needed).
configs_active_from_live() {
  live=$(find_config 2>/dev/null) || { printf 'null'; return; }
  if [ -L "$live" ]; then
    t=$(readlink -f "$live" 2>/dev/null) || { printf 'null'; return; }
    n=$(basename "$t" .config)
    if [ -f "$t" ] && sanitize_name "$n"; then
      printf '"%s"' "$n"
      return
    fi
  fi
  printf 'null'
}

# Active marker value (the profile the store keeps applied).
configs_active_name() {
  [ -r "$CONFIGS_ACTIVE" ] || return 1
  a=$(cat "$CONFIGS_ACTIVE" 2>/dev/null) || return 1
  sanitize_name "$a" && [ -f "$CONFIGS_PROFILES/$a.config" ] || return 1
  printf '%s\n' "$a"
}

json_array() {
  data=$(cat)
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$data" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().split()))'
  else
    out=""
    sep=""
    while IFS= read -r n; do
      sanitize_name "$n" || continue
      out="$out$sep\"$n\""
      sep=","
    done <<EOF
$data
EOF
    printf '[%s]\n' "$out"
  fi
}

# Root: ensure the profile store exists, and resync the active marker when the
# live config is already a managed symlink (recover after a manual edit).
root_setup() {
  mkdir -p "$CONFIGS_DIR" "$CONFIGS_PROFILES" 2>/dev/null || return 1
  chmod 755 "$CONFIGS_DIR" 2>/dev/null
  chmod 755 "$CONFIGS_PROFILES" 2>/dev/null
  live=$(configs_live_path 2>/dev/null) || return 0
  if [ -L "$live" ] && t=$(readlink -f "$live" 2>/dev/null); then
    case "$t" in
      "$CONFIGS_PROFILES"/*)
        n=$(basename "$t" .config)
        sanitize_name "$n" && printf '%s\n' "$n" > "$CONFIGS_ACTIVE" 2>/dev/null
        chmod 644 "$CONFIGS_ACTIVE" 2>/dev/null
        ;;
    esac
  fi
  return 0
}

# Root: before an unmanaged live config (still a plain file) gets replaced by a
# profile symlink, keep its bytes as the "default" profile. No-op once the live
# config is managed. Adding a profile never triggers this — only applying one.
preserve_live() {
  live=$(configs_live_path) || return 0
  [ -f "$live" ] && [ ! -L "$live" ] || return 0
  [ -e "$CONFIGS_PROFILES/default.config" ] && return 0
  cp "$live" "$CONFIGS_PROFILES/default.config" 2>/dev/null || return 1
  chmod 644 "$CONFIGS_PROFILES/default.config" 2>/dev/null
  return 0
}

# Root: point the live config at a profile (symlink swap). No-op when the
# zapret installation is missing (config yet to be created).
deploy_live() {
  name="$1"
  live=$(configs_live_path) || return 0
  [ -r "$CONFIGS_PROFILES/$name.config" ] || return 1
  rm -f "$live" 2>/dev/null
  ln -s "$CONFIGS_PROFILES/$name.config" "$live" 2>/dev/null || return 1
  return 0
}

maybe_restart() {
  [ "$(id -u)" = 0 ] && unit_active && sysctl restart "$SERVICE" 2>/dev/null
}

# Root: full migration — preserve a plain live config as "default" and apply it.
configs_migrate() {
  root_setup || { echo "cannot initialize config store" >&2; return 1; }
  live=$(configs_live_path 2>/dev/null) || { echo ok; return 0; }
  if [ -f "$live" ] && [ ! -L "$live" ]; then
    preserve_live || { echo "migrate failed" >&2; return 1; }
    printf '%s\n' "default" > "$CONFIGS_ACTIVE" 2>/dev/null || { echo "cannot write active marker" >&2; return 1; }
    chmod 644 "$CONFIGS_ACTIVE" 2>/dev/null
    deploy_live "default" || { echo "cannot deploy config" >&2; return 1; }
    maybe_restart
  fi
  echo ok
}

# True when a zapret config actually enables a daemon (nfqws or tpws). The
# stock template the zapret package ships disables both, which makes the
# service start and exit without doing anything — not something worth adopting
# as the default profile.
daemons_enabled() {
  f="${1:-}"
  [ -f "$f" ] || return 1
  n=$(sed -n 's/^[[:space:]]*NFQWS_ENABLE=\([0-9]*\).*/\1/p' "$f" | tail -n1)
  t=$(sed -n 's/^[[:space:]]*TPWS_ENABLE=\([0-9]*\).*/\1/p' "$f" | tail -n1)
  [ "${n:-0}" = 1 ] || [ "${t:-0}" = 1 ]
}

# Root: first-use provisioning so the panel works out of the box. No-op once
# the profile store has anything in it. If zapret's live config already exists
# as a plain file and actually enables a daemon, it is adopted as the "default"
# profile (same as an explicit migrate — nothing lost, stock stays recoverable).
# A fresh/blank template (no daemon enabled) or a bare zapret install gets the
# bundled stock config (default.config next to this script), which enables
# nfqws on 80/443 out of the box. Never touches an existing setup.
bootstrap() {
  config_profiles_list | grep -q . && return 0
  root_setup || return 1
  live=""
  seeded_from_bundle=false
  if configs_live_path >/dev/null 2>&1; then live=$(configs_live_path); fi
  [ -e "${live:-/nonexistent}" ] || live=""
  if [ -n "$live" ] && [ -f "$live" ] && [ ! -L "$live" ] && daemons_enabled "$live"; then
    # Existing, working, plain-file config: adopt it untouched.
    cp "$live" "$CONFIGS_PROFILES/default.config" 2>/dev/null || return 1
  elif [ -r "$DEFAULT_BUNDLE" ]; then
    # Blank template, no custom config, or a broken managed symlink: deploy the
    # bundled working config (nfqws on 80/443) as the default profile.
    cp "$DEFAULT_BUNDLE" "$CONFIGS_PROFILES/default.config" 2>/dev/null || return 1
    seeded_from_bundle=true
  else
    return 0
  fi
  chmod 644 "$CONFIGS_PROFILES/default.config" 2>/dev/null
  printf '%s\n' "default" > "$CONFIGS_ACTIVE" 2>/dev/null || return 1
  chmod 644 "$CONFIGS_ACTIVE" 2>/dev/null
  # Point every candidate dir that is a managed profile symlink at the seeded
  # profile. This always includes the single install path (deploy_live), plus
  # heals any stale/duplicate managed link in the other candidate dirs (e.g.
  # /etc/zapret/config when the real install uses /opt/zapret/config). Plain
  # files and non-managed links are never touched.
  {
    if [ "$seeded_from_bundle" = true ]; then
      for p in $CONFIG_CANDIDATES; do
        [ -L "$p" ] || continue
        t=$(readlink "$p" 2>/dev/null) || continue
        case "$t" in
          "$CONFIGS_PROFILES"*) printf '%s\n' "$p" ;;
        esac
      done
    fi
    [ -n "$live" ] && printf '%s\n' "$live"
  } | while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -f "$p" 2>/dev/null
    mkdir -p "$(dirname "$p")" 2>/dev/null
    ln -s "$CONFIGS_PROFILES/default.config" "$p" 2>/dev/null
  done
  maybe_restart
  return 0
}

status_json() {
  deps_s=$(deps_json)
  command -v systemctl >/dev/null 2>&1 || {
    printf '{"installed":false,"active":false,"enabled":false,"config":null,"configFile":null,"strategy":null,"profile":null,"profiles":[],"deps":%s}\n' \
      "$deps_s"
    return 0
  }
  if ! unit_known; then
    printf '{"installed":false,"active":false,"enabled":false,"config":null,"configFile":null,"strategy":null,"profile":null,"profiles":[],"deps":%s}\n' \
      "$deps_s"
    return 0
  fi
  active=false
  enabled=false
  unit_active && active=true
  unit_enabled && enabled=true
  config_line="null"
  strategy="null"
  if cfg=$(find_config); then
    config_line="\"$cfg\""
    strat=$(sed -nE 's/^(MODE_(HTTP|HTTPS|QUIC)|NFQWS_OPT_[A-Z_]+).*/\1/p' "$cfg" | tr '\n' ' ' | sed 's/ $//')
    if [ -z "$strat" ]; then
      strat=$(sed -nE 's/^(TPWS_SOCKS_ENABLE|TPWS_ENABLE|NFQWS_ENABLE)=1/\1:on/p' "$cfg" | tr '\n' ' ' | sed 's/ $//')
      [ -z "$strat" ] && strat="providers off"
    fi
    if [ -n "$strat" ]; then
      strategy="\"$strat\""
    fi
  fi
  aprof=$(configs_active_from_live)
  config_file="null"
  if [ -n "$aprof" ] && [ "$aprof" != "null" ]; then
    a=$(printf '%s\n' "$aprof" | tr -d '"')
    [ -f "$CONFIGS_PROFILES/$a.config" ] && config_file="\"$CONFIGS_PROFILES/$a.config\""
  fi
  plist=$(config_profiles_list | json_array)
  printf '{"installed":true,"active":%s,"enabled":%s,"config":%s,"configFile":%s,"strategy":%s,"profile":%s,"profiles":%s,"deps":%s}\n' \
    "$active" "$enabled" "$config_line" "$config_file" "$strategy" "$aprof" "$plist" "$deps_s"
}

action() { run "$@"; }

configs_add() {
  name="${3:-}"
  src="${4:-}"
  [ -n "$src" ] || { echo "usage: $0 configs add [name] <path-to-config>" >&2; return 2; }
  [ -f "$src" ] || { echo "no such file: $src" >&2; return 1; }
  [ -s "$src" ] || { echo "empty config: $src" >&2; return 1; }
  [ -n "$name" ] || name=$(basename "$src" .config)
  sanitize_name "$name" || { echo "invalid config name: $name" >&2; return 1; }
  sh -n "$src" >/dev/null 2>&1 || { echo "syntax check failed: $src" >&2; return 1; }
  root_setup || { echo "cannot initialize config store" >&2; return 1; }
  [ -e "$CONFIGS_PROFILES/$name.config" ] && { echo "config $name already exists" >&2; return 1; }
  cp "$src" "$CONFIGS_PROFILES/$name.config" 2>/dev/null || { echo "write failed" >&2; return 1; }
  chmod 644 "$CONFIGS_PROFILES/$name.config" 2>/dev/null
  if ! configs_active_name >/dev/null 2>&1; then
    printf '%s\n' "$name" > "$CONFIGS_ACTIVE" 2>/dev/null
    chmod 644 "$CONFIGS_ACTIVE" 2>/dev/null
    deploy_live "$name" >/dev/null 2>&1
  fi
  echo "$name"
}

configs_select() {
  name="${3:-}"
  sanitize_name "$name" || { echo "invalid config name" >&2; return 1; }
  root_setup || { echo "cannot initialize config store" >&2; return 1; }
  [ -f "$CONFIGS_PROFILES/$name.config" ] || { echo "no such config: $name" >&2; return 1; }
  sh -n "$CONFIGS_PROFILES/$name.config" >/dev/null 2>&1 || { echo "syntax check failed: $name" >&2; return 1; }
  preserve_live
  printf '%s\n' "$name" > "$CONFIGS_ACTIVE" 2>/dev/null || { echo "cannot write active marker" >&2; return 1; }
  chmod 644 "$CONFIGS_ACTIVE" 2>/dev/null
  deploy_live "$name" || { echo "cannot deploy config" >&2; return 1; }
  maybe_restart
  echo ok
}

configs_remove() {
  name="${3:-}"
  sanitize_name "$name" || { echo "invalid config name" >&2; return 1; }
  [ -f "$CONFIGS_PROFILES/$name.config" ] || { echo "no such config: $name" >&2; return 1; }
  a=""
  configs_active_name >/dev/null 2>&1 && a=$(configs_active_name)
  [ "$a" = "$name" ] && { echo "cannot remove active config — select another first" >&2; return 1; }
  rm -f "$CONFIGS_PROFILES/$name.config" || { echo "remove failed" >&2; return 1; }
  echo ok
}

cmd="${1:-status}"

needs_root() {
  case "$cmd" in
    configs)
      case "${2:-list}" in
        add|select|remove|migrate)
          am_root || {
            if [ -t 0 ]; then exec "${ZAPRET_PRIV:-sudo}" "$0" "$@"; else exec "${ZAPRET_PRIV:-pkexec}" "$0" "$@"; fi
          }
          ;;
      esac
      ;;
  esac
}

usage() {
  cat <<EOF
usage: $0 {status|installed|start|stop|restart|toggle|enable|disable|doctor|logs [n]}
       $0 configs {list|add [<name>] <path-to-config>|select <name>|remove <name>|migrate}
       $0 serve
EOF
}

# Elevated, long-lived driver used by the shell panel: reads one JSON request
# per line on stdin, runs the backend CLI with the request's argv (as root,
# since pkexec launched us) and replies with one JSON line per request. Keeps
# running until stdin closes, so pkexec is only ever invoked once per session.
# On the first session it provisions a default config profile when none exists
# (see bootstrap), so the plugin works out of the box.
serve() {
  bootstrap 2>/dev/null
  command -v python3 >/dev/null 2>&1 || {
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' '{"code":1,"out":"","err":"serve requires python3"}'
    done
    return 0
  }
  exec python3 -c '
import json, os, subprocess, sys
script = sys.argv[1]
def respond(rid, code, out, err):
    sys.stdout.write(json.dumps({"id": rid, "code": code, "out": out, "err": err}, ensure_ascii=True) + "\n")
    sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    rid = None
    try:
        req = json.loads(line)
        rid = req.get("id")
        args = req.get("args")
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ValueError("args must be a list of strings")
        if args and args[0] == "serve":
            raise ValueError("serve cannot nest")
        p = subprocess.run([script] + args, capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL)
        respond(rid, p.returncode, p.stdout, p.stderr)
    except Exception as e:
        respond(rid, 1, "", "serve error: %s" % e)
' "$0"
}

needs_root "$@"

case "$cmd" in
  status) status_json ;;
  serve) serve ;;
  installed) unit_known && echo yes || echo no ;;
  start) action start "$SERVICE" ;;
  stop) action stop "$SERVICE" ;;
  restart) action restart "$SERVICE" ;;
  toggle) if unit_active; then action stop "$SERVICE"; else action start "$SERVICE"; fi ;;
  enable) action enable "$SERVICE" ;;
  disable) action disable "$SERVICE" ;;
  doctor) doctor ;;
  configs)
    sub="${2:-list}"
    case "$sub" in
      list)
        aprof=$(configs_active_from_live)
        plist=$(config_profiles_list | json_array)
        printf '{"active":%s,"profiles":%s}\n' "$aprof" "$plist"
        ;;
      add) configs_add "$@" ;;
      select) configs_select "$@" ;;
      remove) configs_remove "$@" ;;
      migrate) configs_migrate ;;
      *) echo "usage: $0 configs {list|add|select|remove|migrate}" >&2; exit 2 ;;
    esac
    ;;
  logs)
    command -v systemctl >/dev/null 2>&1 || exit 2
    n="${2:-40}"
    journalctl -u "$SERVICE" -n "$n" --no-pager 2>/dev/null | tail -n "$n" || true
    ;;
  *)
    usage
    exit 2
    ;;
esac
#!/usr/bin/env bash
# Minimal log collector with redaction + bundle
# Usage: ./collect-logs.sh                  collect, redact and bundle into logs_<UTC time>.tgz
#        ./collect-logs.sh --redact FILE...  redact text files in place with the same rules, then exit
set -euo pipefail

OS_NAME=$(uname -s)

log() { echo "[$(date +%T)] $*"; }

# --- Redaction rules
# Patterns are POSIX extended regular expressions so the same rules work with GNU sed on
# Linux and BSD sed on macOS. Neither supports \b, so the IPv6 rules match the character
# in front of the address and put it back.
REG_IP='([0-9]{1,3}\.){3}[0-9]{1,3}'
REG_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
#six or more hex pairs, so a DHCPv6 DUID, which ends in the MAC address, goes as a whole
REG_MAC='([0-9A-Fa-f]{2}[:-]){5,}[0-9A-Fa-f]{2}'
HEX_GROUP='[0-9A-Fa-f]{1,4}'
REG_IP6_FULL="${HEX_GROUP}(:${HEX_GROUP}){7}"
#a compressed address needs a hex group on at least one side of the ::, so C++ and Swift
#names like Foo::bar and runs of colons in log text are left alone
REG_IP6_SHORT="${HEX_GROUP}(:${HEX_GROUP}){0,6}::(${HEX_GROUP}(:${HEX_GROUP}){0,6})?"
REG_IP6_LEADING="::${HEX_GROUP}(:${HEX_GROUP}){0,6}"
NOT_WORD='(^|[^0-9A-Za-z:])'

# sed_escape TEXT prints TEXT with every character that means something in a regex escaped
sed_escape() { printf '%s' "$1" | LC_ALL=C sed -e 's/[][\/.^$*+?(){}|]/\\&/g'; }

# Host and user names on this machine. Anything shorter than 3 characters is skipped,
# because replacing a 2 letter name everywhere would wreck the logs.
collect_names() {
  local KIND="$1"
  if [[ "$KIND" == host ]]; then
    hostname 2>/dev/null || true
    hostname -s 2>/dev/null || true
    if [[ "$OS_NAME" == Darwin ]]; then
      scutil --get ComputerName 2>/dev/null || true
      scutil --get LocalHostName 2>/dev/null || true
    fi
  else
    local USER_NAME
    for USER_NAME in "$(id -un 2>/dev/null || true)" "${SUDO_USER:-}"; do
      [[ -z "$USER_NAME" || "$USER_NAME" == root ]] && continue
      echo "$USER_NAME"
      if [[ "$OS_NAME" == Darwin ]]; then
        id -F "$USER_NAME" 2>/dev/null || true
      elif command -v getent >/dev/null; then
        getent passwd "$USER_NAME" | cut -d: -f5 | cut -d, -f1
      fi
    done
  fi
}

# This machine's MAC addresses as 12 hex digits with no separators. Some logs print a
# MAC that way, which REG_MAC cannot catch, so the machine's own addresses are replaced by value.
collect_bare_macs() {
  if [[ "$OS_NAME" == Darwin ]]; then
    ifconfig -a 2>/dev/null | awk '$1 == "ether" { print $2 }'
  else
    cat /sys/class/net/*/address 2>/dev/null
  fi | tr -d ':' | grep -E '^[0-9A-Fa-f]{12}$' | grep -v '^000000000000$' | sort -u
}

# build_sed_script FILE writes the sed program used for every text file.
# Longer names go first so a full host name is replaced before its short form.
build_sed_script() {
  local SCRIPT_FILE="$1" NAME KIND TOKEN
  {
    echo "s/(Serial Number[^:]*: ).*/\\1<REDACTED_SERIAL>/"
    echo "s/((Hardware UUID|Provisioning UDID): ).*/\\1<REDACTED_UUID>/"
    for KIND in host user; do
      if [[ "$KIND" == host ]]; then TOKEN='<REDACTED_HOST>'; else TOKEN='<REDACTED_USER>'; fi
      collect_names "$KIND" | awk 'length($0) >= 3' | awk '{ print length($0) "\t" $0 }' \
        | sort -rn | cut -f2- | uniq | while IFS= read -r NAME; do
          echo "s/$(sed_escape "$NAME")/${TOKEN}/g"
          #lower case copy, since host names often show up in lower case in DNS and logs
          LOWER_NAME=$(printf '%s' "$NAME" | LC_ALL=C tr '[:upper:]' '[:lower:]')
          if [[ "$LOWER_NAME" != "$NAME" ]]; then
            echo "s/$(sed_escape "$LOWER_NAME")/${TOKEN}/g"
          fi
        done
    done
    collect_bare_macs | while IFS= read -r BARE_MAC; do
      echo "s/$(printf '%s' "$BARE_MAC" | LC_ALL=C tr '[:upper:]' '[:lower:]')/<REDACTED_MAC>/g"
      echo "s/$(printf '%s' "$BARE_MAC" | LC_ALL=C tr '[:lower:]' '[:upper:]')/<REDACTED_MAC>/g"
    done
    echo "s/${REG_EMAIL}/<REDACTED_EMAIL>/g"
    echo "s/${REG_MAC}/<REDACTED_MAC>/g"
    echo "s/${REG_IP}/<REDACTED_IP>/g"
    echo "s/${NOT_WORD}${REG_IP6_FULL}/\\1<REDACTED_IP6>/g"
    echo "s/${NOT_WORD}${REG_IP6_SHORT}/\\1<REDACTED_IP6>/g"
    echo "s/${NOT_WORD}${REG_IP6_LEADING}/\\1<REDACTED_IP6>/g"
  } >"$SCRIPT_FILE"
}

# LC_ALL=C makes sed work on bytes. Logs can hold bytes that are not valid UTF-8, and
# BSD sed stops with "illegal byte sequence" on those in a UTF-8 locale.
# If sed fails, set -e stops the script before anything unredacted gets bundled.
redact_file() {
  local FILE="$1"
  LC_ALL=C sed -E -f "$SED_SCRIPT" "$FILE" >"$FILE.redacting"
  cat "$FILE.redacting" >"$FILE"
  rm -f "$FILE.redacting"
}

# The sed program holds this machine's names, so it lives outside the bundle folder
SED_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/support_logs_redact.XXXXXX")
trap 'rm -f "$SED_SCRIPT"' EXIT
build_sed_script "$SED_SCRIPT"

if [[ "${1:-}" == "--redact" ]]; then
  shift
  [[ $# -ge 1 ]] || { echo "Usage: $0 --redact FILE..."; exit 2; }
  for f in "$@"; do redact_file "$f"; done
  exit 0
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,4p' "$0" | sed 's/^# //'
  exit 0
elif [[ $# -gt 0 ]]; then
  echo "Unknown argument: $1 (try --help)"
  exit 2
fi

DTS=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="logs_${DTS}"
ROOT="${TMPDIR:-/tmp}/support_logs_${DTS}"
ROOT="${ROOT//\/\//\/}"
mkdir -p "$ROOT"
trap 'rm -f "$SED_SCRIPT"; rm -rf "$ROOT"' EXIT

# --- System & network snapshots
log "Collecting system info"
{
  echo "# uname"; uname -a
  if [[ "$OS_NAME" == Darwin ]]; then
    echo -e "\n# sw_vers"; sw_vers 2>/dev/null || true
  else
    echo -e "\n# os-release"; cat /etc/os-release 2>/dev/null || true
  fi
  echo -e "\n# uptime"; uptime
  echo -e "\n# disk"; df -h
  if [[ "$OS_NAME" == Darwin ]]; then
    echo -e "\n# system_profiler SPSoftwareDataType SPHardwareDataType"
    system_profiler -detailLevel mini SPSoftwareDataType SPHardwareDataType 2>/dev/null || true
  fi
} >"$ROOT/system.txt"

log "Collecting network info"
if [[ "$OS_NAME" == Darwin ]]; then
  {
    echo "# ifconfig -a"; ifconfig -a 2>/dev/null || true
    echo -e "\n# netstat -rn (routes)"; netstat -rn 2>/dev/null || true
    echo -e "\n# scutil --dns (resolver configuration, including VPN and per-domain resolvers)"; scutil --dns 2>/dev/null || true
    echo -e "\n# scutil --proxy"; scutil --proxy 2>/dev/null || true
    echo -e "\n# networksetup -listallhardwareports"; networksetup -listallhardwareports 2>/dev/null || true
    echo -e "\n# ping 1.1.1.1"; ping -c 3 1.1.1.1 2>&1 || true
    echo -e "\n# DNS test (system resolver)"; dscacheutil -q host -a name example.com 2>&1 || true
  } >"$ROOT/network.txt"
else
  {
    echo "# ip addr"; ip addr 2>/dev/null || ifconfig -a 2>/dev/null || true
    echo -e "\n# ip route"; ip route 2>/dev/null || netstat -rn 2>/dev/null || true
    echo -e "\n# resolv.conf"; cat /etc/resolv.conf 2>/dev/null || true
    echo -e "\n# ping 1.1.1.1"; ping -c 3 1.1.1.1 2>&1 || true
    echo -e "\n# DNS test"; getent hosts example.com 2>&1 || host example.com 2>&1 || nslookup example.com 2>&1 || true
  } >"$ROOT/network.txt"
fi

# --- Logs (last 1h)
log "Collecting logs (last 1h)"
mkdir -p "$ROOT/logs"
if [[ "$OS_NAME" == Darwin ]]; then
  # /usr/bin/log by full path, because the log() function above would shadow it
  /usr/bin/log show --last 1h --style compact \
    --predicate 'messageType == error OR messageType == fault' \
    >"$ROOT/logs/unified_err_1h.txt" 2>&1 || true
  /usr/bin/log show --last 1h --style compact \
    --predicate '(subsystem BEGINSWITH "com.apple.network" OR process == "configd" OR process == "mDNSResponder") AND (messageType == error OR messageType == fault)' \
    >"$ROOT/logs/unified_network_1h.txt" 2>&1 || true
else
  if command -v journalctl >/dev/null; then
    journalctl -p err --since "1 hour ago" >"$ROOT/logs/journal_err_1h.txt" || true
    journalctl -u NetworkManager --since "1 hour ago" >"$ROOT/logs/journal_nm_1h.txt" || true
  fi
  dmesg --ctime --level=err,warn >"$ROOT/logs/dmesg_warn.txt" 2>/dev/null || true
fi

# --- Browser proxy/SSL hints (optional, best-effort)
log "Collecting curl verbose for https://example.com"
curl -vsS --max-time 15 https://example.com >/dev/null 2>"$ROOT/logs/curl_example_verbose.txt" || true

# --- Redaction
log "Redacting IPs, MACs, emails, host and user names in text files"
TEXT_FILE_COUNT=0
while IFS= read -r -d '' f; do
  redact_file "$f"
  TEXT_FILE_COUNT=$((TEXT_FILE_COUNT+1))
done < <(find "$ROOT" -type f -name '*.txt' -print0)

# --- Manifest
log "Writing manifest"
{
  echo "Collected at: ${DTS}"
  echo "Host: <REDACTED_HOST>"
  echo "Platform: ${OS_NAME} $(uname -r)"
  echo "Redacted in the text files: IPv4, IPv6, MAC and email addresses, this machine's MAC addresses in any format, host and user names, serial numbers and hardware UUIDs"
  echo "Files:"
  find "$ROOT" -type f | sort | while IFS= read -r f; do
    echo "  - ${f#"$ROOT"/} ($(wc -c <"$f" | tr -d ' ') bytes)"
  done
} >"$ROOT/MANIFEST.txt"

# --- Bundle
log "Creating bundle ${OUT}.tgz"
tar -C "$ROOT" -czf "${OUT}.tgz" .

echo "Done: $(pwd)/${OUT}.tgz (${TEXT_FILE_COUNT} text files redacted)"

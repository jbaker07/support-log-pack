#!/usr/bin/env bash
# Minimal log collector with redaction + bundle
set -euo pipefail

DTS=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="logs_${DTS}"
ROOT="${TMPDIR:-/tmp}/support_logs_${DTS}"
mkdir -p "$ROOT"

log() { echo "[$(date +%T)] $*"; }

# --- System & network snapshots
log "Collecting system info"
{
  echo "# uname"; uname -a
  echo -e "\n# os-release"; cat /etc/os-release 2>/dev/null || true
  echo -e "\n# uptime"; uptime
  echo -e "\n# disk"; df -h
} >"$ROOT/system.txt"

log "Collecting network info"
{
  echo "# ip addr"; ip addr 2>/dev/null || ifconfig -a 2>/dev/null || true
  echo -e "\n# ip route"; ip route 2>/dev/null || netstat -rn 2>/dev/null || true
  echo -e "\n# resolv.conf"; cat /etc/resolv.conf 2>/dev/null || true
  echo -e "\n# ping gateway"; ping -c 3 1.1.1.1 2>&1 || true
  echo -e "\n# DNS test"; getent hosts example.com 2>&1 || host example.com 2>&1 || nslookup example.com 2>&1 || true
} >"$ROOT/network.txt"

# --- Logs (last 1h)
log "Collecting logs (last 1h)"
mkdir -p "$ROOT/logs"
if command -v journalctl >/dev/null; then
  journalctl -p err --since "1 hour ago" >"$ROOT/logs/journal_err_1h.txt" || true
  journalctl -u NetworkManager --since "1 hour ago" >"$ROOT/logs/journal_nm_1h.txt" || true
fi
dmesg --ctime --level=err,warn >"$ROOT/logs/dmesg_warn.txt" 2>/dev/null || true

# --- Browser proxy/SSL hints (optional, best-effort)
log "Collecting curl verbose for https://example.com"
curl -vsS https://example.com >/dev/null 2>"$ROOT/logs/curl_example_verbose.txt" || true

# --- Redaction (naive but useful)
log "Redacting IPs/emails in text files"
REG_IP='([0-9]{1,3}\.){3}[0-9]{1,3}'
REG_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
while IFS= read -r -d '' f; do
  sed -E -i.bak \
    -e "s/${REG_IP}/<REDACTED_IP>/g" \
    -e "s/${REG_EMAIL}/<REDACTED_EMAIL>/g" "$f" && rm -f "${f}.bak"
done < <(find "$ROOT" -type f -name '*.txt' -print0)

# --- Manifest
log "Writing manifest"
{
  echo "Collected at: ${DTS}Z"
  echo "Host: $(hostname)"
  echo "Files:"; find "$ROOT" -type f | sed "s#${ROOT}/#  - #"
} >"$ROOT/MANIFEST.txt"

# --- Bundle
log "Creating bundle ${OUT}.tgz"
tar -C "$ROOT" -czf "${OUT}.tgz" .

echo "Done: $(pwd)/${OUT}.tgz"

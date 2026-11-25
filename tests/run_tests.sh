#!/usr/bin/env bash
# Tests for collect-logs.sh and the redaction in collect-logs.ps1.
# Runs on Linux and macOS without root. The full collection step reaches out to
# 1.1.1.1 and example.com, but those parts are best effort, so the test also passes offline.
# The PowerShell checks run only when pwsh is installed.
#
# Usage: ./tests/run_tests.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
COLLECTOR="$REPO_DIR/collect-logs.sh"
SCRATCH_DIR=$(mktemp -d)
trap 'rm -rf "$SCRATCH_DIR"' EXIT
OS_NAME=$(uname -s)

PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
pass() { echo "[PASS] $1"; PASSED_COUNT=$((PASSED_COUNT+1)); }
fail() { echo "[FAIL] $1"; FAILED_COUNT=$((FAILED_COUNT+1)); }
skip() { echo "[SKIP] $1"; SKIPPED_COUNT=$((SKIPPED_COUNT+1)); }

#this machine's names, the same list the collector builds, 3 characters or longer
machine_names() {
  hostname 2>/dev/null
  hostname -s 2>/dev/null
  if [[ "$OS_NAME" == Darwin ]]; then
    scutil --get ComputerName 2>/dev/null
    scutil --get LocalHostName 2>/dev/null
  fi
  [[ "$(id -un)" != root ]] && id -un
}

#this machine's MAC addresses as 12 hex digits, the same list the collector builds
machine_bare_macs() {
  if [[ "$OS_NAME" == Darwin ]]; then
    ifconfig -a 2>/dev/null | awk '$1 == "ether" { print $2 }'
  else
    cat /sys/class/net/*/address 2>/dev/null
  fi | tr -d ':' | grep -E '^[0-9A-Fa-f]{12}$' | grep -v '^000000000000$' | sort -u
}

#count_mac_leaks DIR prints how many lines under DIR hold one of this machine's MACs, with or without separators
count_mac_leaks() {
  local LEAK_TOTAL=0 BARE_MAC HITS COLON_FORM
  while IFS= read -r BARE_MAC; do
    COLON_FORM=$(printf '%s' "$BARE_MAC" | sed 's/../&:/g; s/:$//')
    for FORM in "$BARE_MAC" "$COLON_FORM" "$(printf '%s' "$COLON_FORM" | tr ':' '-')"; do
      HITS=$(grep -rFi -- "$FORM" "$1" 2>/dev/null | wc -l | tr -d ' ')
      LEAK_TOTAL=$((LEAK_TOTAL+HITS))
    done
  done < <(machine_bare_macs)
  echo "$LEAK_TOTAL"
}

#count_leaks DIR prints how many of this machine's names appear anywhere under DIR
count_leaks() {
  local LEAK_TOTAL=0 NAME HITS
  while IFS= read -r NAME; do
    [[ ${#NAME} -ge 3 ]] || continue
    HITS=$(grep -rFi -- "$NAME" "$1" 2>/dev/null | wc -l | tr -d ' ')
    LEAK_TOTAL=$((LEAK_TOTAL+HITS))
  done < <(machine_names)
  echo "$LEAK_TOTAL"
}

echo "== Redaction rules"
cp "$TEST_DIR/fixtures/redaction_input.txt" "$SCRATCH_DIR/fixture.txt"
"$COLLECTOR" --redact "$SCRATCH_DIR/fixture.txt"
if diff -u "$TEST_DIR/fixtures/redaction_expected.txt" "$SCRATCH_DIR/fixture.txt" >"$SCRATCH_DIR/fixture.diff"; then
  pass "collect-logs.sh --redact turns redaction_input.txt into redaction_expected.txt"
else
  fail "collect-logs.sh --redact output differs from redaction_expected.txt"
  cat "$SCRATCH_DIR/fixture.diff"
fi

#this machine's own names, written into a file the way logs and command output show them
{
  while IFS= read -r NAME; do
    echo "seen: $NAME"
    echo "lower case: $(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
  done < <(machine_names)
  echo "home: $HOME/Documents"
  while IFS= read -r BARE_MAC; do
    echo "mac with no separators: 0x$BARE_MAC and $(printf '%s' "$BARE_MAC" | tr '[:lower:]' '[:upper:]')"
  done < <(machine_bare_macs)
} >"$SCRATCH_DIR/names.txt"
"$COLLECTOR" --redact "$SCRATCH_DIR/names.txt"
NAME_LEAKS=$(count_leaks "$SCRATCH_DIR/names.txt")
if [[ "$NAME_LEAKS" == 0 ]] && grep -q "<REDACTED_HOST>" "$SCRATCH_DIR/names.txt"; then
  pass "this machine's host and user names are replaced"
else
  fail "$NAME_LEAKS lines still hold a host or user name of this machine"
fi
MAC_COUNT=$(machine_bare_macs | wc -l | tr -d ' ')
MAC_LEAKS=$(count_mac_leaks "$SCRATCH_DIR/names.txt")
if [[ "$MAC_COUNT" == 0 ]]; then
  skip "this machine has no MAC address to check"
elif [[ "$MAC_LEAKS" == 0 ]]; then
  pass "this machine's $MAC_COUNT MAC addresses are replaced even without separators"
else
  fail "$MAC_LEAKS lines still hold one of this machine's MAC addresses"
fi

if "$COLLECTOR" --bogus >/dev/null 2>&1; then
  fail "an unknown argument should exit non-zero"
else
  pass "an unknown argument exits non-zero"
fi

echo "== Full collection on $OS_NAME"
mkdir -p "$SCRATCH_DIR/run"
TMPDIR_BEFORE=$(ls -d "${TMPDIR:-/tmp}"/support_logs_* 2>/dev/null | wc -l | tr -d ' ')
(cd "$SCRATCH_DIR/run" && "$COLLECTOR" >"$SCRATCH_DIR/collect.log" 2>&1)
COLLECT_EXIT_CODE=$?
BUNDLE_FILE=$(ls "$SCRATCH_DIR"/run/logs_*.tgz 2>/dev/null | head -1)
if [[ $COLLECT_EXIT_CODE -eq 0 && -n "$BUNDLE_FILE" ]]; then
  pass "collect-logs.sh exits 0 and writes logs_<time>.tgz"
else
  fail "collect-logs.sh failed (exit $COLLECT_EXIT_CODE)"
  cat "$SCRATCH_DIR/collect.log"
  echo "Summary: $PASSED_COUNT passed, $FAILED_COUNT failed, $SKIPPED_COUNT skipped"
  exit 1
fi
TMPDIR_AFTER=$(ls -d "${TMPDIR:-/tmp}"/support_logs_* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TMPDIR_AFTER" == "$TMPDIR_BEFORE" ]]; then
  pass "the temporary work folder is removed after bundling"
else
  fail "a support_logs_ folder was left in the temp directory"
fi

mkdir -p "$SCRATCH_DIR/bundle"
tar -xzf "$BUNDLE_FILE" -C "$SCRATCH_DIR/bundle"
BUNDLE="$SCRATCH_DIR/bundle"
if [[ "$OS_NAME" == Darwin ]]; then
  EXPECTED_FILES="system.txt network.txt MANIFEST.txt logs/curl_example_verbose.txt logs/unified_err_1h.txt logs/unified_network_1h.txt"
else
  EXPECTED_FILES="system.txt network.txt MANIFEST.txt logs/curl_example_verbose.txt logs/dmesg_warn.txt"
  command -v journalctl >/dev/null && EXPECTED_FILES="$EXPECTED_FILES logs/journal_err_1h.txt logs/journal_nm_1h.txt"
fi
for EXPECTED_FILE in $EXPECTED_FILES; do
  if [[ -f "$BUNDLE/$EXPECTED_FILE" ]]; then
    pass "bundle has $EXPECTED_FILE"
  else
    fail "bundle is missing $EXPECTED_FILE"
  fi
done

if [[ "$OS_NAME" == Darwin ]]; then
  #each section header is followed by real output, not an error from a missing tool
  for SECTION_CHECK in "system.txt|# sw_vers|ProductVersion" "system.txt|# system_profiler|Hardware Overview" \
    "network.txt|# ifconfig -a|flags=" "network.txt|# netstat -rn|Destination" \
    "network.txt|# scutil --dns|resolver #1" "network.txt|# networksetup|Hardware Port"; do
    IFS='|' read -r SECTION_FILE SECTION_HEADER SECTION_TEXT <<<"$SECTION_CHECK"
    if grep -qF "$SECTION_HEADER" "$BUNDLE/$SECTION_FILE" && grep -qF "$SECTION_TEXT" "$BUNDLE/$SECTION_FILE"; then
      pass "$SECTION_FILE has \"$SECTION_HEADER\" with output"
    else
      fail "$SECTION_FILE is missing \"$SECTION_HEADER\" output"
    fi
  done
  for UNIFIED_FILE in unified_err_1h.txt unified_network_1h.txt; do
    if head -1 "$BUNDLE/logs/$UNIFIED_FILE" | grep -q "^Timestamp"; then
      pass "logs/$UNIFIED_FILE is log show output ($(wc -l <"$BUNDLE/logs/$UNIFIED_FILE" | tr -d ' ') lines)"
    else
      fail "logs/$UNIFIED_FILE does not look like log show output"
    fi
  done
  if grep -q "Serial Number" "$BUNDLE/system.txt" && ! grep -q "<REDACTED_SERIAL>" "$BUNDLE/system.txt"; then
    fail "system.txt shows a serial number"
  else
    pass "system.txt shows no serial number"
  fi
fi

LEAKS=$(count_leaks "$BUNDLE")
if [[ "$LEAKS" == 0 ]]; then
  pass "no host or user name of this machine in the bundle"
else
  fail "$LEAKS lines in the bundle still hold a host or user name"
fi
MAC_LEAKS=$(count_mac_leaks "$BUNDLE")
if [[ "$MAC_LEAKS" == 0 ]]; then
  pass "no MAC address of this machine in the bundle, in any format"
else
  fail "$MAC_LEAKS lines in the bundle still hold one of this machine's MAC addresses"
fi
for PATTERN_CHECK in "MAC address|([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}" "IPv4 address|([0-9]{1,3}\.){3}[0-9]{1,3}" \
  "IPv6 link local address|fe80:[0-9A-Fa-f:]*:[0-9A-Fa-f]" "email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"; do
  PATTERN_NAME=${PATTERN_CHECK%%|*}
  PATTERN=${PATTERN_CHECK#*|}
  HITS=$(grep -rEo -- "$PATTERN" "$BUNDLE" | wc -l | tr -d ' ')
  if [[ "$HITS" == 0 ]]; then
    pass "no $PATTERN_NAME left in the bundle"
  else
    fail "$HITS ${PATTERN_NAME}es left in the bundle"
  fi
done

if grep -q "^Host: <REDACTED_HOST>$" "$BUNDLE/MANIFEST.txt" && grep -q "  - system.txt (" "$BUNDLE/MANIFEST.txt"; then
  pass "MANIFEST.txt has the redacted host and the file list"
else
  fail "MANIFEST.txt is missing the redacted host or the file list"
fi

echo "== PowerShell collector"
if command -v pwsh >/dev/null; then
  #pwsh -Command does not pass extra arguments through as $args, so the paths go in environment variables
  export PS_SCRIPT="$REPO_DIR/collect-logs.ps1"
  export PS_INPUT="$TEST_DIR/fixtures/redaction_input.txt"
  export PS_OUTPUT="$SCRATCH_DIR/ps_fixture.txt"
  PARSE_ERRORS=$(pwsh -NoProfile -Command '$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:PS_SCRIPT, [ref]$null, [ref]$e); $e.Count')
  if [[ "$PARSE_ERRORS" == 0 ]]; then
    pass "collect-logs.ps1 parses with no errors"
  else
    fail "collect-logs.ps1 has $PARSE_ERRORS parse errors"
  fi
  #dot-sourcing loads the functions without running the Windows only collection
  pwsh -NoProfile -Command '. $env:PS_SCRIPT; $t = Get-Content -Raw $env:PS_INPUT; Set-Content -NoNewline -Path $env:PS_OUTPUT -Value (Invoke-Redaction -Text $t)'
  if diff -u "$TEST_DIR/fixtures/redaction_expected.txt" "$SCRATCH_DIR/ps_fixture.txt" >"$SCRATCH_DIR/ps.diff"; then
    pass "Invoke-Redaction gives the same output as collect-logs.sh for the fixture"
  else
    fail "Invoke-Redaction output differs from redaction_expected.txt"
    cat "$SCRATCH_DIR/ps.diff"
  fi
  PS_NAMES=$(pwsh -NoProfile -Command '. $env:PS_SCRIPT; Invoke-Redaction -Text "Host Name: DESKTOP-TEST01 user c:\Users\testuser\AppData desktop-test01" -HostNames @("DESKTOP-TEST01") -UserNames @("testuser")')
  if [[ "$PS_NAMES" == 'Host Name: <REDACTED_HOST> user c:\Users\<REDACTED_USER>\AppData <REDACTED_HOST>' ]]; then
    pass "Invoke-Redaction replaces computer and user names in any case"
  else
    fail "Invoke-Redaction name output was: $PS_NAMES"
  fi
  #the whole Windows collection flow with the Windows commands replaced by stand ins
  if pwsh -NoProfile -File "$TEST_DIR/windows_bundle_test.ps1" -Engine pwsh -Stubbed >"$SCRATCH_DIR/ps_bundle.log" 2>&1; then
    pass "collect-logs.ps1 builds a correct, redacted bundle with stubbed Windows commands ($(grep -c '^\[PASS\]' "$SCRATCH_DIR/ps_bundle.log") checks)"
  else
    fail "windows_bundle_test.ps1 -Stubbed failed"
    grep -v '^\[PASS\]' "$SCRATCH_DIR/ps_bundle.log"
  fi
else
  skip "pwsh is not installed, PowerShell checks skipped"
fi

echo "Summary: $PASSED_COUNT passed, $FAILED_COUNT failed, $SKIPPED_COUNT skipped"
[[ $FAILED_COUNT -eq 0 ]]

# Support Log Pack

Two log collectors, one in Bash for Linux and macOS and one in PowerShell for Windows, that gather the system and network state a support engineer usually asks for, redact addresses and machine identifiers in the text output, and package everything into a single timestamped archive with a manifest.

## What each collector gathers

### Linux: `collect-logs.sh`

| File | Contents |
|------|----------|
| `system.txt` | `uname -a`, `/etc/os-release`, `uptime`, `df -h` |
| `network.txt` | `ip addr` (or `ifconfig -a`), `ip route` (or `netstat -rn`), `/etc/resolv.conf`, three pings to 1.1.1.1, and a DNS lookup of example.com |
| `logs/journal_err_1h.txt` | `journalctl -p err` for the last hour (systemd hosts only) |
| `logs/journal_nm_1h.txt` | NetworkManager journal for the last hour (systemd hosts only) |
| `logs/dmesg_warn.txt` | Kernel ring buffer entries at error and warning level. Empty when the kernel restricts `dmesg` to root. |
| `logs/curl_example_verbose.txt` | `curl -v https://example.com` output, which shows the TLS handshake and any proxy in the path |
| `MANIFEST.txt` | Collection time, platform, what was redacted, and the file list with sizes |

### macOS: `collect-logs.sh`

The same script detects macOS with `uname -s` and collects the macOS equivalents instead. None of it needs root.

| File | Contents |
|------|----------|
| `system.txt` | `uname -a`, `sw_vers`, `uptime`, `df -h`, and `system_profiler -detailLevel mini SPSoftwareDataType SPHardwareDataType` (macOS version, model, chip, memory, firmware). The mini detail level leaves out the serial number, hardware UUID, computer name and user name. |
| `network.txt` | `ifconfig -a`, `netstat -rn` (routes), `scutil --dns` (every resolver, including the ones a VPN adds for its own domains), `scutil --proxy`, `networksetup -listallhardwareports` (which `enX` is Wi-Fi and which is Ethernet), three pings to 1.1.1.1, and a lookup of example.com through the system resolver with `dscacheutil` |
| `logs/unified_err_1h.txt` | Unified log entries of type error or fault from the last hour, from `log show --last 1h --style compact` |
| `logs/unified_network_1h.txt` | The same, limited to the `com.apple.network` subsystems, `configd` and `mDNSResponder` |
| `logs/curl_example_verbose.txt` | `curl -v https://example.com` output |
| `MANIFEST.txt` | Collection time, platform, what was redacted, and the file list with sizes |

On a busy Mac the hour of errors can be tens of thousands of lines. A run on a desktop Mac collected about 78,000 lines (18 MB), and the finished archive was about 800 KB. The whole run took about 17 seconds.

### Windows: `collect-logs.ps1`

| File | Contents |
|------|----------|
| `system.txt` | `systeminfo` and the last boot time |
| `network.txt` | `ipconfig /all`, `route print`, `netsh wlan show interfaces` |
| `logs/System.evtx`, `logs/Application.evtx` | Full exports of the System and Application event logs |
| `logs/System_last1h.txt`, `logs/Application_last1h.txt` | Error and Warning events (levels 2 and 3) since `-Since` (default one hour ago) as a text table, or a line saying there were none |
| `MANIFEST.txt` | Collection time, what was redacted, and the file list with sizes, as paths inside the bundle |

## Redaction

Both collectors redact every `.txt` file before packaging, with the same rules:

| Found | Replaced with |
|-------|---------------|
| IPv4 addresses | `<REDACTED_IP>` |
| IPv6 addresses, full and compressed, including link local ones such as `fe80::1c2b:3cff:fe4d:5e6f%en0` | `<REDACTED_IP6>` |
| MAC addresses with colons or dashes, and longer runs of hex pairs such as a DHCPv6 DUID, which ends in the MAC address | `<REDACTED_MAC>` |
| This machine's own MAC addresses written as 12 hex digits with no separators, as some event messages print them (for example `0x000D3A123456`) | `<REDACTED_MAC>` |
| Email addresses | `<REDACTED_EMAIL>` |
| This machine's host names (`hostname`, `hostname -s`, and on macOS the ComputerName and LocalHostName), matched in any case | `<REDACTED_HOST>` |
| The user name and full name of the user running the script (and of `SUDO_USER`), matched in any case, which also covers home folder paths | `<REDACTED_USER>` |
| `Serial Number` lines | `<REDACTED_SERIAL>` |
| `Hardware UUID` and `Provisioning UDID` lines | `<REDACTED_UUID>` |

On Windows the names come from `COMPUTERNAME`, the DNS host name and `USERNAME`, and they are matched in any case.

The rules are pattern based. Names shorter than three characters are skipped, because replacing a two letter name everywhere would make the logs unreadable. An IPv6 match needs at least one hex group next to the `::`, so code names such as `std::string` are left alone. Text that only looks like an address can still be replaced, for example a four part version number. The `.evtx` exports on Windows are not redacted. The manifests list paths inside the bundle and show `<REDACTED_HOST>` instead of the host name. Review the bundle before sending it outside the organization.

The Bash collector runs `sed` with `LC_ALL=C`, so log bytes that are not valid UTF-8 do not stop it. If redaction fails anyway, the script stops before creating the archive and removes its work folder, so nothing unredacted is packaged.

The same rules can be run on any text file, for example a log someone pasted into a ticket:

```bash
./collect-logs.sh --redact notes.txt other.log
```

The file is changed in place.

## Requirements

- Linux or macOS: Bash, `tar`, `sed` and `curl`
- Windows: PowerShell 5.0 or later (needed for `Compress-Archive`) and `wevtutil`, which ships with Windows

## Usage

Linux or macOS:

```bash
chmod +x collect-logs.sh
./collect-logs.sh
```

The script works in a temporary folder under `$TMPDIR` (or `/tmp`), writes `logs_<YYYYMMDDTHHMMSSZ>.tgz` to the current directory, and then deletes the temporary folder. Output from a macOS run:

```text
[16:13:28] Collecting system info
[16:13:29] Collecting network info
[16:13:31] Collecting logs (last 1h)
[16:13:37] Collecting curl verbose for https://example.com
[16:13:37] Redacting IPs, MACs, emails, host and user names in text files
[16:13:45] Writing manifest
[16:13:45] Creating bundle logs_20261123T221328Z.tgz
Done: /Users/you/logs_20261123T221328Z.tgz (5 text files redacted)
```

Windows, from a PowerShell prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\collect-logs.ps1
# Or set the start of the event window (any date string Get-Date accepts)
powershell -ExecutionPolicy Bypass -File .\collect-logs.ps1 -Since "2025-11-07T08:00:00"
```

The script writes `logs_<YYYYMMDDTHHMMSSZ>.zip` to the current directory and deletes its temporary folder.

## Tests

`tests/run_tests.sh` runs on Linux and macOS without root:

1. Redacts `tests/fixtures/redaction_input.txt` with `collect-logs.sh --redact` and compares the result with `tests/fixtures/redaction_expected.txt`. The fixture has every kind of address the rules cover, plus text that must be left alone (a time, `std::string`, a run of colons, a version number).
2. Writes this machine's own host names, user name and MAC addresses (with no separators, in upper and lower case) into a file and checks that none survive redaction.
3. Runs a full collection, unpacks the archive and checks that every file for the platform is there, that each macOS section holds real output (for example `scutil --dns` shows `resolver #1`), that no host name, user name, MAC (this machine's in any format, or any with separators), IPv4, IPv6 link local or email address is left anywhere in the bundle, that the manifest is right, and that the work folder is gone.
4. When `pwsh` is installed, checks that `collect-logs.ps1` parses with no errors, dot-sources it (which loads the functions without running the Windows only collection) and checks that `Invoke-Redaction` turns the same fixture into the same expected output as the Bash script.
5. Also with `pwsh`, runs `tests/windows_bundle_test.ps1 -Stubbed`. It replaces `systeminfo`, `ipconfig`, `route`, `netsh`, `wevtutil`, `Get-CimInstance` and `Get-WinEvent` with stand ins that print this machine's real host name, user name and MAC address, runs the whole Windows collection, unpacks the zip and makes the same 25 checks as on Windows (below).

```bash
./tests/run_tests.sh
```

```text
== Redaction rules
[PASS] collect-logs.sh --redact turns redaction_input.txt into redaction_expected.txt
[PASS] this machine's host and user names are replaced
...
== PowerShell collector
[PASS] collect-logs.ps1 parses with no errors
[PASS] Invoke-Redaction gives the same output as collect-logs.sh for the fixture
[PASS] Invoke-Redaction replaces computer and user names in any case
[PASS] collect-logs.ps1 builds a correct, redacted bundle with stubbed Windows commands (25 checks)
Summary: 32 passed, 0 failed, 0 skipped
```

The full collection pings 1.1.1.1 and fetches example.com, but those parts are best effort, so the tests also pass offline.

On Windows, `tests/windows_bundle_test.ps1` runs the real collector, unpacks the zip and checks that every expected file (including both `.evtx` exports) is there and not empty, that `system.txt` and `network.txt` hold real `systeminfo`, `ipconfig` and `route print` output with their line breaks, that no host name, user name, MAC address (with or without separators) or IPv4 address of the machine is left in any text file and the redaction tokens are there instead, that the manifest has the redacted computer name and no absolute paths, and that the work folder in `TEMP` is gone. `-Engine` picks the PowerShell that runs the collector:

```powershell
pwsh -File tests/windows_bundle_test.ps1 -Engine powershell   # Windows PowerShell 5.1
pwsh -File tests/windows_bundle_test.ps1 -Engine pwsh         # PowerShell 7
```

The GitHub Actions workflow in `.github/workflows/tests.yml` runs `tests/run_tests.sh` on Ubuntu 24.04 and macOS, and the Windows test under both engines on `windows-latest`.

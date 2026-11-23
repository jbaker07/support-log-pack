# Support Log Pack

Two log collectors, one in Bash for Linux and macOS and one in PowerShell for Windows, that gather the system and network state a support engineer usually asks for, redact IPv4 and email addresses in the text output, and package everything into a single timestamped archive with a manifest.

## What each collector gathers

### Linux and macOS: `collect-logs.sh`

| File | Contents |
|------|----------|
| `system.txt` | `uname -a`, `/etc/os-release`, `uptime`, `df -h` |
| `network.txt` | `ip addr` (or `ifconfig -a`), `ip route` (or `netstat -rn`), `/etc/resolv.conf`, three pings to 1.1.1.1, and a DNS lookup of example.com |
| `logs/journal_err_1h.txt` | `journalctl -p err` for the last hour (systemd hosts only) |
| `logs/journal_nm_1h.txt` | NetworkManager journal for the last hour (systemd hosts only) |
| `logs/dmesg_warn.txt` | Kernel ring buffer entries at error and warning level |
| `logs/curl_example_verbose.txt` | `curl -v https://example.com` output, which shows the TLS handshake and any proxy in the path |
| `MANIFEST.txt` | Collection time, host name and the file list |

On macOS there is no journalctl and `dmesg` needs root and does not accept the Linux flags, so the log files are empty there. The system, network and curl sections still work.

### Windows: `collect-logs.ps1`

| File | Contents |
|------|----------|
| `system.txt` | `systeminfo` and the last boot time |
| `network.txt` | `ipconfig /all`, `route print`, `netsh wlan show interfaces` |
| `logs/System.evtx`, `logs/Application.evtx` | Full exports of the System and Application event logs |
| `logs/System_last1h.txt`, `logs/Application_last1h.txt` | Error and Warning events since `-Since` (default one hour ago) as a text table |
| `MANIFEST.txt` | Collection time, computer name and the file list |

## Redaction

Both collectors replace IPv4 addresses with `<REDACTED_IP>` and email addresses with `<REDACTED_EMAIL>` in every `.txt` file before packaging. The redaction is pattern based. It does not cover IPv6 addresses, MAC addresses, host names, user names or the contents of the `.evtx` exports. The manifest is written after redaction, so it keeps the host or computer name, and on Windows it lists full file paths under the user's temp folder. Review the bundle before sending it outside the organization.

## Requirements

- Linux or macOS: Bash, `tar` and `curl`
- Windows: PowerShell 5.0 or later (needed for `Compress-Archive`) and `wevtutil`, which ships with Windows

## Usage

Linux or macOS:

```bash
chmod +x collect-logs.sh
./collect-logs.sh
```

The script works in a temporary folder under `$TMPDIR` (or `/tmp`) and writes `logs_<YYYYMMDDTHHMMSSZ>.tgz` to the current directory:

```text
[14:07:30] Collecting system info
[14:07:30] Collecting network info
[14:07:32] Collecting logs (last 1h)
[14:07:32] Collecting curl verbose for https://example.com
[14:07:32] Redacting IPs/emails in text files
[14:07:32] Writing manifest
[14:07:32] Creating bundle logs_20261123T200730Z.tgz
Done: /home/user/logs_20261123T200730Z.tgz
```

Windows, from a PowerShell prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\collect-logs.ps1
# Or set the start of the event window (any date string Get-Date accepts)
powershell -ExecutionPolicy Bypass -File .\collect-logs.ps1 -Since "2025-11-07T08:00:00"
```

The script writes `logs_<YYYYMMDDTHHMMSSZ>.zip` to the current directory.

The temporary folder is left in place after the archive is created.

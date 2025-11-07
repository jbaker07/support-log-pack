# Support Log Pack (MVP)

One-click collectors for Linux/macOS and Windows:
- System snapshot, network snapshot, last-hour errors, optional curl/TLS verbosity
- Naive redaction for IPs/emails (text files)
- Bundles to `logs_YYYYMMDDTHHMMSSZ.tgz|.zip` with a `MANIFEST.txt`

## Quick start
Linux/macOS:
```bash
chmod +x collect-logs.sh
./collect-logs.sh

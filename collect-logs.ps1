<# Minimal Windows log collector with redaction + bundle #>
[CmdletBinding()] Param(
  [string]$Since = (Get-Date).AddHours(-1).ToString("o")
)

$DTS = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$Root = Join-Path $env:TEMP ("support_logs_" + $DTS)
New-Item -ItemType Directory -Path $Root -Force | Out-Null

function Write-Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) }

# System
Write-Log "Collecting system info"
@"
# systeminfo
$(systeminfo 2>$null)

# uptime
$(Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime | Format-List | Out-String)
"@ | Out-File -FilePath (Join-Path $Root "system.txt") -Encoding UTF8

# Network
Write-Log "Collecting network info"
@"
# ipconfig /all
$(ipconfig /all 2>$null)

# route print
$(route print 2>$null)

# WLAN
$(netsh wlan show interfaces 2>$null)
"@ | Out-File -FilePath (Join-Path $Root "network.txt") -Encoding UTF8

# Logs (EVTX export last hour is heavy; export full files for simplicity)
Write-Log "Exporting Event Logs"
$LogsDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
wevtutil epl System (Join-Path $LogsDir "System.evtx")
wevtutil epl Application (Join-Path $LogsDir "Application.evtx")

# Quick textual filters (last hour) for triage
$SinceDT = Get-Date -Date $Since
Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$SinceDT } |
  Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
  Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
  Format-Table -AutoSize | Out-String | Out-File (Join-Path $LogsDir "System_last1h.txt")

Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$SinceDT } |
  Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
  Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
  Format-Table -AutoSize | Out-String | Out-File (Join-Path $LogsDir "Application_last1h.txt")

# Redaction (simple regex in text files only; EVTX left intact)
Write-Log "Redacting IPs/emails in text files"
$IpRegex = '([0-9]{1,3}\.){3}[0-9]{1,3}'
$EmailRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
Get-ChildItem -Path $Root -Recurse -Include *.txt | ForEach-Object {
  $c = Get-Content $_.FullName -Raw
  $c = [Regex]::Replace($c, $IpRegex, '<REDACTED_IP>')
  $c = [Regex]::Replace($c, $EmailRegex, '<REDACTED_EMAIL>')
  Set-Content -Path $_.FullName -Value $c -Encoding UTF8
}

# Manifest
Write-Log "Writing manifest"
$manifest = @()
$manifest += "Collected at: $DTS"
$manifest += "ComputerName: $env:COMPUTERNAME"
$manifest += "Files:"
Get-ChildItem -Path $Root -Recurse -File | ForEach-Object { $manifest += "  - $($_.FullName)" }
$manifest -join "`n" | Out-File -FilePath (Join-Path $Root "MANIFEST.txt") -Encoding UTF8

# Bundle
Write-Log "Creating bundle"
$ZipPath = Join-Path (Get-Location) ("logs_" + $DTS + ".zip")
Compress-Archive -Path (Join-Path $Root '*') -DestinationPath $ZipPath -Force
Write-Host "Done: $ZipPath"

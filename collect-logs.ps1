<# Minimal Windows log collector with redaction + bundle #>
[CmdletBinding()] Param(
  [string]$Since = (Get-Date).AddHours(-1).ToString("o")
)

function Write-Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) }

# Redaction rules. They match the rules in collect-logs.sh, so the same test input gives
# the same output from both scripts. (?m) makes ^ match at the start of every line,
# because the whole file is redacted as one string here and sed works line by line.
$HexGroup = '[0-9A-Fa-f]{1,4}'
$NotWord = '(?m)(^|[^0-9A-Za-z:])'
$IpRegex = '([0-9]{1,3}\.){3}[0-9]{1,3}'
$EmailRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# Six or more hex pairs, so a DHCPv6 DUID, which ends in the MAC address, goes as a whole
$MacRegex = '([0-9A-Fa-f]{2}[:-]){5,}[0-9A-Fa-f]{2}'
$Ip6FullRegex = $NotWord + $HexGroup + '(:' + $HexGroup + '){7}'
$Ip6ShortRegex = $NotWord + $HexGroup + '(:' + $HexGroup + '){0,6}::(' + $HexGroup + '(:' + $HexGroup + '){0,6})?'
$Ip6LeadingRegex = $NotWord + '::' + $HexGroup + '(:' + $HexGroup + '){0,6}'

# Names shorter than 3 characters are skipped, because replacing them everywhere would wreck the logs
function Get-RedactionNames([string[]]$Candidates) {
  $Candidates | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique | Sort-Object -Property Length -Descending
}

# This machine's MAC addresses as 12 hex digits with no separators. Event messages
# sometimes print a MAC that way (for example 0x000D3A123456), which the pattern for
# MACs with separators cannot catch, so the machine's own addresses are replaced by value.
function Get-MacAddresses {
  $Found = @()
  try {
    foreach ($Nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      $Bare = $Nic.GetPhysicalAddress().ToString()
      if ($Bare.Length -eq 12 -and $Bare -ne '000000000000') { $Found += $Bare }
    }
  } catch { }
  $Found | Select-Object -Unique
}

function Invoke-Redaction {
  param(
    [string]$Text,
    [string[]]$HostNames = @(),
    [string[]]$UserNames = @(),
    [string[]]$MacAddresses = @()
  )
  $Text = [Regex]::Replace($Text, '(Serial Number[^:\r\n]*: )[^\r\n]*', '$1<REDACTED_SERIAL>')
  $Text = [Regex]::Replace($Text, '((Hardware UUID|Provisioning UDID): )[^\r\n]*', '$1<REDACTED_UUID>')
  foreach ($Name in (Get-RedactionNames $HostNames)) {
    $Text = [Regex]::Replace($Text, [Regex]::Escape($Name), '<REDACTED_HOST>', 'IgnoreCase')
  }
  foreach ($Name in (Get-RedactionNames $UserNames)) {
    $Text = [Regex]::Replace($Text, [Regex]::Escape($Name), '<REDACTED_USER>', 'IgnoreCase')
  }
  foreach ($Mac in $MacAddresses) {
    if ($Mac) { $Text = [Regex]::Replace($Text, [Regex]::Escape($Mac), '<REDACTED_MAC>', 'IgnoreCase') }
  }
  $Text = [Regex]::Replace($Text, $EmailRegex, '<REDACTED_EMAIL>')
  $Text = [Regex]::Replace($Text, $MacRegex, '<REDACTED_MAC>')
  $Text = [Regex]::Replace($Text, $IpRegex, '<REDACTED_IP>')
  $Text = [Regex]::Replace($Text, $Ip6FullRegex, '$1<REDACTED_IP6>')
  $Text = [Regex]::Replace($Text, $Ip6ShortRegex, '$1<REDACTED_IP6>')
  $Text = [Regex]::Replace($Text, $Ip6LeadingRegex, '$1<REDACTED_IP6>')
  return $Text
}

# Error and Warning events (levels 2 and 3) since SinceDT as a text table. An hour with
# no such events is normal, and an empty file in a bundle looks like a failure, so that
# case gets a line that says so. Width 4096 keeps Out-String from cutting messages short.
function Write-RecentEvents([string]$LogName, [datetime]$SinceDT, [string]$Path) {
  $Events = @(Get-WinEvent -FilterHashtable @{ LogName=$LogName; Level=2,3; StartTime=$SinceDT } -ErrorAction SilentlyContinue)
  if ($Events.Count -eq 0) {
    "No Error or Warning events in the $LogName log since $($SinceDT.ToString('o'))" | Out-File -FilePath $Path -Encoding UTF8
  } else {
    $Events | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
      Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Out-File -FilePath $Path -Encoding UTF8
  }
}

function Invoke-Collection {
  $DTS = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  # The path New-Item hands back is used from here on, so the relative paths in the
  # manifest are cut from the same string Get-ChildItem returns
  $Root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("support_logs_" + $DTS)) -Force).FullName

  # System
  # Out-String keeps the line breaks. A bare $(command) inside a here-string joins the
  # output lines with spaces, which put all of systeminfo on one line.
  Write-Log "Collecting system info"
  @"
# systeminfo
$(systeminfo 2>$null | Out-String)
# uptime
$(Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime | Format-List | Out-String)
"@ | Out-File -FilePath (Join-Path $Root "system.txt") -Encoding UTF8

  # Network
  Write-Log "Collecting network info"
  @"
# ipconfig /all
$(ipconfig /all 2>$null | Out-String)
# route print
$(route print 2>$null | Out-String)
# WLAN
$(netsh wlan show interfaces 2>$null | Out-String)
"@ | Out-File -FilePath (Join-Path $Root "network.txt") -Encoding UTF8

  # Logs (an EVTX export of only the last hour is heavy, so export the full files for simplicity)
  Write-Log "Exporting Event Logs"
  $LogsDir = Join-Path $Root "logs"
  New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
  wevtutil epl System (Join-Path $LogsDir "System.evtx")
  wevtutil epl Application (Join-Path $LogsDir "Application.evtx")

  # Quick textual filters (last hour) for triage. Get-WinEvent reports an error when no
  # event matches, which is the normal case on a healthy machine, so Write-RecentEvents
  # silences it and writes a line instead.
  $SinceDT = Get-Date -Date $Since
  Write-RecentEvents -LogName 'System' -SinceDT $SinceDT -Path (Join-Path $LogsDir "System_last1h.txt")
  Write-RecentEvents -LogName 'Application' -SinceDT $SinceDT -Path (Join-Path $LogsDir "Application_last1h.txt")

  # Redaction (text files only, the EVTX exports are left intact)
  Write-Log "Redacting IPs, MACs, emails, host and user names in text files"
  $HostNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName())
  $UserNames = @($env:USERNAME)
  $MacAddresses = @(Get-MacAddresses)
  Get-ChildItem -Path $Root -Recurse -Include *.txt | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($null -eq $c) { $c = "" }
    $c = Invoke-Redaction -Text $c -HostNames $HostNames -UserNames $UserNames -MacAddresses $MacAddresses
    Set-Content -Path $_.FullName -Value $c -Encoding UTF8
  }

  # Manifest. Paths are relative to the bundle, because the full temp path holds the user name.
  Write-Log "Writing manifest"
  $manifest = @()
  $manifest += "Collected at: $DTS"
  $manifest += "ComputerName: <REDACTED_HOST>"
  $manifest += "Redacted in the text files: IPv4, IPv6, MAC and email addresses, this machine's MAC addresses in any format, computer and user names. The .evtx exports are not redacted."
  $manifest += "Files:"
  Get-ChildItem -Path $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
    $RelativePath = $_.FullName
    if ($RelativePath.StartsWith($Root)) { $RelativePath = $RelativePath.Substring($Root.Length).TrimStart('\', '/') }
    $manifest += "  - $RelativePath ($($_.Length) bytes)"
  }
  $manifest -join "`n" | Out-File -FilePath (Join-Path $Root "MANIFEST.txt") -Encoding UTF8

  # Bundle
  Write-Log "Creating bundle"
  $ZipPath = Join-Path (Get-Location) ("logs_" + $DTS + ".zip")
  Compress-Archive -Path (Join-Path $Root '*') -DestinationPath $ZipPath -Force
  Remove-Item -Path $Root -Recurse -Force
  Write-Host "Done: $ZipPath"
}

# Dot-sourcing the script (. .\collect-logs.ps1) only loads the functions, which is how the
# tests reach Invoke-Redaction on a machine that is not Windows.
# exit 0 makes the exit code explicit for powershell -File and pwsh -File callers. A
# terminating error inside Invoke-Collection never reaches it and exits with 1.
if ($MyInvocation.InvocationName -ne '.') {
  Invoke-Collection
  exit 0
}

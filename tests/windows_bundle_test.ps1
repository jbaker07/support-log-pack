<#
Runs collect-logs.ps1, opens the zip it writes and checks it:
  - every expected file is in the archive and is not empty
  - system.txt and network.txt hold real command output
  - no host name, user name, MAC address or IPv4 address of this machine is left in any
    text file, and the redaction tokens are there instead
  - the manifest has the redacted computer name and paths inside the bundle only
  - the temporary work folder is gone

On Windows it runs the real collector:
  pwsh -File tests/windows_bundle_test.ps1 -Engine powershell   (Windows PowerShell 5.1)
  pwsh -File tests/windows_bundle_test.ps1 -Engine pwsh         (PowerShell 7)

-Stubbed replaces systeminfo, ipconfig, route, netsh, wevtutil, Get-CimInstance and
Get-WinEvent with stand ins that print this machine's real host name, user name, MAC
address and made up IPv4 addresses, so the same flow and the same checks also run with
pwsh on macOS or Linux:
  pwsh -File tests/windows_bundle_test.ps1 -Engine pwsh -Stubbed
#>
param(
  [ValidateSet('powershell', 'pwsh')] [string]$Engine = 'powershell',
  [switch]$Stubbed
)

$RepoDir = Split-Path -Parent $PSScriptRoot
$Collector = Join-Path $RepoDir 'collect-logs.ps1'
$RunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('slp_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $RunDir | Out-Null

$script:PassedCount = 0
$script:FailedCount = 0
function Check([bool]$Ok, [string]$What) {
  if ($Ok) {
    Write-Host "[PASS] $What"
    $script:PassedCount++
  } else {
    Write-Host "[FAIL] $What"
    $script:FailedCount++
  }
}

# This machine's identifiers, collected the same way on every platform
$HostNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique
$UserNames = @($env:USERNAME, [Environment]::UserName) | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique
$MacForms = @()
$Ipv4Addresses = @()
foreach ($Nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
  $Bare = $Nic.GetPhysicalAddress().ToString()
  if ($Bare.Length -eq 12 -and $Bare -ne '000000000000') {
    $Pairs = $Bare -split '(..)' | Where-Object { $_ }
    $MacForms += $Bare
    $MacForms += ($Pairs -join '-')
    $MacForms += ($Pairs -join ':')
  }
  foreach ($Unicast in $Nic.GetIPProperties().UnicastAddresses) {
    if ($Unicast.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
      $Ipv4Addresses += $Unicast.Address.ToString()
    }
  }
}
$MacForms = $MacForms | Select-Object -Unique
Write-Host ("Checking for {0} host names, {1} user names, {2} MAC address forms and {3} IPv4 addresses" -f `
  @($HostNames).Count, @($UserNames).Count, @($MacForms).Count, @($Ipv4Addresses).Count)

$CollectorToRun = $Collector
if ($Stubbed) {
  # The stand ins use this machine's real names and first MAC, so redaction is tested on real values
  $env:TEMP = Join-Path $RunDir 'temp'
  New-Item -ItemType Directory -Path $env:TEMP | Out-Null
  if (-not $env:COMPUTERNAME) { $env:COMPUTERNAME = [System.Net.Dns]::GetHostName() }
  if (-not $env:USERNAME) { $env:USERNAME = [Environment]::UserName }
  $StubScript = @'
param($CollectorPath)
$StubHost = [System.Net.Dns]::GetHostName()
$StubUser = [Environment]::UserName
$StubMac = ([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
  ForEach-Object { $_.GetPhysicalAddress().ToString() } |
  Where-Object { $_.Length -eq 12 -and $_ -ne '000000000000' } | Select-Object -First 1)
if (-not $StubMac) { $StubMac = 'A483E7123456' }
$StubMacDash = (($StubMac -split '(..)' | Where-Object { $_ }) -join '-')
function systeminfo { "Host Name:                 $StubHost"; "OS Name:                   Stub Windows"; "Registered Owner:          $StubUser"; "Logon Server:              \\$StubHost" }
function ipconfig { "Windows IP Configuration"; "   Host Name . . . . . . . . . . . . : $StubHost"; "   Physical Address. . . . . . . . . : $StubMacDash"; "   IPv4 Address. . . . . . . . . . . : 192.168.1.20(Preferred)"; "   Link-local IPv6 Address . . . . . : fe80::1c2b:3cff:fe4d:5e6f%5(Preferred)"; "   DHCPv6 Client DUID. . . . . . . . : 00-01-00-01-2C-6A-1B-D4-$StubMacDash" }
function route { "IPv4 Route Table"; "          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.20     25" }
function netsh { "The Wireless AutoConfig Service (wlansvc) is not running." }
function wevtutil { param($Verb, $LogName, $Path) [System.IO.File]::WriteAllBytes($Path, [byte[]](1..64)) }
function Get-CimInstance { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddHours(-2) } }
function Get-WinEvent {
  [CmdletBinding()] param($FilterHashtable)
  if ($FilterHashtable.LogName -eq 'System') {
    [pscustomobject]@{ TimeCreated = (Get-Date); Id = 1014; ProviderName = 'Microsoft-Windows-DNS-Client'; LevelDisplayName = 'Warning'; Message = "Name resolution for $StubHost timed out after none of the servers at 10.1.2.3 answered, user $StubUser, adapter 0x$StubMac" }
  }
}
. $CollectorPath
Invoke-Collection
'@
  $CollectorToRun = Join-Path $RunDir 'stubbed_collector.ps1'
  Set-Content -Path $CollectorToRun -Value $StubScript -Encoding UTF8
}

$TempBefore = @(Get-ChildItem -Path $env:TEMP -Directory -Filter 'support_logs_*' -ErrorAction SilentlyContinue).Count
Set-Location $RunDir
if ($Stubbed) {
  & $Engine -NoProfile -File $CollectorToRun $Collector
} else {
  & $Engine -NoProfile -ExecutionPolicy Bypass -File $CollectorToRun
}
$CollectorExitCode = $LASTEXITCODE
Check ($CollectorExitCode -eq 0) "collect-logs.ps1 exits 0 under $Engine"

$ZipFiles = @(Get-ChildItem -Path $RunDir -Filter 'logs_*.zip')
Check ($ZipFiles.Count -eq 1) "one logs_<time>.zip in the working directory"
if ($ZipFiles.Count -ne 1) {
  Write-Host "Summary: $script:PassedCount passed, $script:FailedCount failed"
  exit 1
}
$TempAfter = @(Get-ChildItem -Path $env:TEMP -Directory -Filter 'support_logs_*' -ErrorAction SilentlyContinue).Count
Check ($TempAfter -eq $TempBefore) "the support_logs_ work folder is removed from TEMP"

$BundleDir = Join-Path $RunDir 'bundle'
Expand-Archive -Path $ZipFiles[0].FullName -DestinationPath $BundleDir

$ExpectedFiles = @('system.txt', 'network.txt', 'MANIFEST.txt', 'logs/System.evtx', 'logs/Application.evtx',
                   'logs/System_last1h.txt', 'logs/Application_last1h.txt')
foreach ($Relative in $ExpectedFiles) {
  $Path = Join-Path $BundleDir $Relative
  $Present = Test-Path -LiteralPath $Path
  $NotEmpty = $false
  if ($Present) {
    $Item = Get-Item -LiteralPath $Path
    $NotEmpty = $Item.Length -gt 0
    if ($Relative.EndsWith('.txt')) {
      $Content = Get-Content -LiteralPath $Path -Raw
      $NotEmpty = $NotEmpty -and $null -ne $Content -and $Content.Trim().Length -gt 0
    }
  }
  Check ($Present -and $NotEmpty) "bundle has $Relative and it is not empty"
}

$SystemText = Get-Content -LiteralPath (Join-Path $BundleDir 'system.txt') -Raw
$NetworkText = Get-Content -LiteralPath (Join-Path $BundleDir 'network.txt') -Raw
$ManifestText = Get-Content -LiteralPath (Join-Path $BundleDir 'MANIFEST.txt') -Raw
Check ($SystemText -match 'OS Name') "system.txt holds systeminfo output"
Check (($NetworkText -match 'Windows IP Configuration') -and ($NetworkText -match 'IPv4 Route Table')) "network.txt holds ipconfig and route print output"
Check (([regex]::Matches($SystemText, "`n")).Count -gt 3) "system.txt keeps its line breaks"

$TextFiles = @(Get-ChildItem -Path $BundleDir -Recurse -File -Filter '*.txt')
$AllText = ($TextFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

function Count-Hits([string[]]$Needles) {
  $Hits = 0
  foreach ($Needle in $Needles) {
    if ($Needle -and $AllText.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $Hits++ }
  }
  return $Hits
}
Check ((Count-Hits $HostNames) -eq 0) "no host name of this machine in the text files"
Check ((Count-Hits $UserNames) -eq 0) "no user name of this machine in the text files"
Check ((Count-Hits $MacForms) -eq 0) "no MAC address of this machine in the text files, with or without separators"
Check ((Count-Hits $Ipv4Addresses) -eq 0) "no IPv4 address of this machine in the text files"
Check (-not ($AllText -match '([0-9]{1,3}\.){3}[0-9]{1,3}')) "no IPv4 address of any kind in the text files"
Check (-not ($AllText -match '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}')) "no MAC address of any kind in the text files"
Check (-not ($AllText -match 'fe80:[0-9A-Fa-f:]*:[0-9A-Fa-f]')) "no IPv6 link local address in the text files"
Check ($SystemText -match '<REDACTED_HOST>') "system.txt shows <REDACTED_HOST> where the host name was"
Check (($NetworkText -match '<REDACTED_MAC>') -and ($NetworkText -match '<REDACTED_IP>')) "network.txt shows <REDACTED_MAC> and <REDACTED_IP>"

Check ($ManifestText -match 'ComputerName: <REDACTED_HOST>') "MANIFEST.txt has the redacted computer name"
Check ($ManifestText -match '  - system\.txt \(\d+ bytes\)') "MANIFEST.txt lists files with sizes"
Check (-not ($ManifestText -match '[A-Za-z]:\\' -or $ManifestText -match '  - /')) "MANIFEST.txt has no absolute paths"

Write-Host "Summary: $script:PassedCount passed, $script:FailedCount failed"
Set-Location $RepoDir
Remove-Item -Path $RunDir -Recurse -Force -ErrorAction SilentlyContinue
if ($script:FailedCount -gt 0) { exit 1 }
exit 0

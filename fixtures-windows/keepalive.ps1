# keepalive.ps1 -- Windows CF fixture "app": opens and HOLDS a TCP connection to redis so the
# discovery census/probe can observe it. It does NOT need to speak redis correctly -- an open
# socket to the redis port is all the tool needs. Redis address comes from (in order):
#   1. REDIS_HOST / REDIS_PORT env vars   (static / env-var variant)
#   2. VCAP_SERVICES                        (cf-bind variant)
# PowerShell 5.1 compatible (Windows Server 2019 stemcell). No external modules.
$ErrorActionPreference = 'SilentlyContinue'

$rhost = $env:REDIS_HOST
$rport = $env:REDIS_PORT
if (-not $rport) { $rport = 6379 }
if (-not $rhost -and $env:VCAP_SERVICES) {
  # jq-free parse of VCAP_SERVICES for a redis-ish host/port
  $m  = [regex]::Match($env:VCAP_SERVICES, '"(?:host|hostname)"\s*:\s*"([^"]+)"')
  if ($m.Success)  { $rhost = $m.Groups[1].Value }
  $mp = [regex]::Match($env:VCAP_SERVICES, '"port"\s*:\s*(\d+)')
  if ($mp.Success) { $rport = $mp.Groups[1].Value }
}
if (-not $rhost) { Write-Output "no redis host (set REDIS_HOST or bind a redis service)"; while ($true) { Start-Sleep 30 } }
$rport = [int]$rport
Write-Output "fixture: holding a socket to ${rhost}:${rport}"

while ($true) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($rhost, $rport)
    $stream = $client.GetStream()
    $ping = [System.Text.Encoding]::ASCII.GetBytes("PING`r`n")   # keep the socket 'used'; not required
    while ($client.Connected) {
      try { $stream.Write($ping, 0, $ping.Length); $stream.Flush() } catch { break }
      Start-Sleep 10
    }
    $client.Close()
  } catch { Start-Sleep 5 }
}

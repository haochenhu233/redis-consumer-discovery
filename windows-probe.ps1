# windows-probe.ps1 (v2) -- RUN ON the windows diego cell hosting a known redis consumer.
# v1 confirmed: container connections are NOT in the default network compartment, and winc uses
# a NAT network (winc-nat), so redis sees the CELL ip (source-NAT). v2 tests the two ways to map
# a container->redis connection back to a CONTAINER IP (172.30.x.x), which then joins to an app
# via the global cfdot actual-lrps dump (instance_address). No CF_INSTANCE_GUID extraction needed.
#
# Invoke (from the cmd.exe shell `bosh ssh` gives you):
#   powershell -ExecutionPolicy Bypass -File C:\Windows\Temp\rcd.ps1 <redis_ip> [<redis_ip> ...]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$RedisIps)
function Emit($s){ Write-Output ("#WRCD#`t" + $s) }

Emit ("ps_version=" + $PSVersionTable.PSVersion.ToString())
Emit ("redis_ips_arg=" + ($RedisIps -join ','))

# --- 1. WinNAT session table: the cleanest path. Container IP = InternalSourceAddress. ----------
try {
  $nat = Get-NetNat -ErrorAction SilentlyContinue
  Emit ("netnat_instances=" + (@($nat).Count) + " names=" + (($nat | ForEach-Object { $_.Name }) -join ','))
  $sess = Get-NetNatSession -ErrorAction SilentlyContinue
  Emit ("netnat_sessions_total=" + @($sess).Count)
  # dump 2 full sessions so we learn the exact property names for the worker
  $sess | Select-Object -First 2 | ForEach-Object {
    Emit ("natsess_sample " + (($_ | Format-List * | Out-String -Width 500) -replace '\s*\r?\n\s*',' | ').Trim())
  }
  foreach ($rip in $RedisIps) {
    $hits = $sess | Where-Object { $_.InternalDestinationAddress -eq $rip -or $_.ExternalDestinationAddress -eq $rip }
    Emit ("netnat redis=" + $rip + " hits=" + @($hits).Count)
    $hits | Select-Object -First 20 | ForEach-Object {
      Emit ("natmap redis=" + $rip + " container_ip=" + $_.InternalSourceAddress + ":" + $_.InternalSourcePort +
            " extSrc=" + $_.ExternalSourceAddress + ":" + $_.ExternalSourcePort)
    }
  }
} catch { Emit ("Get-NetNatSession error: " + $_.Exception.Message) }

# --- 2. Per-compartment TCP: does Get-NetTCPConnection accept -CompartmentId? -------------------
$compIds = @()
try { $compIds = Get-NetCompartment -ErrorAction SilentlyContinue | ForEach-Object { $_.CompartmentId } } catch {}
Emit ("compartments=" + ($compIds -join ','))
foreach ($cid in $compIds) {
  if ($cid -eq 1) { continue }                       # skip default (host) compartment
  try {
    $cc = Get-NetTCPConnection -CompartmentId $cid -State Established -ErrorAction Stop
    Emit ("comp$cid established=" + @($cc).Count)
    $cc | Where-Object { $RedisIps -contains $_.RemoteAddress } | ForEach-Object {
      Emit ("compconn comp=" + $cid + " container_ip=" + $_.LocalAddress + ":" + $_.LocalPort + " redis=" + $_.RemoteAddress)
    }
  } catch { Emit ("comp$cid -CompartmentId error: " + $_.Exception.Message) }
}

# --- 3. HNS endpoints: full sample so we see where the compartment id / container id live --------
try {
  Get-HnsEndpoint | Select-Object -First 1 | ForEach-Object {
    Emit ("hnsep_sample " + ($_ | ConvertTo-Json -Depth 5 -Compress))
  }
  Get-HnsEndpoint | ForEach-Object { Emit ("hnsep ip=" + $_.IPAddress + " id=" + $_.ID) }
} catch { Emit ("Get-HnsEndpoint error: " + $_.Exception.Message) }

# --- 4. Containers on this cell (correlate container id <-> compartment desc \Container_<id>) ----
try {
  Get-ComputeProcess -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object {
    Emit ("computeproc id=" + $_.Id + " type=" + $_.Type)
  }
} catch { Emit ("Get-ComputeProcess error: " + $_.Exception.Message) }

Write-Output "#WRCD-DONE#"

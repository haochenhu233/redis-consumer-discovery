# windows-probe.ps1 -- RUN ON ONE windows diego cell to learn what we can see.
# We CANNOT use the linux mechanism (no netns/nsenter/ss). Goal of this probe: confirm
# whether the host can enumerate container->redis TCP connections and map them to a
# CONTAINER IP, which then joins to an app via the (global) cfdot actual-lrps dump -- the
# same instance_address join the linux path already uses. No env-var extraction needed.
#
# Invoke (from cmd.exe, which is what `bosh ssh` to a windows cell gives you):
#   powershell -ExecutionPolicy Bypass -File C:\Windows\Temp\rcd.ps1 <redis_ip> [<redis_ip> ...]
#
# All output lines are tagged #WRCD# so the bastion can grep them out of the ssh noise.
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$RedisIps)

function Emit($s){ Write-Output ("#WRCD#`t" + $s) }

Emit ("ps_version=" + $PSVersionTable.PSVersion.ToString())
try { Emit ("host=" + [System.Net.Dns]::GetHostName()) } catch { Emit "host=?" }

# 1) which cmdlets are available? (Get-NetTCPConnection is core; HNS cmdlets may need a module)
foreach ($c in 'Get-NetTCPConnection','Get-NetCompartment','Get-HnsEndpoint','Get-HnsNetwork','Get-ComputeProcess','hnsdiag') {
  $ok = [bool](Get-Command $c -ErrorAction SilentlyContinue)
  Emit ("cmdlet " + $c + " = " + $ok)
}
# HNS module sometimes needs importing before Get-HnsEndpoint resolves
if (-not (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue)) {
  foreach ($m in 'HostNetworkingService','HostComputeService','hns') {
    try { Import-Module $m -ErrorAction SilentlyContinue } catch {}
  }
  Emit ("after-import Get-HnsEndpoint = " + [bool](Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue))
}

# 2) network compartments (containers live in non-default compartments)
try {
  Get-NetCompartment -ErrorAction SilentlyContinue | ForEach-Object {
    Emit ("compartment id=" + $_.CompartmentId + " guid=" + $_.CompartmentGuid + " desc=" + $_.CompartmentDescription)
  }
} catch { Emit ("Get-NetCompartment error: " + $_.Exception.Message) }

# 3) THE KEY QUESTION: do established connections to the redis IP(s) show up, and with a
#    container-looking LocalAddress + a non-default CompartmentId? Enumerate the full table
#    once and filter (so we are not relying on -RemoteAddress searching every compartment).
try {
  $all = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
  Emit ("established_total=" + @($all).Count)
  foreach ($rip in $RedisIps) {
    $hits = $all | Where-Object { $_.RemoteAddress -eq $rip }
    Emit ("redis " + $rip + " established_hits=" + @($hits).Count)
    $hits | ForEach-Object {
      Emit ("conn redis=" + $rip + " local=" + $_.LocalAddress + ":" + $_.LocalPort + " pid=" + $_.OwningProcess + " comp=" + $_.CompartmentId)
    }
  }
} catch { Emit ("Get-NetTCPConnection error: " + $_.Exception.Message) }

# 4) HNS endpoints: the container-IP <-> compartment map. If (3) gives us a compartment or a
#    container LocalAddress, this ties it to the container IP that cfdot knows as instance_address.
try {
  if (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue) {
    Get-HnsEndpoint | ForEach-Object {
      $ip = $_.IPAddress; if (-not $ip) { $ip = ($_.Resources.Allocators | Where-Object { $_.EndpointIPAddress } | Select-Object -First 1).EndpointIPAddress }
      Emit ("hnsep ip=" + $ip + " id=" + $_.ID + " comp=" + $_.CompartmentId + " net=" + $_.VirtualNetworkName)
    }
  } else { Emit "hnsep skipped (Get-HnsEndpoint unavailable)" }
} catch { Emit ("Get-HnsEndpoint error: " + $_.Exception.Message) }

Write-Output "#WRCD-DONE#"

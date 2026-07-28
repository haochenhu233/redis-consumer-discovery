# windows-wsweep.ps1 -- RUNS ON a windows diego cell (scp'd there by cmd_sweep). Read-only.
# Windows containers source-NAT through winc-nat, so redis sees the CELL ip. The WinNAT session
# table still holds the real mapping: InternalSourceAddress = the CONTAINER ip. For each active
# session whose destination is one of the given redis IPs, emit (matching the linux worker shape):
#   #RCD#  <container_ip>  NOGUID  <redis_ip>
# container_ip joins to an app via the global cfdot dump (instance_address); NOGUID because we do
# not read CF_INSTANCE_GUID on windows -- the container ip is the join key (like the linux fallback).
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$RedisIps)
$ErrorActionPreference = 'SilentlyContinue'

$seen = @{}
Get-NetNatSession | ForEach-Object {
  $dst = $_.InternalDestinationAddress
  if (-not $dst) { $dst = $_.ExternalDestinationAddress }
  if ($RedisIps -contains $dst) {
    $cip = $_.InternalSourceAddress
    if ($cip) {
      $key = "$cip`t$dst"                       # one row per (container, redis); apps pool sockets
      if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        Write-Output ("#RCD#`t" + $cip + "`tNOGUID`t" + $dst)
      }
    }
  }
}
Write-Output "#RCD-DONE#"

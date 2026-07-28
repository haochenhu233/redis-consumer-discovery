# windows-wsweep.ps1 -- RUNS ON a windows diego cell (scp'd there by cmd_sweep). Read-only.
# Windows containers source-NAT through winc-nat, so redis sees the CELL ip. The WinNAT session
# table still holds the real mapping: InternalSourceAddress = the CONTAINER ip. For each active
# session whose destination is one of the given redis IPs, emit (matching the linux worker shape):
#   #RCD#  <container_ip>  NOGUID  <redis_ip>
# container_ip joins to an app via the global cfdot dump (instance_address); NOGUID because we do
# not read CF_INSTANCE_GUID on windows -- the container ip is the join key (like the linux fallback).
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$RedisIps)
$ErrorActionPreference = 'SilentlyContinue'

# SPACE-separated, IP-only payload: '#RCD# <container_ip> <redis_ip>'. No tabs -- the windows
# bosh-ssh PTY mangles tabs; the bastion parses this with an IP-anchored regex so fields can't drift.
$seen = @{}
Get-NetNatSession | ForEach-Object {
  $dst = $_.InternalDestinationAddress
  if (-not $dst) { $dst = $_.ExternalDestinationAddress }
  if ($RedisIps -contains $dst) {
    $cip = $_.InternalSourceAddress
    if ($cip) {
      $key = "$cip $dst"                         # one row per (container, redis); apps pool sockets
      if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        Write-Output ("#RCD# " + $cip + " " + $dst)
      }
    }
  }
}
Write-Output "#RCD-DONE#"

#requires -RunAsAdministrator
<#
.SYNOPSIS
  M9.R.8 Part 3 — thread Windows host -> WSL ``repro-cache`` distro for
  ``REPRO_BINARY_CACHE_URL=http://127.0.0.1:7878/`` publishes.

.DESCRIPTION
  The ``repro-cache`` WSL distro binds the cache HTTP server on its
  internal eth0 address (e.g. ``172.27.191.82:7878``), which is NOT
  routable from the Windows host's loopback stack because the WSL
  vEthernet adapter sits behind Hyper-V's NAT layer. The Windows
  ``mkBinaryCachePublisher`` factory reads the cache URL from
  ``REPRO_BINARY_CACHE_URL``; the natural value is
  ``http://127.0.0.1:7878/`` so publishes work without ambient
  WSL-aware logic in the publisher.

  This script bridges the two by installing a Windows
  ``netsh interface portproxy`` rule that forwards
  ``127.0.0.1:7878`` -> ``<wsl-eth0-ip>:7878`` on demand. Because the
  WSL distro's eth0 IP changes on each WSL boot, the rule must be
  re-installed any time the ``repro-cache`` distro is restarted; this
  script idempotently deletes the prior rule (if any) before adding
  the new one.

  After running this script, publishes from the Windows host succeed
  via the natural URL — no WSL-aware exec path in
  ``engine_publisher.nim`` (Option A per the M9.R.8 milestone
  description; the Option B publisher rewrite is left for a future
  pass if the maintenance overhead of re-running this script becomes
  a real burden).

.PARAMETER ListenPort
  Windows-side listen port. Default 7878.

.PARAMETER WslPort
  WSL-side connect port. Default 7878.

.PARAMETER WslDistro
  Name of the WSL distro hosting the cache server. Default
  ``repro-cache``.

.PARAMETER Healthcheck
  Optional URL to probe after installing the portproxy rule. When
  passed the script calls ``Invoke-WebRequest`` and writes the
  response status code; an HTTP failure is treated as fatal. Pass
  ``$null`` to skip.

.EXAMPLE
  D:\metacraft\reprobuild\tools\setup-wsl-cache-portproxy.ps1

  Installs the default 127.0.0.1:7878 -> repro-cache:7878 rule and
  health-checks ``http://127.0.0.1:7878/``.

.EXAMPLE
  D:\metacraft\reprobuild\tools\setup-wsl-cache-portproxy.ps1 -ListenPort 18787

  Same forwarding rule but the Windows host listens on 18787
  (handy if 7878 is already in use by something else).
#>

[CmdletBinding()]
param(
  [int] $ListenPort = 7878,
  [int] $WslPort = 7878,
  [string] $WslDistro = "repro-cache",
  [string] $Healthcheck = "http://127.0.0.1:{0}/"
)

$ErrorActionPreference = "Stop"

function Get-WslDistroIp {
  param([string] $Distro)
  # ``ip -4 -j a show eth0`` emits a JSON envelope listing every IPv4
  # address bound to eth0. The first ``addr_info[].local`` entry is
  # the distro's primary v4 address.
  $json = wsl.exe -d $Distro --user root --exec ip -4 -j a show eth0 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "wsl.exe failed (-d $Distro): $json"
  }
  $parsed = $json | ConvertFrom-Json
  if (-not $parsed) {
    throw "wsl.exe returned empty JSON for distro $Distro"
  }
  $addrInfo = $parsed[0].addr_info
  if (-not $addrInfo -or $addrInfo.Count -lt 1) {
    throw "no IPv4 addresses bound to eth0 in distro $Distro"
  }
  return $addrInfo[0].local
}

function Remove-PriorPortproxyRule {
  param([int] $ListenPort)
  # ``netsh interface portproxy delete`` is idempotent — calling it
  # for a nonexistent rule emits a non-fatal message. Swallow the
  # ``$LASTEXITCODE`` from a missing rule because the caller does not
  # care whether the prior rule existed.
  $null = netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=127.0.0.1 2>&1
}

function Add-PortproxyRule {
  param([int] $ListenPort, [string] $ConnectAddress, [int] $ConnectPort)
  $output = netsh interface portproxy add v4tov4 `
    listenport=$ListenPort `
    listenaddress=127.0.0.1 `
    connectport=$ConnectPort `
    connectaddress=$ConnectAddress 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "netsh add failed: $output"
  }
}

$wslIp = Get-WslDistroIp -Distro $WslDistro
Write-Output ("Resolved WSL distro '{0}' eth0 IPv4 = {1}" -f $WslDistro, $wslIp)

Remove-PriorPortproxyRule -ListenPort $ListenPort
Add-PortproxyRule -ListenPort $ListenPort -ConnectAddress $wslIp -ConnectPort $WslPort
Write-Output ("Installed portproxy 127.0.0.1:{0} -> {1}:{2}" -f $ListenPort, $wslIp, $WslPort)

if ($Healthcheck) {
  $url = $Healthcheck -f $ListenPort
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
    Write-Output ("Healthcheck {0} -> HTTP {1}" -f $url, $response.StatusCode)
  } catch {
    # Re-throw with the original URL so the operator can pin down the
    # failure quickly. Status 404 is still a "the server answered"
    # signal — only connect / timeout failures are fatal here.
    throw ("Healthcheck {0} failed: {1}" -f $url, $_.Exception.Message)
  }
}

Write-Output "Done. Set REPRO_BINARY_CACHE_URL=http://127.0.0.1:$ListenPort/ to publish via the proxy."

<#
.SYNOPSIS
    Starts the persistent repro-cache WSL service and keeps its distro alive.

.DESCRIPTION
    WSL does not count systemd services as foreground activity. Without a
    long-lived wsl.exe client, repro-cache is terminated shortly after a
    one-shot `systemctl start` command exits. This launcher runs the installed
    single-instance keepalive helper in the foreground of a hidden wsl.exe
    process.

    With -InstallStartupTask, an interactive-logon scheduled task is installed
    for the current user. The task remains running while the cache is available.
#>
[CmdletBinding()]
param(
  [string] $Distro = "repro-cache",
  [string] $TaskName = "Reprobuild Binary Cache Keepalive",
  [string] $Healthcheck = "http://127.0.0.1:7878/healthz",
  [switch] $InstallStartupTask
)

$ErrorActionPreference = "Stop"
$wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
$wslArguments = "-d $Distro -u root --exec /usr/local/bin/repro-binary-cache-keepalive"

if ($InstallStartupTask) {
  $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $action = New-ScheduledTaskAction -Execute $wsl -Argument $wslArguments
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $principal = New-ScheduledTaskPrincipal -UserId $userId `
    -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
  Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Keeps the persistent Reprobuild binary-cache WSL distro available." `
    -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
} else {
  Start-Process -FilePath $wsl -ArgumentList $wslArguments `
    -WindowStyle Hidden | Out-Null
}

if ($Healthcheck) {
  $lastError = $null
  foreach ($attempt in 1..30) {
    try {
      $response = Invoke-WebRequest -Uri $Healthcheck -UseBasicParsing -TimeoutSec 2
      if ($response.StatusCode -eq 200) {
        Write-Host "[start-repro-cache] ready: $Healthcheck"
        return
      }
    } catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 500
  }
  throw "cache did not become ready at $Healthcheck`: $lastError"
}

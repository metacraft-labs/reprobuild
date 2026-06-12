<#
  start-boot-vm.ps1 -- Start a boot-harness VM and tail its serial
  named pipe to stdout. The Python driver consumes that stream.

  We connect to the named pipe in DUPLEX mode so the Python side can
  write back to the VM (via the same powershell process's stdin) and
  have it land on COM1.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $VmName,
  [Parameter(Mandatory)] [string] $PipeName,
  [int] $ConnectTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

if (-not $VmName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: VmName must start with 'repro-test-boot-' (got '$VmName')."
  exit 2
}

# Start the VM (idempotent).
$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne 'Running') {
  Start-VM -Name $VmName | Out-Null
}

# Connect to the named pipe. Hyper-V is the SERVER end; we are the
# CLIENT. Open as InOut so we can both read serial output and write
# guest input.
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
  '.',
  $PipeName,
  [System.IO.Pipes.PipeDirection]::InOut,
  [System.IO.Pipes.PipeOptions]::Asynchronous)

try {
  $pipe.Connect($ConnectTimeoutSec * 1000)
} catch {
  Write-Error "Failed to connect to \\.\pipe\$PipeName within ${ConnectTimeoutSec}s: $($_.Exception.Message)"
  exit 3
}

# Read from the pipe and write to stdout. Concurrently read parent
# stdin and forward to the pipe. The Python driver reaps this process
# on close().

$stdout = [Console]::OpenStandardOutput()
$stdin  = [Console]::OpenStandardInput()

$buf = New-Object byte[] 4096

# Stdin -> pipe forwarder runs in a background runspace.
$ps = [PowerShell]::Create()
$null = $ps.AddScript({
  param($pipe, $stdin)
  try {
    $buf = New-Object byte[] 4096
    while ($true) {
      $n = $stdin.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $pipe.Write($buf, 0, $n)
      $pipe.Flush()
    }
  } catch {}
}).AddArgument($pipe).AddArgument($stdin)
$async = $ps.BeginInvoke()

try {
  while ($true) {
    $n = $pipe.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $stdout.Write($buf, 0, $n)
    $stdout.Flush()
  }
} catch {
  Write-Error "Pipe read loop failed: $($_.Exception.Message)"
} finally {
  try { $pipe.Dispose() } catch {}
  try { $ps.Stop() } catch {}
  try { $ps.Dispose() } catch {}
}

# Release-test lifecycle only. Run in an exclusive disposable Windows guest:
# RunQuota's default endpoint is host-wide. Never use this to service consumers.
param([string]$ArchiveDaemon, [string]$ArgumentFile)
$ErrorActionPreference = 'Stop'
# Win32 identity APIs (the handle, not a later PID lookup, owns cleanup):
# https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid
# https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes
# https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ReleaseRunQuota {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(uint rights, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint length);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr handle);
}
'@
function Connect-DefaultPipe {
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'runquota\runquotad', [IO.Pipes.PipeDirection]::InOut)
  try { $pipe.Connect(25); return $pipe }
  catch [TimeoutException] { $pipe.Dispose(); return $null }
  catch { $pipe.Dispose(); throw }
}
# Quote each native argument by the Windows CommandLineToArgvW convention.
function Quote-NativeArgument([string]$Value) {
  return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}
# Native flags such as literal -- must never pass through PowerShell's
# script parameter binder. Bash writes the original argv as NUL-delimited
# UTF-8; the final NUL frames the last argument, including an empty one.
function Read-CommandArguments([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0 -or $bytes[-1] -ne 0) { throw 'Unterminated release command argument file.' }
  $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  $parts = $text.Split([char[]]@([char]0), [StringSplitOptions]::None)
  if ($parts.Count -lt 3 -or -not $parts[0]) { throw 'Release command needs an executable and arguments.' }
  return [pscustomobject]@{ Command = $parts[0]; Arguments = @($parts[1..($parts.Count - 2)]) }
}
if (-not $ArchiveDaemon -or -not $ArgumentFile) { throw 'Release smoke requires ArchiveDaemon and ArgumentFile.' }
$invocation = Read-CommandArguments $ArgumentFile
$Command = $invocation.Command
$CommandArgs = $invocation.Arguments
$expected = [IO.Path]::GetFullPath($ArchiveDaemon)
$existing = Connect-DefaultPipe
if ($null -ne $existing) {
  $existing.Dispose()
  throw 'Release smoke unqualified: the default RunQuota endpoint is already occupied; use a fresh exclusive Windows guest.'
}
$createdAfter = [DateTime]::UtcNow.ToFileTimeUtc()
$server = [IntPtr]::Zero
$child = $null
$exitCode = 1
try {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Command
  $start.UseShellExecute = $false
  $start.Arguments = (($CommandArgs | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
  # Inherit ordinary stdout/stderr. No pipe reader or rewritten output stream.
  $child = [Diagnostics.Process]::Start($start)
  do {
    if ($server -eq [IntPtr]::Zero) {
      $pipe = Connect-DefaultPipe
      if ($null -ne $pipe) {
        try {
          [uint32]$serverPid = 0
          if (-not [ReleaseRunQuota]::GetNamedPipeServerProcessId($pipe.SafePipeHandle.DangerousGetHandle(), [ref]$serverPid)) { throw 'Cannot identify RunQuota pipe server.' }
          # Retain this handle before checking birth/image; PID reuse cannot
          # redirect the eventual cleanup to a different process.
          $candidate = [ReleaseRunQuota]::OpenProcess(0x101001, $false, $serverPid)
          if ($candidate -eq [IntPtr]::Zero) { throw 'Cannot retain RunQuota server handle.' }
          try {
            [long]$birth=0; [long]$ended=0; [long]$kernel=0; [long]$user=0
            $image = [Text.StringBuilder]::new(32768); [uint32]$length=32768
            if (-not [ReleaseRunQuota]::GetProcessTimes($candidate, [ref]$birth, [ref]$ended, [ref]$kernel, [ref]$user) -or
                -not [ReleaseRunQuota]::QueryFullProcessImageName($candidate, 0, $image, [ref]$length)) { throw 'Cannot authenticate RunQuota server identity.' }
            if ($birth -lt $createdAfter -or $birth -gt [DateTime]::UtcNow.ToFileTimeUtc() -or
                -not [StringComparer]::OrdinalIgnoreCase.Equals($expected, $image.ToString())) { throw 'RunQuota endpoint belongs to an unowned process; release smoke unqualified.' }
            $server = $candidate
            $candidate = [IntPtr]::Zero
          } finally { if ($candidate -ne [IntPtr]::Zero) { [void][ReleaseRunQuota]::CloseHandle($candidate) } }
        } finally { $pipe.Dispose() }
      }
    }
    $finished = $child.WaitForExit(25)
  } while (-not $finished)
  $exitCode = $child.ExitCode
  if ($exitCode -eq 0 -and $CommandArgs[0] -eq 'build' -and $server -eq [IntPtr]::Zero) {
    throw 'Release build returned success without an authenticated archive RunQuota server.'
  }
} finally {
  # Only the authenticated retained server handle is termination authority.
  # No process-name scan, PID reopen, prefix match, or foreign-endpoint stop.
  try {
    if ($server -ne [IntPtr]::Zero) {
      try {
        if ([ReleaseRunQuota]::WaitForSingleObject($server, 0) -ne 0) {
          if (-not [ReleaseRunQuota]::TerminateProcess($server, 0)) { throw 'Cannot stop the owned release-smoke RunQuota server.' }
        }
        if ([ReleaseRunQuota]::WaitForSingleObject($server, 30000) -ne 0) { throw 'Owned release-smoke RunQuota server did not exit.' }
      } finally { [void][ReleaseRunQuota]::CloseHandle($server) }
    }
  } finally {
    if ($null -ne $child) {
      try {
        if (-not $child.HasExited) {
          $child.Kill()
          if (-not $child.WaitForExit(30000)) { throw 'Release smoke command did not exit after refusal.' }
        }
      } finally { $child.Dispose() }
    }
  }
}
exit $exitCode

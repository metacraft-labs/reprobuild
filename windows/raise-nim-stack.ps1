param(
  # Absolute path to the nim.exe to patch. Empty => resolve `nim` from PATH.
  [string]$NimExe = "",
  # New main-thread stack reserve. 128 MB. nim.exe ships with the linker default
  # (~1 MB), which the Windows interface-extract of the full DSL-stdlib closure
  # overruns.
  [uint64]$StackBytes = 134217728
)

$ErrorActionPreference = 'Stop'

# Raise nim.exe's OWN thread stack so the Windows `.#release` interface-extract
# (`nim c` over the entire DSL-stdlib closure -- 100+ `--path`, an enormous
# module graph) stops crashing the compiler itself with
# STATUS_STACK_BUFFER_OVERRUN (0xC0000409, seen as exit code -1073740791). nim's
# deep sem/macro recursion blows the linker-default ~1 MB stack. `editbin /STACK`
# is the usual tool for this but needs MSVC (absent on the windows-diy runner:
# `vswhere.exe not found`), so patch the PE header's SizeOfStackReserve field
# directly -- the exact bytes editbin would rewrite, no toolchain required.
#
# `--passL:-Wl,--stack,...` in the extract command does NOT help: it sizes the
# OUTPUT binary (extract_runner.exe), not nim.exe.

if ([string]::IsNullOrWhiteSpace($NimExe)) {
  $cmd = Get-Command nim -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { throw "raise-nim-stack: nim not found on PATH and no -NimExe given" }
  $NimExe = $cmd.Source
}
if (-not (Test-Path -LiteralPath $NimExe)) {
  throw "raise-nim-stack: '$NimExe' does not exist"
}

$bytes = [System.IO.File]::ReadAllBytes($NimExe)

# DOS header: e_lfanew (offset to the PE header) is a DWORD at 0x3C.
$peOff = [System.BitConverter]::ToInt32($bytes, 0x3C)
if ($peOff -le 0 -or ($peOff + 0x78) -ge $bytes.Length) {
  throw "raise-nim-stack: implausible PE offset $peOff in '$NimExe'"
}
# PE signature 'P' 'E' 0 0.
if ($bytes[$peOff] -ne 0x50 -or $bytes[$peOff + 1] -ne 0x45 -or
    $bytes[$peOff + 2] -ne 0 -or $bytes[$peOff + 3] -ne 0) {
  throw "raise-nim-stack: PE signature not found at offset $peOff in '$NimExe'"
}

# Optional header begins after the 4-byte signature + 20-byte COFF file header.
$optOff = $peOff + 24
$magic = [System.BitConverter]::ToUInt16($bytes, $optOff)
if ($magic -ne 0x20B) {
  throw ("raise-nim-stack: expected a PE32+ (0x20B) 64-bit nim.exe but the " +
    "optional-header magic is 0x{0:X}; refusing to patch." -f $magic)
}

# PE32+ layout: SizeOfStackReserve is a ULONGLONG at optional-header offset 0x48.
$stackReserveOff = $optOff + 0x48
$current = [System.BitConverter]::ToUInt64($bytes, $stackReserveOff)
if ($current -ge $StackBytes) {
  Write-Host ("raise-nim-stack: '{0}' stack reserve already {1} bytes (>= {2}); leaving as-is." -f `
    $NimExe, $current, $StackBytes)
  exit 0
}

[System.BitConverter]::GetBytes([uint64]$StackBytes).CopyTo($bytes, $stackReserveOff)
[System.IO.File]::WriteAllBytes($NimExe, $bytes)

# Read back and confirm the field actually changed.
$after = [System.BitConverter]::ToUInt64([System.IO.File]::ReadAllBytes($NimExe), $stackReserveOff)
if ($after -ne $StackBytes) {
  throw "raise-nim-stack: patch verification failed ('$NimExe' reserve is $after, expected $StackBytes)"
}
Write-Host ("raise-nim-stack: patched '{0}' SizeOfStackReserve {1} -> {2} bytes." -f `
  $NimExe, $current, $after)

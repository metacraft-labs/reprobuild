# Hyper-V backend helpers

Three PowerShell scripts called by `lib/backends/hyperv.py`. They are
also usable standalone for manual operator debugging.

## Scripts

### `new-boot-vm.ps1`

Creates the VM, the VHDX, wires `COM1` to a named pipe, and attaches
the boot image (ISO or VHDX). Writes the VM name to stdout.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File new-boot-vm.ps1 `
  -VmName repro-test-boot-abc123 `
  -PipeName repro-test-boot-abc123-com1 `
  -VhdxPath $env:TEMP\repro-boot-harness\repro-test-boot-abc123.vhdx `
  -Generation 2 `
  -MemoryMB 1024 `
  -VhdxSizeGB 8 `
  -ImagePath C:\path\to\alpine.iso `
  -ImageKind iso
```

Pass `-DryRun` to skip image attachment (lifecycle smoke).

Secure Boot is disabled on Gen-2 (Hyper-V's UEFI MS Standard cert chain
does not accept the test ISOs).

### `start-boot-vm.ps1`

Starts the VM (idempotent) and connects to `\\.\pipe\<PipeName>` in
duplex mode. Streams serial output to stdout; forwards anything read
on stdin to the pipe so the harness can type at the guest.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File start-boot-vm.ps1 `
  -VmName repro-test-boot-abc123 `
  -PipeName repro-test-boot-abc123-com1
```

### `stop-boot-vm.ps1`

Force-stops + removes the VM, deletes the VHDX. Idempotent: safe to
run against a half-created VM or a missing one.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File stop-boot-vm.ps1 `
  -VmName repro-test-boot-abc123 `
  -VhdxPath $env:TEMP\repro-boot-harness\repro-test-boot-abc123.vhdx
```

## Safety

All three scripts hard-fail if `VmName` does not start with
`repro-test-boot-`. This is the standing project rule:
`wsl --unregister`-class destructive operations across the harness are
restricted to the `repro-*` namespace.

## Requirements

- Windows 10/11 Pro/Enterprise (or Server) with Hyper-V role enabled.
- PowerShell 5.1+ (PS7 also works).
- Administrator: required for `New-VM` / `Remove-VM` / `Set-VMComPort`.

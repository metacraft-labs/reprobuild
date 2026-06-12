# QEMU backend helpers

Fallback for hosts without Hyper-V (Home edition, ARM Windows, etc.).
Useful for fast local iteration: `qemu-system-x86_64.exe` boots in
seconds with `-nographic -serial stdio`.

## Install

```powershell
winget install QEMU.QEMU
# or
scoop install qemu
```

Verify:

```powershell
where.exe qemu-system-x86_64
qemu-system-x86_64 --version
```

## Use

### Via the harness

```powershell
python tools\boot-harness\harness.py boot `
  --backend qemu `
  --image C:\path\to\alpine.iso `
  --expect tools\boot-harness\tests\alpine-expect.json
```

### Manual

```powershell
.\run-iso.ps1 -IsoPath C:\path\to\alpine.iso
```

## UEFI

For UEFI test ISOs, supply an OVMF firmware via `-BiosPath`:

```powershell
.\run-iso.ps1 -IsoPath C:\path\to\uefi.iso -BiosPath C:\path\to\OVMF.fd
```

Hyper-V Gen-2 is the documented UEFI primary path; the QEMU UEFI path
exists for operator convenience.

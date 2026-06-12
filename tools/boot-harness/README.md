# boot-harness — ReproOS-MVP R0

A "did it actually boot?" harness for the ReproOS-MVP track. Takes a
bootable ISO / VHDX / tarball-rootfs, spins up a transient
VM-or-distro, captures the serial console, lets the caller assert on
what the system says (`expect 'login:' within 60s`), then tears
everything down cleanly — even on Ctrl-C.

## Backends

| Backend | When to use | What it exercises |
|---------|-------------|-------------------|
| `hyperv` | Primary path on Windows hosts with Hyper-V enabled (Pro/Enterprise/Server). Gen-2 UEFI by default; Gen-1 fallback for legacy BIOS ISOs. Serial via named pipe. | Bootloader + kernel + initramfs + userspace. |
| `qemu` | Fallback for hosts without Hyper-V (Home edition, ARM). Fast local iteration: `-nographic -serial stdio`. | Bootloader + kernel + initramfs + userspace. |
| `wsl2` | Inner dev loop for tarball-rootfs userspace correctness. `wsl --import` a rootfs.tar.gz; no kernel/bootloader exercised. | Userspace only. |

All three implement one assertion DSL (`lib/assertions.py`), so a
single `expect.json` works across backends modulo image-format
differences.

## CLI

```powershell
# Smoke: is the backend usable on this host?
python tools/boot-harness/harness.py validate --backend hyperv
python tools/boot-harness/harness.py validate --backend wsl2
python tools/boot-harness/harness.py validate --backend qemu

# Show usable backends at a glance.
python tools/boot-harness/harness.py list

# Boot + assert.
python tools/boot-harness/harness.py boot `
    --backend hyperv `
    --image C:\path\to\reproos.iso `
    --expect tools/boot-harness/tests/alpine-expect.json

# Hyper-V lifecycle smoke (no boot media).
python tools/boot-harness/harness.py boot --backend hyperv --dry-run
```

Every run writes a JSON record to
`boot-harness-out/<image-sha256>/<timestamp>.json` and a serial log to
`$env:TEMP\repro-boot-harness\<vm-name>.log`.

## Assertion DSL

`lib/assertions.py` exports a tiny vocabulary:

```python
from lib.assertions import BootAssertion

assertions = [
    BootAssertion(expect_line=r"login:", timeout_s=60.0,
                  send_after_match="root\n",
                  description="reach login prompt"),
    BootAssertion(expect_line=r"localhost:~#", timeout_s=30.0,
                  send_after_match="cat /etc/alpine-release\n",
                  description="root shell"),
    BootAssertion(expect_line=r"^3\.\d+\.\d+", timeout_s=10.0,
                  description="alpine release line"),
]
```

JSON equivalent (consumed by `harness.py boot --expect`):

```json
[
  {"expect_line": "login:", "timeout_s": 60, "send_after_match": "root\n",
   "description": "reach login prompt"},
  {"expect_line": "localhost:~#", "timeout_s": 30,
   "send_after_match": "cat /etc/alpine-release\n",
   "description": "root shell"},
  {"expect_line": "^3\\.\\d+\\.\\d+", "timeout_s": 10,
   "description": "alpine release line"}
]
```

`expect_within` chains: marker must appear first, then `expect_line`,
sharing one `timeout_s` budget.

## Safety + cleanup guarantees

- Every transient VM/distro carries the prefix `repro-test-boot-`.
  Every script in the harness hard-fails if asked to touch a name
  without that prefix. This is the standing project rule
  (`project_dotfiles_cross_os_migration.md`) for destructive WSL
  operations, extended to Hyper-V VMs.
- All transient files go to `$env:TEMP\repro-boot-harness\<vm-name>\`;
  nothing survives a successful run under the repo.
- Cleanup uses `try`/`finally` + `atexit`. Even on Ctrl-C or an
  unhandled exception in the caller, the backend driver runs its
  teardown helper. If teardown itself fails, the VM name is printed
  to stderr so an operator can sweep manually.
- The JSON outcome under `boot-harness-out/` is the only thing that
  persists under the repo, and that path is git-ignored.

## Known limitations (R0 → R1)

- Alpine ISO `sha256` is pinned to upstream's value in
  `tests/t_smoke_qemu_alpine.py`; if the smoke test is run before
  `ALPINE_ISO_SHA256` is filled in, the download proceeds without
  digest verification (R1 will tighten this).
- The QEMU backend on Windows speaks `-serial stdio`; some legacy
  Hyper-V images may emit CR/LF differently. The `LineBuffer` is
  newline-agnostic but very-old kernels that emit raw `\r` only have
  not been exercised.
- The Hyper-V backend currently assumes the host has the Hyper-V
  PowerShell module loaded. If it isn't, `validate --backend hyperv`
  reports the missing module.
- The WSL2 backend doesn't exercise a kernel or bootloader — it's the
  inner dev loop for userspace correctness only. R1 will run the full
  vendored systemd ISO through the Hyper-V + QEMU backends to
  validate the harness end-to-end against a real boot.

## Repository layout

```
tools/boot-harness/
├── README.md                  (this file)
├── harness.py                 (Python CLI: validate / list / boot)
├── lib/
│   ├── assertions.py          (LineBuffer + HarnessSession + BootAssertion DSL)
│   ├── outcome.py             (Outcome dataclass + JSON writer)
│   └── backends/
│       ├── hyperv.py          (drives PowerShell helpers under hyperv/)
│       ├── wsl2.py            (drives wsl.exe --import / -d / --unregister)
│       └── qemu.py            (drives qemu-system-x86_64.exe directly)
├── hyperv/                    (new/start/stop-boot-vm.ps1 + README)
├── wsl2/                      (import/run/tear-down.ps1 + README)
├── qemu/                      (run-iso.ps1 + README; install hints)
└── tests/
    ├── t_assertions.py        (DSL unit tests, no backend required)
    ├── t_outcome_json.py      (JSON schema stability)
    └── t_smoke_qemu_alpine.py (end-to-end Alpine boot, skips if QEMU absent)
```

## Verification

```powershell
. D:/metacraft/env.ps1
cd D:/metacraft/reprobuild

python tools/boot-harness/tests/t_assertions.py        # unit
python tools/boot-harness/tests/t_outcome_json.py      # schema
python tools/boot-harness/harness.py validate --backend qemu   # may FAIL (no QEMU)
python tools/boot-harness/harness.py validate --backend hyperv
python tools/boot-harness/harness.py validate --backend wsl2

# Hyper-V lifecycle smoke (admin required for New-VM):
python tools/boot-harness/harness.py boot --backend hyperv --dry-run

# Full Alpine smoke (only when QEMU is installed):
python tools/boot-harness/tests/t_smoke_qemu_alpine.py
```

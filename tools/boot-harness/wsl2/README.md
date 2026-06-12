# WSL2 backend helpers

Wrappers around `wsl.exe --import` / `wsl.exe -d <name>` /
`wsl.exe --unregister` for tarball-rootfs userspace iteration.

## When to use

- Inner dev loop for systemd-userspace correctness (no kernel, no
  bootloader). Iterates in seconds, not minutes.
- Smoke-test from a rootfs.tar.gz before paying the Hyper-V / QEMU
  full-VM cost.

## Scripts

### `import-rootfs.ps1`

```powershell
.\import-rootfs.ps1 `
  -InstanceName repro-test-boot-abc123 `
  -TarPath C:\path\to\rootfs.tar.gz `
  -InstallDir $env:TEMP\repro-boot-harness\repro-test-boot-abc123-wsl
```

### `run-in-rootfs.ps1`

```powershell
.\run-in-rootfs.ps1 -InstanceName repro-test-boot-abc123 -Command "cat /etc/os-release"
```

### `tear-down.ps1`

```powershell
.\tear-down.ps1 `
  -InstanceName repro-test-boot-abc123 `
  -InstallDir $env:TEMP\repro-boot-harness\repro-test-boot-abc123-wsl
```

## Safety

All three scripts hard-fail if the instance name does not start with
`repro-test-boot-`. The standing project rule (see project memory
`project_dotfiles_cross_os_migration.md`) restricts `wsl --unregister`
to the `repro-*` namespace.

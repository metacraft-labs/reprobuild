import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

## PROVISIONING ONLY -- there is no `executable bash:` / `cli:` block here,
## so `bash` names no build edge and carries no dependency or non-determinism
## policy. This matters when a `bash <script>` edge turns out to be
## uncacheable and the instinct is to write `nonDeterminism entropyBlessed`
## in this file: such a declaration would have nowhere to attach and would
## reach no edge. The tool identity of a `bash <script>` edge is `sh`, via
## `sh.nim`'s `shell()`, and the argument for leaving it UNBLESSED -- with
## the io-mon measurement it rests on -- is written out there and guarded by
## `tests/t_shell_entropy_is_not_blessed.nim`.

package bash:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/bash",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # linux x86_64: the static (musl) build from robxu9/bash-static -- one
    # self-contained executable, so the realization needs no host
    # libncurses or libc. A from-source bash is `local-only` and links the
    # host's ncurses, so it cannot be shared through the binary cache.
    tarball url = "https://github.com/robxu9/bash-static/releases/download/5.2.015-1.2.3-2/bash-linux-x86_64",
      sha256 = "64469a9512a00199c85622ec56f870f97d50457a4e06e0cfa39bae7adf0cc8f2",
      archiveType = "raw",
      executablePath = "bin/bash",
      version = "5.2.15",
      packageId = "bash-static@5.2.15",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:bash-static@5.2.15:linux-x86_64:sha256:64469a9512a00199c85622ec56f870f97d50457a4e06e0cfa39bae7adf0cc8f2"
    # Windows: there is no standalone `bash` Scoop package; bash is the
    # MSYS shell Git for Windows ships at `usr/bin/bash.exe`, through
    # Scoop's `main/git` or the pinned PortableGit archive. NOT
    # `bin/bash.exe`, Git's launcher, which puts `$HOME/bin` on PATH; see
    # `sh.nim`, which has the same two arms for the same reason.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/bash.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same PortableGit archive as `git.nim`. `version` is
    # bash's, not Git's: `usr/bin/bash.exe --version` in this archive
    # reports 5.3.9 (`etc/package-versions.txt`: bash 5.3.009-1).
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/bash.exe",
      version = "5.3.9",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

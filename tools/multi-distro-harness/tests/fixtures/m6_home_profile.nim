# nim-check: skip
#
# Linux-Distro-Recipe-Validation M6 — multi-distro home-apply test
# profile. Exercises the home-scope primitives that do NOT require
# GUI / Wayland / X (the repro-* WSL instances are headless): the
# whole-file writer (`fs.userFile`), the managed-block writer in the
# `shell.integration` form, the user env var (`env.userVariable`),
# and the POSIX user-path contribution (`env.userPath`).
#
# All managed paths sit under `~/.config/m6-test/` (or, for the shell-
# integration hook, a sibling `~/.config/m6-test/shell-hook.sh` file)
# so the test driver can verify materialization + drift + cleanup with
# a single recursive rm under that directory. The `env.userPath`
# contribution targets the test-seam shell rc declared via
# `REPRO_HOME_POSIX_PATH_RC` so the gate never touches the user's
# real ~/.bashrc / ~/.zshrc on the WSL instance.
#
# Cross-distro path conventions (Debian / Ubuntu / Arch / Fedora /
# Alpine all share `~/.config/` under `$HOME`) are uniform here — the
# milestone's question is whether the apply pipeline materializes
# every resource correctly given those paths, NOT whether the path
# layout differs per distro. Per-distro driver divergences (e.g.
# Debian's `/usr/share/bash-completion/` vs Fedora's
# `/etc/bash_completion.d/`) are system-scope and live in M7's
# infra-plan fixture.
#
# Hosts table: the fixture lists every `repro-*` hostname the harness
# might run under. `currentHost()` returns the lowercased system
# hostname on Linux (gethostname() / $HOSTNAME); for WSL instances
# imported via `wsl --import repro-<distro>` the kernel hostname is
# the distro's default (`archlinux`, `debian`, `ubuntu`, `fedora`,
# `alpine`). The test driver pins `REPRO_HOST=m6-test-host` ahead of
# `repro home apply` so the profile resolves to the `default`
# activity deterministically across distros without relying on the
# WSL-kernel hostname.

import repro_profile

profile "m6-multi-distro-home-profile":

  activity default:
    discard

  resources:
    # 1. Whole-file managed: a small marker file under
    #    `~/.config/m6-test/marker.txt`. The driver writes
    #    `content` byte-for-byte (modulo a trailing newline) at
    #    mode 0644; drift detection compares the live bytes to
    #    the declared `content`.
    fsUserFile(hostFile = "~/.config/m6-test/marker.txt",
      content = "m6: managed by reprobuild home apply\n",
      mode = "0644",
      address = "marker")

    # 2. Whole-file managed (executable): a small shell snippet
    #    under `~/.config/m6-test/hello.sh`. Mode 0755 so the
    #    file is directly runnable; the test driver execs it
    #    and asserts the stdout matches.
    fsUserFile(hostFile = "~/.config/m6-test/hello.sh",
      content = "#!/bin/sh\necho 'm6 hello'\n",
      mode = "0755",
      executable = true,
      address = "hello")

    # 3. User-scope env variable. On Linux the driver renders
    #    `export <name>=<value>` into the shared rc managed
    #    block (the same rc file the `env.userPath` driver
    #    writes to — see (4) below).
    envUserVariable(name = "REPRO_M6_HOME_APPLY",
      value = "1",
      address = "m6Var")

    # 4. PATH contribution. On Linux/POSIX the driver writes a
    #    managed block into the file named by
    #    `$REPRO_HOME_POSIX_PATH_RC` (test seam) or the shell-
    #    derived rc default. The test driver sets the env var to
    #    `~/.config/m6-test/path-rc.sh` so the contribution lands
    #    in an isolated file we own.
    envUserPath(entries = "/opt/repro-m6-test/bin",
      address = "m6Path")

    # 5. Shell integration: a managed block written via the
    #    shared managed-block writer. The block id namespaces the
    #    region so a second resource targeting the same host
    #    file does not clobber it. The test driver verifies the
    #    block sentinels (`# >>> repro:shell.integration:m6-hook >>>`
    #    / `# <<<`) are present in the host file post-apply.
    shellIntegration(hostFile = "~/.config/m6-test/shell-hook.sh",
      blockId = "m6-hook",
      content = "export REPRO_M6_SHELL_HOOK_FIRED=1",
      address = "m6Hook")

  hosts:
    "m6-test-host": [default]

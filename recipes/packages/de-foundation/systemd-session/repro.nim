## NDE0-S: native systemd-session package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-S.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## systemd_session.nim`` (precedent: NDE0-A's apt-jammy package +
## ``apt_jammy.nim`` shim).
##
## ## Why this layout
##
## The package spec calls for a typed-DSL surface:
##
##   files pamStacks:
##     build:
##       fs.configFile(
##         path = "/etc/pam.d/login",
##         content = textContent: ...)
##   files userAccount:
##     build:
##       fs.managedBlock(
##         path = "/etc/passwd",
##         blockId = "system-user-" & config.defaultUser,
##         content = textContent: ...)
##
## The current ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads — the ``files <name>:`` form spec'd in
## Package-Model.md §"Packaging Artifacts As Build Outputs" is purely
## spec at this point (NDE0-A documented the same limitation honestly).
## Consumer packages import the stdlib shim and invoke the
## emission procs from their ``build:`` body. The same pattern is used
## by ``recipes/bootstrap/tcc-chain/recipes/tcc/repro.nim`` which calls
## ``shell(command = ...)`` from a top-level ``build:`` block.
##
## ## Configurables
##
## Per the spec NDE0-S section. Each maps to a field on
## ``SystemdSessionConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it (the impl module's
## per-output ``configFile`` / ``managedBlock`` hashes propagate the
## change atomically; the unaffected outputs stay cached).
##
##   * ``defaultUser`` — propagates to /etc/passwd, /etc/group, and the
##     serial-getty autologin drop-in (cascade-A fix).
##   * ``defaultUid`` / ``defaultGid`` — propagate to /etc/passwd + /etc/group.
##   * ``defaultHome`` / ``defaultShell`` — propagate to /etc/passwd only.
##   * ``aptSnapshot`` — the apt-jammy pin for the PAM .deb input. v1
##     of NDE0-S records this in the package fingerprint but does NOT
##     extract PAM .debs (no libpam fixtures are vendored under
##     ``recipes/reproos-mvp-config/vendored-archives/linux/`` — see
##     "Honest deferrals" below).
##
## ## Honest deferrals
##
## * **PAM .so file emission**: NDE0-S v1 emits the PAM stack TEXT
##   files (``/etc/pam.d/login`` + friends) but does NOT extract the
##   corresponding ``pam_unix.so`` / ``pam_systemd.so`` binaries from
##   apt-jammy. The Tier-2 shell script's stage 1 (plant PAM modules
##   under ``/lib/x86_64-linux-gnu/security/``) is deferred until
##   ``libpam0g`` + ``libpam-modules`` .debs are vendored under
##   ``recipes/reproos-mvp-config/vendored-archives/linux/``. Consumers
##   that need the .so files today must continue to invoke the Tier-2
##   ``de0-systemd-session.sh`` script's stage 1, or supply their own
##   apt-jammy ``AptFiles`` handle via ``installAptDeb()`` with
##   pre-fetched .debs (the surface the impl module is built to consume
##   in a follow-up milestone).
##
## * **``fs.configFile`` / ``fs.managedBlock`` are minimal-viable
##   helpers** in the impl module — the full spec'd surface
##   (multi-contributor merge with priority sort, host-file drift
##   detection across generations, configurable-driven cache-key
##   composition through the DSL ``configurable`` resolution layer) is
##   deferred. NDE0-S's emission shape is forward-compatible: the
##   sentinel format is exactly the NDE-spec-block triple-form so a
##   future multi-contributor merge consuming this contribution sees
##   spec-shape-compatible blocks.
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-S emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# PAM/user/drop-in text. Imported here so it is in scope for downstream
# packages that ``uses: "systemd-session >=0.1.0"`` and inline a ``build:``
# block invoking the procs directly.
import repro_dsl_stdlib/packages/de_foundation/systemd_session as sessionImpl
export sessionImpl

package systemdSession:
  ## NDE0-S native systemd-session package.
  ##
  ## Downstream Tier-1 packages (NDE-H/G/K) ``uses:`` this and consume
  ## the exported ``materializeSystemdSession`` proc to obtain the
  ## emission outputs (PAM stacks, /etc/passwd + group blocks,
  ## autologin drop-in, logind un-mask, user-session targets).

  defaultToolProvisioning "path"

  config:
    ## The default unprivileged user account NDE0-S creates. Propagates
    ## to /etc/passwd, /etc/group, and the serial-getty autologin
    ## drop-in.
    defaultUser: string = "repro"

    ## User-namespace ID for the default user account. Spec'd as 1000
    ## per the Tier-2 ``de0-systemd-session.sh`` stage 5 contract.
    defaultUid: int = 1000

    ## Primary group ID for the default user account.
    defaultGid: int = 1000

    ## Home directory for the default user account. ``/etc/tmpfiles.d/``
    ## creates this on first boot with the right ownership (Tier-2
    ## stage 5 emits the tmpfiles.d snippet; NDE0-S v1 does NOT — see
    ## the Tier-2 fallback note in the module preamble).
    defaultHome: string = "/home/repro"

    ## Login shell. The R9 base ships busybox ash as /bin/sh; DE-H may
    ## overlay-replace with a real bash via its own package.
    defaultShell: string = "/bin/sh"

    ## The apt-jammy snapshot pin for the (deferred) PAM .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the whole
    ## package's emissions atomically — even when the .deb extraction
    ## is deferred, the fingerprint hygiene is preserved.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the PAM .deb
    ## input for the deferred stage 1 (.so file emission). v1 of NDE0-S
    ## records this dependency for fingerprint purposes but does not
    ## yet exercise ``installAptDeb()`` for libpam0g/libpam-modules
    ## (those .debs are not vendored).
    "apt-jammy >=0.1.0"

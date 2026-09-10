## Emit the HCR patchable build profile as shell-assignable variables.
##
## HLX-M1 follow-on. The Linux ELF HCR provider only accepts a target whose
## translation units were compiled with the patchable profile and whose image
## carries a build-id. Those flags are DEFINED in
## ``libs/repro_project_dsl/src/repro_project_dsl/runtime_core.nim``
## (``patchableCompileFlags``, ``patchableLinkFlags``), and every consumer that
## can call Nim already reads them from there — see
## ``tests/integration/t_integration_hcr_linux_elf_object_parsing_and_patch_plan.nim``
## and ``t_integration_hcr_linux_cf_protection_sled_layout.nim``.
##
## The patched Godot engine cannot: it is built by **scons**, from Python, in a
## different repo and a different nix shell. Without this emitter the only way
## to give scons the profile is to retype the flag strings into a SConstruct,
## which is exactly the drift the two gates above were written to prevent — and
## a drift with a silent failure mode, because a target built with the wrong
## ``-fpatchable-function-entry`` operand still links and still runs. It only
## fails much later, at patch time, as an ``absent-sled`` refusal that looks
## like a provider bug.
##
## So this program is the bridge: one process, no arguments, whose entire job is
## to print what the Nim definitions say, in a form ``sh`` can ``eval``. It is
## not a copy of the profile; it is a projection of it. Change the flags in
## ``runtime_core.nim`` and the next Godot build picks them up.
##
## Usage:
##
##   nim c -d:release --outdir:<dir> scripts/hcr_patchable_profile.nim
##   eval "$(<dir>/hcr_patchable_profile)"
##   #  -> HCR_PATCHABLE_CCFLAGS / HCR_PATCHABLE_LINKFLAGS in the environment
##
## The values are host-architecture dependent (``=16,0`` on x86_64, ``=4,0`` on
## aarch64), so it must be run on the machine that will do the build.

import std/strutils
import repro_project_dsl

proc shellQuote(value: string): string =
  ## Single-quote for ``sh``; there is no ``'`` in any flag today, but a
  ## profile change must not be able to turn this into an injection.
  "'" & value.replace("'", "'\\''") & "'"

proc emit(name: string; flags: seq[string]) =
  echo name & "=" & shellQuote(flags.join(" "))

when isMainModule:
  let tool = ReproHcr()
  let compileFlags = patchableCompileFlags(tool)
  let linkFlags = patchableLinkFlags(tool)

  # A profile that emits nothing is not a profile. On a host where the DSL has
  # no patchable answer we must say so loudly rather than hand scons an empty
  # string it would silently accept — the vacuous-check failure mode recorded
  # in `codetracer-specs/Testing/Verification-Harness-Traps.md`.
  if compileFlags.len == 0:
    stderr.writeLine("hcr_patchable_profile: patchableCompileFlags is empty on " &
      hostOS & "/" & hostCPU & "; refusing to emit an empty profile")
    quit(1)

  emit("HCR_PATCHABLE_CCFLAGS", compileFlags)
  emit("HCR_PATCHABLE_LINKFLAGS", linkFlags)
  echo "export HCR_PATCHABLE_CCFLAGS HCR_PATCHABLE_LINKFLAGS"

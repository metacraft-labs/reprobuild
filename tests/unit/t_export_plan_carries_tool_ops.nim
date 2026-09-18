## The shell-hook activation must PROVIDE the toolchain, not just name it.
##
## ``repro exec``, ``repro shell`` and ``repro run`` all put the realized
## packages on PATH. ``repro dev-env export`` did not — and that is the arm
## the SHELL HOOK composes, so it is the default for anyone who activates
## by ``cd``-ing into the project. The result was an environment that looks
## activated, sets a compiler, and resolves every tool from the ambient
## host PATH.
##
## Two properties have to hold together, and they pull against each other,
## which is why this is tested rather than assumed:
##
##   * the emitted plan CARRIES the tool ops, ahead of the recipe's own so
##     an explicit ``prependPath`` can still sit in front (the ordering
##     ``activationOps`` already uses, where these arrive as ``preOps``);
##   * ``dev-env deactivate`` RE-DERIVES the activation script from on-disk
##     state and re-hashes it, so a tool op the export emits and the
##     re-derivation does not recompute makes every deactivation of a
##     correctly-activated shell report tampering.
##
## The second is why both arms call one function. These cases pin the
## conversion both of them go through.

import std/[strutils, unittest]

import repro_cli_support/dev_env_shell_export
import repro_provider_runtime/types

proc prepend(name, value: string): DevEnvShellOp =
  DevEnvShellOp(kind: deskPrependPath, name: name, value: value,
    separator: ";")

proc setEnv(name, value: string): DevEnvShellOp =
  DevEnvShellOp(kind: deskSetEnv, name: name, value: value)

suite "an export plan can carry ops that are not in the artifact":

  test "shell ops convert to export ops of the matching kind":
    let plan = shellOpsToExportPlan(@[
      prepend("PATH", "/store/rustc/bin"),
      setEnv("CC", "cl.exe")])
    check plan.len == 2
    check plan[0].kind == opPrependPath
    check plan[0].pathName == "PATH"
    check plan[0].segment == "/store/rustc/bin"
    check plan[1].kind == opSet
    check plan[1].name == "CC"

  test "an empty op list is an empty plan, not a malformed one":
    # The case a project with no `uses:` takes, and the one that must not
    # emit a stray entry into a shell script.
    check shellOpsToExportPlan(@[]).len == 0

  test "tool ops concatenate ahead of the artifact's own":
    # The ordering the activation contract fixes: a provisioned package is
    # the DEFAULT the recipe asked for, so the recipe's own prepend has to
    # be able to land in front of it. Each `prependPath` puts its value at
    # the head when it runs, so emitting the toolchain FIRST leaves the
    # recipe's entry in front.
    var plan = shellOpsToExportPlan(@[prepend("PATH", "/store/rustc/bin")])
    plan.add(shellOpsToExportPlan(@[prepend("PATH", "node_modules/.bin")]))
    check plan.len == 2
    check plan[0].segment == "/store/rustc/bin"
    check plan[1].segment == "node_modules/.bin"

  test "the same ops render identically through the same converter":
    # The property the tamper seal depends on. `dev-env export` and
    # `dev-env deactivate` build their plans separately; if the two could
    # render the same ops differently, the re-derived hash would never
    # match and every deactivation would report tampering.
    let ops = @[prepend("PATH", "/store/node"), setEnv("AH_DEV_MODE", "1")]
    let a = shellOpsToExportPlan(ops)
    let b = shellOpsToExportPlan(ops)
    check a.len == b.len
    for i in 0 ..< a.len:
      # `ExportOp` is a variant object, so each branch is compared on its
      # OWN fields -- reading `name` off a path op is a FieldDefect, not a
      # mismatch, and a test that did it would fail for the wrong reason.
      check a[i].kind == b[i].kind
      case a[i].kind
      of opSet:
        check a[i].name == b[i].name
        check a[i].value == b[i].value
      of opUnset:
        check a[i].unsetName == b[i].unsetName
      of opPrependPath, opAppendPath:
        check a[i].pathName == b[i].pathName
        check a[i].segment == b[i].segment
        check a[i].separator == b[i].separator
      of opMarker:
        check a[i].markerName == b[i].markerName
        check a[i].markerValue == b[i].markerValue

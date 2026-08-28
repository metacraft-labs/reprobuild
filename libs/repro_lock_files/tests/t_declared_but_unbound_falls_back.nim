## NLF-STAT-2 — a declared name with no binding resolves under `default` and
## does NOT error.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-STAT-2**: "A declared name with
## no `path =` and no `--lock` binding resolves under `default` and does NOT
## error — deliberately the opposite of NLF-STAT-1."
##
## Design §5.3 gives the resolution order and, unusually, states the absence
## of a third case as part of the rule:
##
## > 1. The declaration's **committed `path =`** field, if it has one (§4.2).
## > 2. Otherwise the **workspace lock file** (`default`).
## > 3. There is no third case, and in particular **no error for an unbound
## >    lock file**.
##
## And the distinction from §4.9, which is the reason this case exists beside
## NLF-STAT-1 rather than instead of it:
##
## > - **undeclared symbol** → compile error. The author wrote a name that
## >   means nothing. Nothing sensible can be done.
## > - **declared but unbound lock file** → falls back to `default`. The author
## >   expressed a *potential* boundary that this invocation did not exercise.
## >   Collapsing it is correct and is precisely the behaviour that makes the
## >   mechanism free when unused: a recipe fully annotated with `lockFile
## >   hostTools` designations builds identically to an unannotated one until
## >   someone binds the lock file to a different lock.
##
## > That property — annotation is inert until bound — is what makes §11 a
## > non-event.
##
## ## Why the last test is here and not in the migration file
##
## "Annotation is inert until bound" is the same property NLF-STAT-3 measures
## in fingerprints. It is asserted here at the RESOLUTION layer as well,
## because the two can come apart: a resolution that fell back to `default`
## but recorded a distinguishable marker would satisfy this file and move
## every fingerprint beneath the annotated artifact.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## `resolveLockFilePath` and `resolvedPathFor` are the production resolution;
## nothing here re-implements §5.3.

import std/[tables, unittest]

import repro_lock_files

const
  HostTools = "hostTools"
  Unbound = "experimentalLock"
  Committed = "targetRuntime"

suite "NLF-STAT-2 a declared but unbound lock file falls back to default":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(Unbound,
      description = "Declared, never bound, and that is fine.")
    discard declareLockFile(Committed, path = "locks/aarch64.lock")

  test "it resolves, and it does not raise":
    # The whole of §5.3 case 2. An implementation that treated an unbound
    # declaration the way §4.9 treats an undeclared one would make declaring a
    # lock file a commitment to binding it, which is the opposite of the
    # design.
    var b = initLockBindings()
    b.applyLockFlag("locks/repro.lock")
    check b.resolvedPathFor(Unbound) == "locks/repro.lock"

  test "and it resolves even when `default` itself is unbound":
    # With nothing bound at all, `default` has no path, so the fallback
    # terminates at the empty string rather than recursing. `""` is the
    # workspace's own conventional lock location, which is what every
    # pre-NLF-M7 invocation already used.
    let b = initLockBindings()
    check b.resolvedPathFor(Unbound) == ""
    check b.resolvedPathFor(DefaultLockFileName) == ""

  test "a committed `path =` is used before the fallback":
    let b = initLockBindings()
    check b.resolvedPathFor(Committed) == "locks/aarch64.lock"

  test "the well-known names fall back too":
    var b = initLockBindings()
    b.applyLockFlag("locks/repro.lock")
    check b.resolvedPathFor(HostTools) == "locks/repro.lock"

  test "it is deliberately the OPPOSITE of the undeclared case":
    # Stated as an assertion so the pair cannot drift into agreeing. NLF-STAT-1
    # is a compile error; this one is not an error at any layer.
    check isDeclaredLockFile(Unbound)
    check not isDeclaredLockFile("neverDeclared")
    var b = initLockBindings()
    var raised = false
    try:
      b.applyLockFlag("neverDeclared=locks/x.lock")
    except LockFileError:
      raised = true
    check raised
    # …while binding nothing at all for a DECLARED name raises nothing.
    var b2 = initLockBindings()
    check b2.resolvedPathFor(Unbound) == ""

  test "annotation is inert until bound: the same path for every name":
    # §5.3's closing claim, and §11's whole basis. With one binding for
    # `default` and nothing else, every declared name resolves to the same
    # lock — so a fully annotated workspace and an unannotated one consume
    # the identical file.
    var b = initLockBindings()
    b.applyLockFlag("locks/repro.lock")
    resetLockFileDeclarations()
    discard declareLockFile(Unbound)
    discard declareLockFile("anotherOne")
    for name in [DefaultLockFileName, HostTools, Unbound, "anotherOne"]:
      check b.resolvedPathFor(name) == "locks/repro.lock"

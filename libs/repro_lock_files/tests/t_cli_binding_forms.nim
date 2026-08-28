## NLF-CLI-1 through NLF-CLI-4 — the `--lock` binding grammar.
##
## Named-Lock-Files NLF-M7, design §5.1 and §5.2. Four corpus cases, all about
## one flag:
##
##   * **NLF-CLI-1** — one file, several names, one set of actions.
##   * **NLF-CLI-2** — binding an undeclared name errors.
##   * **NLF-CLI-3** — `--lock <path>` still binds `default`; the forms are
##     distinguished by `=`.
##   * **NLF-CLI-4** — two bindings for `default` is an error, not last-wins.
##
## §5.1 and §5.2, in the design's own words:
##
## > **One flag, not two.** `--lock` is the existing whole-build flag (§2.3)
## > generalised: with an `=` it binds a named lock file, without one it binds
## > `default`. A separate `--lock-file` flag alongside `--lock` would be two
## > spellings for one concept, which §2.3 warns against.
##
## > Binding a lock file that is not declared anywhere in the workspace is an
## > **error**, not a silent no-op — symmetrically with §4.9, and for the same
## > reason: a mistyped `--lock hostTool=…` that was quietly ignored would
## > produce a green build of the wrong thing.
##
## > Two bindings for `default` in one invocation (`--lock a.lock --lock
## > default=b.lock`) is an error, not a precedence puzzle.
##
## ## What is asserted, and what would be too weak
##
## NLF-CLI-2 and NLF-CLI-4 assert on the DIAGNOSTIC, not merely on the throw.
## A binding failure that reported "invalid argument" would satisfy a bare
## `expect LockFileError` while telling an operator nothing about which name
## was wrong or what the alternatives are — and §4.9's whole argument for the
## symbol design is that this class of mistake deserves a diagnostic, not just
## a rejection.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## `applyLockFlag` is the real parser the CLI's `--lock` arm calls, and
## `resolvedPathFor` is the real §5.3 resolution. Nothing here re-implements
## either.

import std/[strutils, tables, unittest]

import repro_lock_files

const
  HostTools = "hostTools"
  TargetRuntime = "targetRuntime"

proc workspaceDeclarations() =
  resetLockFileDeclarations()
  discard declareLockFile(TargetRuntime,
    description = "Everything we ship.",
    sourceFile = "workspace.nim", sourceLine = 16)

suite "NLF-CLI-1..4 the --lock binding grammar":

  setup:
    workspaceDeclarations()

  test "NLF-CLI-1: one file, several names, one set of actions":
    # §5.1's "I am not cross-compiling today" spelling. Under §6.2 it costs
    # nothing: "both names resolve to one lock file's content, so one set of
    # artifacts is built and shared (§8)."
    var b = initLockBindings()
    b.applyLockFlag("hostTools,targetRuntime=locks/native.lock")
    check b.boundNames() == @[HostTools, TargetRuntime]
    check b.resolvedPathFor(HostTools) == "locks/native.lock"
    check b.resolvedPathFor(TargetRuntime) == "locks/native.lock"
    # One file, so one lock file, so one set of artifacts. The sharing is
    # §6.2's consequence and is asserted at the identity layer by
    # `t_lock_identity_two_names_one_content`; here the property is that the
    # binding produced one PATH for both names rather than two.
    check b.resolvedPathFor(HostTools) == b.resolvedPathFor(TargetRuntime)

  test "NLF-CLI-2: binding an undeclared name is an error":
    var b = initLockBindings()
    var message = ""
    try:
      b.applyLockFlag("hostTool=locks/host.lock")
    except LockFileError as err:
      message = err.msg
    check message.len > 0
    # On the diagnostic, not merely on the throw.
    check "unknown lock file `hostTool`" in message
    check "in scope here:" in message
    check "did you mean `hostTools`?" in message
    # And nothing was bound, so a caller that swallowed the error would not
    # find a half-applied binding waiting for it.
    check b.boundNames().len == 0

  test "NLF-CLI-2: and the descriptions are in the listing it prints":
    # §4.2's consumer (2): the diagnostic "should print each name's
    # description alongside it. The §4.9 diagnostic is exactly where a reader
    # who typed the wrong name learns what the right ones mean."
    var b = initLockBindings()
    var message = ""
    try:
      b.applyLockFlag("targetRuntim=locks/x.lock")
    except LockFileError as err:
      message = err.msg
    check "Everything we ship." in message
    check "workspace.nim:16" in message

  test "NLF-CLI-3: `--lock <path>` still binds default":
    # §5.2: the un-named form "is exactly `--lock default=<path>`. It is
    # retained … and is **not** deprecated."
    var bare = initLockBindings()
    bare.applyLockFlag("locks/repro.lock")
    check bare.boundNames() == @[DefaultLockFileName]
    check bare.resolvedPathFor(DefaultLockFileName) == "locks/repro.lock"

    var named = initLockBindings()
    named.applyLockFlag("default=locks/repro.lock")
    check named.boundNames() == bare.boundNames()
    check named.resolvedPathFor(DefaultLockFileName) ==
      bare.resolvedPathFor(DefaultLockFileName)

  test "NLF-CLI-3: the forms are distinguished by `=` and nothing else":
    # A path containing a slash, a dot and a dash still binds `default`; a
    # value containing `=` is read as the named form. If the discriminator
    # were anything else — a heuristic on "does this look like a path" — the
    # two forms would overlap somewhere and the overlap would be silent.
    var b = initLockBindings()
    b.applyLockFlag("./locks/aarch64-native.lock")
    check b.boundNames() == @[DefaultLockFileName]

  test "NLF-CLI-4: two bindings for default is an error, not last-wins":
    var b = initLockBindings()
    b.applyLockFlag("a.lock")
    var message = ""
    try:
      b.applyLockFlag("default=b.lock")
    except LockFileError as err:
      message = err.msg
    check "bound twice" in message
    check "a.lock" in message
    check "b.lock" in message
    # Last-wins would have left `b.lock` in place; the first binding stands
    # and the invocation fails.
    check b.resolvedPathFor(DefaultLockFileName) == "a.lock"

  test "NLF-CLI-4: and it is an error across the two SPELLINGS":
    # The interesting half. §5.2's example uses one of each form, so an
    # implementation that treated `--lock <path>` and `--lock default=<path>`
    # as different flags would let the pair through — which is exactly the
    # "precedence puzzle" the rule exists to refuse.
    var b = initLockBindings()
    b.applyLockFlag("default=b.lock")
    var raised = false
    try:
      b.applyLockFlag("a.lock")
    except LockFileError:
      raised = true
    check raised

  test "a declared but unbound name falls back to default (§5.3)":
    # NLF-STAT-2's property seen from the binding side, asserted here because
    # this is where the resolution actually happens.
    var b = initLockBindings()
    b.applyLockFlag("locks/repro.lock")
    check b.resolvedPathFor(HostTools) == "locks/repro.lock"

  test "a declaration's committed path outranks the default fallback":
    # §5.3 step 1: "The declaration's **committed `path =`** field, if it has
    # one (§4.2). This is the normal case: bindings are committed, not typed
    # at a prompt."
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime, path = "locks/aarch64.lock",
      description = "Everything we ship.")
    var b = initLockBindings()
    b.applyLockFlag("locks/repro.lock")
    check b.resolvedPathFor(TargetRuntime) == "locks/aarch64.lock"
    check b.resolvedPathFor(HostTools) == "locks/repro.lock"

  test "an explicit binding outranks the declaration's committed path":
    # §5.1: "an explicit binding **overrides the committed `path =` in that
    # name's declaration** (§4.2) for that invocation only."
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime, path = "locks/aarch64.lock")
    var b = initLockBindings()
    b.applyLockFlag("targetRuntime=locks/today.lock")
    check b.resolvedPathFor(TargetRuntime) == "locks/today.lock"

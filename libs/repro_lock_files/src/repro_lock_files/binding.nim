## `--lock` — one flag, two forms, distinguished by `=`.
##
## Named-Lock-Files NLF-M7, design §5.1 and §5.2.
##
## > **One flag, not two.** `--lock` is the existing whole-build flag (§2.3)
## > generalised: with an `=` it binds a named lock file, without one it binds
## > `default`. A separate `--lock-file` flag alongside `--lock` would be two
## > spellings for one concept, which §2.3 warns against.
##
## Three properties this module exists to hold, each of which is a corpus case:
##
##   * **NLF-CLI-1** — one file, several names, one set of actions:
##     `--lock hostTools,targetRuntime=locks/native.lock` binds both. Under
##     §6.2 that costs nothing, "both names resolve to one lock file's content,
##     so one set of artifacts is built and shared".
##   * **NLF-CLI-2** — binding an undeclared name is an **error**, not a silent
##     no-op, "symmetrically with §4.9, and for the same reason: a mistyped
##     `--lock hostTool=…` that was quietly ignored would produce a green build
##     of the wrong thing".
##   * **NLF-CLI-4** — two bindings for `default` in one invocation "is an
##     error, not a precedence puzzle". Including the case where one of them
##     arrived through the bare `--lock <path>` form, since §5.2 says that form
##     "is exactly `--lock default=<path>`" and an implementation that treated
##     them as different flags would let the pair through.

import std/[algorithm, strutils, tables]

import ./declarations

type
  LockBindings* = object
    ## The name → path assignments for one invocation.
    byName*: Table[string, string]
    order*: seq[string]
      ## Names in the order they were bound, so a diagnostic can name the
      ## FIRST binding of a duplicated name rather than an arbitrary one.

proc initLockBindings*(): LockBindings =
  LockBindings(byName: initTable[string, string](), order: @[])

proc boundNames*(b: LockBindings): seq[string] =
  result = @[]
  for n in b.order: result.add(n)
  result.sort()

proc bindLockFile*(b: var LockBindings; name, path: string) =
  ## Bind one name. Raises on a second binding of the same name (NLF-CLI-4)
  ## and on an undeclared name (NLF-CLI-2).
  if not isDeclaredLockFile(name):
    var msg = "unknown lock file `" & name & "`\n" &
      "  --lock " & name & "=" & path & "\n" &
      "  no lock file with that name is declared in this workspace.\n\n" &
      "  in scope here:\n"
    for line in inScopeListingLines():
      msg.add(line & "\n")
    let suggestion = suggestLockFileName(name)
    if suggestion.len > 0:
      msg.add("\n  did you mean `" & suggestion & "`?\n")
    raise newException(LockFileError, msg)
  if b.byName.hasKey(name):
    raise newException(LockFileError,
      "lock file `" & name & "` is bound twice in one invocation\n" &
      "  first:  " & b.byName[name] & "\n" &
      "  second: " & path & "\n" &
      "  this is an error rather than a precedence puzzle; pass one " &
      "binding per name.")
  b.byName[name] = path
  b.order.add(name)

proc applyLockFlag*(b: var LockBindings; value: string) =
  ## Apply one `--lock` occurrence.
  ##
  ## §5.2: "The two forms are distinguished by the presence of `=`." A value
  ## with no `=` is `--lock default=<value>` — the existing whole-build
  ## spelling, retained and NOT deprecated.
  ##
  ## The split is on the FIRST `=`, so a path containing `=` still binds
  ## correctly once a name precedes it, and a bare path containing `=` is the
  ## one ambiguity the grammar has. It resolves toward the named form, which
  ## is the safe direction: the named form validates the name against the
  ## declarations and therefore ERRORS on a path misread as a name, while the
  ## reverse mistake would silently bind `default` to a path that is not one.
  let eq = value.find('=')
  if eq < 0:
    b.bindLockFile(DefaultLockFileName, value)
    return
  let namePart = value[0 ..< eq]
  let path = value[eq + 1 .. ^1]
  for raw in namePart.split(','):
    let name = raw.strip()
    if name.len == 0: continue
    b.bindLockFile(name, path)

proc resolvedPathFor*(b: LockBindings; name: string): string =
  ## §5.3's resolution for one name under these bindings.
  resolveLockFilePath(name, b.byName)

# ---------------------------------------------------------------------------
# The invocation's bindings, where the build path can reach them
# ---------------------------------------------------------------------------

var activeBindings {.threadvar.}: LockBindings
var activeBindingsInit {.threadvar.}: bool

proc resetActiveLockBindings*() =
  ## Drop the invocation's bindings, leaving §5.3's unbound behaviour: every
  ## name resolves to `default`'s lock. Called between test scenarios; the
  ## CLI calls it nowhere, because an invocation has exactly one binding set.
  activeBindings = initLockBindings()
  activeBindingsInit = true

proc setActiveLockBindings*(b: LockBindings) =
  ## Record the bindings THIS invocation parsed off `--lock`, so the build
  ## path can resolve a lock file per NAME.
  ##
  ## Named-Lock-Files NLF-M8, folded from NLF-M7. M7 landed the grammar, the
  ## validation, the errors and §5.3's resolution, all tested — and then the
  ## build path read only `default`'s binding out of the result, because
  ## `--lock hostTools=…` could not mean anything until §9 settled what
  ## happens where two graphs meet. So the flag parsed, validated, and
  ## governed nothing: "a flag that parses and then quietly governs one
  ## graph".
  ##
  ## This is process state rather than a parameter for the same reason the
  ## designation stack in `declarations.nim` is: the consumer is
  ## `governingLockIdentityFor`, which is called once per EDGE from deep
  ## inside graph lowering, and threading an invocation-level fact through
  ## every lowering signature to reach it would put a `--lock` parameter on
  ## functions that have nothing to do with the CLI.
  activeBindings = b
  activeBindingsInit = true

proc activeLockBindings*(): LockBindings =
  ## The invocation's bindings, or an empty set when nothing was bound.
  if not activeBindingsInit:
    activeBindings = initLockBindings()
    activeBindingsInit = true
  activeBindings

proc activeLockFilePath*(name: string): string =
  ## §5.3's resolution for `name` under the invocation's bindings.
  ##
  ## Returns `""` for "no explicit path" — which §5.3 case 3 makes the
  ## workspace lock file, whatever the caller's convention for naming it is.
  ## This module has no idea where a workspace keeps its committed lock and
  ## deliberately does not learn: §6.2 forbids the name from entering any key,
  ## and the way that is kept structural is that this library never composes a
  ## name with a path it resolved itself.
  activeLockBindings().resolvedPathFor(name)

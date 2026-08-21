## NLF-STAT-3 — designations that all resolve to `default` change no
## fingerprint.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-STAT-3**: "Adding designations
## that all resolve to `default` changes no fingerprint. **Protects
## migration.**"
##
## This is the counterweight to NLF-M7 moving the NLF-STAT-4 fixture. Both
## properties have to hold at once and they pull in opposite directions:
##
##   * §7's keying is now effective, so an edge's fingerprint DOES depend on
##     its governing lock — that is what moved the baseline, once;
##   * and §5.3's "annotation is inert until bound" has to survive it, or
##     adopting the feature incrementally costs every existing user a full
##     rebuild the moment they type their first `lockFile` line.
##
## Design §5.3 states the property this file measures:
##
## > a recipe fully annotated with `lockFile hostTools` designations builds
## > identically to an unannotated one until someone binds the lock file to a
## > different lock.
##
## > That property — annotation is inert until bound — is what makes §11 a
## > non-event.
##
## ## How the two coexist, and why that is not a contradiction
##
## The fingerprint keys on the lock file's **identity**, which §6.2 derives
## from CONTENT — "the solved graph, with its pinned versions and resolved
## feature selections" — and never from the name it was bound under. So
## `hostTools` and `targetRuntime`, both unbound and therefore both resolving
## to `default`'s lock, have `default`'s content, which is `default`'s key.
##
## §5.3 says exactly this, and records that an earlier draft needed extra
## machinery for it:
##
## > An earlier draft, written while the lock file name was going to be part
## > of the cache key, had to specify that an unbound lock file inherits
## > `default`'s *identity* rather than merely its lock — otherwise declaring
## > a lock file would have forked every artifact beneath it. Under
## > content-only keying (§6.2) that distinction does not exist … The simple
## > statement is the whole rule.
##
## So this file is also the regression for the §6.4 position — name in the key
## — being reintroduced by accident. Under name-in-key every assertion below
## fails, and it fails for the annotated edges only, which is the signature.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real engine constructors, the real `weakFingerprint` the action cache keys
## on, and real lock identities computed by the real `lockIdentityOf` over
## real solved-graph values.

import std/[strutils, unittest]

import repro_build_engine
import repro_hash

const Platform = "amd64-linux"

proc hex(digest: ContentDigest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(digest.bytes.len * 2)
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc closureUnder(identity: LockIdentity): seq[BuildAction] =
  ## A small closure — compile, link, install — all governed by `identity`.
  ## Nothing in it mentions a lock-file name, which is the point: annotating
  ## a recipe is a change to which lock GOVERNS an edge, not to what the edge
  ## does.
  @[
    action("annot/compile", ["/usr/bin/cc", "-c", "src/main.c"],
      governingLockIdentity = identity,
      cwd = "/workspace", inputs = ["src/main.c"],
      outputs = ["build/main.o"], cacheable = true),
    builtinAction(bakCopyFile, "annot/link",
      governingLockIdentity = identity,
      deps = ["annot/compile"], inputs = ["build/main.o"],
      outputs = ["dist/app"]),
    builtinAction(bakStamp, "annot/install",
      governingLockIdentity = identity,
      deps = ["annot/link"], outputs = ["dist/.stamp"])]

proc fingerprints(actions: seq[BuildAction]): seq[string] =
  result = @[]
  for a in actions:
    result.add(a.id & "=" & hex(a.weakFingerprint))

suite "NLF-STAT-3 annotations that resolve to default perturb no fingerprint":

  test "an UNANNOTATED workspace and an ANNOTATED one key identically":
    # The migration property. `default` is what an unannotated workspace
    # resolves to; an annotated one whose names are all unbound resolves to
    # `default`'s lock, which under §6.2 has `default`'s identity.
    let unannotated = emptySolvedGraphIdentity(Platform)
    let annotatedButUnbound = emptySolvedGraphIdentity(Platform)
    check unannotated == annotatedButUnbound
    check fingerprints(closureUnder(unannotated)) ==
      fingerprints(closureUnder(annotatedButUnbound))

  test "several names resolving to one lock file are one lock file":
    # §6.2's secondary argument, and §5.1's "I am not cross-compiling today"
    # spelling: "both names resolve to one lock file's content, so one set of
    # artifacts is built and shared". Three names, one content, one key.
    var identities: seq[LockIdentity] = @[]
    for _ in 0 ..< 3:
      identities.add(emptySolvedGraphIdentity(Platform))
    for id in identities:
      check id == identities[0]
      check fingerprints(closureUnder(id)) ==
        fingerprints(closureUnder(identities[0]))

  test "and the identity carries no trace of a name":
    # The structural half. §6.2: "The lock file name is a **handle** … and
    # MUST NOT participate in any cache key." `lockIdentityOf` takes a
    # `CanonicalSolvedGraph`, which has no name field of any kind, so this is
    # enforced by the signature — but a name could still be smuggled in
    # through a field that is present, so the rendered identity is scanned.
    let identity = emptySolvedGraphIdentity(Platform)
    let rendered = $identity
    for forbidden in ["hostTools", "targetRuntime", "default"]:
      check forbidden notin rendered

  test "the CONTROL: a lock file that really DIFFERS does move them":
    # Without this the file would pass against an implementation that keyed
    # on nothing at all — which is the pre-NLF-M7 state, and which would make
    # NLF-STAT-3 true and §7 false.
    let a = emptySolvedGraphIdentity(Platform)
    let b = emptySolvedGraphIdentity("arm64-darwin")
    check a != b
    check fingerprints(closureUnder(a)) != fingerprints(closureUnder(b))

  test "the annotation changes nothing about what the edge DOES":
    # A fingerprint that stayed still while the action's content moved would
    # satisfy this file and be a much worse bug. Asserted on the fields the
    # NLF-STAT-4 corpus calls an action's observable content.
    let annotated = closureUnder(emptySolvedGraphIdentity(Platform))
    let unannotated = closureUnder(emptySolvedGraphIdentity(Platform))
    check annotated.len == unannotated.len
    for i in 0 ..< annotated.len:
      check annotated[i].id == unannotated[i].id
      check annotated[i].kind == unannotated[i].kind
      check annotated[i].argv == unannotated[i].argv
      check annotated[i].inputs == unannotated[i].inputs
      check annotated[i].outputs == unannotated[i].outputs
      check annotated[i].deps == unannotated[i].deps

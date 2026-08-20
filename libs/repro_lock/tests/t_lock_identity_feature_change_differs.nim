## NLF-ID-3 — a feature change changes the key.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-3**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §6.1 and §7.
##
## - **Input.** Two lock files pinning **identical versions** of every
##   package, but assigning `libfoo`'s `enableTLS` variant differently.
## - **Expect.** Distinct fingerprints for every action in `libfoo`'s closure.
##   Two artifacts, both retained, neither serving the other.
## - **Catches.** "A key built from version pins only — the defect §6.1 exists
##   to prevent, and the one the current implementation is closest to, since
##   it already forwards locked variants as soft `#minimize` weights and drops
##   versions entirely (§1.2). This is a *cache-poisoning* case: under the
##   broken implementation the second build silently receives the first's
##   artifacts."
##
## ## The construction, and why the versions have to be identical
##
## §6.1: "A key that omitted feature selections would let **two genuinely
## different lock files collide** — the same package set at the same versions,
## built with different features, sharing one identity and therefore one set
## of cache entries."
##
## So the two locks are built to be identical in EVERY other respect: the same
## packages, the same versions, the same platform, the same solver-inputs
## digest. The only difference is one variant value. A version-only key
## returns one identity for both, and the assertions below fail.
##
## The cache-poisoning half is measured rather than argued: the two closures
## run against ONE shared action cache, and the second build must produce the
## second lock's artifact rather than being served the first's. Under a
## version-only key the second build reports success while the file on disk
## still holds the first build's bytes — success with the wrong artifact,
## which is exactly the failure this case exists to make loud.
##
## Test-double policy: NO mocks, doubles, or fakes. Real committed
## `…lock.v2` files, the product's reader and key function, the engine's real
## constructors, and a real `runBuild` against a real shared on-disk cache.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_lock

import ./nlf_lock_fixtures

proc identicalVersions(): seq[(string, string)] =
  @[("app", "0.9.0"), ("libfoo", "1.4.2"), ("nim", "2.2.0"),
    ("openssl", "3.3.1")]

proc libfooClosure(identity: LockIdentity; outDir: string;
                   payload: string): seq[BuildAction] =
  ## `libfoo`'s closure: compile, then link. Both edges are governed by
  ## `identity`, and both write `payload` — the bytes a TLS-enabled build
  ## would differ in.
  let objOut = absolutePath(outDir / "libfoo.o")
  let libOut = absolutePath(outDir / "libfoo.a")
  @[
    builtinAction(bakWriteText, "compile/libfoo@" & $identity,
      outputs = [objOut], text = payload,
      governingLockIdentity = identity),
    builtinAction(bakCopyFile, "archive/libfoo@" & $identity,
      deps = ["compile/libfoo@" & $identity],
      inputs = [objOut], outputs = [libOut],
      governingLockIdentity = identity)
  ]

proc fingerprints(actions: seq[BuildAction]): seq[string] =
  result = @[]
  for a in actions:
    result.add(toHex(a.weakFingerprint.bytes.toOpenArray(
      0, a.weakFingerprint.bytes.high)))

suite "NLF-ID-3 a feature change changes the key":

  test "identical versions, one variant flipped, distinct identities":
    let tempRoot = createTempDir("repro-nlf-id3-key", "")
    defer: removeDir(tempRoot)

    # Identical in every respect the two locks can be identical in — same
    # packages, same versions, same platform, same solver-inputs text.
    const SharedInputs = "identical constraint set for both lock files"
    let tlsOn = tempRoot / "tls-on.lock"
    let tlsOff = tempRoot / "tls-off.lock"
    writeCommittedLock(tlsOn,
      solutionOf(identicalVersions(), @[("enableTLS", "true")]),
      inputsText = SharedInputs)
    writeCommittedLock(tlsOff,
      solutionOf(identicalVersions(), @[("enableTLS", "false")]),
      inputsText = SharedInputs)

    let onLock = readCommittedLock(tlsOn)
    let offLock = readCommittedLock(tlsOff)

    # The premise, asserted rather than assumed: every VERSION pin agrees.
    check onLock.packages.len == offLock.packages.len
    for i in 0 ..< min(onLock.packages.len, offLock.packages.len):
      check onLock.packages[i].name == offLock.packages[i].name
      check onLock.packages[i].version == offLock.packages[i].version
      check onLock.packages[i].source == offLock.packages[i].source
    # … and the solver-inputs digest agrees too, so nothing below can pass by
    # accidentally keying on the constraint set.
    check onLock.inputsDigest == offLock.inputsDigest
    check onLock.platform == offLock.platform
    # … and exactly one variant assignment differs.
    check onLock.variants != offLock.variants

    let onIdentity = lockIdentityOf(onLock)
    let offIdentity = lockIdentityOf(offLock)
    check onIdentity.isValid()
    check offIdentity.isValid()
    check onIdentity != offIdentity

  test "every action in libfoo's closure gets a distinct fingerprint":
    let tempRoot = createTempDir("repro-nlf-id3-closure", "")
    defer: removeDir(tempRoot)

    let tlsOn = tempRoot / "tls-on.lock"
    let tlsOff = tempRoot / "tls-off.lock"
    writeCommittedLock(tlsOn,
      solutionOf(identicalVersions(), @[("enableTLS", "true")]))
    writeCommittedLock(tlsOff,
      solutionOf(identicalVersions(), @[("enableTLS", "false")]))

    let onFp = fingerprints(libfooClosure(
      lockIdentityOf(readCommittedLock(tlsOn)), tempRoot / "on", "tls\n"))
    let offFp = fingerprints(libfooClosure(
      lockIdentityOf(readCommittedLock(tlsOff)), tempRoot / "off", "no-tls\n"))

    check onFp.len == 2
    check offFp.len == 2
    # "Distinct fingerprints for EVERY action in the closure" — not just the
    # one that visibly links openssl. §7: "The fingerprint must include the
    # solved instances of everything the action's identity depends on, not
    # only what it visibly links."
    for i in 0 ..< min(onFp.len, offFp.len):
      check onFp[i] != offFp[i]

  test "two artifacts are retained; neither build serves the other's":
    # The cache-poisoning half, measured against ONE shared action cache.
    let tempRoot = createTempDir("repro-nlf-id3-cache", "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "cache"
    createDir(cacheRoot)

    let tlsOn = tempRoot / "tls-on.lock"
    let tlsOff = tempRoot / "tls-off.lock"
    writeCommittedLock(tlsOn,
      solutionOf(identicalVersions(), @[("enableTLS", "true")]))
    writeCommittedLock(tlsOff,
      solutionOf(identicalVersions(), @[("enableTLS", "false")]))

    proc buildInto(lockPath, outDir, payload: string): string =
      createDir(outDir)
      let identity = lockIdentityOf(readCommittedLock(lockPath))
      var cfg = defaultBuildEngineConfig(cacheRoot)
      cfg.maxParallelism = 1
      cfg.bypassRunQuota = true
      cfg.deferLocalOutputBlobs = false
      discard runBuild(graph(libfooClosure(identity, outDir, payload)), cfg)
      readFile(absolutePath(outDir / "libfoo.a"))

    let onArtifact = buildInto(tlsOn, tempRoot / "on", "built-with-tls\n")
    let offArtifact = buildInto(tlsOff, tempRoot / "off", "built-without-tls\n")

    # Each build produced ITS OWN artifact …
    check onArtifact == "built-with-tls\n"
    check offArtifact == "built-without-tls\n"
    # … and they are different, so the second was not served the first's.
    check onArtifact != offArtifact
    # … and both are still on disk: "two artifacts, both retained".
    check fileExists(absolutePath(tempRoot / "on" / "libfoo.a"))
    check fileExists(absolutePath(tempRoot / "off" / "libfoo.a"))
    check readFile(absolutePath(tempRoot / "on" / "libfoo.a")) ==
      "built-with-tls\n"

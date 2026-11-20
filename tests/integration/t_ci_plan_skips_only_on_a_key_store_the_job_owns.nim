## ``repro ci plan`` grants a ``skip`` only against a registered-key store the
## CI job owns, never one the candidate checkout can supply
## (Test-Certificates.md §"Who owns the registered-key store"; CLI/ci.md
## §"Decision rules (security-critical)").
##
## A committed-lock project whose BASE sets ``ci_trust = "skip"``, and a
## certificate covering ``t-unit`` on this platform for the candidate's
## content, signed by a key that only the CANDIDATE vouches for: the
## candidate commit tracks ``.repro/workspace/certificates/registered-keys.toml``
## naming that signer.
##
##   1. The job runs in the checkout (``--workspace-root`` is the checkout),
##      with no ``--registered-keys``: ``ci_trust`` is ``advisory`` and
##      ``t-unit`` runs.
##   2. A separate workspace root whose store registers the signer, no flag:
##      still ``advisory``, and ``policy.detail`` says why.
##   3. ``--registered-keys`` naming a job store that registers nobody, while
##      the workspace store registers the signer: ``t-unit`` runs.
##   4. ``--registered-keys`` naming the tracked store, the same store spelled
##      through ``..``, or the workspace root's store: each exits 1; the
##      tracked store is refused even when the workspace root lies elsewhere.
##   5. A symbolic link outside both roots that points into the checkout:
##      exits 1.
##   6. A missing store, a malformed one and an empty ``--registered-keys=``:
##      each exits 1.
##   7. Positive control: a job store that registers the signer skips
##      ``t-unit``.
##
## Falsifiability: read the store under ``--workspace-root`` for the skip
## decision → 1 and 2 skip ``t-unit``; fall back to the workspace store →
## 3 skips; drop the containment check → 4 and 5
## exit 0; compare paths without resolving links → 5 exits 0; treat a
## missing store as "nobody is trusted" → 6 exits 0.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git and
## ssh-keygen.

import std/[json, os, osproc, strutils, unittest]

include policy_gate_fixture

proc ciPlanRaw(fx: StoreFixture; workspaceRoot, base: string;
               extra: seq[string] = @[]): tuple[code: int; output: string] =
  let res = runArgv(@[fx.reproBin, "ci", "plan",
    "--platform=" & currentPlatformTag(), "--branch=main", "--base=" & base,
    "--workspace-root=" & workspaceRoot, "--current-repo=" & fx.libAPath,
    "--json"] & extra)
  checkpoint("ci plan " & extra.join(" ") & " (workspace " & workspaceRoot &
    "):\n" & res.output)
  res

proc ciPlanJson(fx: StoreFixture; workspaceRoot, base: string;
                extra: seq[string] = @[]): JsonNode =
  let res = ciPlanRaw(fx, workspaceRoot, base, extra)
  doAssert res.code == 0, "repro ci plan failed:\n" & res.output
  let start = res.output.find("{\n")
  doAssert start >= 0, "no JSON in ci plan output:\n" & res.output
  parseJson(res.output[start .. ^1])

proc storeWith(path: string; entries: openArray[RegisteredKey]) =
  var store: RegisteredKeyStore
  for e in entries: store.keys.add(e)
  createDir(path.parentDir)
  writeRegisteredKeyStore(store, path)

suite "the CI plan skips only on a key store the job owns":

  test "t_ci_plan_skips_only_on_a_key_store_the_job_owns":
    let host = currentPlatformTag()
    let fx = setupStoreFixture("", "ci-keystore", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    let signer = RegisteredKey(keyId: storeKeyId,
      publicKey: readFile(fx.daemonKey & ".pub").strip(), status: rksActive)
    # The workspace store the fixture registered the signer in is not one a
    # CI job owns; empty it, so only the stores below can vouch for it.
    writeRegistry(fx.workspaceRoot, [])
    let unitRule = policyRule(["main"], pmRequired, [req("t-unit", host)])
    # The snapshot records what t-unit means, so the base anchors it and the
    # only thing deciding a skip below is the key store (Test-Certificates.md
    # §"What a required name means: its command set").
    let skipBase = fx.commitPolicy(
      snapshotOf([unitRule], ciTrust = pctSkip, commandSets = true),
      "base: skip")
    # The candidate: it tracks a registered-key store that names the signer.
    let tracked = registeredKeyStorePath(fx.libAPath)
    storeWith(tracked, [signer])
    discard fx.mustGit("add", "-f", tracked)
    discard fx.mustGit("commit", "-q", "--no-verify", "-m",
      "candidate: trust my signer")
    let candidate = fx.head
    let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      candidate & "^{tree}")
    fx.certifyTargets(content, @["t-unit"])

    # ---- 1. the job runs in the checkout, no flag: advisory ---------------
    let p1 = ciPlanJson(fx, fx.libAPath, skipBase)
    check p1["ci_trust"].getStr() == "advisory"
    let h1 = planPlatform(p1, host)
    check strings(h1, "skip").len == 0
    check strings(h1, "run") == @["t-unit"]
    # The certificate was found and verified against the checkout's store:
    # the skip is withheld because of the store's owner, not for want of
    # coverage.
    check h1["matching_certs"].getInt() == 1

    # ---- 2. a separate workspace root that registers the signer -----------
    let otherRoot = fx.scratch / "other-workspace"
    storeWith(registeredKeyStorePath(otherRoot), [signer])
    let p2 = ciPlanJson(fx, otherRoot, skipBase)
    check p2["ci_trust"].getStr() == "advisory"
    check "--registered-keys" in p2["policy"]["detail"].getStr()
    let h2 = planPlatform(p2, host)
    check strings(h2, "skip").len == 0
    check strings(h2, "run") == @["t-unit"]
    check h2["matching_certs"].getInt() == 1

    # ---- 3. a job store that registers nobody: t-unit runs ----------------
    let jobDir = fx.scratch / "ci-job"
    let emptyStore = jobDir / "nobody.toml"
    storeWith(emptyStore, [])
    # The workspace store here registers the signer: the named store alone
    # decides, with no fallback to the workspace's.
    let p3 = ciPlanJson(fx, otherRoot, skipBase,
      @["--registered-keys=" & emptyStore])
    check p3["ci_trust"].getStr() == "skip"
    let h3 = planPlatform(p3, host)
    check strings(h3, "skip").len == 0
    check strings(h3, "run") == @["t-unit"]

    # ---- 4. a store inside the checkout or the workspace root: exit 1 -----
    let wsStore = registeredKeyStorePath(fx.workspaceRoot)
    for named in [tracked,
                  fx.libAPath / ".repro" / ".." / ".repro" / "workspace" /
                    "certificates" / "registered-keys.toml",
                  wsStore]:
      let r = ciPlanRaw(fx, fx.workspaceRoot, skipBase,
        @["--registered-keys=" & named])
      check r.code == 1
      check "lies inside" in r.output
    # The checkout is refused on its own account, with a workspace root that
    # does not contain it.
    let r4 = ciPlanRaw(fx, otherRoot, skipBase,
      @["--registered-keys=" & tracked])
    check r4.code == 1
    check "lies inside the candidate checkout" in r4.output

    # ---- 5. a link outside both roots that points into the checkout -------
    let link = jobDir / "linked.toml"
    createSymlink(tracked, link)
    let r5 = ciPlanRaw(fx, fx.workspaceRoot, skipBase,
      @["--registered-keys=" & link])
    check r5.code == 1
    check "lies inside" in r5.output

    # ---- 6. a missing store and a malformed one: exit 1 -------------------
    let r6a = ciPlanRaw(fx, fx.workspaceRoot, skipBase,
      @["--registered-keys=" & jobDir / "missing.toml"])
    check r6a.code == 1
    check "is not a readable file" in r6a.output
    let malformed = jobDir / "malformed.toml"
    writeFile(malformed, "this is [not a key store\n")
    let r6b = ciPlanRaw(fx, fx.workspaceRoot, skipBase,
      @["--registered-keys=" & malformed])
    check r6b.code == 1
    check "could not be parsed" in r6b.output
    let r6c = ciPlanRaw(fx, fx.workspaceRoot, skipBase, @["--registered-keys="])
    check r6c.code == 1
    check "needs a path" in r6c.output

    # ---- 7. positive control: the job's store registers the signer --------
    let jobStore = jobDir / "registered-keys.toml"
    storeWith(jobStore, [signer])
    let p7 = ciPlanJson(fx, fx.workspaceRoot, skipBase,
      @["--registered-keys=" & jobStore])
    check p7["ci_trust"].getStr() == "skip"
    let h7 = planPlatform(p7, host)
    check strings(h7, "skip") == @["t-unit"]
    check strings(h7, "run").len == 0

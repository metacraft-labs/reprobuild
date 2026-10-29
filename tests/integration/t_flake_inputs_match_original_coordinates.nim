## Real git checkouts, committed-format workspace lock and consumer flake lock;
## no mocks. Forge URLs in the workspace lock identify repositories without
## contacting a forge: all commands run against already-present local trees.
## Different input and node names prevent accidental name-based success.
import std/[json, os, strutils, tables, unittest]
import nf3_override_state_fixture
from hl11_two_lock_fixture import reproLockText, lockDepEntry

suite "flake input original coordinates":
  test "aliases use source identity and cannot fall back across owners":
    let binary = getEnv("REPRO_COORDINATE_TEST_BINARY", reproBinaryPath())
    doAssert fileExists(binary), "build repro before running this regression"
    doAssert findExe("git").len > 0
    var fx = setupNf2Fixture("original-coordinates")
    fx.repro = absolutePath(binary)
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    let alphaUrl = "git@github.com:metacraft-labs/alpha.git"
    let betaUrl = "https://github.com/metacraft-labs/beta"
    let gammaUrl = "https://github.com/other-owner/gamma"
    var wsLock = readFile(fx.ws / "repro.lock")
    wsLock = wsLock.replace(originUrl(fx, "alpha"), alphaUrl)
    wsLock = wsLock.replace(originUrl(fx, "beta"), betaUrl)
    wsLock = wsLock.replace(originUrl(fx, "gamma"), gammaUrl)
    writeFile(fx.ws / "repro.lock", wsLock)
    writeFile(fx.app / "flake.nix", "{ inputs = { " &
      "wazero.url = \"github:metacraft-labs/alpha\"; " &
      "toolchain.url = \"github:metacraft-labs/beta\"; " &
      "gamma-src.url = \"github:metacraft-labs/gamma\"; " &
      "epsilon-src.url = \"path:../epsilon\"; " &
      "delta-src.url = \"github:metacraft-labs/delta\"; " &
      "}; outputs = _: {}; }\n")
    var lock = parseJson(nf2FlakeLockText(fx, fx.seedSha[0], fx.seedSha[1], fx.seedSha[2]))
    let nodes = lock["nodes"]
    for pair in [("alpha-src", "alpha"), ("beta-src", "beta"), ("gamma-src", "gamma")]:
      nodes[pair[0]]["original"] = %*{"type": "github", "owner": "metacraft-labs", "repo": pair[1]}
    nodes["epsilon-src"] = %*{"original": {"type": "path", "path": "../epsilon"},
      "locked": {"type": "git", "rev": fx.seedSha[4], "url": originUrl(fx, "epsilon")}}
    nodes["delta-src"] = %*{"original": {"type": "github", "owner": "metacraft-labs", "repo": "delta"},
      "locked": {"type": "github", "owner": "metacraft-labs", "repo": "delta", "rev": fx.seedSha[3]}}
    nodes["root"]["inputs"] = %*{"wazero": "alpha-src", "toolchain": "beta-src",
      "gamma-src": "gamma-src", "epsilon-src": "epsilon-src", "delta-src": "delta-src"}
    let lockBytes = $lock
    writeFile(lockPath(fx), lockBytes)
    proc invoke(verb: string; flags = "--all"): tuple[code: int; output: string] =
      run(q(fx.repro) & " flake " & verb & " --tool-provisioning=path --workspace-root=" &
        q(fx.ws) & " " & flags, cwd = fx.app)
    let args = invoke("override-args")
    checkpoint(args.output)
    check args.code == 0
    check ("--override-input wazero git+file://" & siblingDir(fx, "alpha")) in args.output
    check ("--override-input toolchain git+file://" & siblingDir(fx, "beta")) in args.output
    check ("--override-input epsilon-src git+file://" & siblingDir(fx, "epsilon")) in args.output
    check "--override-input gamma-src" notin args.output
    check "--override-input delta-src" notin args.output
    check "gamma-src" in args.output
    check readFile(lockPath(fx)) == lockBytes
    let status = invoke("override-status", "--json")
    checkpoint(status.output)
    check status.code == 0
    check "\"input\": \"wazero\"" in status.output
    check "\"repo\": \"alpha\"" in status.output
    let refresh = invoke("refresh-lock")
    checkpoint(refresh.output)
    check refresh.code == 0
    check "no-overrides" notin refresh.output
    check "3 overridden input(s)" in refresh.output
    let selected = invoke("override-args", "--only=alpha")
    check selected.code == 0
    check "--override-input wazero" in selected.output
    check "--override-input toolchain" notin selected.output

    # A matched coordinate candidate without a usable locked revision gets the
    # existing actionable develop-set explanation, rather than 'no repo'.
    let manifests = fx.ws / ".repro" / "manifests"
    createDir(manifests / "projects")
    createDir(manifests / "repos")
    var remotes = ""
    let projectHeader = "schema = \"reprobuild.workspace.project.v1\"\n"
    var includes: seq[string]
    for name in Nf2Repos:
      let url = case name
        of "alpha": alphaUrl
        of "beta": betaUrl
        of "gamma": gammaUrl
        else: originUrl(fx, name)
      let explicitUrl = if url.endsWith(".git"): url else: url & ".git"
      remotes.add("\n[[remote]]\nname = \"" & name & "\"\nfetch = \"" & explicitUrl & "\"\n")
      includes.add("\"repos/" & name & ".toml\"")
      writeFile(manifests / "repos" / (name & ".toml"),
        "schema = \"reprobuild.workspace.repo.v1\"\n[repo]\nname = \"" & name &
        "\"\npath = \"" & name & "\"\nremote = \"" & name & "\"\nrevision = \"main\"\n")
    let project = projectHeader & "includes = [" & includes.join(", ") & "]\n" &
      "[project]\nname = \"nf2\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n" & remotes
    writeFile(manifests / "projects" / "nf2.toml", project)
    let betaStart = wsLock.find("{ name = \"beta\"")
    let betaEnd = wsLock.find(" }", betaStart) + 2
    doAssert betaStart > 1 and betaEnd > betaStart
    writeFile(fx.ws / "repro.lock", wsLock[0 ..< betaStart - 2] & wsLock[betaEnd .. ^1])
    check "name = \"beta\"" notin readFile(fx.ws / "repro.lock")
    check not fileExists(siblingDir(fx, "beta") / "repro.lock")
    let omitted = invoke("override-args")
    checkpoint(omitted.output)
    check omitted.code == 0
    check "NOT in the develop set" in omitted.output
    check "toolchain' names repo 'beta'" in omitted.output
    check "repro lock refresh" in omitted.output
    check "--override-input toolchain" notin omitted.output
    writeFile(fx.ws / "repro.lock", wsLock)
    removeDir(manifests)

    # A real published sibling advance must refresh the aliased lock NODE.
    let moved = moveSibling(fx, "alpha", "coordinate refresh")
    publishSibling(fx, "alpha")
    commitLockAndPublish(fx, "coordinate-alias consumer")
    removePreCommitDispatch(fx)
    publishAll(fx)
    let stale = gatePrePush(fx)
    checkpoint(stale.output)
    check stale.code != 0
    check hasGateFailure(stale.report, "flake_lock_stale")
    installPreCommitDispatch(fx)
    writeFile(fx.app / "consumer-marker.txt", "trigger a real commit\n")
    discard gitIn(fx, fx.app, "add -A")
    let committed = run(q(fx.gitBin) & " -C " & q(fx.app) &
      " commit -q -m 'refresh aliased sibling through real hook'")
    checkpoint(committed.output)
    check committed.code == 0
    check parseJson(readFile(lockPath(fx)))["nodes"]["alpha-src"]["locked"]["rev"].getStr() == moved
    check parseJson(lockInCommit(fx))["nodes"]["alpha-src"]["locked"]["rev"].getStr() == moved
    let fresh = gatePrePush(fx)
    checkpoint(fresh.output)
    check not hasGateFailure(fresh.report, "flake_lock_stale")
    removePreCommitDispatch(fx)
    let directlyMoved = moveSibling(fx, "alpha", "direct coordinate refresh")
    publishSibling(fx, "alpha")
    let advanced = invoke("refresh-lock")
    checkpoint(advanced.output)
    check advanced.code == 0
    check parseJson(readFile(lockPath(fx)))["nodes"]["alpha-src"]["locked"]["rev"].getStr() == directlyMoved
    check parseJson(readFile(lockPath(fx)))["nodes"]["gamma-src"]["locked"]["rev"].getStr() == fx.seedSha[2]

    # Partial and unsupported coordinates also forbid a same-name fallback.
    for original in [%*{"owner": "metacraft-labs"},
        %*{"type": "github", "host": "other-forge.example"},
        %*{"host": "other-forge.example"},
        %*{"type": "github", "host": 42},
        %*{"host": 42},
        %*{"type": 42},
        %*{"type": nil},
        %*{"type": ""},
        %*{"type": "github"},
        %*{"type": "gitlab"},
        %*{"type": "sourcehut"},
        %*{"type": "unknown-forge", "owner": "other-owner", "repo": "gamma"},
        %*{"type": "github", "owner": "other-owner", "repo": "gamma", "host": 42},
        %*{"type": "github", "owner": "other-owner", "repo": "gamma", "host": nil},
        %*{"type": "github", "owner": "other-owner", "repo": "gamma", "host": ""},
        %*{"type": "github", "owner": "other-owner", "repo": "gamma", "host": "github.com/other"},
        %*{"type": "github", "owner": "other-owner", "repo": "gamma", "host": "other-forge.example"}]:
      lock["nodes"]["gamma-src"]["original"] = original
      writeFile(lockPath(fx), $lock)
      let rejected = invoke("override-args")
      checkpoint("original reference: " & $original)
      checkpoint(rejected.output)
      check rejected.code == 0
      check "--override-input gamma-src" notin rejected.output
      check "input-name fallback is disabled" in rejected.output
      var namedRefusal = false
      for line in rejected.output.splitLines():
        if "NOT substituted: flake input 'gamma-src'" in line and
            "input-name fallback is disabled" in line:
          namedRefusal = true
      check namedRefusal

    # An indirect reference really carries no hosted repository identity;
    # preserve its suffix-based fallback as the positive control.
    lock["nodes"]["gamma-src"]["original"] = %*{"type": "indirect", "id": "gamma-src"}
    writeFile(lockPath(fx), $lock)
    let indirect = invoke("override-args")
    checkpoint(indirect.output)
    check indirect.code == 0
    check "--override-input gamma-src" in indirect.output

    # Missing and malformed metadata never establish coordinate absence.
    for mode in ["follows", "dangling", "missing", "bad-original", "bad-json", "bad-root", "bad-inputs", "bad-target"]:
      var invalid = parseJson(lockBytes)
      case mode
      of "follows": invalid["nodes"]["root"]["inputs"]["gamma-src"] = %*["gamma-src"]
      of "dangling": invalid["nodes"]["root"]["inputs"]["gamma-src"] = %"absent-node"
      of "missing": invalid["nodes"]["root"]["inputs"].delete("gamma-src")
      of "bad-original": invalid["nodes"]["gamma-src"]["original"] = %42
      of "bad-root": invalid["root"] = %42
      of "bad-inputs": invalid["nodes"]["root"]["inputs"] = %*["gamma-src"]
      of "bad-target": invalid["nodes"]["root"]["inputs"]["gamma-src"] = %42
      else: discard
      writeFile(lockPath(fx), if mode == "bad-json": "{malformed" else: $invalid)
      let rejected = invoke("override-args")
      checkpoint(mode & ": " & rejected.output)
      check "--override-input gamma-src" notin rejected.output
      check "guessing" in rejected.output or "NOT substituted" in rejected.output
      if mode in ["bad-json", "bad-root", "bad-inputs"]:
        let before = readFile(lockPath(fx))
        let refused = invoke("refresh-lock")
        checkpoint(refused.output)
        check refused.code != 0
        check "refused-unreadable-lock" in refused.output
        check readFile(lockPath(fx)) == before
    writeFile(lockPath(fx), lockBytes)
    # Two declared checkouts with one identity must not choose by traversal order.
    writeFile(fx.ws / "repro.lock", wsLock.replace(betaUrl, alphaUrl))
    let ambiguous = invoke("override-args")
    checkpoint(ambiguous.output)
    check "match multiple workspace repositories: alpha, beta" in ambiguous.output
    check "--override-input wazero" notin ambiguous.output

    writeFile(fx.ws / "repro.lock", wsLock.replace(gammaUrl,
      "https://other-forge.example/other-owner/gamma"))
    lock["nodes"]["gamma-src"]["original"] = %*{"type": "github",
      "owner": "other-owner", "repo": "gamma", "host": "other-forge.example"}
    writeFile(lockPath(fx), $lock)
    let customHost = invoke("override-args")
    checkpoint(customHost.output)
    check "--override-input gamma-src" in customHost.output

  test "git url originals bind by repository url, never by input name":
    # reprobuild-pm issue
    # `2026-10-18-flake-override-binder-binds-a-git-url-input-by-name.md`:
    # nix writes a `git+…` input's `original` as `{"type": "git", "url": …}`,
    # with no owner/repo. The binder used to read coordinates only from
    # github/gitlab/sourcehut originals, so such an input fell back to its
    # suffix-stripped NAME and the shell could substitute a same-named repo
    # at a different URL. Each input below is NAMED after one workspace repo
    # and FETCHES another (or none), so a name-based binding cannot pass.
    # Falsifiability: against reprobuild `agents` 9b4b298c64 `alpha-src` was
    # bound to `alpha`, `beta-src` to `beta`, `gamma-src` to `gamma` and
    # `delta-src` to `delta`, all by name.
    let binary = getEnv("REPRO_COORDINATE_TEST_BINARY", reproBinaryPath())
    doAssert fileExists(binary), "build repro before running this regression"
    doAssert findExe("git").len > 0
    var fx = setupNf2Fixture("git-url-coordinates")
    fx.repro = absolutePath(binary)
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    writeFile(fx.app / "flake.nix", "{ inputs = { " &
      "alpha-src.url = \"git+" & originUrl(fx, "beta") & "?ref=main\"; " &
      "beta-src.url = \"git+" & originUrl(fx, "gamma") & "?ref=main\"; " &
      "gamma-src.url = \"git+https://example.invalid/elsewhere/gamma?ref=main\"; " &
      "delta-src.url = \"git+https://example.invalid/elsewhere/delta\"; " &
      "}; outputs = _: {}; }\n")
    var lock = parseJson(nf2FlakeLockText(fx, fx.seedSha[1], fx.seedSha[2],
      fx.seedSha[2]))
    let nodes = lock["nodes"]
    # alpha-src fetches beta, beta-src fetches gamma: nix's own shape, a plain
    # fetch URL in `url` (no `git+`).
    nodes["alpha-src"]["original"] = %*{"type": "git", "ref": "main",
      "url": originUrl(fx, "beta")}
    nodes["alpha-src"]["locked"]["url"] = %originUrl(fx, "beta")
    nodes["beta-src"]["original"] = %*{"type": "git", "ref": "main",
      "url": originUrl(fx, "gamma")}
    nodes["beta-src"]["locked"]["url"] = %originUrl(fx, "gamma")
    # gamma-src names a repository no workspace repo is: never bound by name.
    nodes["gamma-src"]["original"] = %*{"type": "git", "ref": "main",
      "url": "https://example.invalid/elsewhere/gamma"}
    # delta-src's original is malformed (no url): it fails closed, it is not
    # bound by its name to `delta`.
    nodes["delta-src"] = %*{"original": {"type": "git"},
      "locked": {"type": "git", "rev": fx.seedSha[3],
        "url": "https://example.invalid/elsewhere/delta"}}
    nodes["root"]["inputs"] = %*{"alpha-src": "alpha-src",
      "beta-src": "beta-src", "gamma-src": "gamma-src",
      "delta-src": "delta-src"}
    writeFile(lockPath(fx), $lock)
    let args = run(q(fx.repro) & " flake override-args --all --json " &
      "--tool-provisioning=path --workspace-root=" & q(fx.ws) & " 2>" &
      q(fx.scratch / "override-args.err"), cwd = fx.app)
    let stderrText = readFile(fx.scratch / "override-args.err")
    checkpoint(args.output & "\nstderr:\n" & stderrText)
    check args.code == 0
    var boundTo = initTable[string, string]()
    for o in parseJson(args.output)["overrides"]:
      boundTo[o["input"].getStr()] = o["repo"].getStr()
    check boundTo.getOrDefault("alpha-src") == "beta"
    check boundTo.getOrDefault("beta-src") == "gamma"
    check "gamma-src" notin boundTo
    check "delta-src" notin boundTo
    check "no workspace repository matches original coordinates" in stderrText
    check "original git repository url is missing or malformed" in stderrText

    # Git originals use URL identity across transports, including Nix's
    # git+ spelling and revision queries. The manifest-free fixture reads
    # fetch identities from repro.lock; no forge contact is needed to bind.
    let workspaceLock = fx.ws / "repro.lock"
    let workspaceBytes = readFile(workspaceLock)
    writeFile(workspaceLock, workspaceBytes.replace(originUrl(fx, "beta"),
      "git@github.com:metacraft-labs/beta.git"))
    for url in ["https://github.com/metacraft-labs/beta.git",
        "ssh://git@github.com/metacraft-labs/beta",
        "git+https://github.com/metacraft-labs/beta?ref=main",
        "git+ssh://git@github.com/metacraft-labs/beta.git?rev=" & fx.seedSha[1]]:
      nodes["alpha-src"]["original"]["url"] = %url
      writeFile(lockPath(fx), $lock)
      let normalized = flakeArgs(fx, "--all --json", cwd = fx.app)
      checkpoint("git original URL: " & url & "\n" & normalized.stderr)
      check normalized.code == 0
      var alphaRepo = ""
      for o in parseJson(normalized.stdout)["overrides"]:
        if o["input"].getStr() == "alpha-src":
          alphaRepo = o["repo"].getStr()
      check alphaRepo == "beta"
    writeFile(workspaceLock, workspaceBytes)

    for badUrl in [%"", %"  ", %42, newJNull(), %*["file:///elsewhere"]]:
      nodes["delta-src"]["original"]["url"] = badUrl
      writeFile(lockPath(fx), $lock)
      let rejected = flakeArgs(fx, "--all --json", cwd = fx.app)
      checkpoint("malformed git URL: " & $badUrl & "\n" & rejected.stderr)
      check rejected.code == 0
      for o in parseJson(rejected.stdout)["overrides"]:
        check o["input"].getStr() != "delta-src"
      check "original git repository url is missing or malformed" in rejected.stderr

  test "the commit pre-filter hands over when the binder pairs an input with another checkout":
    # The managed `pre-commit` refresh answers "nothing moved" from a cheap
    # scan that compares each member of the hooks' develop set with ITS
    # checkout, which ``hookDevelopSetOf`` binds by the URL `flake.nix`
    # declares. The binder the authoritative path runs binds by the lock's
    # `original` instead. Here the two disagree about `zeta-src` (its
    # `flake.nix` URL names `alpha`, its stale lock `original` names `beta`),
    # and `beta` is a member through `alpha-src`, so the binder pairs
    # `zeta-src` with `beta`'s checkout, which the scan never compares it with.
    # Every member's checkout is at its own pin, so the scan alone answers
    # `up-to-date` although the shell substitutes `beta` for `zeta-src` at a
    # revision the lock does not name. The pre-filter must stay a superset of
    # the authoritative path and hand over.
    # Falsifiability: with the pre-filter that only scanned members (the
    # first version of the fix for
    # `2026-10-18-flake-override-binder-binds-a-git-url-input-by-name.md`),
    # the commit logged `flake-lock up-to-date`.
    let binary = getEnv("REPRO_COORDINATE_TEST_BINARY", reproBinaryPath())
    doAssert fileExists(binary), "build repro before running this regression"
    doAssert findExe("git").len > 0
    var fx = setupNf2Fixture("prefilter-superset")
    fx.repro = absolutePath(binary)
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    let alphaHead = headOf(fx, siblingDir(fx, "alpha"))
    let betaHead = headOf(fx, siblingDir(fx, "beta"))
    doAssert alphaHead != betaHead
    writeFile(fx.app / "flake.nix", "{ inputs = { " &
      "alpha-src.url = \"git+" & originUrl(fx, "beta") & "?ref=main\"; " &
      "zeta-src.url = \"git+" & originUrl(fx, "alpha") & "?ref=main\"; " &
      "}; outputs = _: {}; }\n")
    var lock = parseJson(nf2FlakeLockText(fx, betaHead, betaHead, betaHead))
    let nodes = lock["nodes"]
    nodes["alpha-src"]["original"] = %*{"type": "git", "ref": "main",
      "url": originUrl(fx, "beta")}
    nodes["alpha-src"]["locked"]["url"] = %originUrl(fx, "beta")
    # `zeta-src` is pinned at `alpha`'s HEAD (what the hooks compare it with),
    # but its `original` still names `beta` (what the binder binds it by).
    nodes["zeta-src"] = %*{"original": {"type": "git", "ref": "main",
        "url": originUrl(fx, "beta")},
      "locked": {"type": "git", "ref": "main", "rev": alphaHead,
        "url": originUrl(fx, "alpha")}}
    nodes["root"]["inputs"] = %*{"alpha-src": "alpha-src",
      "zeta-src": "zeta-src"}
    writeFile(lockPath(fx), $lock)
    commitLockAndPublish(fx, "zeta-src carries a stale original")
    # What the shell substitutes: `beta` for both inputs.
    let bound = flakeArgs(fx, "--all --json", cwd = fx.app)
    checkpoint("override-args stderr:\n" & bound.stderr)
    check bound.code == 0
    var boundTo = initTable[string, string]()
    for o in parseJson(bound.stdout)["overrides"]:
      boundTo[o["input"].getStr()] = o["repo"].getStr()
    check boundTo.getOrDefault("alpha-src") == "beta"
    check boundTo.getOrDefault("zeta-src") == "beta"
    let c = tryCommitInApp(fx, "the binder pairs zeta-src with beta")
    checkpoint(c.output)
    checkpoint("pre-commit log:\n" & preCommitLog(fx))
    let line = lastFlakeLogLine(fx)
    check line.len > 0
    check "flake-lock up-to-date" notin line

  test "an input that fetches a fork's upstream is not bound to the fork":
    # A fork declares its upstream as a second remote (`noir` declares
    # `noir-lang/noir`). An input whose `original` fetches that UPSTREAM must
    # not have the fork's working tree substituted for it: the shell would
    # build the fork, and the commit-time re-pin would record a fork revision
    # in a lock node that fetches from upstream. The binder therefore matches
    # a repo's fetch URL and checkout, never its other remotes, while the
    # managed hooks (``hookDevelopSetOf``) do bind by every remote; the hooks
    # then leave the input alone because the shell does not substitute it.
    # Falsifiability: the first version of the fix for
    # `2026-10-18-flake-override-binder-binds-a-git-url-input-by-name.md`
    # matched every declared remote and bound `up-src` to `alpha`.
    let binary = getEnv("REPRO_COORDINATE_TEST_BINARY", reproBinaryPath())
    doAssert fileExists(binary), "build repro before running this regression"
    doAssert findExe("git").len > 0
    var fx = setupNf2Fixture("fork-upstream")
    fx.repro = absolutePath(binary)
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    const upstreamUrl = "https://example.invalid/upstream-owner/alpha.git"
    # A manifest in which `alpha` carries a second remote, `upstream`.
    let manifests = fx.ws / ".repro" / "manifests"
    createDir(manifests / "projects")
    createDir(manifests / "repos")
    var remotes = "\n[[remote]]\nname = \"alpha-upstream\"\nfetch = \"" &
      upstreamUrl & "\"\n"
    var includes: seq[string]
    for name in Nf2Repos:
      remotes.add("\n[[remote]]\nname = \"" & name & "\"\nfetch = \"" &
        originUrl(fx, name) & "\"\n")
      includes.add("\"repos/" & name & ".toml\"")
      let extra =
        if name == "alpha":
          "remotes = [{ name = \"origin\", remote = \"alpha\" }, " &
            "{ name = \"upstream\", remote = \"alpha-upstream\" }]\n"
        else: ""
      writeFile(manifests / "repos" / (name & ".toml"),
        "schema = \"reprobuild.workspace.repo.v1\"\n[repo]\nname = \"" & name &
        "\"\npath = \"" & name & "\"\nremote = \"" & name &
        "\"\nrevision = \"main\"\n" & extra)
    writeFile(manifests / "projects" / "nf2.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n" &
      "includes = [" & includes.join(", ") & "]\n" &
      "[project]\nname = \"nf2\"\ndefault_revision = \"main\"\n" &
      "trunk = \"main\"\n" & remotes)
    let alphaHead = headOf(fx, siblingDir(fx, "alpha"))
    let betaHead = headOf(fx, siblingDir(fx, "beta"))
    writeFile(fx.app / "flake.nix", "{ inputs = { " &
      "up-src.url = \"git+" & upstreamUrl & "?ref=main\"; " &
      "beta-src.url = \"git+" & originUrl(fx, "beta") & "?ref=main\"; " &
      "}; outputs = _: {}; }\n")
    var lock = parseJson(nf2FlakeLockText(fx, alphaHead, betaHead, betaHead))
    let nodes = lock["nodes"]
    nodes["up-src"] = %*{"original": {"type": "git", "ref": "main",
        "url": upstreamUrl},
      "locked": {"type": "git", "ref": "main", "rev": alphaHead,
        "url": upstreamUrl}}
    nodes["root"]["inputs"] = %*{"up-src": "up-src", "beta-src": "beta-src"}
    writeFile(lockPath(fx), $lock)
    commitLockAndPublish(fx, "up-src fetches alpha's upstream")
    let bound = flakeArgs(fx, "--all --json", cwd = fx.app)
    checkpoint("override-args stderr:\n" & bound.stderr)
    check bound.code == 0
    var boundTo = initTable[string, string]()
    for o in parseJson(bound.stdout)["overrides"]:
      boundTo[o["input"].getStr()] = o["repo"].getStr()
    # Positive control for the manifest: `beta-src` is bound by fetch URL.
    check boundTo.getOrDefault("beta-src") == "beta"
    check "up-src" notin boundTo
    check ("NOT substituted: flake input 'up-src': no workspace repository " &
      "matches original coordinates") in bound.stderr
    # `alpha` moves. The hooks DO bind `up-src` to `alpha` through its
    # upstream remote (the control that the remote was resolved), and since
    # the shell does not substitute it, nothing is recorded.
    let moved = moveSibling(fx, "alpha", "alpha moves past the upstream pin")
    publishSibling(fx, "alpha")
    let c = tryCommitInApp(fx, "alpha moved")
    checkpoint(c.output)
    checkpoint("pre-commit log:\n" & preCommitLog(fx))
    check c.code == 0
    check moved notin lockInCommit(fx)
    # Not even attempted: a re-pin of `up-src` to `alpha`'s revision would
    # name a fork commit in a node that fetches from upstream.
    check "'up-src'" notin lastFlakeLogLine(fx)
    var hookLine = ""
    for line in preCommitLog(fx).splitLines():
      if " hook-develop-set " in line: hookLine = line
    check "not substituted by develop mode, not compared: up-src=alpha" in
      hookLine


  test "selected source survives renamed membership and checkout URI pins":
    let binary = getEnv("REPRO_COORDINATE_TEST_BINARY", reproBinaryPath())
    doAssert fileExists(binary), "build repro before running this regression"
    doAssert findExe("git").len > 0
    var fx = setupNf2Fixture("renamed-selected-source")
    fx.repro = absolutePath(binary)
    defer: removeDir(fx.scratch)
    isolateNf2Config(fx)
    defer: releaseNf2Config()
    removePreCommitDispatch(fx)
    let alphaUrl = "https://github.com/metacraft-labs/alpha"
    let wsLock = readFile(fx.ws / "repro.lock").replace(originUrl(fx, "alpha"), alphaUrl)
    writeFile(fx.ws / "repro.lock", wsLock)
    let manifests = fx.ws / ".repro" / "manifests"
    createDir(manifests / "projects")
    createDir(manifests / "repos")
    var remotes = ""
    var includes: seq[string]
    for name in Nf2Repos:
      let url = if name == "alpha": alphaUrl else: originUrl(fx, name)
      let explicitUrl = if url.endsWith(".git"): url else: url & ".git"
      remotes.add("\n[[remote]]\nname = \"" & name & "\"\nfetch = \"" & explicitUrl & "\"\n")
      includes.add("\"repos/" & name & ".toml\"")
      let member = if name == "alpha": "legacy-alpha" else: name
      writeFile(manifests / "repos" / (name & ".toml"),
        "schema = \"reprobuild.workspace.repo.v1\"\n[repo]\nname = \"" & member &
        "\"\npath = \"" & name & "\"\nremote = \"" & name & "\"\nrevision = \"main\"\n")
    writeFile(manifests / "projects" / "nf2.toml",
      "schema = \"reprobuild.workspace.project.v1\"\nincludes = [" & includes.join(", ") &
      "]\n[project]\nname = \"nf2\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n" & remotes)
    writeFile(fx.app / "flake.nix", "{ inputs.modules-alias.url = \"github:metacraft-labs/alpha\"; outputs = _: {}; }\n")
    var lock = parseJson(nf2FlakeLockText(fx, fx.seedSha[0], fx.seedSha[1], fx.seedSha[2]))
    lock["nodes"]["root"]["inputs"] = %*{"modules-alias": "alpha-src"}
    lock["nodes"]["alpha-src"]["original"] = %*{"type": "github", "owner": "metacraft-labs", "repo": "alpha"}
    writeFile(lockPath(fx), $lock)
    proc bound(doc: JsonNode): JsonNode =
      for item in doc["overrides"]:
        if item["input"].getStr() == "modules-alias": return item
      nil
    let selected = flakeArgs(fx, "--all --json")
    checkpoint(selected.stdout & selected.stderr)
    check selected.code == 0
    let selectedDoc = parseJson(selected.stdout)
    let binding = bound(selectedDoc)
    let hasBinding = binding != nil
    require hasBinding
    check binding["repo"].getStr() == "legacy-alpha"
    check binding["path"].getStr() == siblingDir(fx, "alpha")
    check %"alpha" in selectedDoc["developSet"]
    check "NOT in the develop set" notin selected.stdout
    # Exact-name selectors keep their existing composed-lock universe; a
    # membership label is not silently added as a selector alias.
    for flag in ["--only=legacy-alpha", "--except=legacy-alpha"]:
      let rejected = flakeArgs(fx, flag & " --json")
      check rejected.code == 2
      check rejected.stdout.len == 0
      check "names no repo" in rejected.stderr
    # The actual checkout HEAD is distinct from the composer's locked pin.
    let advanced = moveSibling(fx, "alpha", "selected-source-head")
    check advanced != fx.seedSha[0]
    let state = flakeStatus(fx, "--json")
    check state.code == 0
    let row = statusRow(parseJson(state.stdout), "modules-alias")
    let hasStatusRow = row != nil
    require hasStatusRow
    check row["pinned"].getStr() == fx.seedSha[0]
    check row["sibling"].getStr() == advanced
    check readFile(fx.ws / "repro.lock") == wsLock
    # The checkout URI still identifies the declared primary forge source;
    # matching selected permission directly against file:// would lose it.
    let checkoutUrl = "file://" & siblingDir(fx, "alpha")
    lock["nodes"]["alpha-src"]["original"] = %*{"type": "git", "url": checkoutUrl}
    writeFile(lockPath(fx), $lock)
    writeFile(fx.app / "flake.nix", "{ inputs.modules-alias.url = \"git+" & checkoutUrl & "\"; outputs = _: {}; }\n")
    let local = flakeArgs(fx, "--all --json")
    check local.code == 0
    let localBinding = bound(parseJson(local.stdout))
    let hasLocalBinding = localBinding != nil
    require hasLocalBinding
    check localBinding["path"].getStr() == siblingDir(fx, "alpha")
    # A recipe pin names the primary forge identity while the flake input
    # names its local checkout. It must not be related by input-name guess.
    writeFile(siblingDir(fx, "alpha") / "repro.nim",
      "import repro_project_dsl\n\npackage alpha:\n  versions:\n    \"1.0.0\":\n      sourceRevision = \"refs/tags/a1\"\n")
    discard gitIn(fx, siblingDir(fx, "alpha"), "tag a1 " & fx.seedSha[0])
    writeFile(fx.app / "repro.nim", "import repro_project_dsl\n\npackage app:\n  uses:\n    \"alpha ==1.0.0\"\n")
    writeFile(fx.app / "repro.lock", reproLockText(fx, "app", headOf(fx, fx.app),
      [lockDepEntry(fx, "alpha", "../alpha", "alpha", fx.seedSha[0])]).replace(originUrl(fx, "alpha"), alphaUrl))
    let automatic = flakeArgs(fx, "--all --json")
    check automatic.code == 0
    let automaticDoc = parseJson(automatic.stdout)
    check bound(automaticDoc) == nil
    check automaticDoc["pinnedByRecipe"].len == 1
    check automaticDoc["pinnedByRecipe"][0]["repo"].getStr() == "alpha"
    let explicit = flakeArgs(fx, "--only=alpha --json")
    check explicit.code == 0
    let explicitBinding = bound(parseJson(explicit.stdout))
    let hasExplicitBinding = explicitBinding != nil
    require hasExplicitBinding
    check explicitBinding["repo"].getStr() == "legacy-alpha"
    check explicitBinding["path"].getStr() == siblingDir(fx, "alpha")
    let excluded = flakeArgs(fx, "--all --except=alpha --json")
    check excluded.code == 0
    check bound(parseJson(excluded.stdout)) == nil
    # Two selected records for the same primary source are ambiguous, even
    # when workspace membership has exactly one candidate. Never pick one.
    let start = wsLock.find("{ name = \"alpha\"")
    let finish = wsLock.find(" }", start) + 2
    require start >= 0 and finish > start
    let duplicate = wsLock[start ..< finish].replace("name = \"alpha\"", "name = \"shadow-alpha\"")
    writeFile(fx.ws / "repro.lock", wsLock[0 ..< finish] & ", " & duplicate & wsLock[finish .. ^1])
    let ambiguous = flakeArgs(fx, "--all --json")
    check ambiguous.code == 0
    check bound(parseJson(ambiguous.stdout)) == nil
    check "multiple selected develop rows" in ambiguous.stdout

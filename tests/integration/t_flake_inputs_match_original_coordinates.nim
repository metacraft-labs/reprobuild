## Real git checkouts, committed-format workspace lock and consumer flake lock;
## no mocks. Forge URLs in the workspace lock identify repositories without
## contacting a forge: all commands run against already-present local trees.
## Different input and node names prevent accidental name-based success.
import std/[json, os, strutils, unittest]
import nf3_override_state_fixture

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

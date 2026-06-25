## RA-31 — ``repro workspace init <url>`` URL resolution.
##
## Black-box test of the three resolution forms the cold-start ``init``
## accepts, driven through the resolution-only ``--print-resolved-url`` dry
## run so it is hermetic (no network, no clone):
##
##   1. a full HTTPS/git/SSH/file URL is used VERBATIM;
##   2. a ``host:org`` shorthand maps to ``<host-base>/<org>/repro-workspace``;
##   3. a bare org resolves via the DEFAULT VCS HOST to
##      ``<default-host-base>/<org>/repro-workspace``.
##
## The host-alias base URLs are overridden to a local ``file://`` base via
## ``REPRO_VCS_HOST_BASE_<HOST>`` so the shorthand and default-host forms are
## driven against local paths rather than github.com. The default host alias
## is selected hermetically with ``REPRO_DEFAULT_VCS_HOST``.
##
## Falsifiability:
##   - If the ``repro-workspace`` repo-name convention were dropped, the
##     ``host:org`` / bare-org resolved URLs would not end in
##     ``/<org>/repro-workspace`` and the equality checks fail.
##   - If a full URL were rewritten instead of used verbatim, the full-URL
##     check fails.
##   - If the default-host alias were ignored (hardcoded to github), the
##     bare-org check (driven against a NON-github alias base) fails.
##
## Skip rule: ``git`` missing on PATH (the binary still resolves URLs without
## it, but we keep the suite's uniform skip-on-no-git posture).

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc resolve(reproBin, url: string;
             env: openArray[tuple[name, value: string]]): CmdResult =
  runShell(shellCommand(@[reproBin, "workspace", "init", url,
    "--print-resolved-url"], env = env))

suite "RA-31 — init URL resolution":

  test "t_workspace_init_resolves_url_shorthand_and_default_host":
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-ra31-resolve-", "")
    defer: removeDir(scratch)

    # A local base dir standing in for the VCS host. ``host:org`` and
    # bare-org resolution append ``/<org>/repro-workspace`` to this base.
    let hostBase = scratch / "hosts" / "local"
    createDir(hostBase)
    let localBaseUrl = fileUrl(hostBase)

    # We override BOTH the ``github`` alias and a custom ``acme`` alias so the
    # bare-org/default-host path can be driven against a NON-github alias —
    # proving the default-host config is honored rather than hardcoded.
    let baseEnv = @[
      (name: "REPRO_VCS_HOST_BASE_GITHUB", value: localBaseUrl),
      (name: "REPRO_VCS_HOST_BASE_ACME", value: localBaseUrl),
    ]

    # --- Form 2: host:org shorthand --------------------------------------
    block:
      let res = resolve(reproBin, "github:metacraft-labs", baseEnv)
      check res.code == 0
      let resolved = res.output.strip()
      check resolved == localBaseUrl & "/metacraft-labs/repro-workspace"

    # --- Form 3: bare org via the DEFAULT VCS HOST -----------------------
    block:
      # Default host = github (env-selected); resolves through the github
      # alias base.
      let res = resolve(reproBin, "metacraft-labs",
        baseEnv & @[(name: "REPRO_DEFAULT_VCS_HOST", value: "github")])
      check res.code == 0
      check res.output.strip() ==
        localBaseUrl & "/metacraft-labs/repro-workspace"

    block:
      # Switch the DEFAULT VCS HOST to the custom ``acme`` alias: the bare-org
      # resolution must follow it (NOT a hardcoded github). This is the
      # load-bearing default-host assertion.
      let res = resolve(reproBin, "some-org",
        baseEnv & @[(name: "REPRO_DEFAULT_VCS_HOST", value: "acme")])
      check res.code == 0
      check res.output.strip() ==
        localBaseUrl & "/some-org/repro-workspace"

    # --- Form 1: a full URL is used VERBATIM -----------------------------
    block:
      let full = "https://example.invalid/some-org/repro-workspace"
      let res = resolve(reproBin, full, baseEnv)
      check res.code == 0
      check res.output.strip() == full

    block:
      # An scp-like SSH URL is also verbatim.
      let sshUrl = "git@github.com:metacraft-labs/repro-workspace.git"
      let res = resolve(reproBin, sshUrl, baseEnv)
      check res.code == 0
      check res.output.strip() == sshUrl

    # --- Unknown host alias fails loud (no silent fallback) --------------
    block:
      let res = resolve(reproBin, "nosuchhost:org", baseEnv)
      check res.code != 0
      check res.output.toLowerAscii().contains("unknown vcs host alias")

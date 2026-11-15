## Behavioural coverage for the OpenSSL link-search selection that
## scripts/build_apps.sh makes for --define:ssl entrypoints: in a Nix package
## build the -L comes from NIX_LDFLAGS, else OPENSSL_LIBDIR, else the build
## refuses instead of using the Homebrew fallback.
##
## There are no fakes. The test runs the real scripts/lib/package_build_openssl.sh
## (the file build_apps.sh sources) with the real bash, in a scrubbed
## environment (`env -i`), against real temporary directories. The non-package
## cases assert only "no refusal", never a Homebrew path, so the result does not
## depend on whether this host has /opt/homebrew.

import std/[os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  type Run = tuple[output: string, exitCode: int]

  proc selectOpenssl(repoRoot: string; vars: seq[(string, string)]): Run =
    ## Sources the real helper under `env -i` with exactly `vars` set.
    let helper = repoRoot / "scripts" / "lib" / "package_build_openssl.sh"
    var args = @["-i", "PATH=" & getEnv("PATH")]
    for (k, v) in vars: args.add(k & "=" & v)
    args.add(["bash", "-c",
      "set -euo pipefail; source \"$1\"; " &
      "echo \"package_build=${package_build}\"; " &
      "echo \"passl=${openssl_passl[*]:-}\"", "select", helper])
    let (output, code) = execCmdEx(quoteShellCommand(@["env"] & args),
      options = {poStdErrToStdOut})
    (output, code)

  proc requirePrefix(repoRoot, name: string;
                     vars: seq[(string, string)]): Run =
    ## Sources the real helper, then calls its `require_package_prefix NAME`.
    let helper = repoRoot / "scripts" / "lib" / "package_build_openssl.sh"
    var args = @["-i", "PATH=" & getEnv("PATH")]
    for (k, v) in vars: args.add(k & "=" & v)
    args.add(["bash", "-c",
      "set -euo pipefail; source \"$1\"; require_package_prefix \"$2\"; " &
      "echo accepted", "select", helper, name])
    let (output, code) = execCmdEx(quoteShellCommand(@["env"] & args),
      options = {poStdErrToStdOut})
    (output, code)

  suite "package-build OpenSSL selection":
    let repoRoot = getCurrentDir()
    let nixLib = "/nix/store/00000000000000000000000000000000-openssl-3.0/lib"

    template withTmp(body: untyped) =
      let tmp {.inject.} = createTempDir("repro-openssl-select-", "")
      let libDir {.inject.} = tmp / "openssl" / "lib"
      createDir(libDir)
      defer: removeDir(tmp)
      body

    test "a package build with no OpenSSL source refuses":
      withTmp:
        let r = selectOpenssl(repoRoot, @[("NIX_BUILD_TOP", tmp)])
        check r.exitCode == 2
        check r.output.contains("refusing the")

    test "a package build uses an existing OPENSSL_LIBDIR":
      withTmp:
        let r = selectOpenssl(repoRoot,
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", libDir)])
        check r.exitCode == 0
        check r.output.contains("--passL:-L" & libDir)

    test "a package build refuses a nonexistent OPENSSL_LIBDIR":
      withTmp:
        let r = selectOpenssl(repoRoot,
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", tmp / "missing")])
        check r.exitCode == 2

    test "NIX_LDFLAGS wins over OPENSSL_LIBDIR in a package build":
      withTmp:
        let r = selectOpenssl(repoRoot,
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", libDir),
            ("NIX_LDFLAGS", "-L/nix/store/zzz-other/lib -L" & nixLib)])
        check r.exitCode == 0
        check r.output.contains("--passL:-L" & nixLib)
        check not r.output.contains(libDir)

    test "a dev shell (IN_NIX_SHELL) keeps the host fallback and does not refuse":
      withTmp:
        let r = selectOpenssl(repoRoot,
          @[("NIX_BUILD_TOP", tmp), ("IN_NIX_SHELL", "impure")])
        check r.exitCode == 0
        check r.output.contains("package_build=0")

    test "a non-package environment does not refuse":
      withTmp:
        let r = selectOpenssl(repoRoot, @[])
        check r.exitCode == 0
        check r.output.contains("package_build=0")

    test "a package build refuses a runtime prefix that is unset":
      withTmp:
        let r = requirePrefix(repoRoot, "CLINGO_PREFIX",
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", libDir)])
        check r.exitCode == 2
        check r.output.contains("CLINGO_PREFIX is unset")

    test "a package build refuses a runtime prefix that is not a directory":
      withTmp:
        let r = requirePrefix(repoRoot, "ZSTD_PREFIX",
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", libDir),
            ("ZSTD_PREFIX", tmp / "missing")])
        check r.exitCode == 2
        check r.output.contains("is not a directory")

    test "a package build accepts a runtime prefix that is a directory":
      withTmp:
        let r = requirePrefix(repoRoot, "ZSTD_PREFIX",
          @[("NIX_BUILD_TOP", tmp), ("OPENSSL_LIBDIR", libDir),
            ("ZSTD_PREFIX", tmp)])
        check r.exitCode == 0
        check r.output.contains("accepted")

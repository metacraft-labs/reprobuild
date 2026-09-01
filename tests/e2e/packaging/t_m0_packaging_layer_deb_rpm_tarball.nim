## M0 PACKAGING-LAYER gate — one build-graph definition → `.deb` + `.rpm`
## + `.tar.gz`, and a container that installs the `.deb` and runs a binary.
##
## Spec: `reprobuild-specs/Distribution-And-Packaging.md` §5–§6 +
## `Distribution-And-Packaging.milestones.org` `* M0 PACKAGING-LAYER`.
##
## Drives the checked-in sample `examples/two-binary-dist` (whose
## `reprobuild.nim` emits all three formats from a single `distribution`
## value via `libs/repro_dsl_stdlib/.../packaging/`) and asserts:
##
##   1. `repro build` produces the `.deb`, `.rpm`, AND `.tar.gz`.
##   2. Re-running the build cache-hits every producer edge
##      (content-addressed: rebuild is cache-hit-identical).
##   3. `docker run debian … dpkg -i <deb> && greeter` installs both
##      binaries to `/usr/bin` and the §5 wrapper's env-default is applied
##      (installed `greeter` prints the packaged default greeting).
##
## Self-gating. The backend tools (`gcc`, `tar`, `dpkg-deb`, `rpmbuild`)
## and the Docker daemon are not present on every host — each missing
## capability degrades the test to a checkpoint+return rather than a
## failure, so it runs fully on a Debian/Fedora CI runner with Docker and
## skips cleanly elsewhere. It still hard-requires the bootstrapped
## `build/bin/repro` (the suite builds `.#apps` before running, per
## `scripts/run_tests.sh`).

import std/[os, osproc, strutils, unittest]

import repro_test_support

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc firstWithExt(dir, ext: string): string =
  ## The first file in `dir` whose name ends with `ext`, or "".
  if not dirExists(dir): return ""
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(ext):
      return path
  ""

proc dockerAvailable(): bool =
  findExe("docker").len > 0 and
    execCmdEx("docker info").exitCode == 0

proc actionCacheEffective(log, id: string): bool =
  let p = "action: " & id & " status="
  log.contains(p & "asCacheHit launched=false") or
  log.contains(p & "asUpToDate launched=false")

suite "m0_packaging_layer_deb_rpm_tarball":
  when isNixSupported:
    test "m0_packaging_layer_deb_rpm_tarball":
      let repoRoot = getCurrentDir()
      let projectDir = repoRoot / "examples" / "two-binary-dist"
      let buildDir = projectDir / "build"

      # --- capability gate: the backend toolchain must be on PATH -------
      # (`return` is not allowed inside a unittest `test` body, so the
      # gates are nested rather than early-returned.)
      var missing: seq[string] = @[]
      for tool in ["gcc", "tar", "dpkg-deb", "rpmbuild"]:
        if findExe(tool).len == 0: missing.add(tool)
      if missing.len > 0:
        checkpoint("skip: packaging backend tools absent on PATH: " &
          missing.join(", "))
      else:
        let reproBin = reproBinary(repoRoot)

        # Clean any prior artifacts so existence assertions are meaningful.
        removeDir(buildDir)

        # --- gate check 1: one definition → deb + rpm + tarball ---------
        let buildArgs = @[reproBin, "build", projectDir,
          "--daemon=off", "--no-runquota",
          "--tool-provisioning=path", "--log=actions"]
        let first = requireSuccess(shellCommand(buildArgs), repoRoot)
        check first.contains(
          "action: package-deb-two-bin-dist status=asSucceeded launched=true")
        check first.contains(
          "action: package-rpm-two-bin-dist status=asSucceeded launched=true")
        check first.contains(
          "action: package-tarball-two-bin-dist status=asSucceeded launched=true")

        let debPath = firstWithExt(buildDir, ".deb")
        let rpmPath = firstWithExt(buildDir, ".rpm")
        let tgzPath = firstWithExt(buildDir, ".tar.gz")
        check debPath.len > 0
        check rpmPath.len > 0
        check tgzPath.len > 0

        # --- gate check 2: producers are content-addressed edges -------
        let second = requireSuccess(shellCommand(buildArgs), repoRoot)
        check actionCacheEffective(second, "package-deb-two-bin-dist")
        check actionCacheEffective(second, "package-rpm-two-bin-dist")
        check actionCacheEffective(second, "package-tarball-two-bin-dist")

        # --- gate check 3: install the .deb in a container and run -----
        if debPath.len == 0 or not dockerAvailable():
          checkpoint("skip container leg: Docker daemon unavailable " &
            "(artifacts still produced + verified above)")
        else:
          let debName = debPath.extractFilename
          let containerScript =
            "set -e; dpkg -i /pkg/" & debName & "; " &
            "test -x /usr/bin/greeter; test -x /usr/bin/farewell; " &
            "/usr/bin/greeter; /usr/bin/farewell"
          let dockerOut = requireSuccess(shellCommand([
            "docker", "run", "--rm",
            "-v", buildDir & ":/pkg:ro",
            "debian:stable-slim",
            "sh", "-c", containerScript]), repoRoot)
          # Both binaries ran from the declared prefix …
          check dockerOut.contains(
            "farewell: goodbye from reprobuild packaging")
          # … and the §5 env-default wrapper seeded TWO_BIN_DIST_GREETING,
          # so the installed greeter prints the PACKAGED default.
          check dockerOut.contains(
            "greeter: hello from the installed package")

import repro_project_dsl

package stylus:
  provisioning:
    nixPackage "reprobuild-stdlib-stylus-0.64.0",
      executablePath = "bin/stylus",
      expressionFile = "nix/stylus-0.64.0/default.nix",
      lockIdentity = "npm:stylus@0.64.0"
    # Windows: stylus is an npm package with no native scoop manifest.
    # Operators on cakScoop need a Node.js install (covered by `node`'s
    # scoopApp(...) entry above) and a workspace-local
    # `yarn install`-driven `node_modules/.bin/stylus.cmd`. There is no
    # clean way to surface that through scoopApp's content-addressable
    # prefix shape; this placeholder fails at install time with a clear
    # `EScoopBucketMissing` so operators see the gap rather than a
    # silent fallback. A future milestone should add an `npm:`
    # provisioning shape to the DSL that runs `npm install -g
    # stylus@<ver>` and surfaces the `npm prefix -g` path.
    scoopApp(bucket = "main", app = "nodejs",
      preferredVersion = ">=20", executablePath = "node.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download fallback: same Node.js archive as `node.nim`.
    # stylus itself is npm-only and the project's `yarn install` step
    # lands `node_modules/.bin/stylus.cmd` in the workspace; this
    # entry exists so the build-time tool resolution can satisfy the
    # `stylus` selector without a workspace-local yarn yet.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.7z",
      sha256 = "9f0ad977a75a1ca1a2ebe1294caf64e6c6b4de89d3b6dff218455de3fa0a3211",
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "node.exe",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:9f0ad977a75a1ca1a2ebe1294caf64e6c6b4de89d3b6dff218455de3fa0a3211"
    # Linux x86_64: same Node.js distribution as `node.nim`. Same
    # caveat as the Windows entry — stylus itself is npm-only and
    # the project's `yarn install` lands the actual `stylus` binary
    # in `node_modules/.bin/stylus`; this points at `bin/node` to
    # satisfy build-time tool resolution.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz",
      sha256 = "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:linux:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"

  executable stylus:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: ``-o`` is the primary output. The DSL
        # records the flag name; the engine derives the implicit
        # target name from the value the call supplies at M1.
        outputs output

## ``repro_dsl_stdlib/packages/chocolatey`` — the Chocolatey CLI (``choco``).
##
## WINDOWS ONLY, and not because the other arms are merely unwritten: Chocolatey
## is a Windows package manager and has no POSIX build. A recipe that needs it
## MUST guard the dependency, e.g.
##
##   uses:
##     when defined(windows):
##       "chocolatey"
##
## The guard is still required, but it is no longer the only thing standing
## between an unguarded `uses:` and a wrong answer. Since PMC-1 the package
## itself declares `platforms: [windows]`, and resolution consults that BEFORE
## the adapter chain: an unguarded `uses: "chocolatey"` on Linux now fails
## naming the reason ("chocolatey is declared for windows only; this host is
## linux") instead of exhausting the chain and advising remediations —
## catalogue it, put it on PATH — that are impossible for a Windows package
## manager. It also no longer reaches the `cakPath` adapter, so a Linux host
## carrying some unrelated `chocolatey` binary can no longer resolve to it.
##
## The guard remains because availability and conditionality are different
## questions, which is why Nix keeps `meta.platforms` alongside
## `lib.optionals stdenv.isLinux` and Spack keeps `requires(...)` alongside
## `depends_on(..., when=...)`. `platforms:` says where this package CAN exist;
## `when defined(windows):` says whether this recipe NEEDS it here. See
## reprobuild-specs Package-Model.md, "GAP: a package cannot declare the
## platforms it exists on".
##
## WHAT CONSUMES THIS. The ``codetracer-*-recorder`` repos publish a Chocolatey
## package per release: ``packaging/chocolatey/`` holds the ``.nuspec`` and the
## ``chocolateyInstall.ps1`` / ``chocolateyUninstall.ps1`` scripts, and
## ``publish-chocolatey.yml`` runs ``choco pack`` + ``choco push`` against the
## Chocolatey Community Repository on a version tag. Chocolatey is therefore an
## OUTPUT channel for those projects — the Windows sibling of their Homebrew,
## Scoop and AUR lanes — not a build input.
##
## WHY IT IS DECLARED HERE RATHER THAN INSTALLED ON THE CI RUNNER. A project's
## tools belong to the project. Putting ``choco`` in a runner's system profile
## would make one machine carry a dependency owned by thirteen repositories,
## and the next consumer's tool after it; worse, the developer and CI would then
## get whatever the box happened to have rather than the same pinned artifact.
## Declared here, ``repro`` materialises the identical ``choco`` for both on
## entering the dev env.
##
## PORTABILITY OF THE ARM — verified rather than assumed, because this is
## exactly the shape ``packages/clingo.nim`` warns about (a resolver that
## succeeds and then yields a broken realization). Chocolatey's own installer
## normally sets ``$env:ChocolateyInstall``, registers a shim and writes under
## ``C:\ProgramData\chocolatey``. None of that is required for the operations
## the recorders use. Measured on win-ci-bare-001, 2026-08-20, from a plain
## extraction of the pinned ``.nupkg`` with no install step and no
## ``ChocolateyInstall`` set:
##
##   choco.exe --version            -> 2.4.3, exit 0
##   choco.exe pack <a real nuspec> -> "Successfully created package …nupkg", exit 0
##
## ``push`` is not exercisable here (it needs the community API key and the
## network), but it is the same binary and the same code path as ``pack`` up to
## the HTTP call.
##
## THE ARTIFACT. ``https://community.chocolatey.org/api/v2/package/chocolatey/<ver>``
## is the NuGet v2 package endpoint; it returns a ``.nupkg``, which is a zip —
## hence ``archiveType = "zip"`` despite the URL carrying no extension. The
## payload nests the real binary at ``tools/chocolateyInstall/choco.exe``
## alongside its ``helpers/`` and ``tools/`` trees, so there is no
## ``stripComponents``: the nesting IS the prefix shape and ``executablePath``
## addresses into it, the same way ``packages/capnp.nim`` handles its
## two-top-level-directory zip.

import repro_project_dsl

package chocolatey:
  platforms:
    [windows]
    msg = "Chocolatey is a Windows package manager; it has no POSIX " &
      "build, so there is nothing to catalogue for Linux or macOS."
  provisioning:
    tarball url = "https://community.chocolatey.org/api/v2/package/chocolatey/2.4.3",
      sha256 = "d4998ca928a85a484507dcaa39c30948a6516de0d1469b0511931d44a53456c3",
      archiveType = "zip",
      executablePath = "tools/chocolateyInstall/choco.exe",
      packageId = "chocolatey@2.4.3",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:chocolatey@2.4.3:sha256:d4998ca928a85a484507dcaa39c30948a6516de0d1469b0511931d44a53456c3"

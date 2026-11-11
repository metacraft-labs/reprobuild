## The Nix-channel pins of the catalog's Rust toolchains (``packages/rustc.nim``
## and ``packages/cargo.nim``, one expression per release for both).
##
## Each ``packages/nix/rust-<version>/default.nix`` realises rust-lang's own
## release archive for the platform it is evaluated on, one archive and
## SHA-256 per platform (each equal to rust-lang's published ``.sha256``).
## A lock identity names what was realised, so it names that platform's
## archive: the engine is built for the platform it realises tools on, and
## the compile-time platform of this module selects the row. It used to name
## the x86_64-linux archive on every platform (ReproOS Add-On Mode §13
## decision 35(a), A12 review).
##
## The catalog offers more than one release. Each ``nixPackage`` arm declares
## its ``version``, so a ``uses:`` range selects among them; the default
## release (``RustDefaultRelease``) is listed first, and an unranged or wide
## ``uses:`` takes it.
##
## Keep each release's rows equal to the ``archives`` set of its
## ``default.nix``; a platform without a row there is refused by the
## expression, and named as unpinned here.

type
  RustRelease* = object
    ## One rust-lang release, as the Nix channel pins it.
    version*: string
    sha256X8664Linux*: string
    sha256Aarch64Linux*: string
    sha256Aarch64Darwin*: string
    sha256X8664Darwin*: string

const
  RustRelease1940* = RustRelease(version: "1.94.0",
    sha256X8664Linux:
      "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
    sha256Aarch64Linux:
      "c6fd6d1c925ed986df3b2c0b89bbc90ce15afb62e4d522a054e7d50c856b3c1a",
    sha256Aarch64Darwin:
      "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
    sha256X8664Darwin:
      "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7")
    ## The default release.

  RustRelease1971* = RustRelease(version: "1.97.1",
    # https://static.rust-lang.org/dist/rust-1.97.1-<triple>.tar.xz.sha256,
    # read 2026-11-11 and equal to the ``xz_hash`` rows of
    # https://static.rust-lang.org/dist/channel-rust-1.97.toml.
    sha256X8664Linux:
      "88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f",
    sha256Aarch64Linux:
      "9a7a2c336b4787f1b72f6bab7c35d5b7af2fd03cbd39b4fc721466a70d402a7d",
    sha256Aarch64Darwin:
      "c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2",
    sha256X8664Darwin:
      "891c32ea77b750dccc7fb0ea98e3feb9db3d29fe0cfea5907d002f270c59cf58")
    ## For crates that need a newer stable compiler than the default
    ## (``std::hint::cold_path`` is stable from 1.95, for example).

  RustDefaultRelease* = RustRelease1940
  RustReleases* = [RustRelease1940, RustRelease1971]
    ## Default first: the order of the ``nixPackage`` arms.

  RustNixPlatform* =
    when defined(linux) and defined(amd64): "x86_64-linux"
    elif defined(linux) and defined(arm64): "aarch64-linux"
    elif defined(macosx) and defined(arm64): "aarch64-darwin"
    elif defined(macosx) and defined(amd64): "x86_64-darwin"
    else: ""
    ## The Nix system of the platform this engine is built for, "" when the
    ## expression pins no archive for it.

proc rustNixArchiveSha256*(release: RustRelease): string =
  ## ``release``'s archive digest for the platform this engine is built for,
  ## "" when it pins none.
  when defined(linux) and defined(amd64): release.sha256X8664Linux
  elif defined(linux) and defined(arm64): release.sha256Aarch64Linux
  elif defined(macosx) and defined(arm64): release.sha256Aarch64Darwin
  elif defined(macosx) and defined(amd64): release.sha256X8664Darwin
  else: ""

proc rustNixLockIdentity*(release: RustRelease): string =
  ## The ``lockIdentity`` of ``release``'s ``rustc`` and ``cargo``
  ## ``nixPackage`` arms on this platform.
  if RustNixPlatform.len > 0:
    "nix-expression:rust@" & release.version & ":" & RustNixPlatform &
      ":sha256:" & rustNixArchiveSha256(release)
  else:
    "nix-expression:rust@" & release.version & ":unpinned-platform"

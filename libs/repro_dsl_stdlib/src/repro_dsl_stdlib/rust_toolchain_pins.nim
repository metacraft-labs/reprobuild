## The Nix-channel pins of the catalog's Rust toolchain (``packages/rustc.nim``
## and ``packages/cargo.nim``, one expression for both).
##
## ``packages/nix/rust-1.94.0/default.nix`` realises rust-lang's own 1.94.0
## release archive for the platform it is evaluated on, one archive and
## SHA-256 per platform (each equal to rust-lang's published ``.sha256``).
## A lock identity names what was realised, so it names that platform's
## archive: the engine is built for the platform it realises tools on, and
## the compile-time platform of this module selects the row. It used to name
## the x86_64-linux archive on every platform (ReproOS Add-On Mode §13
## decision 35(a), A12 review).
##
## Keep the rows equal to the ``archives`` set of ``default.nix``; a platform
## without a row there is refused by the expression, and named as unpinned
## here.

const
  RustNixVersion* = "1.94.0"
  RustNixArchiveSha256X8664Linux* =
    "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a"
  RustNixArchiveSha256Aarch64Linux* =
    "c6fd6d1c925ed986df3b2c0b89bbc90ce15afb62e4d522a054e7d50c856b3c1a"
  RustNixArchiveSha256Aarch64Darwin* =
    "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c"
  RustNixArchiveSha256X8664Darwin* =
    "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7"

  RustNixPlatform* =
    when defined(linux) and defined(amd64): "x86_64-linux"
    elif defined(linux) and defined(arm64): "aarch64-linux"
    elif defined(macosx) and defined(arm64): "aarch64-darwin"
    elif defined(macosx) and defined(amd64): "x86_64-darwin"
    else: ""
    ## The Nix system of the platform this engine is built for, "" when the
    ## expression pins no archive for it.

  RustNixArchiveSha256* =
    when defined(linux) and defined(amd64): RustNixArchiveSha256X8664Linux
    elif defined(linux) and defined(arm64): RustNixArchiveSha256Aarch64Linux
    elif defined(macosx) and defined(arm64): RustNixArchiveSha256Aarch64Darwin
    elif defined(macosx) and defined(amd64): RustNixArchiveSha256X8664Darwin
    else: ""

  RustNixLockIdentity* =
    if RustNixPlatform.len > 0:
      "nix-expression:rust@" & RustNixVersion & ":" & RustNixPlatform &
        ":sha256:" & RustNixArchiveSha256
    else:
      "nix-expression:rust@" & RustNixVersion & ":unpinned-platform"
    ## The ``lockIdentity`` of the ``rustc`` and ``cargo`` ``nixPackage``
    ## arms on this platform.

## The Nix-channel pins of the catalog's Go toolchain (``packages/go.nim``).
##
## ``packages/nix/go-1.25.4/default.nix`` realises go.dev's own 1.25.4
## release archive for the platform it is evaluated on, one archive and
## SHA-256 per platform, from https://go.dev/dl/?mode=json&include=all
## (ReproOS Add-On Mode §13 decision 36: nixpkgs' Go embeds /nix/store paths
## in the binaries it compiles). A lock identity names what was realised,
## so it names this platform's archive; the engine is built for the platform
## it realises tools on, and the compile-time platform selects the row.
##
## Keep the rows equal to the ``archives`` set of ``default.nix`` and to the
## ``tarball`` arms of ``go.nim``.

const
  GoNixVersion* = "1.25.4"
  GoNixArchiveSha256LinuxAmd64* =
    "9fa5ffeda4170de60f67f3aa0f824e426421ba724c21e133c1e35d6159ca1bec"
  GoNixArchiveSha256LinuxArm64* =
    "a68e86d4b72c2c2fecf7dfed667680b6c2a071221bbdb6913cf83ce3f80d9ff0"
  GoNixArchiveSha256DarwinAmd64* =
    "33ba03ff9973f5bd26d516eea35328832a9525ecc4d169b15937ffe2ce66a7d8"
  GoNixArchiveSha256DarwinArm64* =
    "c1b04e74251fe1dfbc5382e73d0c6d96f49642d8aebb7ee10a7ecd4cae36ebd2"

  GoNixPlatform* =
    when defined(linux) and defined(amd64): "x86_64-linux"
    elif defined(linux) and defined(arm64): "aarch64-linux"
    elif defined(macosx) and defined(arm64): "aarch64-darwin"
    elif defined(macosx) and defined(amd64): "x86_64-darwin"
    else: ""
    ## The Nix system this engine is built for, "" when unpinned.

  GoNixArchiveSha256* =
    when defined(linux) and defined(amd64): GoNixArchiveSha256LinuxAmd64
    elif defined(linux) and defined(arm64): GoNixArchiveSha256LinuxArm64
    elif defined(macosx) and defined(arm64): GoNixArchiveSha256DarwinArm64
    elif defined(macosx) and defined(amd64): GoNixArchiveSha256DarwinAmd64
    else: ""

  GoNixLockIdentity* =
    if GoNixPlatform.len > 0:
      "nix-expression:go@" & GoNixVersion & ":" & GoNixPlatform &
        ":sha256:" & GoNixArchiveSha256
    else:
      "nix-expression:go@" & GoNixVersion & ":unpinned-platform"
    ## The ``lockIdentity`` of ``go``'s ``nixPackage`` arm on this platform.

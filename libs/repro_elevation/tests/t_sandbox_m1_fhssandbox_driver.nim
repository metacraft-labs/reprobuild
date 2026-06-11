## Library-local unit tests for the Linux-Third-Party-Sandbox-MVP M1
## driver scaffold: `linux.fhsSandbox`.
##
## Covers the PLATFORM-PURE surface — closed-set validation, RBEB
## codec round-trip, kind <-> string helpers, `requiresElevation`, the
## desired-digest computation, and the pure argv-builder
## `buildLinuxFhsSandboxArgv` (the M0-locked transparency-posture
## bwrap invocation shape). The actual `bwrap`-spawn apply path is
## gated `when defined(linux)` and exercised by the M6 host integration
## tier — off-Linux it raises `ENotImplementedPlatform`.
##
## These tests run on every host (Windows, Linux, macOS) via
## `nim c -r`; they do NOT require a Linux runtime, a real bubblewrap
## process, or any privileged-broker IPC.

import std/[strutils, unittest]

import repro_core
import repro_elevation

# ---------------------------------------------------------------------
# Helper: a known-good apply op the closed-set validator accepts.
# Keeps every test's setup boilerplate to one line so each test names
# the SPECIFIC field it is exercising rather than re-stating the whole
# happy-path object.
# ---------------------------------------------------------------------

proc goodApplyOp(): PrivilegedOperation =
  PrivilegedOperation(
    kind: pokLinuxFhsSandbox,
    address: "hello-from-debian",
    fsbBinPath: "/usr/bin/hello",
    fsbFhsTreeRoots: @["/repro/store/abc123-hello"],
    fsbArgv: @["--greeting", "world"],
    fsbDestroy: false)

proc goodDestroyOp(): PrivilegedOperation =
  PrivilegedOperation(
    kind: pokLinuxFhsSandbox,
    address: "remove-hello",
    fsbBinPath: "/usr/bin/hello",
    fsbFhsTreeRoots: @[],
    fsbArgv: @[],
    fsbDestroy: true)

suite "Linux-Third-Party-Sandbox-MVP M1 — linux.fhsSandbox kind tag":

  test "kind tag round-trips through the string helpers":
    check $pokLinuxFhsSandbox == "linux.fhsSandbox"
    check isKnownPrivilegedOperationKind("linux.fhsSandbox")
    check privilegedOperationKindFromString("linux.fhsSandbox") ==
      pokLinuxFhsSandbox

  test "requiresElevation is true (system-scope)":
    # bubblewrap needs the user-namespace + mount-namespace privilege
    # the broker is here to acquire. Even on hosts where unprivileged
    # user-ns is enabled (every M0-target distro), the dispatch flow
    # still goes through the broker for the apply-log + drift gate.
    check requiresElevation(pokLinuxFhsSandbox)

suite "Linux-Third-Party-Sandbox-MVP M1 — closed-set validation":

  test "operationValidationError accepts a valid apply op":
    check operationValidationError(goodApplyOp()) == ""

  test "operationValidationError accepts a valid destroy op":
    # A destroy is a no-op (sandbox isn't persistent) so an empty
    # fhsTreeRoots is accepted — the apply path short-circuits before
    # composing the FHS view.
    check operationValidationError(goodDestroyOp()) == ""

  test "operationValidationError rejects an empty address":
    var bad = goodApplyOp()
    bad.address = ""
    check "empty address" in operationValidationError(bad)

  test "operationValidationError rejects an empty binPath":
    var bad = goodApplyOp()
    bad.fsbBinPath = ""
    let err = operationValidationError(bad)
    check err.len > 0
    check "binPath" in err

  test "operationValidationError rejects a non-absolute binPath":
    var bad = goodApplyOp()
    bad.fsbBinPath = "usr/bin/hello"
    let err = operationValidationError(bad)
    check err.len > 0
    check "absolute path" in err

  test "operationValidationError rejects a Windows-style binPath":
    var bad = goodApplyOp()
    bad.fsbBinPath = "C:\\Windows\\System32\\cmd.exe"
    let err = operationValidationError(bad)
    check err.len > 0
    check "absolute path" in err

  test "operationValidationError rejects a binPath with a NUL byte":
    var bad = goodApplyOp()
    bad.fsbBinPath = "/usr/bin/x\x00rm"
    let err = operationValidationError(bad)
    check err.len > 0
    check "NUL" in err

  test "operationValidationError rejects an empty fhsTreeRoots list":
    var bad = goodApplyOp()
    bad.fsbFhsTreeRoots = @[]
    let err = operationValidationError(bad)
    check err.len > 0
    check "fhsTreeRoots" in err

  test "operationValidationError rejects a non-absolute fhsTreeRoots entry":
    var bad = goodApplyOp()
    bad.fsbFhsTreeRoots = @["repro/store/abc"]
    let err = operationValidationError(bad)
    check err.len > 0
    check "absolute path" in err

  test "operationValidationError rejects an empty fhsTreeRoots entry":
    var bad = goodApplyOp()
    bad.fsbFhsTreeRoots = @[""]
    let err = operationValidationError(bad)
    check err.len > 0

  test "operationValidationError rejects a fhsTreeRoots entry with a NUL byte":
    var bad = goodApplyOp()
    bad.fsbFhsTreeRoots = @["/repro/store/x\x00rm"]
    let err = operationValidationError(bad)
    check err.len > 0
    check "NUL" in err

  test "operationValidationError rejects an argv entry with a NUL byte":
    var bad = goodApplyOp()
    bad.fsbArgv = @["--first", "second\x00rm -rf /"]
    let err = operationValidationError(bad)
    check err.len > 0
    check "NUL" in err

  test "operationValidationError accepts argv with shell metacharacters":
    # The driver builds a bwrap argv VECTOR (not a shell command); a
    # shell-metacharacter in an argv element flows through `execve` as
    # a literal byte. The closed-set validator therefore does NOT
    # refuse `;` / `&` / `|` / `$` etc. — only NUL (the kernel limit).
    var ok = goodApplyOp()
    ok.fsbArgv = @["--flag", "value; rm -rf /", "$HOME", "`x`", "|", "&"]
    check operationValidationError(ok) == ""

  test "operationValidationError accepts multiple fhsTreeRoots entries":
    # M1 only USES the first entry, but the closed-set validator
    # accepts a multi-entry shape today so M2's compose path does not
    # need a wire-format break.
    var ok = goodApplyOp()
    ok.fsbFhsTreeRoots = @["/repro/store/a", "/repro/store/b",
                             "/repro/store/c"]
    check operationValidationError(ok) == ""

suite "Linux-Third-Party-Sandbox-MVP M1 — RBEB codec":

  test "RBEB codec round-trips an apply op":
    let ok = goodApplyOp()
    let wired = WireOperation(operation: ok, baselineDigestHex: "abc")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.kind == pokLinuxFhsSandbox
    check decoded.operation.address == "hello-from-debian"
    check decoded.operation.fsbBinPath == "/usr/bin/hello"
    check decoded.operation.fsbFhsTreeRoots == @["/repro/store/abc123-hello"]
    check decoded.operation.fsbArgv == @["--greeting", "world"]
    check decoded.operation.fsbDestroy == false
    check decoded.baselineDigestHex == "abc"

  test "RBEB codec round-trips a destroy op":
    let dop = goodDestroyOp()
    let wired = WireOperation(operation: dop, baselineDigestHex: "")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.kind == pokLinuxFhsSandbox
    check decoded.operation.fsbDestroy == true
    check decoded.operation.fsbFhsTreeRoots.len == 0
    check decoded.operation.fsbArgv.len == 0

  test "RBEB codec round-trips a multi-entry fhsTreeRoots shape":
    var op = goodApplyOp()
    op.fsbFhsTreeRoots = @[
      "/repro/store/aaa-glibc",
      "/repro/store/bbb-coreutils",
      "/repro/store/ccc-hello"]
    op.fsbArgv = @["--one", "--two", "--three"]
    let wired = WireOperation(operation: op, baselineDigestHex: "")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.fsbFhsTreeRoots.len == 3
    check decoded.operation.fsbFhsTreeRoots[1] ==
      "/repro/store/bbb-coreutils"
    check decoded.operation.fsbArgv == @["--one", "--two", "--three"]

  test "RBEB codec round-trips an empty argv":
    var op = goodApplyOp()
    op.fsbArgv = @[]
    let wired = WireOperation(operation: op, baselineDigestHex: "")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.fsbArgv.len == 0

suite "Linux-Third-Party-Sandbox-MVP M1 — desired-digest":

  test "linux.fhsSandbox desired digest covers binPath":
    let opA = goodApplyOp()
    var opB = goodApplyOp()
    opB.fsbBinPath = "/usr/bin/different"
    let digA = posixSystemDesiredDigestHex(opA)
    let digB = posixSystemDesiredDigestHex(opB)
    check digA != digB
    check digA.len == 64

  test "linux.fhsSandbox desired digest covers fhsTreeRoots":
    let opA = goodApplyOp()
    var opB = goodApplyOp()
    opB.fsbFhsTreeRoots = @["/repro/store/different-hello"]
    check posixSystemDesiredDigestHex(opA) !=
      posixSystemDesiredDigestHex(opB)

  test "linux.fhsSandbox desired digest covers argv":
    let opA = goodApplyOp()
    var opB = goodApplyOp()
    opB.fsbArgv = @["--greeting", "moon"]
    check posixSystemDesiredDigestHex(opA) !=
      posixSystemDesiredDigestHex(opB)

  test "linux.fhsSandbox desired digest is stable across runs":
    # Two identical PrivilegedOperations digest identically. The
    # NUL-separated canonical form encodes every component
    # deterministically.
    let digA = posixSystemDesiredDigestHex(goodApplyOp())
    let digB = posixSystemDesiredDigestHex(goodApplyOp())
    check digA == digB

  test "linux.fhsSandbox destroy op digests to ZeroDigestHex":
    check posixSystemDesiredDigestHex(goodDestroyOp()) == ZeroDigestHex

suite "Linux-Third-Party-Sandbox-MVP M1 — argv composition (M0 posture)":

  test "buildLinuxFhsSandboxArgv emits the M0 bwrap invocation shape":
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    # First token is the bubblewrap executable name; the driver does
    # NOT pin a path to bubblewrap — `osproc.startProcess` with
    # `poUsePath` resolves it against the operator's PATH (the M0
    # transparency posture leaves the operator's PATH intact).
    check argv[0] == "bwrap"

  test "buildLinuxFhsSandboxArgv binds the six FHS roots from the first tree":
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    let joined = argv.join(" ")
    # Every M0-locked FHS sub-path appears as a `--bind <composed>/X
    # /X` triple. The composed root is `/repro/store/abc123-hello` per
    # `goodApplyOp`.
    check "--bind /repro/store/abc123-hello/usr /usr" in joined
    check "--bind /repro/store/abc123-hello/lib /lib" in joined
    check "--bind /repro/store/abc123-hello/lib64 /lib64" in joined
    check "--bind /repro/store/abc123-hello/bin /bin" in joined
    check "--bind /repro/store/abc123-hello/sbin /sbin" in joined
    check "--bind /repro/store/abc123-hello/etc /etc" in joined

  test "buildLinuxFhsSandboxArgv host-binds /home /tmp /run /sys /var":
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    let joined = argv.join(" ")
    # The M0 lock: these five paths are host-pass-through (bound from
    # /<x> on the host to /<x> in the sandbox). `/dev` is separately
    # bound via `--dev-bind` (different bubblewrap flag for device-
    # node semantics); `/proc` is `--proc /proc` (bubblewrap mounts a
    # fresh procfs, host-visible because no `--unshare-pid` flag).
    check "--bind /home /home" in joined
    check "--bind /tmp /tmp" in joined
    check "--bind /run /run" in joined
    check "--bind /sys /sys" in joined
    check "--bind /var /var" in joined
    check "--dev-bind /dev /dev" in joined
    check "--proc /proc" in joined

  test "buildLinuxFhsSandboxArgv ends with -- + binary + argv":
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    # The `--` separator stops bubblewrap's own option parsing; every
    # token after it is the wrapped binary's argv. The driver appends
    # `fsbBinPath` then every entry of `fsbArgv` in order.
    let dashIdx = argv.find("--")
    check dashIdx >= 0
    check argv[dashIdx + 1] == "/usr/bin/hello"
    check argv[dashIdx + 2] == "--greeting"
    check argv[dashIdx + 3] == "world"
    # And no further tokens.
    check argv.len == dashIdx + 4

  test "buildLinuxFhsSandboxArgv does NOT pass any --unshare-* flag":
    # The M0 lock: NO `--unshare-pid`, NO `--unshare-net`, NO
    # `--unshare-ipc`, NO `--unshare-uts`, NO `--unshare-cgroup`. The
    # transparency posture is the wrapped program runs with the same
    # privileges as a native exec.
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    for token in argv:
      check not token.startsWith("--unshare")

  test "buildLinuxFhsSandboxArgv does NOT pass --cap-drop or --seccomp":
    # The M0 lock: NO capability restriction, NO syscall filter.
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    check "--cap-drop" notin argv
    check "--cap-add" notin argv
    check "--seccomp" notin argv

  test "buildLinuxFhsSandboxArgv does NOT pass --ro-bind on host paths":
    # The M0 lock: /home, /tmp, /run, /var are bound read-WRITE.
    # `--ro-bind` would make them read-only, which is an isolation
    # posture, not transparency.
    let argv = buildLinuxFhsSandboxArgv(goodApplyOp())
    check "--ro-bind" notin argv

  test "buildLinuxFhsSandboxArgv is deterministic across calls":
    # Same input => same argv vector, byte-identical. This is the
    # contract two operators across two hosts rely on when comparing
    # plans for byte-equal output.
    let a = buildLinuxFhsSandboxArgv(goodApplyOp())
    let b = buildLinuxFhsSandboxArgv(goodApplyOp())
    check a == b

  test "buildLinuxFhsSandboxArgv uses the FIRST fhsTreeRoots entry":
    # M2's multi-entry compose path is NOT yet implemented. M1 takes
    # the first entry as the single composed prefix; subsequent
    # entries are ignored. The closed-set validator accepts multi-
    # entry shapes today so the M2 wire format does not break.
    var op = goodApplyOp()
    op.fsbFhsTreeRoots = @[
      "/repro/store/first-prefix",
      "/repro/store/second-prefix",
      "/repro/store/third-prefix"]
    let argv = buildLinuxFhsSandboxArgv(op)
    let joined = argv.join(" ")
    check "/repro/store/first-prefix/usr" in joined
    check "/repro/store/second-prefix" notin joined
    check "/repro/store/third-prefix" notin joined

  test "buildLinuxFhsSandboxArgv with empty argv emits no trailing tokens":
    var op = goodApplyOp()
    op.fsbArgv = @[]
    let argv = buildLinuxFhsSandboxArgv(op)
    # Last two tokens are `--` and the wrapped binary path; no
    # additional argv.
    check argv[^2] == "--"
    check argv[^1] == "/usr/bin/hello"

suite "Linux-Third-Party-Sandbox-MVP M1 — off-platform stubs":

  when not defined(linux):
    test "observe + apply raise ENotImplementedPlatform off-Linux":
      let op = goodApplyOp()
      expect ENotImplementedPlatform:
        discard observeLinuxFhsSandbox(op)
      expect ENotImplementedPlatform:
        discard applyLinuxFhsSandbox(op)

    test "destroy raises ENotImplementedPlatform off-Linux":
      let op = goodDestroyOp()
      expect ENotImplementedPlatform:
        discard destroyLinuxFhsSandbox(op)

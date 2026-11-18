## A Rust binary built by the Nix-realized ``rustc`` finds, at run time, the
## Nix store libraries it was linked against.
##
## ## The defect this protects against
##
## reprobuild-pm ``issues/2026-11-16-provisioned-rust-links-with-rust-lld-so-binaries-get-no-runpath-for-nix-libraries.md``.
## Since Rust 1.90, rust-lang's release links the x86_64-unknown-linux-gnu
## target through ``cc -B <sysroot>/.../gcc-ld -fuse-ld=lld``: ``cc`` runs
## the bundled ``rust-lld`` instead of its own ``ld``. Under Nix that skips
## the bintools wrapper, which is what writes a RUNPATH entry for each ``-L``
## directory a library came from. A recipe that links ``openssl-sys`` then
## builds a binary that dies with ``libssl.so.3: cannot open shared object
## file``. nixpkgs' own rustc links through the wrapper, and the spec
## promises the provisioned rustc links "through ``cc`` from ``PATH``, as
## nixpkgs' ``rustc`` did" (Language-Conventions/Rust.md, decision 35(a)).
## ``packages/nix/rust-release.nix`` therefore wraps ``rustc`` to pass
## ``-C linker-features=-lld`` for that target. ``rustdoc`` is not wrapped:
## it links doctests by running the sysroot's ``bin/rustc``, the wrapper,
## and the doctest case checks that this path finds the library too.
##
## ## What is exercised, and what is mocked
##
## Nothing is mocked. The stdlib's own expression for the default release
## is realized with the host's ``nix-build``, and the C compiler and OpenSSL
## come from the same nixpkgs pin the stdlib uses. The compile runs with a
## hermetic environment holding only the toolchain's and ``cc``'s ``bin``
## directories on ``PATH``, as an action that declares ``rustc`` and
## ``gcc`` does. The built program calls into ``libssl`` and runs with an
## empty environment, so it can find ``libssl.so.3`` only through what the
## link wrote into it.
##
## ## Red, then green
##
## The unwrapped compiler is still in the realization
## (``bin/.rustc-wrapped``). The first case links with it too and reports,
## as a checkpoint, whether that binary starts: with Rust 1.94.0 it does
## not (exit 127, ``libssl.so.3``), which is the defect.
##
## ## Skips, each announced
##
## Not x86_64 Linux (the defect and the flag are specific to the
## x86_64-unknown-linux-gnu target, and the realization carries only the
## host's standard library), or ``nix-build`` not on ``PATH``. Realizing the toolchain
## downloads rust-lang's ~300 MB archive the first time.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/rust_toolchain_pins
import repro_test_support/reasoned_skip

const NixDir = currentSourcePath().parentDir.parentDir.parentDir /
  "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" / "packages" / "nix"

const SslProgram = """
#[link(name = "ssl")]
extern "C" {
    fn OPENSSL_init_ssl(opts: u64, settings: *const u8) -> i32;
}
fn main() {
    let r = unsafe { OPENSSL_init_ssl(0, std::ptr::null()) };
    println!("OPENSSL_init_ssl={}", r);
    std::process::exit(if r == 1 { 0 } else { 1 });
}
"""

const SslDoctest = """
//! ```
//! #[link(name = "ssl")]
//! extern "C" {
//!     fn OPENSSL_init_ssl(opts: u64, settings: *const u8) -> i32;
//! }
//! assert_eq!(unsafe { OPENSSL_init_ssl(0, std::ptr::null()) }, 1);
//! ```
"""

proc nixBuild(args: openArray[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(
    @["nix-build", "--no-out-link"] & @args), workingDir = NixDir)
  if code != 0:
    raise newException(OSError, "nix-build failed:\n" & output)
  output.strip.splitLines[^1]

proc run(cmd: seq[string], env: openArray[(string, string)],
         dir: string): tuple[output: string, code: int] =
  ## Runs ``cmd`` with exactly ``env`` (``env -i``), so nothing from the
  ## caller's environment (``LD_LIBRARY_PATH``, ``NIX_LDFLAGS``) leaks in.
  var argv = @["env", "-i"]
  for (k, v) in env:
    argv.add k & "=" & v
  argv.add cmd
  let (output, code) = execCmdEx(quoteShellCommand(argv), workingDir = dir)
  (output, code)

let enabled = defined(linux) and defined(amd64) and
  findExe("nix-build").len > 0

const SkipReason = "needs x86_64 Linux and nix-build on PATH: the defect " &
  "and the flag are specific to x86_64-unknown-linux-gnu, and the " &
  "toolchain is realized with nix-build"

var rust, cc, ssl, work = ""
if enabled:
  rust = nixBuild(["rust-" & RustDefaultRelease.version & "/default.nix"])
  cc = nixBuild(["-E", "(import ./nixpkgs.nix).stdenv.cc"])
  ssl = nixBuild(["-E", "(import ./nixpkgs.nix).openssl.out"])
  work = createTempDir("rust-runpath-", "")
  writeFile(work / "ssl.rs", SslProgram)
  writeFile(work / "lib.rs", SslDoctest)

proc actionEnv(): seq[(string, string)] =
  @{"PATH": rust / "bin" & ":" & cc / "bin", "HOME": work}

suite "the Nix-realized rustc links store libraries the binary can find":

  test "a binary linking libssl from the store runs with an empty " &
      "environment":
    if not enabled:
      skip(SkipReason)
    else:
      let built = run(@[rust / "bin" / "rustc", "-L", ssl / "lib",
        "-o", "ssl-wrapped", "ssl.rs"], actionEnv(), work)
      checkpoint built.output
      check built.code == 0
      let ran = run(@[work / "ssl-wrapped"], [], work)
      checkpoint ran.output
      check ran.code == 0
      check "OPENSSL_init_ssl=1" in ran.output
      # The unwrapped compiler, for the record: the defect.
      let unwrapped = run(@[rust / "bin" / ".rustc-wrapped", "-L",
        ssl / "lib", "-o", "ssl-unwrapped", "ssl.rs"], actionEnv(), work)
      if unwrapped.code == 0:
        let r = run(@[work / "ssl-unwrapped"], [], work)
        checkpoint "unwrapped rustc's binary: exit " & $r.code & ": " &
          r.output.strip

  test "an explicit --target x86_64-unknown-linux-gnu gets the same link":
    if not enabled:
      skip(SkipReason)
    else:
      let built = run(@[rust / "bin" / "rustc", "--target",
        "x86_64-unknown-linux-gnu", "-L", ssl / "lib", "-o", "ssl-target",
        "ssl.rs"], actionEnv(), work)
      checkpoint built.output
      check built.code == 0
      let ran = run(@[work / "ssl-target"], [], work)
      checkpoint ran.output
      check ran.code == 0

  test "rustdoc's doctests, linked through the sysroot's rustc, find it too":
    if not enabled:
      skip(SkipReason)
    else:
      let tested = run(@[rust / "bin" / "rustdoc", "--test",
        "--crate-name", "ssldoc", "-L", ssl / "lib", "lib.rs"],
        actionEnv(), work)
      checkpoint tested.output
      check tested.code == 0
      check "1 passed" in tested.output

  test "another target is not given the flag, which is unstable there":
    # ``-C linker-features=-lld`` is refused on every target but
    # x86_64-unknown-linux-gnu; were the wrapper to pass it regardless,
    # every cross build would fail before it started.
    if not enabled:
      skip(SkipReason)
    else:
      writeFile(work / "target.args", "--target\naarch64-unknown-linux-gnu\n")
      # rustc strips a trailing CR from each argfile line; so must the
      # wrapper, or ``--target\r`` would not match and the host's flag
      # would be passed for aarch64.
      writeFile(work / "target-crlf.args",
        "--target\r\naarch64-unknown-linux-gnu\r\n")
      for args in [@["--target", "aarch64-unknown-linux-gnu"],
                   @["--target=aarch64-unknown-linux-gnu"],
                   @["@target.args"],
                   @["@target-crlf.args"]]:
        let printed = run(@[rust / "bin" / "rustc"] & args &
          @["--print", "cfg"], actionEnv(), work)
        checkpoint $args & ": " & printed.output
        check printed.code == 0
        check "target_arch=\"aarch64\"" in printed.output
      # An argfile that is a pipe cannot be read without draining it, so
      # the wrapper cannot know its target and must pass no flag.
      let bash = findExe("bash")
      if bash.len == 0:
        checkpoint "pipe argfile case skipped: no bash on PATH"
      else:
        let piped = run(@[bash, "-c", "exec " & quoteShell(rust / "bin" /
          "rustc") & " @<(printf -- '--target\\naarch64-unknown-linux-gnu\\n')" &
          " --print cfg"], actionEnv(), work)
        checkpoint "pipe argfile: " & piped.output
        check piped.code == 0
        check "target_arch=\"aarch64\"" in piped.output
      # The premise: the flag really is refused there.
      let refused = run(@[rust / "bin" / ".rustc-wrapped", "--target",
        "aarch64-unknown-linux-gnu", "-C", "linker-features=-lld",
        "--print", "cfg"], actionEnv(), work)
      checkpoint refused.output
      check refused.code != 0
      check "linker-features=-lld` is unstable" in refused.output

if work.len > 0:
  removeDir(work)

## The rustc sysroot of a cross build: the host compiler with the target's
## standard library merged in.
##
## rustc finds a target's standard library under its own sysroot,
## `<prefix>/lib/rustlib/<triple>/lib`, and the `rustc` the catalog realizes
## carries only the host's. Upstream ships every other target's as a
## separate component (`packages/rust_std`), meant to be merged into the
## same prefix -- what `rustup target add` does. A realized prefix is
## immutable, so the merge is made as a prefix of its own: the host
## toolchain's tree reproduced by symbolic links, with the component's
## `lib/rustlib/<triple>/` copied in. `bin/rustc` is a COPY rather than a
## link, because rustc finds its sysroot through the real path of its own
## executable (`current_exe()` resolves links), so a linked `rustc` would
## resolve to the host prefix and never see the target library. Everything
## `bin/rustc` loads lives under `lib/` (`$ORIGIN/../lib`), which is why
## `lib/` is a real directory of links and not one link.
##
## `cargo_package` points cargo at it with `RUSTC`: cargo then drives this
## rustc for the host (build scripts, proc macros) and the target alike, and
## both standard libraries are present. `cargo` itself stays the catalog's.
##
## This is the stdlib's version of what reprobuild-packages'
## `rust-sysroot-armv7-unknown-linux-musleabihf` recipe did for one target
## (ReproOS-Add-On-Mode A15 retired it): two edges, emitted for the active
## cross target by the constructor, with the component's URL and digest read
## from the catalog table rather than restated per target.
##
## ## The two edges
##
## * `rust-std-fetch-<triple>`: downloads the component archive by the
##   catalog's URL, verifies the catalog's sha256, extracts it. Not
##   cacheable, like every source fetch: it reaches the network. Its output
##   is a stamp the merge edge lists as an input.
## * `rust-sysroot-<triple>`: the merge. Cacheable: its inputs are the
##   extracted component (through the stamp) and the host `rustc` (a tool
##   identity ref), and its output is a pure function of both. It refuses a
##   host `rustc --version` that is not the component's version, because a
##   standard library built by one rustc is not loadable by another, and it
##   proves the result by asking the merged rustc for the target's libdir.

import std/[os, strutils]

import repro_project_dsl

import ../packages/rust_std
export rust_std

const
  RustSysrootScratchSubdir* = ".repro/build/cross"
    ## Beside the zig wrappers (`cross_zig.ZigCrossScratchSubdir`), so a
    ## `repro clean` takes both.

proc rustTargetSysrootDir*(projectRoot, triple: string): string =
  ## Where the merged prefix lands: `<projectRoot>/.repro/build/cross/<triple>/rust-sysroot`.
  projectRoot / RustSysrootScratchSubdir / triple / "rust-sysroot"

proc rustStdExtractDir*(projectRoot, triple: string): string =
  projectRoot / RustSysrootScratchSubdir / triple / "rust-std"

proc rustTargetRustcPath*(projectRoot, triple: string): string =
  ## The `RUSTC` a cargo edge is pointed at.
  rustTargetSysrootDir(projectRoot, triple) / "bin" / "rustc"

proc sanitizedIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')

proc rustStdFetchActionId*(packageName, triple: string): string =
  "rust-std-fetch-" & sanitizedIdPart(packageName & "-" & triple)

proc rustSysrootActionId*(packageName, triple: string): string =
  "rust-sysroot-" & sanitizedIdPart(packageName & "-" & triple)

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc rustSysrootMergeScript*(hostRustcVersion, triple, extracted,
                             sysroot: string): string =
  ## The merge, as the shell that runs it. Pure, so a test can read it.
  ##
  ## `HOST_RUSTC` is the `rustc` OF THE COMPONENT'S VERSION on the edge's
  ## PATH -- not the first `rustc` there. The engine puts every resolved
  ## tool's directory on PATH, and a path-mode resolution can put a
  ## different rustc first (the catalog's nix arm is realized without the
  ## declared version range: reprobuild-pm issue
  ## 2026-10-30-path-mode-realizes-a-nix-rustc-outside-the-declared-version-range),
  ## while the pinned toolchain's prefix (the rust-installer archive that
  ## also carries `cargo`) is on PATH too. So the script walks PATH and
  ## takes the first `rustc` whose `--version` is the component's, and
  ## refuses, naming every version it saw, when none is. Its prefix is two
  ## levels up. The component's `rust-std-<triple>/lib/rustlib/<triple>`
  ## is the one directory copied; everything else is a link into it.
  "set -e; HOST_RUSTC=; SEEN=; IFS_SAVE=$IFS; IFS=:; " &
  "for d in $PATH; do IFS=$IFS_SAVE; [ -x \"$d/rustc\" ] || continue; " &
  "v=$(\"$d/rustc\" --version 2>/dev/null || true); SEEN=\"$SEEN $v;\"; " &
  "case \"$v\" in \"rustc " & hostRustcVersion & " \"*) HOST_RUSTC=\"$d/rustc\"; " &
  "break;; esac; done; IFS=$IFS_SAVE; " &
  "[ -n \"$HOST_RUSTC\" ] || { echo \"rust-sysroot: no rustc " & hostRustcVersion &
    " on the edge's PATH (seen:$SEEN), the " & triple &
    " standard library is " & hostRustcVersion & "\" >&2; exit 1; }; " &
  "HOST_PREFIX=$(CDPATH= cd -- \"$(dirname -- \"$HOST_RUSTC\")/..\" && pwd); " &
  "OUT=" & q(sysroot) & "; rm -rf \"$OUT\"; " &
  "mkdir -p \"$OUT/bin\" \"$OUT/lib/rustlib\"; " &
  "cp \"$HOST_RUSTC\" \"$OUT/bin/rustc\"; " &
  "for f in \"$HOST_PREFIX\"/bin/*; do n=$(basename \"$f\"); " &
    "[ \"$n\" = rustc ] || ln -s \"$f\" \"$OUT/bin/$n\"; done; " &
  "for f in \"$HOST_PREFIX\"/lib/*; do n=$(basename \"$f\"); " &
    "[ \"$n\" = rustlib ] || ln -s \"$f\" \"$OUT/lib/$n\"; done; " &
  "for f in \"$HOST_PREFIX\"/lib/rustlib/*; do n=$(basename \"$f\"); " &
    "[ \"$n\" = " & triple & " ] || ln -s \"$f\" \"$OUT/lib/rustlib/$n\"; " &
    "done; " &
  "cp -a " & q(extracted / ("rust-std-" & triple) / "lib" / "rustlib" / triple) &
    " \"$OUT/lib/rustlib/\"; " &
  "test -d \"$OUT/lib/rustlib/" & triple & "/lib\"; " &
  # The proof the merge is what rustc sees: it must answer for the target
  # and for the host from this prefix alone.
  "\"$OUT/bin/rustc\" --print sysroot | grep -qx \"$OUT\"; " &
  "\"$OUT/bin/rustc\" --target " & triple & " --print target-libdir >/dev/null"

proc emitRustStdFetchAction*(projectRoot, packageName, triple: string):
    BuildActionDef =
  ## The fetch edge (see the header). The archive lands in the project's
  ## fetch scratch, keyed by its digest, and is extracted into
  ## `rustStdExtractDir`.
  let c = rustStdComponent(triple)
  let url = rustStdUrl(c)
  let scratch = projectRoot / ".repro/fetch"
  createDir(scratch)
  let tarball = scratch / (c.sha256 & ".tar.gz")
  let stamp = scratch / (c.sha256 & ".stamp")
  let extracted = rustStdExtractDir(projectRoot, triple)
  createDir(parentDir(extracted))
  let staged = extracted & ".repro-extract-" & c.sha256
  proc dq(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("rm -rf \"" & dq(staged) & "\"; ")
  script.add("mkdir -p \"" & dq(staged) & "\"; ")
  script.appendCurlDownload(tarball, url)
  script.add("echo \"" & c.sha256 & "  " & dq(tarball) &
    "\" | sha256sum -c -; ")
  script.appendTarExtraction(tarball, staged, 1)
  script.add("rm -rf \"" & dq(extracted) & "\"; ")
  script.add("mv \"" & dq(staged) & "\" \"" & dq(extracted) & "\"; ")
  script.appendVerifiedFetchStamp(stamp)
  buildAction(
    id = rustStdFetchActionId(packageName, triple),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust-sysroot.fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = shellFetchToolIdentityRefs(["sha256sum"],
      archiveUrl = url))

proc emitRustTargetSysrootAction*(projectRoot, packageName, triple: string;
                                  fetch: BuildActionDef): BuildActionDef =
  ## The merge edge (see the header), ordered after `fetch` through its
  ## stamp. Its declared output is the sysroot directory, so a cargo edge
  ## that reads it orders after it by depending on it.
  let c = rustStdComponent(triple)
  let sysroot = rustTargetSysrootDir(projectRoot, triple)
  let script = rustSysrootMergeScript(c.version, triple,
    rustStdExtractDir(projectRoot, triple), sysroot)
  buildAction(
    id = rustSysrootActionId(packageName, triple),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = (if fetch.outputs.len > 0: @[fetch.outputs[0]] else: @[]),
    outputs = @[sysroot],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust-sysroot.merge",
    # `cargo` beside `rustc`: the pinned toolchain is one rust-installer
    # archive realized as one prefix that carries both, and naming `cargo`
    # puts that prefix on the edge's PATH even when the `rustc` selector
    # resolved to another arm (the path-mode nix arm, see the merge script).
    toolIdentityRefs = @["sh", "rustc", "cargo", "cp", "ln", "mkdir", "rm",
                         "dirname", "basename", "grep"])

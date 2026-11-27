## An installed prefix: built files laid out the way an install puts them,
## carrying its own runtime libraries, checked to name no build-host path.
##
## The producer behind `repro build --target=<triple> .#prefix`
## (reprobuild-pm Distribution-And-Packaging.md §5.3, approved by Zahary
## Karadjov, 2026-11-03). Like every producer of the §6 layer it is
## ordinary edges over typed inputs; the engine knows nothing of prefixes.
##
## Two edges, then a third for the archive:
##
## 1. **Assembly** (`installedPrefix`). Copies the spec's files and trees to
##    their prefix paths and strips the debug sections of every ELF image
##    under `bin/`, `lib/` and `nim/bin/` that carries any -- an entry as
##    copied, a library as it is bundled -- with `debugStripCommand`
##    (`llvm-objcopy --strip-debug` by default): debug info names the
##    directories the image was built in, whatever compiler built it, and
##    the gate refuses those. An image with no debug section is copied as
##    it is. Then it completes the runtime closure: every
##    `DT_NEEDED` name of every ELF in the prefix, transitively, and every
##    name the images `dlopen`, is copied into `lib/` from the spec's
##    library sources -- except the C library, which stays the target's
##    (§5.3 decision C). A name found nowhere fails the edge, naming it and
##    the image that needs it. Each image that needs or loads a bundled
##    library gets a RUNPATH relative to itself (`$ORIGIN/../lib` from
##    `bin/`, `$ORIGIN` in `lib/`, `$ORIGIN/../../lib` from `nim/bin/`);
##    one that needs none keeps none, which is what the monitor shim must be
##    (it is preloaded into processes nobody here built). When the C
##    library stays the target's (`libc.so.6` in `systemSonames`), each
##    image whose `PT_INTERP` names glibc's loader for the triple, wherever
##    it lives, is made to name the triple's system loader
##    (`glibc_loaders.GlibcLoaders`: `/lib64/ld-linux-x86-64.so.2`,
##    `/lib/ld-linux-armhf.so.3`, ...), so a prefix linked by a toolchain
##    with a loader of its own (a Nix gcc's `/nix/store/...-glibc-...`)
##    loads on the target and passes the gate. An image that already names
##    it is not touched; one with no `PT_INTERP` (a static image, a
##    library) or another C library's loader (musl's) is left alone. A
##    triple the table does not hold is refused when the edges are
##    declared. Then every
##    global undefined symbol of every ELF that is not glibc-versioned must
##    be defined by some ELF of the prefix: an image linked against one
##    build of a library and run with another must not take a symbol the
##    run-time build lacks. Last, it writes `share/repro/cross-build-info`.
## 2. **The builder-path gate** (`InstalledPrefix.gate`). Every ELF under
##    `bin/`, `lib/` and `nim/bin/` is searched for a concrete Nix store
##    path, a concrete home directory, the edge's working directory and
##    `$HOME`. A hit fails the build, naming the image, the needle and the
##    number of matching lines. No allowlist.
## 3. **The archive** (`installedPrefixArchive`), after the gate: the prefix
##    packed under one top-level directory.
##
## The tools are declared on the edges (`readelf`, `patchelf`, `grep`, ...),
## so a host that lacks one is refused by name before anything runs.

import std/[os, sequtils, strutils]

import repro_project_dsl

import ../../glibc_loaders

type
  PrefixEntry* = object
    ## One file or directory tree placed in the prefix.
    source*: string      ## where the build produced it
    dest*: string        ## its path under the prefix (`bin/reprobuild`)
    producer*: string    ## the id of the edge that produced it ("" = none)

  PrefixLibrarySource* = object
    ## A directory the runtime closure takes libraries from.
    dir*: string         ## searched for a soname, in spec order
    origin*: string      ## what the record says the libraries came from
    producer*: string    ## the edge that fills `dir` ("" = none)

  InstalledPrefixSpec* = object
    name*: string               ## an id part (`reprobuild`)
    triple*: string
      ## the platform the prefix is for. With `libc.so.6` in
      ## `systemSonames` it must be a triple `GlibcLoaders` holds, whose
      ## loader the images are made to name.
    output*: string             ## the prefix directory
    entries*: seq[PrefixEntry]
    symlinks*: seq[(string, string)]
      ## `(path under the prefix, link target)`: `bin/nim` -> `../nim/bin/nim`
    librarySources*: seq[PrefixLibrarySource]
    systemSonames*: seq[string]
      ## sonames that stay the target's: the C library and its loader
    dlopenNames*: seq[string]
      ## names the images load by leaf name, so no `DT_NEEDED` finds them
    recordLines*: seq[string]
      ## `key=value` lines for `share/repro/cross-build-info`, in order
    recordCommands*: seq[string]
      ## shell commands whose output lines are appended to the record after
      ## `recordLines`: what only the build knows (a revision, a version).
      ## A command that fails fails the edge.
    extraInputs*: seq[string]
      ## files the assembly reads beside the entries (a lock it checks)
    preChecks*: seq[string]
      ## shell fragments run before assembly; each must exit non-zero, with
      ## a message, to refuse the prefix (a revision mismatch, say)
    extraDeps*: seq[string]
      ## ids of edges the assembly orders after beyond the entries'
      ## producers (every image of a collection, say)
    extraTools*: seq[string]
      ## tools the pre-checks and record commands run
    gateChecks*: seq[string]
      ## shell fragments the gate edge runs after the builder-path search,
      ## each exiting non-zero, with a message, to refuse the prefix (a
      ## type-check of the shipped sources, say); `$O` is the prefix
    gateTools*: seq[string]
      ## the tools `gateChecks` run
    buildRoots*: seq[string]
      ## directories the edges built in besides the project root (a
      ## catalog checkout, say). The gate refuses an image naming any of
      ## them, as it refuses the project root; `prefixBuildRoots` adds the
      ## recipe directory of every entry and library source.
    debugStripCommand*: string
      ## A filter that reads an object on its standard input and writes it,
      ## without its debug info, to its standard output. "" =
      ## `LlvmObjcopyDebugStrip`, which reads every architecture, and whose
      ## tool (`llvm-objcopy`) the assembly edge then declares; a recipe
      ## that names another declares its tool in `extraTools`. Applied to
      ## every ELF image of the prefix (an entry, a bundled library) that
      ## carries debug sections -- debug info names the build host's
      ## directories (the C library's headers, the compiler's cache, the
      ## project root), whichever compiler wrote it -- and to none that
      ## carries none, so a distribution's stripped library keeps its signed
      ## bytes. Only debug sections go (`--strip-debug`); the symbol table
      ## stays. A strip that fails refuses the prefix, naming the image.
      ##
      ## A filter, not `<command> <in> <out>`: given an output path,
      ## llvm-objcopy writes a temporary with a random name beside it and
      ## renames it into place, and that draw (`arc4random`) is entropy from
      ## a tool nobody has blessed. The engine then withholds the assembly's
      ## cache entry, so the edge re-runs on every build, the publishing one
      ## included, and what is published is not the tree that was measured.
      ## Streamed through standard output it draws none (measured with LLVM
      ## 18's llvm-objcopy, 2026-11-05).
    omitShellCompletion*: bool
      ## The opt-out from the shell completion files the prefix gets on its
      ## own: every entry placed under `bin/` whose source is the binary of
      ## an executable with a `cli:` description that a Nim compile of the
      ## package builds brings its Bash, Zsh and Fish scripts, generated
      ## from the description by its completion edge (never by running the
      ## binary, which a prefix for another machine could not), at
      ## `share/bash-completion/completions/<name>`,
      ## `share/zsh/site-functions/_<name>` and
      ## `share/fish/vendor_completions.d/<name>.fish`, `<name>` being the
      ## entry's file name. `true` adds none.

  InstalledPrefix* = object
    dir*: string
    assemble*: BuildActionDef
    gate*: BuildActionDef

const
  PrefixRecordPath* = "share/repro/cross-build-info"
  PrefixGateStampName* = ".builder-path-gate.ok"
  GlibcSoname* = "libc.so.6"
    ## The soname whose presence in `systemSonames` says the prefix runs on
    ## the target's glibc, so its images must name the target's loader.
  GlibcSonames* = @["libc.so.6", "libm.so.6", "libdl.so.2",
    "libpthread.so.0", "librt.so.1", "libutil.so.1", "libresolv.so.2"] &
    glibcLoaderSonames()
    ## The C library and every loader of `GlibcLoaders`, which an installed
    ## prefix never bundles: it is the ABI of the target's kernel and loader
    ## (§5.3 decision C).
  LlvmObjcopyDebugStrip* = "llvm-objcopy --strip-debug - -"
    ## The default `debugStripCommand`: LLVM's objcopy reads every target
    ## (an armv7 image on an x86_64 build host, which the host's GNU objcopy
    ## does not recognise), and `- -` makes it the filter that field
    ## requires, so it names no temporary.
  LlvmObjcopyTool* = "llvm-objcopy"
    ## The tool `LlvmObjcopyDebugStrip` runs, declared on the assembly edge
    ## when the spec leaves `debugStripCommand` empty.
  BuilderPathPatterns* = ["/nix/store/[0-9a-df-np-sv-z]{32}-",
                          "/home/[A-Za-z0-9._-]+/"]
    ## A concrete store path (its 32-character hash) and a concrete home
    ## directory (its user name): the words alone occur in code literals.

proc effectiveDebugStrip*(spec: InstalledPrefixSpec): string =
  ## The strip filter the assembly runs: the spec's, or
  ## `LlvmObjcopyDebugStrip`. Never empty: every image is stripped of its
  ## debug info, whatever compiler built it.
  if spec.debugStripCommand.len > 0: spec.debugStripCommand
  else: LlvmObjcopyDebugStrip

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc idPart(value: string): string =
  for ch in value:
    result.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '_')

proc systemLoaderOf*(spec: InstalledPrefixSpec): string =
  ## The loader the prefix's images are made to name: the triple's glibc
  ## loader when glibc is a system soname of the prefix, "" when it is not
  ## (a musl or a static prefix: the images keep what they name). A triple
  ## the table does not hold is a `ValueError`, never a prefix whose images
  ## keep the build toolchain's loader.
  if GlibcSoname notin spec.systemSonames:
    return ""
  result = glibcLoaderOfTriple(spec.triple)
  if result.len == 0:
    raise newException(ValueError, "installedPrefix '" & spec.name &
      "': glibc (" & GlibcSoname & ") is a system soname, so the images " &
      "must name the system loader of '" & spec.triple & "', and no loader " &
      "is known for that triple; known: " & glibcLoaderTriples().join(", ") &
      ". Add its row to GlibcLoaders (repro_dsl_stdlib/glibc_loaders).")

proc validate(spec: InstalledPrefixSpec) =
  if spec.name.len == 0 or spec.output.len == 0:
    raise newException(ValueError,
      "installedPrefix: the spec needs a name and an output directory")
  discard systemLoaderOf(spec)
  for e in spec.entries:
    if e.dest.len == 0 or e.dest.isAbsolute or ".." in e.dest.split('/'):
      raise newException(ValueError, "installedPrefix '" & spec.name &
        "': entry '" & e.source & "' has destination '" & e.dest &
        "', which is not a path inside the prefix")
  for line in spec.recordLines:
    if '=' notin line or '\n' in line:
      raise newException(ValueError, "installedPrefix '" & spec.name &
        "': record line '" & line & "' is not one key=value line")

proc assemblyScript*(spec: InstalledPrefixSpec): string =
  ## The assembly edge's shell program (see the header). Exposed for the
  ## tests.
  validate(spec)
  let o = spec.output
  var s = "set -e; umask 022; "
  for check in spec.preChecks:
    s.add("( " & check & " ); ")
  s.add("rm -rf " & q(o) & "; mkdir -p " & q(o / "bin") & " " & q(o / "lib") &
    " " & q(o / "share" / "repro") & "; ")
  for e in spec.entries:
    s.add("mkdir -p " & q((o / e.dest).parentDir) & "; ")
    s.add("cp -a " & q(e.source) & " " & q(o / e.dest) & "; ")
  for (path, target) in spec.symlinks:
    s.add("mkdir -p " & q((o / path).parentDir) & "; ln -sfn " & q(target) &
      " " & q(o / path) & "; ")
  # A read-only source tree (a store copy) stays read-only when copied.
  s.add("chmod -R u+w " & q(o) & "; ")
  s.add("O=" & q(o) & "; STRIP=" & q(effectiveDebugStrip(spec)) & "; ")
  # ---- the runtime closure ----------------------------------------------
  s.add("SYSTEM=' " & spec.systemSonames.join(" ") & " '; ")
  s.add("SOURCES=" & q(spec.librarySources.mapIt(it.dir).join("\n")) & "; ")
  s.add("""
is_elf() { [ "$(head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }
# Every function returns 0 explicitly: under `set -e` a loop whose last test
# was false would end the script silently.
elfs() { find "$1/bin" "$1/lib" "$1/nim/bin" -type f 2>/dev/null | while IFS= read -r f; do if is_elf "$f"; then printf '%s\n' "$f"; fi; done; return 0; }
needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; }
# strip_debug <file>: drop the debug sections of an ELF image that has any.
# One with none is left byte for byte as it is (a distribution's signed
# library), which also makes a second strip a no-op. A strip that fails can
# leave a truncated output: never ship it, and never ship the unstripped
# image in its place.
strip_debug() {
  readelf -S -W "$1" 2>/dev/null | grep -q '\.debug' || return 0
  if ! $STRIP < "$1" > "$1.stripped"; then
    rm -f "$1.stripped"
    echo "installed prefix: stripping the debug info of ${1#$O/} failed ($STRIP)" >&2
    exit 1
  fi
  # Copied over the image rather than renamed onto it, so the image keeps
  # its mode (an executable stays executable).
  cp "$1.stripped" "$1"; rm -f "$1.stripped"
  return 0
}
find_lib() {
  printf '%s\n' "$SOURCES" | while IFS= read -r d; do
    if [ -n "$d" ] && [ -e "$d/$1" ]; then printf '%s\n' "$d/$1"; break; fi
  done
  return 0
}
bundle() {  # bundle <soname> <wanted-by>
  case "$SYSTEM" in *" $1 "*) return 0;; esac
  [ -e "$O/lib/$1" ] && return 0
  src=$(find_lib "$1")
  [ -n "$src" ] || { echo "installed prefix: $2 needs $1, which no library source holds:" >&2; printf '  %s\n' "$SOURCES" >&2; exit 1; }
  cp -L "$src" "$O/lib/$1"; chmod u+w "$O/lib/$1"
  strip_debug "$O/lib/$1"
  echo "$O/lib/$1" >> "$WORK"
}
""")
  # ---- debug info --------------------------------------------------------
  # Every image the entries placed, before anything else reads or rewrites
  # it: the closure and the symbol check then read the bytes that ship, and
  # the strip never runs over a file patchelf has rewritten (patchelf moves
  # program headers and adds segments that objcopy-style tools are known to
  # mishandle). The bundled libraries are stripped as they are bundled.
  s.add("WORK=$(mktemp); ")
  s.add("elfs \"$O\" > \"$WORK\"; ")
  s.add("while IFS= read -r f; do strip_debug \"$f\"; done < \"$WORK\"; ")
  s.add("for n in " & spec.dlopenNames.mapIt(q(it)).join(" ") &
    "; do bundle \"$n\" 'the engine (dlopen)'; done; ")
  # The worklist grows as libraries are bundled: walk it to a fixed point.
  s.add("""
i=1
while f=$(sed -n "${i}p" "$WORK"); [ -n "$f" ]; do
  for n in $(needed "$f"); do bundle "$n" "${f#$O/}"; done
  i=$((i + 1))
done
""")
  # ---- RUNPATH ----------------------------------------------------------
  s.add("""
bundled() { ls "$O/lib" 2>/dev/null; }
needs_bundled() {
  for n in $(needed "$1"); do [ -e "$O/lib/$n" ] && return 0; done
  return 1
}
for f in $(elfs "$O"); do
  rel=${f#$O/}
  case "$rel" in
    bin/*) rp='$ORIGIN/../lib'; loads=1;;
    nim/bin/*) rp='$ORIGIN/../../lib'; loads=1;;
    lib/*) rp='$ORIGIN'; loads=0;;
    *) continue;;
  esac
  if needs_bundled "$f" || [ $loads = 1 ]; then
    patchelf --set-rpath "$rp" "$f"
  elif [ -n "$(patchelf --print-rpath "$f")" ]; then
    patchelf --remove-rpath "$f"
  fi
done
""")
  # ---- PT_INTERP --------------------------------------------------------
  let loader = systemLoaderOf(spec)
  if loader.len > 0:
    s.add("LOADER=" & q(loader) & "; ")
    s.add("""
for f in $(elfs "$O"); do
  interp=$(readelf -l -W "$f" 2>/dev/null | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]$/\1/p')
  # No PT_INTERP: a static image, or a library.
  [ -n "$interp" ] || continue
  # Another C library's loader (musl's): not glibc's, so not ours to move.
  [ "${interp##*/}" = "${LOADER##*/}" ] || continue
  # Already the system loader: the image is left byte for byte as it is.
  [ "$interp" = "$LOADER" ] || patchelf --set-interpreter "$LOADER" "$f"
done
""")
  # ---- the symbol check -------------------------------------------------
  s.add("""
DEF=$(mktemp); UND=$(mktemp)
for f in $(elfs "$O"); do
  readelf --dyn-syms -W "$f" | awk -v f="${f#$O/}" -v def="$DEF" -v und="$UND" '
    $1 ~ /^[0-9]+:$/ && NF >= 8 {
      name = $8; sub(/@.*/, "", name)
      if ($7 == "UND") { if ($5 == "GLOBAL" && $8 !~ /@(GLIBC|GCC|CXXABI|GLIBCXX)_/ && name != "") print name " " f >> und }
      else if (name != "") print name >> def
    }'
done
sort -u "$DEF" -o "$DEF"
missing=$(sort -u "$UND" | awk 'NR == FNR { d[$1] = 1; next } !($1 in d)' "$DEF" -)
if [ -n "$missing" ]; then
  echo "installed prefix: symbols no library in the prefix defines (symbol, image):" >&2
  printf '%s\n' "$missing" | sed 's/^/  /' >&2
  exit 1
fi
rm -f "$DEF" "$UND" "$WORK"
""")
  # ---- the record -------------------------------------------------------
  var record = "# written by repro_dsl_stdlib/packaging/producers/installed_prefix\n"
  record.add("triple=" & spec.triple & "\n")
  for line in spec.recordLines:
    record.add(line & "\n")
  s.add("printf '%s' " & q(record) & " > " & q(o / PrefixRecordPath) & "; ")
  for command in spec.recordCommands:
    s.add("( " & command & " ) >> " & q(o / PrefixRecordPath) & "; ")
  # One `runtime <soname> <origin>` line per bundled library: the first
  # source that holds it, which is the one the closure copied it from.
  s.add("for f in \"$O\"/lib/*; do b=$(basename \"$f\"); ")
  var first = true
  for src in spec.librarySources:
    s.add((if first: "if" else: "elif") & " [ -e " & q(src.dir) &
      "/\"$b\" ]; then printf 'runtime %s %s\\n' \"$b\" " & q(src.origin) &
      " >> " & q(o / PrefixRecordPath) & "; ")
    first = false
  if not first:
    s.add("fi; ")
  s.add("done; ")
  s

proc gateStamp*(prefix: string): string =
  ## The file the gate writes beside the prefix when it passes.
  prefix & PrefixGateStampName

proc prefixBuildRoots*(spec: InstalledPrefixSpec): seq[string] =
  ## Every build root the prefix's inputs came from, beyond the project
  ## root: `spec.buildRoots`, and the recipe directory (the part before
  ## `/.repro/`) of each entry and library source. A source build names its
  ## own tree in what it compiles -- the catalog's `nim-fork` put 47 lines of
  ## `<catalog>/nim-fork/.repro/build/...` into `nim/bin/nim`, outside every
  ## other needle (measured 2026-11-04).
  proc addRoot(r: var seq[string]; dir: string) =
    let d = dir.strip(leading = false, chars = {'/'})
    if d.len > 1 and d notin r: r.add(d)
  for root in spec.buildRoots: result.addRoot(root)
  var dirs: seq[string]
  for e in spec.entries: dirs.add(e.source)
  for src in spec.librarySources: dirs.add(src.dir)
  for d in dirs:
    let at = d.find("/.repro/")
    if at > 0: result.addRoot(d[0 ..< at])

proc gateScript*(prefix: string; checks: seq[string] = @[];
                 roots: seq[string] = @[]): string =
  ## The builder-path gate's shell program, then `checks`. `roots` are
  ## searched for as the project root (`$PWD`) and `$HOME` are. Exposed for
  ## the tests.
  var s = "set -e; O=" & q(prefix) & "; hits=$(mktemp); "
  s.add("""
for f in $(find "$O/bin" "$O/lib" "$O/nim/bin" -type f 2>/dev/null); do
  [ "$(head -c 4 "$f")" = "$(printf '\177ELF')" ] || continue
""")
  for pattern in BuilderPathPatterns:
    s.add("  n=$(LC_ALL=C grep -a -c -E -- " & q(pattern) & " \"$f\" || true); " &
      "[ \"$n\" = 0 ] || echo \"${f#$O/}: $n line(s) match " & pattern &
      "\" >> \"$hits\"\n")
  s.add("""
  for needle in "$PWD" "${HOME:-/nonexistent}" """ & roots.mapIt(q(it)).join(" ") & """; do
    n=$(LC_ALL=C grep -a -c -F -- "$needle" "$f" || true)
    [ "$n" = 0 ] || echo "${f#$O/}: $n line(s) carry $needle" >> "$hits"
  done
done
if [ -s "$hits" ]; then
  echo "installed prefix: images carry build-host paths (Distribution-And-Packaging 5.3, the builder-path gate):" >&2
  sed 's/^/  /' "$hits" >&2
  rm -f "$hits"
  exit 1
fi
rm -f "$hits"
""")
  for check in checks:
    s.add("( " & check & " ); ")
  s.add("touch " & q(gateStamp(prefix)))
  s

const PrefixCompletionDirs = [
  ("bash", "share/bash-completion/completions", ""),
  ("zsh", "share/zsh/site-functions", "_"),
  ("fish", "share/fish/vendor_completions.d", "")]
  ## `(shell, directory under the prefix, file-name prefix)`; the file is
  ## `<prefix><name><suffix>`, the suffix `.fish` for fish and none else.

proc completionEntries*(spec: InstalledPrefixSpec): seq[PrefixEntry] =
  ## The completion files `installedPrefix` adds to `spec` (see
  ## `omitShellCompletion`), as entries. Only the provider builds
  ## completion edges, so outside it this is empty.
  if spec.omitShellCompletion:
    return
  when defined(reproProviderMode):
    var dests: seq[string]
    for e in spec.entries:
      dests.add(e.dest)
    for e in spec.entries:
      let parts = e.dest.split('/')
      if parts.len != 2 or parts[0] != "bin":
        continue
      let set = cliCompletionFilesOf("", e.source, parts[1])
      if set.program.len == 0:
        continue
      for file in set.files:
        for (shell, dir, lead) in PrefixCompletionDirs:
          if shell != file.shell:
            continue
          let dest = dir & "/" & lead & set.program &
            (if shell == "fish": ".fish" else: "")
          if dest in dests:
            continue
          dests.add(dest)
          result.add(PrefixEntry(source: file.path, dest: dest,
            producer: set.edge.id))

proc installedPrefix*(spec: InstalledPrefixSpec; projectRoot: string):
    InstalledPrefix =
  ## The assembly and gate edges for `spec` (see the header), with the
  ## shell completion files of its `cli:` executables (`completionEntries`).
  var spec = spec
  spec.entries.add(completionEntries(spec))
  let assemblyTools = @["sh", "cp", "ln", "mkdir", "rm", "chmod", "find",
    "head", "printf", "sed", "readelf", "patchelf", "awk", "sort", "grep",
    "ls", "mktemp", "basename", "mv"]
  var deps: seq[string]
  var inputs: seq[string]
  for e in spec.entries:
    if e.producer.len > 0 and e.producer notin deps: deps.add(e.producer)
    inputs.add(e.source)
  for src in spec.librarySources:
    if src.producer.len > 0 and src.producer notin deps: deps.add(src.producer)
  inputs.add(spec.extraInputs)
  for dep in spec.extraDeps:
    if dep notin deps: deps.add(dep)
  var tools = assemblyTools
  if spec.debugStripCommand.len == 0:
    tools.add(LlvmObjcopyTool)
  for tool in spec.extraTools:
    if tool notin tools: tools.add(tool)
  result.dir = spec.output
  result.assemble = buildAction(
    id = "installed-prefix-" & idPart(spec.name) & "@" & idPart(spec.triple),
    call = inlineExecCall(@["sh", "-c", assemblyScript(spec)], projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[spec.output],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "installed-prefix.assemble",
    toolIdentityRefs = tools)
  result.gate = buildAction(
    id = "installed-prefix-gate-" & idPart(spec.name) & "@" & idPart(spec.triple),
    call = inlineExecCall(@["sh", "-c", gateScript(spec.output,
      spec.gateChecks, prefixBuildRoots(spec))], projectRoot),
    deps = @[result.assemble.id],
    inputs = @[spec.output],
    outputs = @[gateStamp(spec.output)],
    # The needles include the working directory and $HOME, which are this
    # host's: the verdict is about these bytes on this host, every run.
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "installed-prefix.gate",
    toolIdentityRefs = @["sh", "find", "head", "printf", "grep", "sed", "rm",
      "mktemp", "touch"] & spec.gateTools)

proc installedPrefixArchive*(prefix: InstalledPrefix; archive,
                             topLevel: string; projectRoot: string;
                             refuseDirty = true): BuildActionDef =
  ## The prefix packed as `archive` (`.tar.gz`) under `topLevel/`, after the
  ## gate. With `refuseDirty`, a prefix whose record says it was built from
  ## a modified tree (`-dirty` in `source_revision=`) is refused: an archive
  ## is what gets published (§5.3).
  var s = "set -e; "
  if refuseDirty:
    s.add("if grep -q -- '-dirty' " &
      q(prefix.dir / PrefixRecordPath) & "; then echo " &
      q("installed prefix: refusing to pack a prefix built from a modified " &
        "tree (" & PrefixRecordPath & " says -dirty); commit first") &
      " >&2; grep -- '-dirty' " & q(prefix.dir / PrefixRecordPath) &
      " >&2; exit 1; fi; ")
  s.add("mkdir -p " & q(archive.parentDir) & "; ")
  s.add("tar --sort=name --owner=0 --group=0 --numeric-owner " &
    "--mtime='@0' -C " & q(prefix.dir.parentDir) & " --transform " &
    q("s|^" & prefix.dir.extractFilename & "|" & topLevel & "|") &
    " -cf - " & q(prefix.dir.extractFilename) & " | gzip -n > " & q(archive))
  buildAction(
    id = "installed-prefix-archive-" & idPart(topLevel),
    call = inlineExecCall(@["sh", "-c", s], projectRoot),
    deps = @[prefix.gate.id],
    inputs = @[prefix.dir, gateStamp(prefix.dir)],
    outputs = @[archive],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "installed-prefix.archive",
    toolIdentityRefs = @["sh", "grep", "mkdir", "tar", "gzip"])

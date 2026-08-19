## Joining the consumer side (`runtimeDeps:`) to the producer side
## (`runtimeLibrary`) — the directories a launcher must make searchable.
##
## The join is what answers "which runtime dependencies are libraries?" without
## a heuristic. `runtimeDeps:` is documented as carrying "tools/libraries"
## together, so classifying by name would be both unreliable and invisible when
## wrong. Instead: a dependency contributes a directory exactly when the package
## providing it declares a `runtimeLibrary` matching this host. A tool declares
## none and contributes none.
##
## The other thing pinned here is that an unresolvable dependency is REPORTED.
## Silently omitting a directory yields a launcher that looks complete and fails
## at load time with the same "could not load: clingo.dll" this model exists to
## prevent — the original bug relocated. The caller may decide that is
## tolerable; it does not get to not know.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/prefix_layout

package resolvLibA:
  runtimeLibrary "clingo", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "linux"

package resolvLibB:
  runtimeLibrary "other", dir = "lib64"

package resolvLibFlat:
  # The flat-zip layout: the loadable artifact sits at the prefix root.
  runtimeLibrary "flat", dir = "."

package resolvLibMulti:
  runtimeLibrary "one", dir = "lib"
  runtimeLibrary "two", dir = "lib"     # same dir — must dedupe
  runtimeLibrary "three", dir = "other"

# A package that declares NO runtime library: an ordinary tool dependency.
package resolvToolOnly:
  uses:
    "nim >=2.2 <3.0"

const Prefixes = {
  "resolvLibA": "/store/a",
  "resolvLibB": "/store/b",
  "resolvLibFlat": "/store/flat",
  "resolvLibMulti": "/store/multi",
  "resolvToolOnly": "/store/tool",
}

proc prefixOf(pkg: string): string {.raises: [].} =
  for (k, v) in Prefixes:
    if k == pkg:
      return v
  ""

proc noPrefixes(pkg: string): string {.gcsafe, raises: [].} = ""

suite "runtime library resolution":
  test "a declaring dependency contributes its directory":
    let r = resolveRuntimeLibraryDirs(["resolvLibA"], "x86_64", "windows",
      prefixOf)
    check r.dirs == @["/store/a/Library/bin"]
    check r.unresolved.len == 0

  test "the host selects the directory, not the declaration order":
    let r = resolveRuntimeLibraryDirs(["resolvLibA"], "x86_64", "linux",
      prefixOf)
    check r.dirs == @["/store/a/lib"]

  test "a dependency declaring nothing contributes nothing and is not an error":
    # This is the tool case, and it is the common case. It must not appear in
    # `unresolved`, which is reserved for something genuinely missing.
    let r = resolveRuntimeLibraryDirs(["resolvToolOnly"], "x86_64", "linux",
      prefixOf)
    check r.dirs.len == 0
    check r.unresolved.len == 0
    check r.providedNone == @["resolvToolOnly"]

  test "order follows the consumer's declaration order":
    # The spec requires the resulting search path be prepend-only and never
    # wider than runtimeLibraryDirs, so the order is part of the contract.
    let r = resolveRuntimeLibraryDirs(["resolvLibB", "resolvLibA"],
      "x86_64", "linux", prefixOf)
    check r.dirs == @["/store/b/lib64", "/store/a/lib"]

  test "a repeated directory is dropped, keeping the first occurrence":
    let r = resolveRuntimeLibraryDirs(["resolvLibMulti"], "x86_64", "linux",
      prefixOf)
    check r.dirs == @["/store/multi/lib", "/store/multi/other"]

  test "the same dependency named twice yields one entry":
    let r = resolveRuntimeLibraryDirs(["resolvLibA", "resolvLibA"],
      "x86_64", "linux", prefixOf)
    check r.dirs == @["/store/a/lib"]

  test "a flat layout resolves to the prefix root, not to prefix/.":
    let r = resolveRuntimeLibraryDirs(["resolvLibFlat"], "x86_64", "linux",
      prefixOf)
    check r.dirs == @["/store/flat"]

  test "an unrealized dependency is REPORTED, not silently skipped":
    # The failure this whole model exists to prevent, relocated: a launcher
    # that looks complete and dies at load time.
    let r = resolveRuntimeLibraryDirs(["resolvLibA"], "x86_64", "linux",
      noPrefixes)
    check r.dirs.len == 0
    check r.unresolved == @["resolvLibA"]

  test "one unresolvable dependency does not suppress the others":
    # Partial resolution must still yield what it could, so a caller that
    # decides to continue gets the maximum working set rather than nothing.
    proc partial(pkg: string): string {.raises: [].} =
      if pkg == "resolvLibA": "" else: prefixOf(pkg)
    let r = resolveRuntimeLibraryDirs(["resolvLibA", "resolvLibB"],
      "x86_64", "linux", partial)
    check r.dirs == @["/store/b/lib64"]
    check r.unresolved == @["resolvLibA"]

  test "a host matching no declared slice contributes nothing":
    # resolvLibA declares windows only for x86_64; an aarch64 windows host
    # matches neither slice.
    let r = resolveRuntimeLibraryDirs(["resolvLibA"], "aarch64", "windows",
      prefixOf)
    check r.dirs.len == 0
    check r.unresolved.len == 0
    check r.providedNone == @["resolvLibA"]

  test "an empty dependency list yields an empty resolution":
    let r = resolveRuntimeLibraryDirs([], "x86_64", "linux", prefixOf)
    check r.dirs.len == 0
    check r.unresolved.len == 0
    check r.providedNone.len == 0

  test "an unknown package is reported as declaring nothing, not as missing":
    # A dependency on a package outside the registry cannot be distinguished
    # from a tool here, and must not be reported as unresolved — that field is
    # about a package that DOES declare a library but has no prefix.
    let r = resolveRuntimeLibraryDirs(["noSuchPackage"], "x86_64", "linux",
      prefixOf)
    check r.unresolved.len == 0
    check r.providedNone == @["noSuchPackage"]

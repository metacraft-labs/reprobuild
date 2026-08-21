## NLF-DIA-8 — an inherited `multiVersion` default is traceable.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-8**:
##
## > A C library declaring **no** `multiVersion`, inheriting `forbidden` from
## > the language convention, reached at two irreconcilable versions.
## > **Expect.** The error states the default was **inherited**, names the
## > language convention it came from, and cites that convention's source —
## > not merely "libfoo forbids co-linking".
##
## ## Why this is a requirement rather than a nicety
##
## Q-11 settled that the default is per-language, and it answered the
## objection to that rather than dropping it:
##
## > A per-language default is invisible at the library that inherits it, so
## > the §9.4 diagnostic MUST state **where an inherited default came from** —
## > naming the language convention and its source — whenever a co-linking
## > error rests on a default the library did not write. An inherited default
## > that cannot be traced is the invisible-rule failure §4.7 is written
## > against.
##
## The library's recipe contains no `multiVersion` line, so an author reading
## it cannot tell why the build refused. A diagnostic that says only "libfoo
## declares `multiVersion forbidden`" is worse than incomplete — it is FALSE,
## and it sends the reader to grep a file for a line that is not in it.
##
## ## Paired with NLF-DIA-4
##
## DIA-4 asserts the inherited answer is `forbidden`. This one asserts the
## inheritance is visible. An implementation can pass DIA-4 with a two-valued
## property whose zero value is `forbidden`, and that implementation has
## nothing to say here.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header.

import std/[strutils, unittest]

import ./nlf_m8_fixture

const
  App = "app"
  LibImaging = "libimaging"
  LibReport = "libreport"
  LibFoo = "libfoo"
  Binary = "build/app"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(language: string): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(App, @["1.0.0"], @[m8dep(LibImaging, ">=3.0 <4.0"),
                               m8dep(LibReport, ">=0.9 <1.0")]),
      m8pkg(LibImaging, @["3.1.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      m8pkg(LibReport, @["0.9.4"], @[m8dep(LibFoo, ">=1.4 <2.0")]),
      m8pkg(LibFoo, @Published, language = language)],
    artifacts: @[m8artifact(Binary, App)])

suite "NLF-DIA-8 an inherited multiVersion default is traceable":

  setup:
    resetLockFileDeclarations()

  test "the resolution records that the answer was inherited":
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvUnset, language: "c"))
    check resolution.policy == mvForbidden
    check resolution.inherited
    check resolution.convention.language == "c"
    check resolution.convention.source.len > 0

  test "a library that DECLARED the same answer is not marked inherited":
    # The control that makes the flag mean something. If `inherited` were
    # simply true whenever the answer is `forbidden`, the diagnostic would
    # claim a convention for a line the author actually wrote.
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvForbidden, language: "c"))
    check resolution.policy == mvForbidden
    check not resolution.inherited

  test "the error says the default was inherited, and does not claim a declaration":
    let message = renderColinkingError(
      solveDiamond(workspace("c")).conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "declares no `multiVersion`" in message
    check "inherits" in message
    # And it must NOT say the thing that is false.
    check not (LibFoo & " declares `multiVersion forbidden`" in message)

  test "the error names the language convention and cites its source":
    let message = renderColinkingError(
      solveDiamond(workspace("c")).conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "c language convention" in message
    check "flat native symbol table" in message
    check "convention source: " in message
    check MultiVersionConventionSource in message

  test "a different language names a different convention":
    # The convention is read, not stamped. `d` and `c` are both `forbidden`,
    # so an implementation that hard-coded C's text would pass every
    # assertion above; it fails here, because the convention it names would
    # be the wrong one.
    let message = renderColinkingError(
      solveDiamond(workspace("d")).conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "d language convention" in message
    check not ("c language convention" in message)

  test "a language whose runtime keeps versions apart inherits `allowed`":
    # Q-11's other half, and the reason the per-language table is not a
    # decoration on a universal default: the same undeclared library in Rust
    # is not refused at all.
    let solved = solveDiamond(workspace("rust"))
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.versionsReached(Binary, LibFoo).len == 2
    check solved.conflicts.len == 0

  test "a language nobody has characterised inherits `forbidden`, and says so":
    # §9.3's naming rule applied to the convention table itself: an absent
    # convention must not read as a permission nobody granted.
    let message = renderColinkingError(
      solveDiamond(workspace("brainfuck")).conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "inherits `multiVersion forbidden`" in message
    check "no language convention names" in message

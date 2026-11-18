## NLF-DIA-9 — a runtime with one version per name inherits `forbidden`.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-9**
## (`reprobuild-pm/spec/Named-Lock-Files-Test-Corpus.md`):
##
## > Four libraries, each declaring **no** `multiVersion` and each reached at
## > two irreconcilable versions within one unit that loads together: a Python
## > package in one environment, a JVM library on one classpath, an Erlang/OTP
## > application in one release, and a Rust crate whose `Cargo.toml` declares a
## > `links` key, in one binary.
## > **Expect.** Each fails with the NLF-DIA-2 error, and, as in NLF-DIA-8, the
## > error names the language convention the inherited `forbidden` came from.
## > A Rust crate *without* a `links` key, reached the same way, inherits
## > `allowed`.
##
## ## The property protected
##
## The per-language default table (`Named-Lock-Files.md` §9.3, Q-11 as
## corrected on 2026-11-16) must not mark a runtime `allowed` merely because
## it LOOKS isolated. `sys.modules`, a flat JVM classpath and a BEAM node each
## hold ONE version per name, so a second version is replaced or shadowed, not
## isolated: the build is green and the program runs whichever version loaded
## first. That is the silent "links cleanly and misbehaves" failure NLF-DIA-4
## guards against for C. A Rust crate with a Cargo `links` key binds a native
## library, which is a flat symbol table again whatever Rust mangles.
##
## Written as the confirmation test for the provisional issue
## `reprobuild-pm/issues/2026-11-16-stdlib-multiversion-defaults-may-still-allow-python-jvm-and-beam.md`:
## at the commit it was written against, the convention table gave Python,
## Java, Kotlin, Erlang and Elixir `allowed` and had no notion of a `links`
## key, and every refusal case below built cleanly.
##
## ## Scope
##
## The default applies where Reprobuild's solver selects the versions (§9.3,
## last paragraph). This test drives exactly that path: the real
## `repro_solver` solve over a diamond whose two ranges cannot be unified,
## then the real link-closure walk and co-linking check. Where a language's own
## resolver selects versions (Cargo in Mode B, `uv`, Maven, `rebar3`), that
## resolver's answer is reported unchanged and is out of this test's reach.
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

proc workspace(language: string; cargoLinks = ""): M8Recipe =
  ## NLF-DIA-8's diamond: `app` reaches `libfoo` through two consumers whose
  ## ranges (`>=2.0 <3.0` and `>=1.4 <2.0`) admit no common version, and
  ## `libfoo` declares no `multiVersion`.
  M8Recipe(
    packages: @[
      m8pkg(App, @["1.0.0"], @[m8dep(LibImaging, ">=3.0 <4.0"),
                               m8dep(LibReport, ">=0.9 <1.0")],
            language = language),
      m8pkg(LibImaging, @["3.1.0"], @[m8dep(LibFoo, ">=2.0 <3.0")],
            language = language),
      m8pkg(LibReport, @["0.9.4"], @[m8dep(LibFoo, ">=1.4 <2.0")],
            language = language),
      m8pkg(LibFoo, @Published, language = language,
            cargoLinks = cargoLinks)],
    artifacts: @[m8artifact(Binary, App)])

template checkRefusedByConvention(language, conventionName,
                                  rationaleFragment: string;
                                  cargoLinks = "") =
  ## A template, not a proc: `unittest`'s `check` marks the enclosing TEST
  ## failed only when it expands inside the test body. Called from a proc it
  ## prints "Check failed" and the test still reports `[OK]`.
  let solved = solveDiamond(workspace(language, cargoLinks))
  # The precondition, so a refusal is not mistaken for a solve that never
  # reached two versions at all.
  check solved.versionsReached(Binary, LibFoo).len == 2
  check solved.conflicts.len == 1
  if solved.conflicts.len == 1:
    let message = renderColinkingError(solved.conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "cannot be linked at two versions into one binary" in message
    check "declares no `multiVersion`" in message
    check "inherits `multiVersion forbidden`" in message
    # The rest of the NLF-DIA-2 error: both versions with their demanding
    # paths, and the statement that unification was attempted.
    check "app  ->  libimaging 3.1.0  ->  libfoo >=2.0 <3.0" in message
    check "app  ->  libreport 0.9.4  ->  libfoo >=1.4 <2.0" in message
    check "unification was attempted and failed" in message
    check (conventionName & " language convention") in message
    check "convention source: " in message
    check MultiVersionConventionSource in message
    # The convention's own reason, so a row that flips its policy but keeps
    # the retired "keeps versions apart" rationale is still caught.
    check rationaleFragment in message
    check not ("keeps versions apart" in message)
    # Named by its own convention, not by the catch-all for unlisted
    # languages: an implementation that simply dropped these runtimes from
    # the table would also refuse, but would tell the author nobody had
    # characterised Python.
    check not ("no language convention names" in message)

suite "NLF-DIA-9 a runtime with one version per name inherits forbidden":

  setup:
    resetLockFileDeclarations()

  test "a Python package at two versions in one environment is refused":
    checkRefusedByConvention("python", "python", "sys.modules")

  test "a Python package spelled `py` is refused under the same convention":
    checkRefusedByConvention("py", "python", "sys.modules")

  test "a Java library at two versions on one classpath is refused":
    checkRefusedByConvention("java", "java", "defines a class name once")

  test "a Kotlin library at two versions on one classpath is refused":
    checkRefusedByConvention("kotlin", "kotlin", "defines a class name once")

  test "a Scala library at two versions on one classpath is refused":
    checkRefusedByConvention("scala", "scala", "defines a class name once")

  test "an Erlang/OTP application at two versions in one release is refused":
    checkRefusedByConvention("erlang", "erlang", "one current version of each module")

  test "an Elixir application at two versions in one release is refused":
    checkRefusedByConvention("elixir", "elixir", "one current version of each module")

  test "a Rust crate with a Cargo `links` key is refused":
    checkRefusedByConvention("rust", "rust", "binds a native library",
                             cargoLinks = "foo")
    let message = renderColinkingError(
      solveDiamond(workspace("rust", "foo")).conflictFor(Binary, LibFoo))
    # The rationale must name the reason this crate differs from every other
    # Rust crate, or the author is left contradicting "Rust mangles".
    check "`links = \"foo\"`" in message

  test "a Rust crate without a `links` key still inherits `allowed`":
    # The control. Without it, an implementation that turned Rust `forbidden`
    # wholesale would pass the case above.
    let solved = solveDiamond(workspace("rust"))
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.versionsReached(Binary, LibFoo).len == 2
    check solved.conflicts.len == 0

  test "the resolution of each one-version-per-name runtime is `forbidden`":
    for language in ["python", "java", "kotlin", "scala", "clojure", "groovy",
                     "erlang", "elixir", "gleam"]:
      let resolution = resolveMultiVersion(LibraryMultiVersion(
        library: LibFoo, declared: mvUnset, language: language))
      checkpoint(language & ": " & $resolution.policy)
      check resolution.policy == mvForbidden
      check resolution.inherited
      check resolution.convention.language == language

  test "common spellings reach the named convention, not the catch-all":
    for (spelling, language) in [("python3", "python"), ("kt", "kotlin"),
                                 ("erl", "erlang"), ("exs", "elixir"),
                                 ("Python", "python"), (" Java ", "java")]:
      let resolution = resolveMultiVersion(LibraryMultiVersion(
        library: LibFoo, declared: mvUnset, language: spelling))
      checkpoint(spelling)
      check resolution.policy == mvForbidden
      check resolution.convention.language == language

  test "the `links` key is read whatever the spelling of Rust and the padding":
    for (spelling, links, expected) in [
        ("Rust", "foo", mvForbidden), ("rs", "foo", mvForbidden),
        ("rust", "  foo  ", mvForbidden), ("rust", "   ", mvAllowed),
        ("rs", "", mvAllowed)]:
      let resolution = resolveMultiVersion(LibraryMultiVersion(
        library: LibFoo, declared: mvUnset, language: spelling,
        cargoLinks: links))
      checkpoint(spelling & " links=`" & links & "`")
      check resolution.policy == expected
      check resolution.convention.language == "rust"

  test "node-style JavaScript and TypeScript still inherit `allowed`":
    # §9.3's other `allowed` row. The correction narrowed the list; it must
    # not have swept JavaScript into `forbidden` with Python.
    for language in ["javascript", "js", "node", "typescript", "ts"]:
      let resolution = resolveMultiVersion(LibraryMultiVersion(
        library: LibFoo, declared: mvUnset, language: language))
      checkpoint(language)
      check resolution.policy == mvAllowed
      check resolution.inherited

  test "an explicit `allowed` still overrides the inherited `forbidden`":
    # §9.3: an author who has set up isolation (shading, JPMS layers, OSGi)
    # claims it with `allowed`. The correction tightens the default; it must
    # not remove the override.
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvAllowed, language: "java"))
    check resolution.policy == mvAllowed
    check not resolution.inherited

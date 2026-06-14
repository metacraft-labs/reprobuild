## C2 P2: apt-index parser smoke test.
##
## Exercises ``parsePackagesIndex``, ``parseDepends``, ``buildAptIndex``,
## and ``resolveClosure`` against a hand-authored Packages stanza set
## modelled on a Debian bookworm snapshot. The fixture intentionally
## stresses the harder corners of the parser:
##
##   * multi-line Depends: values (RFC 822 continuation),
##   * version-constraint operators (<<, <=, =, >=, >>),
##   * architecture qualifiers (``foo:any``),
##   * ``|``-joined alternatives,
##   * virtual packages reached via ``Provides:``,
##   * transitive closure walking + deduplication,
##   * the missing-dep error path.

import std/[algorithm, strutils, unittest, tables]

import repro_dsl_stdlib/packages/apt_index

const Fixture = """
Package: git
Version: 1:2.39.5-0+deb12u2
Architecture: amd64
Section: vcs
Priority: optional
Filename: pool/main/g/git/git_2.39.5-0+deb12u2_amd64.deb
Size: 8000000
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Depends: libc6 (>= 2.34), libcurl3-gnutls (>= 7.74.0),
 libpcre2-8-0 (>= 10.32), zlib1g (>= 1:1.1.4), perl:any,
 git-man (>= 1:2.39.5-0+deb12u2)
Description: fast, scalable, distributed revision control system
 Git is popular version control system designed to handle very large
 projects.

Package: libc6
Version: 2.36-9+deb12u9
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/g/glibc/libc6_2.36-9+deb12u9_amd64.deb
Size: 3000000
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Depends: libgcc-s1 (>= 3.5), libcrypt1 (>= 1:4.1.0-4)
Description: GNU C Library: Shared libraries

Package: libcurl3-gnutls
Version: 7.88.1-10+deb12u8
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/c/curl/libcurl3-gnutls_7.88.1-10+deb12u8_amd64.deb
Size: 400000
SHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
Depends: libc6 (>= 2.34), libnghttp2-14 (>= 1.41.0), zlib1g (>= 1:1.1.4)
Description: easy-to-use client-side URL transfer library (GnuTLS flavour)

Package: libpcre2-8-0
Version: 10.42-1
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/p/pcre2/libpcre2-8-0_10.42-1_amd64.deb
Size: 200000
SHA256: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
Depends: libc6 (>= 2.34)
Description: New Perl Compatible Regular Expression Library

Package: zlib1g
Version: 1:1.2.13.dfsg-1
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb
Size: 100000
SHA256: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
Depends: libc6 (>= 2.14)
Description: compression library - runtime

Package: libgcc-s1
Version: 12.2.0-14
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/g/gcc-12/libgcc-s1_12.2.0-14_amd64.deb
Size: 120000
SHA256: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
Depends: gcc-12-base (= 12.2.0-14), libc6 (>= 2.34)
Description: GCC support library

Package: libcrypt1
Version: 1:4.4.33-2
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/libx/libxcrypt/libcrypt1_4.4.33-2_amd64.deb
Size: 80000
SHA256: 0000000000000000000000000000000000000000000000000000000000000001
Depends: libc6 (>= 2.34)
Description: libcrypt shared library

Package: libnghttp2-14
Version: 1.52.0-1+deb12u2
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/n/nghttp2/libnghttp2-14_1.52.0-1+deb12u2_amd64.deb
Size: 90000
SHA256: 0000000000000000000000000000000000000000000000000000000000000002
Depends: libc6 (>= 2.34)
Description: library implementing HTTP/2 protocol

Package: gcc-12-base
Version: 12.2.0-14
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/g/gcc-12/gcc-12-base_12.2.0-14_amd64.deb
Size: 50000
SHA256: 0000000000000000000000000000000000000000000000000000000000000003
Description: GCC, the GNU Compiler Collection (base package)

Package: git-man
Version: 1:2.39.5-0+deb12u2
Architecture: all
Section: doc
Priority: optional
Filename: pool/main/g/git/git-man_2.39.5-0+deb12u2_all.deb
Size: 1700000
SHA256: 0000000000000000000000000000000000000000000000000000000000000004
Description: fast, scalable, distributed revision control system (manual pages)

Package: perl-base
Version: 5.36.0-7+deb12u1
Architecture: amd64
Section: perl
Priority: required
Filename: pool/main/p/perl/perl-base_5.36.0-7+deb12u1_amd64.deb
Size: 1500000
SHA256: 0000000000000000000000000000000000000000000000000000000000000005
Depends: libc6 (>= 2.34)
Provides: perl, perl5, perlapi-5.36.0
Description: minimal Perl system
"""

suite "C2 P2 apt-index parser":

  test "parsePackagesIndex returns one record per stanza":
    let records = parsePackagesIndex(Fixture)
    check records.len == 11
    check records[0].name == "git"
    check records[0].version == "1:2.39.5-0+deb12u2"
    check records[0].sha256 ==
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    check records[0].sizeBytes == 8000000

  test "parseDepends handles version constraints + alternatives":
    let clauses = parseDepends(
      "libc6 (>= 2.34), libcurl3-gnutls (>= 7.74.0), perl:any, " &
      "libfoo (<< 3.0) | libbar")
    check clauses.len == 4
    check clauses[0].alternatives[0].name == "libc6"
    check clauses[0].alternatives[0].op == adoGe
    check clauses[0].alternatives[0].version == "2.34"
    check clauses[2].alternatives[0].name == "perl"
    check clauses[2].alternatives[0].architecture == "any"
    check clauses[3].alternatives.len == 2
    check clauses[3].alternatives[0].name == "libfoo"
    check clauses[3].alternatives[0].op == adoLt
    check clauses[3].alternatives[1].name == "libbar"

  test "parseDepends tolerates blanks and multi-line input":
    let clauses = parseDepends("  ,  foo,\n bar (>= 1.0),  \n , baz")
    check clauses.len == 3
    check clauses[0].alternatives[0].name == "foo"
    check clauses[1].alternatives[0].name == "bar"
    check clauses[1].alternatives[0].op == adoGe
    check clauses[2].alternatives[0].name == "baz"

  test "buildAptIndex populates byName + virtuals":
    let records = parsePackagesIndex(Fixture)
    let index = buildAptIndex(records)
    check "git" in index.byName
    check "libc6" in index.byName
    check "perl" in index.virtuals
    check "perl" notin index.byName  # virtual only
    check "perl-base" in index.byName
    check index.virtuals["perl"] == @["perl-base"]

  test "resolveClosure walks git transitively":
    let records = parsePackagesIndex(Fixture)
    let index = buildAptIndex(records)
    let closure = resolveClosure("git", index)
    # git itself + libc6 + libcurl3-gnutls + libpcre2-8-0 + zlib1g +
    # libgcc-s1 + libcrypt1 + libnghttp2-14 + gcc-12-base + git-man +
    # perl-base (reached via the perl virtual) = 11
    check closure.len == 11
    var names: seq[string] = @[]
    for c in closure: names.add(c.name)
    check "git" in names
    check "libc6" in names
    check "perl-base" in names  # via Provides: perl
    check "git-man" in names
    # Output is sorted alphabetically.
    var sortedNames = names
    sortedNames.sort(cmp)
    check sortedNames == names

  test "resolveClosure raises AptClosureError on missing dep":
    var records = parsePackagesIndex(Fixture)
    # Add a stanza that depends on a package not in the index.
    records.add(parsePackagesIndex("""
Package: orphan
Version: 1.0
Architecture: amd64
Filename: pool/main/o/orphan/orphan_1.0_amd64.deb
Size: 100
SHA256: 0000000000000000000000000000000000000000000000000000000000000099
Depends: does-not-exist
""")[0])
    let index = buildAptIndex(records)
    expect AptClosureError:
      discard resolveClosure("orphan", index)
    # allowUnresolved=true tolerates the missing dep.
    let partial = resolveClosure("orphan", index, allowUnresolved = true)
    check partial.len == 1
    check partial[0].name == "orphan"

  test "resolveMultiClosure deduplicates shared transitive deps":
    let records = parsePackagesIndex(Fixture)
    let index = buildAptIndex(records)
    let unionClosure = resolveMultiClosure(
      @["git", "libpcre2-8-0"], index)
    # git's closure (11) already contains libpcre2-8-0 + its closure, so
    # the union should still be 11 packages.
    check unionClosure.len == 11

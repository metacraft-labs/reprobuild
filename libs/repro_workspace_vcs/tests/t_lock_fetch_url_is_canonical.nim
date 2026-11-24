## `canonicalLockFetchUrl` — the URL a committed `repro.lock` entry records
## for a repository.
##
## A lock entry's bytes must depend only on the repository and the commit it
## pins, so every network spelling of one repository's remote must reduce to
## one URL, and no credential configured in a remote may survive. Local
## remotes name a directory on the writing machine and are kept verbatim.
## The integration test
## `tests/integration/t_a_siblings_clone_transport_does_not_change_its_lock_entry.nim`
## proves the writer uses this; these cases pin the reduction itself,
## including the spellings that integration test does not reach.
##
## Pure string function: no fixture, no mocks.

import std/unittest

import shared_clones

suite "canonicalLockFetchUrl":

  test "every network spelling of one repository is one URL":
    const want = "https://github.com/metacraft-labs/nim-cli-spec"
    for spelled in [
        "https://github.com/metacraft-labs/nim-cli-spec",
        "https://github.com/metacraft-labs/nim-cli-spec.git",
        "https://github.com/metacraft-labs/nim-cli-spec/",
        "https://github.com/metacraft-labs/nim-cli-spec.git/",
        "https://GitHub.COM/metacraft-labs/nim-cli-spec",
        "https://github.com:443/metacraft-labs/nim-cli-spec",
        "https://github.com//metacraft-labs///nim-cli-spec",
        "git@github.com:metacraft-labs/nim-cli-spec.git",
        "git@github.com:metacraft-labs/nim-cli-spec",
        "github.com:metacraft-labs/nim-cli-spec.git",
        "ssh://git@github.com/metacraft-labs/nim-cli-spec.git",
        "ssh://git@github.com:22/metacraft-labs/nim-cli-spec.git",
        "ssh://git@github.com:2222/metacraft-labs/nim-cli-spec",
        "git+ssh://git@github.com/metacraft-labs/nim-cli-spec.git",
        "ssh+git://git@github.com/metacraft-labs/nim-cli-spec.git",
        "git://github.com/metacraft-labs/nim-cli-spec.git",
        "  https://github.com/metacraft-labs/nim-cli-spec\n"]:
      checkpoint(spelled)
      check canonicalLockFetchUrl(spelled) == want

  test "credentials, queries and fragments never survive":
    check canonicalLockFetchUrl(
      "https://alice:ghp_s3cret@github.com/o/r.git") == "https://github.com/o/r"
    check canonicalLockFetchUrl("https://x-access-token:t@github.com/o/r") ==
      "https://github.com/o/r"
    check canonicalLockFetchUrl("https://alice@github.com/o/r") ==
      "https://github.com/o/r"
    check canonicalLockFetchUrl("https://github.com/o/r?token=abc#frag") ==
      "https://github.com/o/r"
    check canonicalLockFetchUrl("https://github.com/o/r.git#main") ==
      "https://github.com/o/r"

  test "a credential never leaves a tail behind":
    # Userinfo ends at the LAST `@` of the authority, so an unencoded `@` in
    # a token does not leave its tail in front of the host.
    check canonicalLockFetchUrl("https://u:p@ss@github.com/o/r.git") ==
      "https://github.com/o/r"
    check canonicalLockFetchUrl("https://u:tok%40x@github.com/o/r") ==
      "https://github.com/o/r"
    # A `#` or `?` inside userinfo does not cut the authority before the `@`.
    check canonicalLockFetchUrl("https://user:tok#en@host/o/r") ==
      "https://host/o/r"
    check canonicalLockFetchUrl("https://user:tok?en@host/o/r") ==
      "https://host/o/r"
    # A query straight after the host drops the query, not the host.
    check canonicalLockFetchUrl("https://host?token=abc") == "https://host"
    # Nothing parseable as a host: empty (the writer refuses it, naming the
    # entry), never the remote echoed with its userinfo.
    check canonicalLockFetchUrl("https://user:tok@/o/r") == ""
    check canonicalLockFetchUrl("ssh://git@:22/o/r") == ""

  test "an IPv6 host keeps its brackets and colons":
    for spelled in ["ssh://git@[2001:db8::1]/o/r.git",
        "ssh://git@[2001:db8::1]:22/o/r.git",
        "git@[2001:db8::1]:o/r.git", "[2001:db8::1]:o/r",
        "https://[2001:DB8::1]/o/r", "https://[2001:db8::1]:443/o/r/"]:
      checkpoint(spelled)
      check canonicalLockFetchUrl(spelled) == "https://[2001:db8::1]/o/r"
    check canonicalLockFetchUrl("https://[::1]:8443/o/r") ==
      "https://[::1]:8443/o/r"

  test "odd but well-formed spellings":
    # An `@` in an scp-like PATH is not userinfo.
    check canonicalLockFetchUrl("host:o/r@v1") == "https://host/o/r@v1"
    # An absolute scp-like path.
    check canonicalLockFetchUrl("git@host:/srv/o/r.git") ==
      "https://host/srv/o/r"
    # A non-numeric "port" is not a port.
    check canonicalLockFetchUrl("https://host:abc/o/r") == "https://host/o/r"
    check canonicalLockFetchUrl("HTTPS://Host/O/R.GIT") == "https://host/O/R"
    check canonicalLockFetchUrl("https://host") == "https://host"
    # An SSH port on a non-default endpoint says nothing about HTTPS.
    check canonicalLockFetchUrl("ssh://git@ssh.github.com:443/o/r.git") ==
      "https://ssh.github.com/o/r"

  test "http, a non-default https port and path case are kept":
    check canonicalLockFetchUrl("http://git.example.org/o/r.git") ==
      "http://git.example.org/o/r"
    check canonicalLockFetchUrl("https://git.example.org:8443/o/r.git") ==
      "https://git.example.org:8443/o/r"
    check canonicalLockFetchUrl("http://git.example.org:80/o/r") ==
      "http://git.example.org/o/r"
    check canonicalLockFetchUrl("https://github.com/Org/Repo") ==
      "https://github.com/Org/Repo"
    check canonicalLockFetchUrl("https://seed.radicle.dev/z3gq.git") ==
      "https://seed.radicle.dev/z3gq"

  test "local remotes are written as spelled":
    for local in ["file:///srv/git/lib-b.git", "file:///srv/git/lib-b",
        "/srv/git/lib-b.git", "../origin-lib-b.git", "./lib-b",
        "C:/repos/lib-b.git", "C:\\repos\\lib-b.git",
        "\\\\server\\share\\lib-b.git"]:
      checkpoint(local)
      check canonicalLockFetchUrl(local) == local

  test "empty stays empty":
    check canonicalLockFetchUrl("") == ""
    check canonicalLockFetchUrl("   ") == ""

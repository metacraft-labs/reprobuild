#!/usr/bin/env python3
"""Scope a CI git credential to exactly the repositories a ``repro.lock`` clones.

WHY THIS EXISTS
===============

The ``Test`` job in ``.github/workflows/ci.yml`` provisions CodeTracer's
source siblings with ``repro develop --all --reset``, which clones every
``coord_kind = "vcs"`` dependency recorded in CodeTracer's committed
``repro.lock``. That step used to run with every git credential masked, on the
premise that whatever a committed lock names is anonymously cloneable.

The spec declines to provide that premise. ``reprobuild-pm/spec/
Unified-Locking-And-Hooks.md`` §14.1: "Tiers are configuration, never hosting
visibility." A lock entry's ``visibility = "public"`` says that no layer
beyond the built-in default declared the repo, so it is recorded in the
committed lock -- the DEFAULT home of every develop-set sibling. It says
nothing about who can read the repository on its forge, and reprobuild never
asks a forge. So CodeTracer's lock legitimately names forge-private repos
(``codetracer-launcher``, ``codetracer-native-backend``, ...), all marked
``visibility = "public"``, and the anonymous clone died with
``fatal: could not read Username for 'https://github.com': terminal prompts
disabled`` (reprobuild-pm issue ``2026-10-14-ci-reconcile-step-assumes-the-
committed-lock-names-only-forge-public-repos``).

The resolution is a credential that covers the lock's develop set and nothing
else. This script derives that set FROM THE LOCK -- the same source
``develop --all`` reads, so the two cannot drift -- and renders the credential
in the one form that reaches the engine's clones.

WHAT IT DELIBERATELY DOES NOT READ
==================================

The ``visibility`` field. Filtering on it is the bug. Every vcs dependency
under ``<url-base><owner>/`` is credentialed whatever its tier says; the only
other filter is the root entry (``path = "."``), which is the checkout
``develop`` runs in and is never cloned by it.

Dependencies under another owner or host are NOT credentialed -- the token is
an installation token for ``<owner>`` and has no business being sent
elsewhere. They are named on stderr instead, so that the day one of them goes
forge-private the failure arrives with its explanation beside it rather than
as a bare ``could not read Username``.

WHY A ``GIT_CONFIG_GLOBAL`` FILE, AND WHY ``extraHeader``
=========================================================

Two other mechanisms look equivalent and are not:

* ``GIT_CONFIG_COUNT`` / ``GIT_CONFIG_KEY_<n>`` / ``GIT_CONFIG_VALUE_<n>``,
  which the later "Build codetracer ct" step uses. The engine runs its git
  actions with ``scrubbedGitRepositoryEnv()``
  (``libs/repro_workspace_vcs/src/git_tool.nim``, ``GitRepositoryLocalEnv`` and
  ``GitRepositoryLocalEnvPrefixes``), which DROPS those variables, so a
  credential carried there never reaches ``develop``'s clones.
  ``GIT_CONFIG_GLOBAL`` is not scrubbed.
* A ``url.<token-url>.insteadOf`` rewrite. It puts the token into the
  rewritten URL, which git passes as an argument to every ``git-remote-https``
  it spawns, so it is readable through ``ps`` / ``/proc`` by every process on
  a self-hosted runner shared across jobs. (The clone's ``remote.origin.url``
  keeps the un-rewritten spelling; only a token embedded in the clone URL
  itself is written into ``.git/config``.) An ``http.<url>.extraHeader`` stays
  in the config file, is sent only on the wire, and is never written into the
  clone.

``http.<url>.*`` keys match by slash-delimited path prefix
(https://git-scm.com/docs/git-config#Documentation/git-config.txt-httplturlgt),
so the subsection ``https://github.com/<owner>/isonim/`` authenticates
``isonim`` and ``isonim/info/refs`` but not ``isonim-tui``. Both the bare and
the ``.git`` spelling are emitted, because ``isonim/`` is not a prefix of
``isonim.git/``.

THE TOKEN
=========

Read from ``$GH_TOKEN`` only -- an argv element is visible to every process on
the host through ``ps`` and ``/proc``. It is never printed. The output file is
created exclusively (``O_CREAT | O_EXCL | O_NOFOLLOW``) with mode 0600, so a
pre-planted file or symlink at the path is refused rather than reused. The
caller owns deleting it.

``--emit-actions-mask`` prints a single ``::add-mask::`` workflow command for
the base64 header payload. GitHub masks the App token it mints, but not this
encoding of it; masking it means anything that ever echoes the header is
redacted in the job log.

USAGE
=====

    ci_lock_source_credentials.py repositories --lock repro.lock --owner OWNER
    GH_TOKEN=... ci_lock_source_credentials.py gitconfig \\
        --lock repro.lock --owner OWNER --out FILE [--emit-actions-mask]

``--url-base`` (default ``https://github.com/``) exists for the test suite's
loopback forge (``tests/unit/test_ci_reconcile_lock_credentials.py``) and
accepts nothing but that default or ``http://127.0.0.1:<port>/`` /
``http://localhost:<port>/`` -- the same restriction
``metacraft-github-actions/git-auth/scoped-git-auth.sh`` places on its
``GIT_AUTH_URL_BASE``. A token sent in clear text is acceptable only to a
socket that never leaves the host.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11, e.g. a stock macOS python3
    # Say what is wrong instead of a traceback: CI runs this under
    # `dev-exec python3` (nixpkgs, >= 3.11); a host interpreter may be older.
    sys.exit("ci_lock_source_credentials: error: needs Python >= 3.11 "
             f"(tomllib); this is {sys.version.split()[0]}. Run it under "
             "`dev-exec python3` or the reprobuild dev shell.")

GITHUB_URL_BASE = "https://github.com/"

# Loopback only, with an explicit port and nothing after the slash. Anything
# looser (another host, an implicit port, a path) is refused, because the
# knob's only legitimate use is a test server bound to 127.0.0.1.
LOOPBACK_URL_BASE = re.compile(r"^http://(127\.0\.0\.1|localhost):[0-9]{1,5}/$")

# GitHub owner and repository names are drawn from this set. The names are
# written into a git config subsection, where `"` and `\` are syntax and a
# newline would start a new key, so anything outside it is refused rather
# than escaped: a lock naming such a repo is malformed, not exotic.
NAME = re.compile(r"^[A-Za-z0-9._-]+$")

# What a GitHub App installation token may contain is not documented as a
# fixed alphabet, but it is a single printable word. A token with whitespace
# or a control character would inject into the header line, so refuse it.
TOKEN = re.compile(r"^[\x21-\x7e]+$")


class LockCredentialError(Exception):
    """A lock, argument or token this script refuses to act on."""


def validate_url_base(url_base: str) -> str:
    if url_base == GITHUB_URL_BASE or LOOPBACK_URL_BASE.match(url_base):
        return url_base
    raise LockCredentialError(
        f"--url-base must be {GITHUB_URL_BASE} or a loopback "
        f"http://127.0.0.1:<port>/ address (got {url_base!r})")


def load_lock_deps(lock_path: Path) -> list[dict]:
    """The ``[lock].deps`` entries of a committed lock, or a loud error."""
    try:
        raw = lock_path.read_bytes()
    except OSError as error:
        raise LockCredentialError(
            f"cannot read lock {lock_path}: {error.strerror or error}") from error
    try:
        document = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise LockCredentialError(
            f"lock {lock_path} is not valid TOML: {error}") from error
    lock = document.get("lock")
    deps = lock.get("deps") if isinstance(lock, dict) else None
    if not isinstance(deps, list):
        raise LockCredentialError(
            f"lock {lock_path} has no [lock].deps array; this is not a "
            "solved-graph lock, or its schema changed under this script")
    return deps


def repository_name(url: str, prefix: str) -> str | None:
    """The repository name of ``<prefix><name>[.git][/]``, else ``None``.

    ``None`` means the URL is not a repository directly under the owner --
    another owner, another host, or a deeper path -- and so is not covered.
    """
    if not url.startswith(prefix):
        return None
    rest = url[len(prefix):]
    if rest.endswith("/"):
        rest = rest[:-1]
    if rest.endswith(".git"):
        rest = rest[:-len(".git")]
    if not rest or "/" in rest:
        return None
    if not NAME.match(rest) or rest in (".", ".."):
        raise LockCredentialError(
            f"lock names a repository URL {url!r} whose name is not a valid "
            "forge repository name; refusing to write it into a git config")
    return rest


def derive_repositories(lock_path: Path, owner: str,
                        url_base: str = GITHUB_URL_BASE,
                        ) -> tuple[list[str], list[str]]:
    """Return ``(credentialed names, anonymous URLs)`` for a lock.

    Credentialed: every vcs dep directly under ``<url_base><owner>/`` except
    the root entry, sorted and deduplicated, REGARDLESS of ``visibility``
    (see the module docstring). Anonymous: every other vcs dep URL, which
    ``develop`` will clone with no credential.
    """
    if not NAME.match(owner):
        raise LockCredentialError(f"--owner {owner!r} is not a valid owner name")
    url_base = validate_url_base(url_base)
    prefix = f"{url_base}{owner}/"
    names: set[str] = set()
    anonymous: set[str] = set()
    for entry in load_lock_deps(lock_path):
        if not isinstance(entry, dict) or entry.get("coord_kind") != "vcs":
            continue
        # The root entry is the checkout develop runs from; it is never
        # cloned, so it needs no credential.
        if entry.get("path") == ".":
            continue
        url = entry.get("url")
        if not isinstance(url, str) or not url:
            raise LockCredentialError(
                f"lock {lock_path} has a vcs dep without a url: "
                f"{entry.get('name', '<unnamed>')!r}")
        name = repository_name(url, prefix)
        if name is None:
            anonymous.add(url)
        else:
            names.add(name)
    if not names:
        # An empty set is refused rather than passed on: the token action
        # reads an empty `repositories:` as "every repository the
        # installation can reach", the opposite of the scope intended here.
        raise LockCredentialError(
            f"lock {lock_path} yields no repositories under {prefix}; "
            "refusing to mint or render a credential for an empty set")
    return sorted(names), sorted(anonymous)


def header_payload(token: str) -> str:
    """The Basic payload GitHub accepts for an installation token."""
    return base64.b64encode(f"x-access-token:{token}".encode()).decode()


def render_gitconfig(names: list[str], owner: str, token: str,
                     url_base: str = GITHUB_URL_BASE) -> str:
    """One ``http."<url>/".extraHeader`` per repository and spelling."""
    header = f"AUTHORIZATION: basic {header_payload(token)}"
    lines = [
        "# Generated by scripts/ci_lock_source_credentials.py. Holds a",
        "# short-lived installation token; the creating step deletes it.",
    ]
    for name in names:
        for spelling in (name, f"{name}.git"):
            lines.append(f'[http "{url_base}{owner}/{spelling}/"]')
            lines.append(f'\textraHeader = "{header}"')
    return "\n".join(lines) + "\n"


def write_private(path: Path, text: str) -> None:
    """Create ``path`` exclusively with mode 0600 and write ``text``."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as error:
        raise LockCredentialError(
            f"cannot create {path} exclusively: {error.strerror or error}"
        ) from error
    try:
        # The umask can only remove bits from 0600; set it exactly anyway so
        # the mode does not depend on the caller's umask.
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
    except BaseException:
        if fd != -1:
            os.close(fd)
        # Never leave a partially written credential behind.
        try:
            path.unlink()
        except OSError:
            pass
        raise


def report_anonymous(anonymous: list[str], owner: str) -> None:
    for url in anonymous:
        print(f"ci_lock_source_credentials: not under {owner}, will be cloned "
              f"WITHOUT a credential: {url}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Scope a CI git credential to a repro.lock's vcs deps.")
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("repositories", "gitconfig"):
        p = sub.add_parser(command)
        p.add_argument("--lock", required=True, type=Path)
        p.add_argument("--owner", required=True)
        p.add_argument("--url-base", default=GITHUB_URL_BASE)
        if command == "gitconfig":
            p.add_argument("--out", required=True, type=Path)
            p.add_argument("--emit-actions-mask", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.command == "gitconfig":
            # Checked before the lock is read, so a missing token fails the
            # same way whatever state the lock is in.
            token = os.environ.get("GH_TOKEN", "")
            if not token or not TOKEN.match(token):
                raise LockCredentialError(
                    "GH_TOKEN is empty or not a single printable word; "
                    "refusing to render a credential")
        names, anonymous = derive_repositories(args.lock, args.owner,
                                               args.url_base)
        report_anonymous(anonymous, args.owner)
        if args.command == "repositories":
            sys.stdout.write("".join(f"{name}\n" for name in names))
            return 0
        write_private(args.out, render_gitconfig(names, args.owner, token,
                                                 args.url_base))
        if args.emit_actions_mask:
            print(f"::add-mask::{header_payload(token)}")
        print(f"ci_lock_source_credentials: wrote a credential for "
              f"{len(names)} {args.owner} repositories to {args.out}",
              file=sys.stderr)
        return 0
    except LockCredentialError as error:
        print(f"ci_lock_source_credentials: error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

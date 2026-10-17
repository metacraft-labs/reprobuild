"""The CI reconcile step must carry a credential covering the lock's develop set.

WHAT IS UNDER TEST
==================

The ``Test`` job in ``.github/workflows/ci.yml`` provisions CodeTracer's
source siblings by running ``repro develop --all --reset`` against
CodeTracer's committed ``repro.lock``. That step used to run with every git
credential masked, on the premise that whatever the committed lock names is
anonymously cloneable. The spec declines to provide that premise:
``reprobuild-pm/spec/Unified-Locking-And-Hooks.md`` §14.1 says a lock entry's
``visibility`` names the configuration TIER that declared the repo, never who
can read it on its forge, and that the committed lock is the default home of
every develop-set sibling. CodeTracer's lock therefore legitimately names
forge-private repos (``codetracer-launcher`` and four others) marked
``visibility = "public"``, and the anonymous clone died with
``fatal: could not read Username for 'https://github.com': terminal prompts
disabled`` (reprobuild-pm issue
``2026-10-14-ci-reconcile-step-assumes-the-committed-lock-names-only-forge-public-repos``).

The fix is ``scripts/ci_lock_source_credentials.py``: it derives the
repository set from the lock itself -- ignoring ``visibility`` -- so a token
can be minted for exactly that set, and renders a private git config file
that attaches the token to exactly those repositories. These cases pin:

* the DERIVATION, against a fixture lock shaped like CodeTracer's;
* the SCOPE of the rendered credential, by asking real git which URLs it
  authenticates, and then by making real git clone over real HTTP from a
  loopback server that refuses unauthenticated requests;
* the WORKFLOW CONTRACT: the step that runs ``develop --all`` is preceded by
  a token minted for the derived set, and hands it to ``develop`` through
  ``GIT_CONFIG_GLOBAL``. This is the case that fails on the unfixed
  ``ci.yml`` for the reason the issue states.

FIXTURES AND THE ONE STAND-IN, JUSTIFIED
========================================

No mocks of the code under test: the real script runs as a subprocess under
the same ``python3``, and every git interaction is the real ``git`` binary.

The lock files are hand-written TOML fixtures rather than CodeTracer's real
lock, because the suite must not depend on a sibling checkout being present
and at a particular revision; they reproduce the real lock's shape (one
``[lock]`` table whose ``deps`` is an array of inline tables, a root entry at
``path = "."``, ``visibility = "public"`` on a forge-private repo).

The forge is the one stand-in. GitHub cannot be reached from a hermetic test
and a real private repository would need a real credential, so the clone
cases serve bare repositories through ``git http-backend`` -- the smart-HTTP
CGI that ships with git -- from an in-process ``http.server`` on 127.0.0.1,
which answers 401 to any request under the owner prefix that lacks the
expected ``Authorization`` header. That reproduces the observable behaviour
of a private GitHub repository for an anonymous clone (git prints exactly
``could not read Username`` with prompts disabled) and records what arrived
on the wire, so a credential reaching a repository outside the lock is
observed rather than inferred from configuration. The prior art is
``metacraft-github-actions/git-auth/git-http-auth-server.py``, whose header
explains why configuration-only checks (``git config --get-urlmatch``) are
not sufficient on their own: they cannot see a credential that leaks by
another route. Pointing the script at that server needs its ``--url-base``
knob, which the script refuses for anything other than ``https://github.com/``
or a loopback ``http://`` address; one case below pins that refusal.

The workflow contract is checked by a small text parser rather than a YAML
library, because PyYAML is not a declared dependency of the dev shell. It
understands only the block layout ``ci.yml`` is written in, and it fails --
it does not skip -- when it cannot find the step it is meant to check.
"""

from __future__ import annotations

import base64
import hmac
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci_lock_source_credentials.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

OWNER = "metacraft-labs"
# A recognisable fake. It is long and unique enough that finding it in any
# captured stream or file is unambiguous, and it is not a credential anywhere.
FAKE_TOKEN = "ghs_FAKEtestTOKENnotARealCredential0123456789"


def basic_payload(token: str) -> str:
    """The base64 payload of the header GitHub accepts for an App token."""
    return base64.b64encode(f"x-access-token:{token}".encode()).decode()


def lock_text(deps: list[str]) -> str:
    """A lock in the committed ``repro.lock`` shape: inline-table ``deps``."""
    return (
        'schema = "reprobuild.solved-graph-lock.v2"\n\n'
        "[lock]\n"
        'platform = "amd64-linux"\n'
        "packages = []\n"
        "deps = [" + ", ".join(deps) + "]\n"
    )


def dep(name: str, url: str, *, path: str | None = None,
        coord_kind: str = "vcs", visibility: str | None = "public") -> str:
    """One inline-table dep entry, spelled as the engine writes them."""
    fields = [
        f'name = "{name}"',
        f'path = "{path if path is not None else "../" + name}"',
        f'coord_kind = "{coord_kind}"',
        f'url = "{url}"',
        'ref = "agents"',
        'revision = "0123456789abcdef0123456789abcdef01234567"',
    ]
    if visibility is not None:
        fields.append(f'visibility = "{visibility}"')
    return "{ " + ", ".join(fields) + " }"


# The codetracer-shaped fixture. `codetracer-launcher` is forge-private in
# reality and is marked `visibility = "public"`, exactly as in CodeTracer's
# committed lock; `team-tier-repo` carries a non-public tier and
# `no-visibility-repo` none at all, so "the field is ignored" is asserted in
# all three states rather than only the one that happened to break CI.
CODETRACER_SHAPED_DEPS = [
    dep("codetracer", "https://github.com/metacraft-labs/codetracer", path="."),
    dep("isonim", "https://github.com/metacraft-labs/isonim"),
    dep("codetracer-launcher",
        "https://github.com/metacraft-labs/codetracer-launcher"),
    dep("nim-pty", "https://github.com/metacraft-labs/nim-pty.git"),
    dep("nim-acp", "https://github.com/metacraft-labs/nim-acp/"),
    dep("team-tier-repo", "https://github.com/metacraft-labs/team-tier-repo",
        visibility="team"),
    dep("no-visibility-repo",
        "https://github.com/metacraft-labs/no-visibility-repo",
        visibility=None),
    # The same repository reached twice must be listed once.
    dep("isonim-again", "https://github.com/metacraft-labs/isonim.git"),
    dep("direnv-nix-flake-overrides",
        "https://github.com/blocksense-network/direnv-nix-flake-overrides"),
    dep("some-registry-package", "https://example.invalid/pkg",
        coord_kind="registry"),
]
CODETRACER_SHAPED_EXPECTED = [
    "codetracer-launcher",
    "isonim",
    "nim-acp",
    "nim-pty",
    "no-visibility-repo",
    "team-tier-repo",
]


def isolated_git_env(base: Path, global_config: str) -> dict[str, str]:
    """An environment in which git can see no credential but the one under test.

    Mirrors the CI step: global config replaced, system config off, prompts
    off. Everything that could supply a credential by another route
    (``GIT_CONFIG_COUNT`` pairs, askpass helpers, the user's real ``HOME``)
    is removed, so a clone that succeeds did so through ``global_config``.
    """
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("GIT_", "SSH_ASKPASS"))
        and key not in ("GH_TOKEN", "GITHUB_TOKEN")
    }
    home = base / "home"
    home.mkdir(exist_ok=True)
    env.update({
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "GIT_CONFIG_GLOBAL": global_config,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    })
    return env


class ScriptCase(unittest.TestCase):
    """Shared scratch directory and a runner for the real script."""

    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory(prefix="repro-ci-lock-cred-")
        self.addCleanup(self._scratch.cleanup)
        self.base = Path(self._scratch.name)

    def write_lock(self, deps: list[str], name: str = "repro.lock") -> Path:
        path = self.base / name
        path.write_text(lock_text(deps), encoding="utf-8")
        return path

    def run_script(self, *args: str, token: str | None = None,
                   ) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k != "GH_TOKEN"}
        if token is not None:
            env["GH_TOKEN"] = token
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True, text=True, env=env, check=False,
        )


class LockDerivationTests(ScriptCase):
    """``repositories``: which repos the lock's develop set will clone."""

    def test_forge_private_repo_marked_public_is_included(self):
        """The issue's case: `visibility` is the tier, so it must not filter."""
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), CODETRACER_SHAPED_EXPECTED)
        self.assertIn("codetracer-launcher", result.stdout.splitlines())

    def test_root_entry_is_excluded(self):
        """The checkout itself (`path = "."`) is not cloned by develop."""
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotIn("codetracer", result.stdout.splitlines())

    def test_other_owners_are_reported_as_anonymous(self):
        """A dep the credential does not cover is named on stderr, not dropped.

        Today `direnv-nix-flake-overrides` is public, so it clones without a
        credential. The report exists so that a future forge-private repo
        under another owner fails diagnosably rather than with a bare
        `could not read Username`.
        """
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotIn("direnv-nix-flake-overrides", result.stdout)
        self.assertIn(
            "https://github.com/blocksense-network/direnv-nix-flake-overrides",
            result.stderr,
        )
        # Non-vcs coordinates are not git clones and are not reported.
        self.assertNotIn("example.invalid", result.stderr)

    def test_missing_lock_fails_loudly(self):
        result = self.run_script("repositories", "--lock",
                                 str(self.base / "absent.lock"),
                                 "--owner", OWNER)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("absent.lock", result.stderr)

    def test_unparseable_lock_fails_loudly(self):
        lock = self.base / "repro.lock"
        lock.write_text("[lock\ndeps = [", encoding="utf-8")
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("not valid TOML", result.stderr)

    def test_lock_without_deps_table_fails_loudly(self):
        lock = self.base / "repro.lock"
        lock.write_text('schema = "x"\n[lock]\npackages = []\n',
                        encoding="utf-8")
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deps", result.stderr)

    def test_zero_repositories_fails_loudly(self):
        """An empty set would mint an all-repositories token, or none at all.

        `actions/create-github-app-token` treats an empty `repositories:` as
        "every repository the installation can reach", which is the breadth
        this whole step exists to avoid. So an empty derivation is an error.
        """
        lock = self.write_lock([
            dep("codetracer", "https://github.com/metacraft-labs/codetracer",
                path="."),
            dep("elsewhere", "https://github.com/other-owner/elsewhere"),
        ])
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("no repositories", result.stderr)

    def test_url_that_is_not_a_repository_root_is_not_credentialed(self):
        """A deeper path under the owner is not a repo name; report it."""
        lock = self.write_lock([
            dep("isonim", "https://github.com/metacraft-labs/isonim"),
            dep("odd", "https://github.com/metacraft-labs/isonim/tree/x"),
        ])
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["isonim"])
        self.assertIn("https://github.com/metacraft-labs/isonim/tree/x",
                      result.stderr)

    def test_repository_name_that_could_break_the_config_is_refused(self):
        """A name is written into a config subsection; refuse odd characters."""
        lock = self.write_lock([
            dep("bad", 'https://github.com/metacraft-labs/bad\\"name'),
        ])
        result = self.run_script("repositories", "--lock", str(lock),
                                 "--owner", OWNER)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


class GitconfigScopeTests(ScriptCase):
    """``gitconfig``: which URLs real git authenticates with the file."""

    def render(self, deps: list[str]) -> tuple[Path, subprocess.CompletedProcess]:
        lock = self.write_lock(deps)
        out = self.base / "out" / "gitconfig"
        out.parent.mkdir()
        result = self.run_script("gitconfig", "--lock", str(lock),
                                 "--owner", OWNER, "--out", str(out),
                                 token=FAKE_TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        return out, result

    def header_for(self, config: Path, url: str) -> str | None:
        result = subprocess.run(
            ["git", "config", "--get-urlmatch", "http.extraHeader", url],
            capture_output=True, text=True, check=False,
            env=isolated_git_env(self.base, str(config)),
        )
        # 1 is git's "no value matched"; anything else is a real error.
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stdout.strip() if result.returncode == 0 else None

    def test_each_lock_repository_is_authenticated_in_both_spellings(self):
        config, _ = self.render(CODETRACER_SHAPED_DEPS)
        expected = f"AUTHORIZATION: basic {basic_payload(FAKE_TOKEN)}"
        for name in CODETRACER_SHAPED_EXPECTED:
            for spelling in (name, name + ".git"):
                url = f"https://github.com/{OWNER}/{spelling}/info/refs"
                with self.subTest(url=url):
                    self.assertEqual(self.header_for(config, url), expected)

    def test_nothing_outside_the_lock_set_is_authenticated(self):
        """Prefix neighbours, the root, other owners and the host get nothing.

        git matches `http.<url>.*` by slash-delimited path prefix, so a
        subsection ending in `/isonim/` must not match `isonim-tui`; this is
        asserted with `isonim` listed and `isonim-tui` absent, and with a
        hostile-looking `codetracer-launcher-evil` beside a listed
        `codetracer-launcher`.
        """
        config, _ = self.render(CODETRACER_SHAPED_DEPS)
        for url in (
            f"https://github.com/{OWNER}/codetracer-launcher-evil/info/refs",
            f"https://github.com/{OWNER}/isonim-tui/info/refs",
            f"https://github.com/{OWNER}/codetracer/info/refs",
            f"https://github.com/{OWNER}/info/refs",
            "https://github.com/blocksense-network/"
            "direnv-nix-flake-overrides/info/refs",
            "https://github.com/other-owner/isonim/info/refs",
            "https://github.com/",
            f"http://github.com/{OWNER}/isonim/info/refs",
            f"https://gitlab.com/{OWNER}/isonim/info/refs",
        ):
            with self.subTest(url=url):
                self.assertIsNone(self.header_for(config, url))

    @unittest.skipIf(os.name == "nt",
                     "POSIX permission bits do not describe Windows ACLs")
    def test_file_is_private(self):
        config, _ = self.render(CODETRACER_SHAPED_DEPS)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)

    def test_token_never_reaches_stdout_or_stderr(self):
        _, result = self.render(CODETRACER_SHAPED_DEPS)
        for stream in (result.stdout, result.stderr):
            self.assertNotIn(FAKE_TOKEN, stream)
            self.assertNotIn(basic_payload(FAKE_TOKEN), stream)

    def test_actions_mask_is_the_only_thing_printed_when_requested(self):
        """With --emit-actions-mask, stdout carries only the mask command.

        GitHub masks the App token it mints, but not this base64 form of it.
        The workflow asks for the `::add-mask::` command so that anything
        that ever echoes the header is redacted in the job log.
        """
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        out = self.base / "gitconfig"
        result = self.run_script("gitconfig", "--lock", str(lock),
                                 "--owner", OWNER, "--out", str(out),
                                 "--emit-actions-mask", token=FAKE_TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [f"::add-mask::{basic_payload(FAKE_TOKEN)}"])
        self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)

    def test_empty_token_is_refused_and_nothing_is_written(self):
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        out = self.base / "gitconfig"
        for token in (None, "", "two words", "line\nbreak"):
            with self.subTest(token=token):
                result = self.run_script("gitconfig", "--lock", str(lock),
                                         "--owner", OWNER, "--out", str(out),
                                         token=token)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GH_TOKEN", result.stderr)
                self.assertFalse(out.exists())

    def test_existing_output_path_is_refused(self):
        """Creation is exclusive, so a pre-planted file or symlink is not reused."""
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        out = self.base / "gitconfig"
        out.write_text("planted\n", encoding="utf-8")
        result = self.run_script("gitconfig", "--lock", str(lock),
                                 "--owner", OWNER, "--out", str(out),
                                 token=FAKE_TOKEN)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(out.read_text(encoding="utf-8"), "planted\n")

    def test_a_lock_that_yields_nothing_writes_nothing(self):
        lock = self.write_lock([
            dep("elsewhere", "https://github.com/other-owner/elsewhere"),
        ])
        out = self.base / "gitconfig"
        result = self.run_script("gitconfig", "--lock", str(lock),
                                 "--owner", OWNER, "--out", str(out),
                                 token=FAKE_TOKEN)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(out.exists())

    def test_url_base_other_than_github_or_loopback_is_refused(self):
        lock = self.write_lock(CODETRACER_SHAPED_DEPS)
        for base in ("http://github.com/", "https://evil.example/",
                     "http://10.0.0.1:8080/", "http://127.0.0.1/",
                     "http://127.0.0.1:80/x/", "http://localhost.evil:1/"):
            with self.subTest(base=base):
                result = self.run_script("repositories", "--lock", str(lock),
                                         "--owner", OWNER, "--url-base", base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--url-base", result.stderr)


# ---------------------------------------------------------------------------
# A loopback smart-HTTP server that behaves like a private forge.
# ---------------------------------------------------------------------------


def git_http_backend() -> str:
    exec_path = subprocess.run(
        ["git", "--exec-path"], capture_output=True, text=True, check=True,
    ).stdout.strip()
    candidate = os.path.join(exec_path, "git-http-backend")
    if not os.path.exists(candidate):
        raise unittest.SkipTest(
            f"git-http-backend is not shipped with this git ({candidate})")
    return candidate


class PrivateForge:
    """``git http-backend`` behind Basic auth for every path under ``/<owner>/``.

    The journal records the request path and one of ``none`` / ``ok`` /
    ``mismatch`` -- never a header value -- so the test can see whether a
    credential reached a repository without the fixture ever holding a copy
    of it in a log.
    """

    def __init__(self, root: Path, owner: str, token: str):
        self.root = root
        self.prefix = f"/{owner}/"
        self.expected = basic_payload(token).encode()
        self.backend = git_http_backend()
        self.journal: list[tuple[str, str]] = []
        self._lock = threading.Lock()
        forge = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):  # keep test output readable
                pass

            def _serve(self, method: str):
                path, _, query = self.path.partition("?")
                if path.startswith(forge.prefix):
                    supplied = self.headers.get("Authorization")
                    verdict = "none"
                    if supplied is not None:
                        scheme, _, payload = supplied.partition(" ")
                        verdict = (
                            "ok" if scheme.lower() == "basic"
                            and hmac.compare_digest(payload.strip().encode(),
                                                    forge.expected)
                            else "mismatch")
                    with forge._lock:
                        forge.journal.append((path, verdict))
                    if verdict != "ok":
                        self.send_response(401 if verdict == "none" else 403)
                        self.send_header("WWW-Authenticate", 'Basic realm="git"')
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                proc = subprocess.run(
                    [forge.backend], input=body, capture_output=True,
                    check=False,
                    env={
                        "PATH": os.environ.get("PATH", ""),
                        "GIT_PROJECT_ROOT": str(forge.root),
                        "GIT_HTTP_EXPORT_ALL": "1",
                        "REQUEST_METHOD": method,
                        "PATH_INFO": path,
                        "QUERY_STRING": query,
                        "REMOTE_ADDR": "127.0.0.1",
                        "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                        "CONTENT_LENGTH": str(len(body)),
                        "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
                    },
                )
                head, sep, payload = proc.stdout.partition(b"\r\n\r\n")
                if not sep:
                    head, _, payload = proc.stdout.partition(b"\n\n")
                status, headers = 200, []
                for line in head.replace(b"\r\n", b"\n").split(b"\n"):
                    name, _, value = line.partition(b":")
                    if not name:
                        continue
                    name_s = name.strip().decode("latin-1")
                    value_s = value.strip().decode("latin-1")
                    if name_s.lower() == "status":
                        status = int(value_s.split()[0])
                    else:
                        headers.append((name_s, value_s))
                self.send_response(status)
                for name_s, value_s in headers:
                    self.send_header(name_s, value_s)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):  # noqa: N802
                self._serve("GET")

            def do_POST(self):  # noqa: N802
                self._serve("POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)

    @property
    def url_base(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}/"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)

    def verdicts_for(self, repo: str) -> set[str]:
        with self._lock:
            return {
                verdict for path, verdict in self.journal
                if path.startswith(f"{self.prefix}{repo}/")
                or path.startswith(f"{self.prefix}{repo}.git/")
            }


@unittest.skipIf(os.name == "nt",
                 "the loopback forge runs git-http-backend as a POSIX CGI")
class LoopbackCloneTests(ScriptCase):
    """Real ``git clone`` against a forge that refuses anonymous requests."""

    REPOS = ("private-sibling", "codetracer-launcher",
             "codetracer-launcher-evil")

    def setUp(self):
        super().setUp()
        self.forge_root = self.base / "forge"
        seed = self.base / "seed"
        subprocess.run(["git", "init", "-q", "-b", "agents", str(seed)],
                       check=True, env=isolated_git_env(self.base, os.devnull))
        (seed / "README").write_text("seed\n", encoding="utf-8")
        seed_env = isolated_git_env(self.base, os.devnull)
        seed_env.update({
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.invalid",
        })
        subprocess.run(["git", "-C", str(seed), "add", "README"], check=True,
                       env=seed_env)
        subprocess.run(["git", "-C", str(seed), "commit", "-q", "-m", "seed"],
                       check=True, env=seed_env)
        for name in self.REPOS:
            bare = self.forge_root / OWNER / name
            subprocess.run(["git", "clone", "-q", "--bare", str(seed),
                            str(bare)], check=True, env=seed_env)
            # Serve the `<name>.git` spelling from the same repository.
            (self.forge_root / OWNER / f"{name}.git").symlink_to(bare)

    def clone(self, forge: PrivateForge, config: str, spelling: str,
              ) -> subprocess.CompletedProcess:
        dest = self.base / "clones" / f"{spelling}-{len(forge.journal)}"
        return subprocess.run(
            ["git", "clone", "-q", f"{forge.url_base}{OWNER}/{spelling}",
             str(dest)],
            capture_output=True, text=True, check=False,
            env=isolated_git_env(self.base, config),
        )

    def render_for(self, forge: PrivateForge) -> Path:
        lock = self.write_lock([
            dep("root", f"{forge.url_base}{OWNER}/root", path="."),
            dep("private-sibling", f"{forge.url_base}{OWNER}/private-sibling"),
            dep("codetracer-launcher",
                f"{forge.url_base}{OWNER}/codetracer-launcher.git"),
        ])
        out = self.base / "gitconfig"
        result = self.run_script("gitconfig", "--lock", str(lock),
                                 "--owner", OWNER, "--out", str(out),
                                 "--url-base", forge.url_base,
                                 token=FAKE_TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)
        return out

    def test_masked_clone_fails_exactly_as_ci_did(self):
        """The pre-fix configuration, reproduced: no credential, no clone."""
        with PrivateForge(self.forge_root, OWNER, FAKE_TOKEN) as forge:
            result = self.clone(forge, os.devnull, "codetracer-launcher")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("could not read Username", result.stderr)
            self.assertEqual(forge.verdicts_for("codetracer-launcher"),
                             {"none"})

    def test_generated_config_clones_every_lock_repository(self):
        with PrivateForge(self.forge_root, OWNER, FAKE_TOKEN) as forge:
            config = self.render_for(forge)
            for spelling in ("private-sibling", "private-sibling.git",
                             "codetracer-launcher", "codetracer-launcher.git"):
                with self.subTest(spelling=spelling):
                    result = self.clone(forge, str(config), spelling)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)
            self.assertEqual(forge.verdicts_for("private-sibling"), {"ok"})
            self.assertEqual(forge.verdicts_for("codetracer-launcher"), {"ok"})

    def test_credential_does_not_reach_a_repository_outside_the_lock(self):
        """Observed on the wire: the neighbour receives no header at all."""
        with PrivateForge(self.forge_root, OWNER, FAKE_TOKEN) as forge:
            config = self.render_for(forge)
            result = self.clone(forge, str(config), "codetracer-launcher-evil")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(forge.verdicts_for("codetracer-launcher-evil"),
                             {"none"})

    def test_clone_persists_no_credential(self):
        """The token lives in the temp file only, never in the clone's config."""
        with PrivateForge(self.forge_root, OWNER, FAKE_TOKEN) as forge:
            config = self.render_for(forge)
            result = self.clone(forge, str(config), "private-sibling")
            self.assertEqual(result.returncode, 0, result.stderr)
        clones = list((self.base / "clones").iterdir())
        self.assertEqual(len(clones), 1)
        for path in clones[0].joinpath(".git").rglob("*"):
            if path.is_file() and path.suffix not in (".pack", ".idx"):
                data = path.read_bytes()
                self.assertNotIn(FAKE_TOKEN.encode(), data, str(path))
                self.assertNotIn(basic_payload(FAKE_TOKEN).encode(), data,
                                 str(path))


# ---------------------------------------------------------------------------
# The workflow contract.
# ---------------------------------------------------------------------------


class WorkflowStep:
    """One `- ` item of a job's `steps:` list, read from block-style YAML.

    Only what the contract needs: top-level scalar keys, the `env:` and
    `with:` mappings (one level, block scalars joined), and the `run:` body.
    """

    def __init__(self, index: int, lines: list[str], item_indent: int):
        self.index = index
        self.lines = lines
        key_indent = item_indent + 2
        self.fields: dict[str, str] = {}
        self.maps: dict[str, dict[str, str]] = {}
        current_key = None
        block: list[str] = []
        for raw in lines:
            line = raw.rstrip("\n")
            if line[:key_indent].strip() in ("", "-") and len(line) > key_indent \
                    and line[key_indent] not in (" ", "#"):
                if current_key is not None:
                    self._close(current_key, block)
                key, _, value = line[key_indent:].partition(":")
                current_key = key.strip()
                block = [value.strip()]
            elif current_key is not None:
                block.append(line)
        if current_key is not None:
            self._close(current_key, block)

    def _close(self, key: str, block: list[str]):
        head, body = block[0], block[1:]
        if head in ("|", "|-", ">", ">-"):
            self.fields[key] = "\n".join(body)
        elif head == "" and key in ("env", "with"):
            self.maps[key] = self._mapping(body)
        else:
            self.fields[key] = head

    @staticmethod
    def _mapping(body: list[str]) -> dict[str, str]:
        content = [line for line in body
                   if line.strip() and not line.strip().startswith("#")]
        if not content:
            return {}
        indent = len(content[0]) - len(content[0].lstrip())
        result: dict[str, str] = {}
        key = None
        for line in content:
            if len(line) - len(line.lstrip()) == indent:
                key, _, value = line.strip().partition(":")
                value = value.strip()
                result[key] = "" if value in ("|", "|-", ">", ">-") else value
            elif key is not None:
                result[key] = (result[key] + "\n" + line.strip()).strip()
        return {k: v.strip("'\"") for k, v in result.items()}

    @property
    def name(self) -> str:
        return self.fields.get("name", f"<step {self.index}>")


def job_steps(workflow: str, job: str) -> list[WorkflowStep]:
    lines = workflow.splitlines()
    try:
        start = lines.index(f"  {job}:")
    except ValueError:
        raise AssertionError(f"job `{job}` not found in {CI_WORKFLOW}")
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^  \S", lines[i])), len(lines))
    body = lines[start + 1:end]
    steps_at = next(i for i, line in enumerate(body)
                    if line.strip() == "steps:")
    item_indent = None
    steps: list[WorkflowStep] = []
    current: list[str] = []
    for line in body[steps_at + 1:]:
        match = re.match(r"^( *)- ", line)
        if match and (item_indent is None or len(match.group(1)) == item_indent):
            item_indent = len(match.group(1))
            if current:
                steps.append(WorkflowStep(len(steps), current, item_indent))
            current = [line]
        elif current:
            # A comment at or left of the item indent introduces the NEXT
            # step (ci.yml documents each step above its `- name:`), so it
            # is not part of this step's run body.
            stripped = line.lstrip()
            if stripped.startswith("#") and \
                    len(line) - len(stripped) <= item_indent:
                continue
            current.append(line)
    if current:
        steps.append(WorkflowStep(len(steps), current, item_indent))
    return steps


def lock_argument(run: str, after: int = 0) -> str:
    """The ``--lock`` value of the first script call after ``after``.

    Both steps spell it ``"$ct_root/repro.lock"``; ``$ct_root`` is expanded
    from its ``ct_root="$(cd "<dir>" && pwd)"`` assignment in the same run
    body, so the assertion is about WHICH lock is read, not about spelling.
    """
    match = re.compile(r'--lock[ =]"?([^"\s]+)"?').search(run, after)
    if match is None:
        raise AssertionError("no --lock argument in the step's run body")
    value = match.group(1)
    root = re.search(r'ct_root="\$\(cd "([^"]+)" && pwd\)"', run)
    if root is not None:
        value = value.replace("$ct_root", root.group(1))
    return value


STEP_OUTPUT = re.compile(r"^\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.(\w+)\s*\}\}$")


class WorkflowContractTests(unittest.TestCase):
    """The reconcile step's credential, read from ``ci.yml`` itself."""

    @classmethod
    def setUpClass(cls):
        cls.steps = job_steps(CI_WORKFLOW.read_text(encoding="utf-8"), "test")

    def develop_steps(self) -> list[WorkflowStep]:
        found = [s for s in self.steps if "develop --all" in s.fields.get("run", "")]
        self.assertTrue(
            found,
            "no step of the `test` job runs `repro develop --all`; this "
            "contract is about that step and must be updated, not skipped, "
            "if it moved.")
        return found

    def step_by_id(self, step_id: str) -> WorkflowStep:
        for step in self.steps:
            if step.fields.get("id") == step_id:
                return step
        self.fail(f"no step with id `{step_id}` in the `test` job")

    def test_develop_all_carries_a_token_for_the_lock_derived_set(self):
        for step in self.develop_steps():
            env = step.maps.get("env", {})
            token_ref = STEP_OUTPUT.match(env.get("GH_TOKEN", ""))
            self.assertIsNotNone(
                token_ref,
                f"step `{step.name}` runs `repro develop --all`, which clones "
                "every vcs dep of CodeTracer's committed repro.lock. Per "
                "Unified-Locking-And-Hooks.md §14.1 a lock entry's "
                "`visibility` is its configuration tier, not its forge "
                "readability, so that set contains forge-private repos "
                "(codetracer-launcher, ...). The step carries no credential "
                "(env GH_TOKEN from a create-github-app-token step), so the "
                "clone fails with `could not read Username for "
                "'https://github.com': terminal prompts disabled`.")
            token_step = self.step_by_id(token_ref.group(1))
            self.assertEqual(token_ref.group(2), "token")
            self.assertTrue(
                token_step.fields.get("uses", "").startswith(
                    "actions/create-github-app-token@"),
                f"GH_TOKEN of `{step.name}` must come from "
                "actions/create-github-app-token")

            # Minted immediately before: installation tokens expire after an
            # hour, and the job-wide one is minted at job start.
            minted_before = [
                s for s in self.steps[:step.index]
                if s.fields.get("uses", "").startswith(
                    "actions/create-github-app-token@")]
            self.assertIs(
                minted_before[-1], token_step,
                f"the token for `{step.name}` must be the last one minted "
                "before it, so it is fresh when the clones start")

            with_ = token_step.maps.get("with", {})
            self.assertEqual(with_.get("owner"), OWNER)
            self.assertEqual(with_.get("permission-contents"), "read")
            repos_ref = STEP_OUTPUT.match(with_.get("repositories", ""))
            self.assertIsNotNone(
                repos_ref,
                f"`{token_step.name}` must scope the token to the repositories "
                "derived from the lock (a step output), not a hand-kept list "
                "that drifts from the lock, and not the empty list that "
                "means every repository")
            self.assertEqual(repos_ref.group(2), "repositories")
            derive = self.step_by_id(repos_ref.group(1))
            self.assertLess(derive.index, token_step.index)
            derive_run = derive.fields.get("run", "")
            self.assertIn("scripts/ci_lock_source_credentials.py repositories",
                          derive_run)
            self.assertRegex(lock_argument(derive_run),
                             r"/\.\./codetracer/repro\.lock$")
            self.assertIn(f"--owner {OWNER}", derive_run)
            self.assertIn("GITHUB_OUTPUT", derive_run)
            self.assertIn("repositories<<", derive_run)

    def test_develop_all_reads_the_credential_through_git_config_global(self):
        """GIT_CONFIG_GLOBAL, not GIT_CONFIG_COUNT, and only for the call.

        The engine runs its git actions with `scrubbedGitRepositoryEnv()`
        (libs/repro_workspace_vcs/src/git_tool.nim), which drops
        `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_*` / `GIT_CONFIG_VALUE_*`; a
        credential there would never reach `develop`'s clones.
        """
        for step in self.develop_steps():
            env = step.maps.get("env", {})
            run = step.fields.get("run", "")
            self.assertEqual(env.get("GIT_CONFIG_NOSYSTEM"), "1")
            self.assertEqual(env.get("GIT_TERMINAL_PROMPT"), "0")
            self.assertFalse(
                [k for k in env if k.startswith("GIT_CONFIG_KEY_")],
                "GIT_CONFIG_KEY_* is scrubbed by the engine's git actions")
            # The run body legitimately NAMES an `x-access-token:` URL, in
            # the cleanup that removes setup-dev-env's broad rewrite; what
            # must not happen is the step installing one of its own.
            self.assertNotIn("x-access-token:", "\n".join(env.values()),
                             "the token must not be embedded in a URL")

            generate = re.search(
                r"scripts/ci_lock_source_credentials\.py gitconfig\b"
                r"(?:[^\n]*\\\n)*[^\n]*--out[ =](\"?\$[A-Za-z_{}]+\"?)",
                run)
            self.assertIsNotNone(
                generate,
                f"`{step.name}` must render the credential with "
                "`scripts/ci_lock_source_credentials.py gitconfig --out ...`")
            out_var = generate.group(1).strip('"')
            # The SAME lock the token was scoped from.
            self.assertRegex(lock_argument(run, generate.start()),
                             r"/\.\./codetracer/repro\.lock$")
            export = re.search(
                r"export GIT_CONFIG_GLOBAL=\"?" + re.escape(out_var) + r"\"?",
                run)
            self.assertIsNotNone(
                export,
                f"`{step.name}` must point GIT_CONFIG_GLOBAL at {out_var}")
            # The invocation, not a mention of it in a comment.
            develop_call = re.search(r"(?m)^[ \t]*[^#\n]*\bdevelop --all\b",
                                     run)
            self.assertIsNotNone(develop_call)
            develop_at = develop_call.start()
            self.assertLess(generate.start(), export.start())
            self.assertLess(export.start(), develop_at)
            # Scoped to the develop call: the export lives in the subshell
            # that runs it, so the local-config cleanup above keeps the
            # masked /dev/null global config.
            subshell_open = run.rfind("(", 0, export.start())
            self.assertNotEqual(subshell_open, -1)
            self.assertNotIn(")", run[subshell_open:export.start()])
            self.assertEqual(env.get("GIT_CONFIG_GLOBAL"), "/dev/null")
            self.assertRegex(run, r"trap [^\n]*rm -[rf]+")


if __name__ == "__main__":
    unittest.main()

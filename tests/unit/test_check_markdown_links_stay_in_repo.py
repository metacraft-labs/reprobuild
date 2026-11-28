"""scripts/check_markdown_links_stay_in_repo.py refuses links that leave the repo.

The lint is a zero-tolerance gate over tracked Markdown files: a relative link,
reference definition or raw HTML href/src whose target, resolved against the
linking file's directory, escapes the repository root fails the run. These
cases pin what is refused (inline links, link text spanning lines, reference
definitions, also inside block quotes and list items, angle-bracket
destinations, raw HTML attributes, a link after a stray backtick on an
earlier line), what passes (an in-repository ``..`` link, a URL,
an anchor), what is not judged (fenced code, inline code, untracked files),
and that this checkout itself carries no such link.

Each scratch case runs the real script with real python and git in a scratch
git repository that holds a copy of it under scripts/. The scratch repository
stands in for this checkout because the cases need files this checkout must
not carry: links that leave it, and untracked files. Nothing is mocked. The
scratch tree is a handful of files, so every scratch run passes
`--markdown-file-floor 1` except the one case that tests the floor itself. The
last case runs the script against this checkout unchanged.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_markdown_links_stay_in_repo.py"
GIT = shutil.which("git")


class MarkdownLinksStayInRepo(unittest.TestCase):
    def setUp(self):
        # Never a silent pass: without git these cases say nothing.
        self.assertIsNotNone(GIT, "git is not on PATH")
        self.repo = Path(tempfile.mkdtemp(prefix="md-links-in-repo-"))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        self.write("docs/guide/intro.md", "# Intro\n\nSee [the top](../../README.md).\n")
        self.write("README.md", "# Readme\n")
        self.git("add", "-A")

    # -- helpers ----------------------------------------------------------

    def git(self, *args):
        subprocess.run(
            [GIT, "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def track(self, relative, text):
        self.write(relative, text)
        self.git("add", relative)

    def run_gate(self, floor=True):
        extra = ["--markdown-file-floor", "1"] if floor else []
        return subprocess.run(
            [sys.executable, str(self.repo / "scripts" / SCRIPT.name), *extra],
            cwd=self.repo,
            capture_output=True,
            text=True,
        )

    def assert_refused(self, *expected):
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for line in expected:
            self.assertIn(line, result.stderr)
        self.assertIn("rewrite rather than link", result.stderr)
        return result

    def assert_passes(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no relative link leaves the repository", result.stdout)
        return result

    # -- what is refused --------------------------------------------------

    def test_an_in_repository_parent_link_passes(self):
        # The setUp tree: docs/guide/intro.md -> ../../README.md stays inside.
        self.assert_passes()

    def test_an_escaping_inline_link_is_refused(self):
        self.track("docs/a.md", "# A\n\nSee [the plan](../../sibling/plan.md#sec).\n")
        self.assert_refused("docs/a.md:3: ../../sibling/plan.md#sec")

    def test_link_text_spanning_lines_is_refused_at_the_destination_line(self):
        self.track("docs/a.md", "Read\n[the long\nlink text](../../sibling/x.md) now.\n")
        self.assert_refused("docs/a.md:3: ../../sibling/x.md")

    def test_a_reference_definition_is_refused(self):
        self.track("docs/a.md", "See [the plan][p].\n\n[p]: ../../sibling/plan.md\n")
        self.assert_refused("docs/a.md:3: ../../sibling/plan.md")

    def test_an_angle_bracket_destination_is_refused(self):
        self.track("docs/a.md", "See [it](<../../sibling/with space.md>).\n")
        self.assert_refused("docs/a.md:1: ../../sibling/with space.md")

    def test_an_escaping_image_is_refused(self):
        self.track("a.md", "![diagram](../outside.png)\n")
        self.assert_refused("a.md:1: ../outside.png")

    def test_a_reference_definition_in_a_container_block_is_refused(self):
        # CommonMark allows a definition inside a block quote or list item.
        self.track("a.md", "> [p]: ../quoted.md\n\n- [q]: ../listed.md\n")
        self.assert_refused("a.md:1: ../quoted.md", "a.md:3: ../listed.md")

    def test_raw_html_href_and_src_are_refused(self):
        self.track(
            "a.md",
            '<a href="../anchor.md">x</a>\n<img alt=x src=\'../image.png\'>\n'
            '<a href="https://example.invalid/../ok">fine</a>\n',
        )
        result = self.assert_refused("a.md:1: ../anchor.md", "a.md:2: ../image.png")
        self.assertIn("2 relative link(s)", result.stderr)

    def test_an_unmatched_backtick_does_not_hide_the_next_line(self):
        # A stray backtick in one list item or table row must not pair with
        # one on a later line and mask the link between them.
        self.track(
            "a.md",
            "- a stray ` here\n- [x](../list.md) and `code`\n\n"
            "| `a | b |\n|---|---|\n| [y](../table.md) | `c` |\n",
        )
        self.assert_refused("a.md:2: ../list.md", "a.md:6: ../table.md")

    def test_every_finding_is_listed(self):
        self.track("a.md", "[x](../one.md) and [y](../two.md)\n")
        result = self.assert_refused("a.md:1: ../one.md", "a.md:1: ../two.md")
        self.assertIn("2 relative link(s)", result.stderr)

    # -- what passes ------------------------------------------------------

    def test_urls_and_anchors_pass(self):
        self.track(
            "docs/a.md",
            "[web](https://example.invalid/../../x) [mail](mailto:a@example.invalid)\n"
            "[here](#section) [rooted](/docs/a.md) [proto](//example.invalid/x)\n"
            "\n[r]: https://example.invalid/../x\n",
        )
        self.assert_passes()

    # -- what is not judged -----------------------------------------------

    def test_fenced_code_is_ignored(self):
        self.track(
            "docs/a.md",
            "```markdown\n[x](../../sibling/x.md)\n[p]: ../../sibling/p.md\n```\n"
            "~~~~\n[y](../../y.md)\n~~~\n```\n~~~~\n",
        )
        self.assert_passes()

    def test_a_link_after_a_closed_fence_is_judged(self):
        self.track("a.md", "```\n[x](../in-code.md)\n```\n[y](../after.md)\n")
        result = self.assert_refused("a.md:4: ../after.md")
        self.assertNotIn("in-code", result.stderr)

    def test_inline_code_is_ignored(self):
        self.track(
            "a.md",
            "Write `[x](../../sibling/x.md)` or ``[y](../y.md) with ` inside``.\n",
        )
        self.assert_passes()

    def test_untracked_files_are_not_judged(self):
        self.write("scratch.md", "[x](../../sibling/x.md)\n")
        self.assert_passes()

    def test_vendored_trees_are_not_judged(self):
        self.track("references/up/README.md", "[x](../../../x.md)\n")
        self.track("libs/a/vendor/README.md", "[x](../../../../x.md)\n")
        self.assert_passes()

    # -- refusals that keep a bad scan from passing -----------------------

    def test_a_corpus_below_the_floor_is_refused(self):
        result = self.run_gate(floor=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("floor", result.stderr)

    # -- this checkout ----------------------------------------------------

    def test_this_repository_has_no_link_that_leaves_it(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=ROOT, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

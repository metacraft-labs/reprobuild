"""scripts/check_markdown_link_targets.py refuses relative links to nowhere.

A relative Markdown link names a path inside this repository. Four of them in
tracked documents named design documents that were never in this repository:
they had been copied here with links that were relative to the planning
documents they were written beside, so they were dead for every reader. The
gate refuses any relative link whose target is not tracked.

The first case runs the real script against this checkout: it is the
regression test for those four links, and for any others of the same kind.
The rest pin the gate's own rules. Each runs the real script with real git in
a scratch git repository holding a copy of it under scripts/. The scratch
repository stands in for this checkout because the cases need files this
checkout must not carry: dead links, untracked targets, a symlinked document.
Nothing is mocked.
"""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_markdown_link_targets.py"
SHARED = ROOT / "scripts" / "check_markdown_links_stay_in_repo.py"
GIT = shutil.which("git")


def run_script(script: Path, cwd: Path):
    return subprocess.run(
        [sys.executable, "-I", str(script)],
        cwd=cwd,
        capture_output=True,
        text=True,
    )


class ThisCheckout(unittest.TestCase):
    def test_every_relative_link_in_this_repository_names_a_tracked_path(self):
        self.assertIsNotNone(GIT, "git is not on PATH")
        result = run_script(SCRIPT, ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK", result.stdout)


class MarkdownLinkTargetGate(unittest.TestCase):
    def setUp(self):
        # Never a silent pass: without git these cases say nothing.
        self.assertIsNotNone(GIT, "git is not on PATH")
        self.repo = Path(tempfile.mkdtemp(prefix="markdown-link-gate-"))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        # The gate takes its Markdown parsing from its sibling, so the copy
        # needs the sibling beside it, as in this checkout.
        shutil.copy2(SHARED, self.repo / "scripts" / SHARED.name)
        (self.repo / "docs" / "guide").mkdir(parents=True)
        (self.repo / "docs" / "guide" / "page.md").write_text("# Page\n")
        (self.repo / "docs" / "README.md").write_text("# Docs\n")
        self.git("add", "-A")

    def git(self, *args):
        subprocess.run(
            [GIT, "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )

    def write_tracked(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.git("add", relative)

    def run_gate(self):
        return run_script(self.repo / "scripts" / SCRIPT.name, self.repo)

    def test_links_that_resolve_or_are_not_paths_pass(self):
        self.write_tracked(
            "docs/index.md",
            "\n".join(
                [
                    "[file](guide/page.md) [dot](./README.md)",
                    "[anchor](guide/page.md#page) [query](README.md?plain=1)",
                    "[directory](guide/) [up](../scripts/check_markdown_link_targets.py)",
                    "[root](/docs/guide/page.md) [self](#docs) [angle](<guide/page.md>)",
                    "[web](https://example.com/x.md) [mail](mailto:a@example.invalid)",
                    "[escaped](guide%2Fpage.md) ![img](guide/page.md)",
                    # Outside the repository: a sibling checkout, not judged here.
                    "[sibling](../../other-repo/spec.md)",
                    "[ref]: guide/page.md",
                    "",
                ]
            ),
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK", result.stdout)

    def test_an_inline_link_to_an_absent_file_is_refused_with_its_line(self):
        # The shape of the defect: a target "next to" the document that this
        # repository does not hold.
        self.write_tracked(
            "docs/runtime.md",
            "# Runtime\n\nSee [the design](../Third-Party-Design.md).\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/runtime.md:3: ../Third-Party-Design.md", result.stderr)

    def test_a_reference_definition_to_an_absent_file_is_refused(self):
        self.write_tracked(
            "recipes/cache/TAXONOMY.md",
            "Per [the spec][spec].\n\n[spec]: ./Binary-Caches.md\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("recipes/cache/TAXONOMY.md:3: ./Binary-Caches.md", result.stderr)

    def test_a_link_that_stops_inside_the_repository_is_judged(self):
        # One "../" short of a sibling checkout: it resolves to a directory
        # inside this repository that does not exist, so it is refused, not
        # waved through as a sibling link.
        self.write_tracked(
            "tools/harness/README.md",
            "[plan](../../old-specs/Plan.milestones.org)\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tools/harness/README.md:1:", result.stderr)

    def test_an_untracked_target_does_not_satisfy_a_link(self):
        # The document is committed; the file it names is not, so a reader of
        # the repository does not have it.
        (self.repo / "docs" / "draft.md").write_text("# Draft\n")
        self.write_tracked("docs/index.md", "[draft](draft.md)\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/index.md:1: draft.md", result.stderr)

    def test_links_inside_code_are_not_links(self):
        self.write_tracked(
            "docs/index.md",
            "\n".join(
                [
                    "Write `[text](missing.md)` to link.",
                    "```markdown",
                    "[example](missing.md)",
                    "[label]: missing.md",
                    "```",
                    "~~~~",
                    "```",
                    "[still code](missing.md)",
                    "~~~~",
                    "",
                ]
            ),
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Positive control: the same link outside code is refused, so the case
        # above passes because of the code rule, not a parser that sees nothing.
        self.write_tracked("docs/other.md", "[example](missing.md)\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/other.md:1: missing.md", result.stderr)

    def test_a_link_whose_text_wraps_a_line_is_judged(self):
        # Link text may wrap inside a paragraph; the link is still a link.
        self.write_tracked(
            "docs/index.md",
            "# Index\n\nSee [the high-level\ndesign](../Absent-Design.md) too.\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/index.md:4: ../Absent-Design.md", result.stderr)

    def test_an_image_nested_in_a_link_is_judged(self):
        # A badge: the image's own destination is a repository path even when
        # the link around it goes to the web.
        self.write_tracked(
            "docs/index.md",
            "[![badge](assets/badge.svg)](https://example.com/)\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/index.md:1: assets/badge.svg", result.stderr)

    def test_a_raw_html_link_to_an_absent_file_is_refused(self):
        # GitHub renders <a href> and <img src> as links; the shared parser
        # finds them, so this gate judges them too.
        self.write_tracked(
            "docs/index.md",
            '<a href="guide/page.md">ok</a> <img src="missing.png">\n',
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/index.md:1: missing.png", result.stderr)
        self.assertNotIn("guide/page.md", result.stderr)

    def test_a_footnote_definition_is_not_a_reference_definition(self):
        # "[^1]: text" is GFM footnote prose; its first word is not a target.
        # Positive control in the same file: a real reference definition to an
        # absent file is still refused, so the pass is the footnote rule's.
        self.write_tracked(
            "docs/index.md",
            "Claim.[^1]\n\n[^1]: Measured in [the log](gone.md).\n\n[spec]: absent.md\n",
        )
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/index.md:5: absent.md", result.stderr)
        # A link inside the footnote's text is still a link.
        self.assertIn("docs/index.md:3: gone.md", result.stderr)
        self.assertNotIn("Measured", result.stderr)

    @unittest.skipIf(os.name == "nt", "a git symlink checks out as a file on Windows")
    def test_a_symlinked_document_is_judged_at_its_target(self):
        # docs/guide/page.md is tracked at the root-relative path the root
        # document uses, so its link resolves there and not from .agents/.
        self.write_tracked("AGENTS.md", "[guide](docs/guide/page.md)\n")
        (self.repo / ".agents").mkdir()
        os.symlink("../AGENTS.md", self.repo / ".agents" / "AGENTS.md")
        self.git("add", ".agents/AGENTS.md")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

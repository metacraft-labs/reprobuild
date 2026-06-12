#!/usr/bin/env python3
"""Unit tests for the assertion DSL (no backend required)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent))

from lib.assertions import (  # noqa: E402
    AssertionRecord,
    BootAssertion,
    BootAssertionError,
    BootTimeoutError,
    HarnessSession,
    LineBuffer,
)


class FakeSession(HarnessSession):
    """In-memory session backed by a scripted feed of chunks."""

    def __init__(self, chunks: list[str]) -> None:
        self.buf = LineBuffer()
        self._chunks = list(chunks)
        self.sent: list[str] = []

    def _drain(self) -> None:
        if self._chunks:
            self.buf.feed(self._chunks.pop(0))

    def expect_line(self, pattern: str, timeout_s: float = 60.0):
        return self.buf.expect(pattern, timeout_s, more=self._drain, poll_s=0.0)

    def send(self, text: str) -> None:
        self.sent.append(text)

    def capture_until(self, pattern: str, timeout_s: float = 60.0) -> str:
        return self.buf.capture_until(pattern, timeout_s, more=self._drain, poll_s=0.0)

    def close(self) -> None:
        pass


class TestLineBuffer(unittest.TestCase):
    def test_expect_matches_on_already_buffered(self):
        b = LineBuffer()
        b.feed("hello world\nlogin: \n")
        m = b.expect(r"login:", timeout_s=1.0)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(0), "login:")

    def test_expect_advances_cursor(self):
        b = LineBuffer()
        b.feed("login: \nfoo\nlogin: \n")
        m1 = b.expect(r"login:", timeout_s=1.0)
        m2 = b.expect(r"login:", timeout_s=1.0)
        self.assertGreater(m2.start(), m1.end() - 1)

    def test_expect_timeout(self):
        b = LineBuffer()
        b.feed("nothing of interest\n")
        with self.assertRaises(BootTimeoutError):
            b.expect(r"never-matches", timeout_s=0.05)

    def test_expect_uses_more_callback(self):
        b = LineBuffer()
        chunks = ["partial", " line\n", "login: alpine\n"]
        def more() -> None:
            if chunks:
                b.feed(chunks.pop(0))
        m = b.expect(r"login: \w+", timeout_s=1.0, more=more, poll_s=0.0)
        self.assertEqual(m.group(0), "login: alpine")

    def test_capture_until_returns_consumed_text(self):
        b = LineBuffer()
        b.feed("foo\nbar\nbaz\n")
        s = b.capture_until(r"bar", timeout_s=1.0)
        self.assertIn("foo", s)
        self.assertIn("bar", s)
        self.assertNotIn("baz", s)


class TestSessionDSL(unittest.TestCase):
    def test_run_assertions_pass(self):
        sess = FakeSession([
            "Welcome to Alpine\nlogin: \n",
            "alpine:~# \n",
            "3.20.0\nalpine:~# \n",
        ])
        assertions = [
            BootAssertion(expect_line=r"login:", timeout_s=1.0,
                          send_after_match="root\n", description="reach login prompt"),
            BootAssertion(expect_line=r"\w+:~#", timeout_s=1.0,
                          send_after_match="cat /etc/alpine-release\n",
                          description="root prompt"),
            BootAssertion(expect_line=r"^3\.\d+\.\d+", timeout_s=1.0,
                          description="alpine release line"),
        ]
        records = sess.run_assertions(assertions)
        self.assertEqual(len(records), 3)
        self.assertTrue(all(r.matched for r in records))
        # The send_after_match strings landed.
        self.assertEqual(sess.sent[0], "root\n")
        self.assertEqual(sess.sent[1], "cat /etc/alpine-release\n")

    def test_run_assertions_stops_on_first_failure(self):
        sess = FakeSession(["login: \n"])
        assertions = [
            BootAssertion(expect_line=r"login:", timeout_s=0.2),
            BootAssertion(expect_line=r"this-never-appears", timeout_s=0.1),
            BootAssertion(expect_line=r"unreachable", timeout_s=0.1),
        ]
        records = sess.run_assertions(assertions)
        self.assertEqual(len(records), 2)  # halt after the 2nd's failure
        self.assertTrue(records[0].matched)
        self.assertFalse(records[1].matched)

    def test_expect_within(self):
        sess = FakeSession(["mark1\n", "mark2\n"])
        m = sess.expect_within("mark1", "mark2", timeout_s=1.0)
        self.assertEqual(m.group(0), "mark2")


class TestRecordSerialization(unittest.TestCase):
    def test_record_dict_includes_assertion_fields(self):
        a = BootAssertion(expect_line=r"login:", timeout_s=5.0, description="x")
        r = AssertionRecord(assertion=a, matched=True, elapsed_s=0.42, matched_text="login: ")
        d = r.to_dict()
        self.assertEqual(d["expect_line"], r"login:")
        self.assertEqual(d["timeout_s"], 5.0)
        self.assertTrue(d["matched"])
        self.assertEqual(d["matched_text"], "login: ")
        self.assertEqual(d["description"], "x")


if __name__ == "__main__":
    unittest.main(verbosity=2)

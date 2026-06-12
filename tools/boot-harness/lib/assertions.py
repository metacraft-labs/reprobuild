"""Backend-agnostic assertion DSL for boot-harness runs.

The ``HarnessSession`` interface is implemented by each backend driver
(hyperv, wsl2, qemu). Test scripts and the JSON expect-file consumer
both drive sessions through this interface so the assertions are
written once.

Patterns are Python regular expressions (``re``); ``expect_line``
returns a ``re.Match`` so the caller can extract groups.
"""

from __future__ import annotations

import re
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Iterable, Optional


class BootAssertionError(Exception):
    """Raised when an assertion fails (pattern not seen, timeout, etc.)."""


class BootTimeoutError(BootAssertionError):
    """Raised specifically on a wall-clock timeout."""


@dataclass
class BootAssertion:
    """Declarative single-step assertion.

    These are also the rows that get serialized into the per-run JSON
    under ``assertions: [...]`` so the run record stays self-describing.
    """

    expect_line: Optional[str] = None
    timeout_s: float = 60.0
    expect_within: Optional[str] = None
    send_after_match: Optional[str] = None
    description: str = ""

    def to_dict(self) -> dict:
        return {
            "expect_line": self.expect_line,
            "timeout_s": self.timeout_s,
            "expect_within": self.expect_within,
            "send_after_match": self.send_after_match,
            "description": self.description,
        }


@dataclass
class AssertionRecord:
    """Outcome of running one ``BootAssertion`` against a session."""

    assertion: BootAssertion
    matched: bool
    elapsed_s: float
    matched_text: str = ""
    error: str = ""

    def to_dict(self) -> dict:
        d = self.assertion.to_dict()
        d.update(
            {
                "matched": self.matched,
                "elapsed_s": self.elapsed_s,
                "matched_text": self.matched_text,
                "error": self.error,
            }
        )
        return d


class HarnessSession(ABC):
    """Abstract session driven by the three backends.

    Implementations buffer the serial/stdout stream and let ``expect_line``
    scan forward over newly-arrived bytes. ``send`` writes a string to
    the guest's stdin (or serial input). ``capture_until`` returns the
    raw bytes consumed up to and including the matching line.
    """

    @abstractmethod
    def expect_line(self, pattern: str, timeout_s: float = 60.0) -> re.Match[str]:
        """Block until a line matches ``pattern`` or timeout expires."""

    @abstractmethod
    def send(self, text: str) -> None:
        """Send ``text`` as guest input. Caller terminates with ``\\n``."""

    @abstractmethod
    def capture_until(self, pattern: str, timeout_s: float = 60.0) -> str:
        """Return the captured text from the most recent expect cursor
        up to and including the line that matches ``pattern``."""

    @abstractmethod
    def close(self) -> None:
        """Tear down the underlying VM/distro/process."""

    # Convenience helpers built on top of the abstract primitives.
    def expect_within(self, marker: str, then: str, timeout_s: float = 60.0) -> re.Match[str]:
        """Two-step: marker must appear first, then ``then``. Single budget."""
        deadline = time.monotonic() + timeout_s
        self.expect_line(marker, timeout_s=max(0.1, deadline - time.monotonic()))
        return self.expect_line(then, timeout_s=max(0.1, deadline - time.monotonic()))

    def run_assertions(self, assertions: Iterable[BootAssertion]) -> list[AssertionRecord]:
        """Run a sequence of ``BootAssertion``s, halting on first failure."""
        records: list[AssertionRecord] = []
        for a in assertions:
            t0 = time.monotonic()
            try:
                if a.expect_within is not None and a.expect_line is not None:
                    m = self.expect_within(a.expect_within, a.expect_line, a.timeout_s)
                elif a.expect_line is not None:
                    m = self.expect_line(a.expect_line, a.timeout_s)
                else:
                    raise BootAssertionError(
                        "BootAssertion needs at least expect_line set"
                    )
                rec = AssertionRecord(
                    assertion=a,
                    matched=True,
                    elapsed_s=time.monotonic() - t0,
                    matched_text=m.group(0),
                )
                if a.send_after_match is not None:
                    self.send(a.send_after_match)
                records.append(rec)
            except BootAssertionError as exc:
                records.append(
                    AssertionRecord(
                        assertion=a,
                        matched=False,
                        elapsed_s=time.monotonic() - t0,
                        error=str(exc),
                    )
                )
                break
        return records


# Helpers shared by concrete backend buffer implementations.

@dataclass
class LineBuffer:
    """Ring-buffer-ish accumulator of serial output.

    Concrete backends push bytes via ``feed``; ``expect`` scans forward
    from ``cursor`` for a regex match. Once matched, ``cursor`` advances
    past the matched line so subsequent ``expect`` calls don't re-match.
    """

    text: str = ""
    cursor: int = 0
    history: list[str] = field(default_factory=list)

    def feed(self, chunk: str) -> None:
        if not chunk:
            return
        self.text += chunk

    def expect(self, pattern: str, timeout_s: float, *, poll_s: float = 0.05,
               more: "Optional[callable]" = None) -> re.Match[str]:
        """Scan forward for ``pattern``; if not present, invoke ``more()``
        to feed additional bytes, repeating until timeout."""
        rx = re.compile(pattern, re.MULTILINE)
        deadline = time.monotonic() + timeout_s
        while True:
            m = rx.search(self.text, self.cursor)
            if m is not None:
                self.history.append(self.text[self.cursor : m.end()])
                self.cursor = m.end()
                return m
            if time.monotonic() >= deadline:
                tail = self.text[self.cursor :][-400:]
                raise BootTimeoutError(
                    f"timeout waiting for /{pattern}/ after {timeout_s:.1f}s; "
                    f"tail={tail!r}"
                )
            if more is not None:
                more()
            time.sleep(poll_s)

    def capture_until(self, pattern: str, timeout_s: float, *, poll_s: float = 0.05,
                      more: "Optional[callable]" = None) -> str:
        m = self.expect(pattern, timeout_s, poll_s=poll_s, more=more)
        # cursor was set to m.end() inside expect(); return what just got captured
        return self.history[-1]

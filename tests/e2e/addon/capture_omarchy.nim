## Capture the pinned Omarchy release into the Arch test bed's content
## cache and write its SHA-256 list (``arch_testbed.OmarchyCaptureManifest``).
##
## Run by hand, in the dev shell, when the pin set changes
## (``just addon-omarchy-capture``); the list it writes is committed, and a
## build of the Omarchy guest then reads only the list and the cache. It
## installs the pinned ISO in a guest of its own (no network), reads which
## repositories the installed pacman names and which packages it has, and
## fetches each repository's database and every package file pacman
## resolves against them from Omarchy's servers, each checked against its
## database's SHA-256 before it enters the cache. Not a test: nothing here
## passes or fails a gate.

import std/os

import ./addon_testbed
import ./arch_testbed

when isMainModule:
  let entries = captureOmarchy(OmarchyCaptureManifest)
  echo "captured ", entries.len, " files; list written to ",
    OmarchyCaptureManifest
  discard cacheDir()

import std/[os, strutils, unittest]

suite "app entrypoint manifest":
  test "all manifest paths exist":
    for line in lines("apps/entrypoints.txt"):
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#"):
        continue
      let parts = stripped.splitWhitespace()
      check parts.len == 2
      check fileExists(parts[1])

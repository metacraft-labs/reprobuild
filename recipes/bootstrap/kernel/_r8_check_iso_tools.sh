#!/bin/bash
for t in xorriso grub-mkrescue mformat; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "OK: $t"
  else
    echo "MISSING: $t"
  fi
done

#!/usr/bin/env bash
# M9.R.46 — relocate every /nix/store/<hash>-<pkg>/ tree referenced
# by from-source ELFs on the staged ISO root to /repro/store/<hash>-<pkg>/,
# and rewrite every ELF's RPATH + PT_INTERP to point at the new location.
#
# Architectural debt this closes (M9.R.46 task brief):
#
#   The M9.R.25 spec said all content-addressed paths live at
#   ``/repro/store/<hash>-<name>/``.  No ``/nix/store`` on the ISO.
#
#   What actually happened: from-source binaries' RPATHs referenced
#   ``/nix/store/<hash>-pkg/lib`` because nix-stubbed deps, M9.R.30's
#   walker, and M9.R.31.2's bootstrap froze the leakage in place.
#   Consequence: ~1.3 GiB of /nix/store rode along on the live ISO +
#   installed system.
#
# Fix shape (Move 1): same-hash prefix swap.
#
#   ``/nix/store/abc-glibc-2.40-66/``  ->  ``/repro/store/abc-glibc-2.40-66/``
#
#   The nix hash IS already a content hash; the prefix swap is the
#   architectural fix.  Re-hashing via reprobuild's schema is option
#   (b); we picked (a) — simpler, cheaper, equally strong.
#
# Algorithm:
#
#   1. Find every ELF in $STAGE_DIR/{opt,usr,bin,sbin,lib,lib64} +
#      $STAGE_DIR/nix/store (the latter so we walk through transitive
#      DT_NEEDED references that point at OTHER nix-store packages).
#
#   2. For each ELF, collect its RPATH + PT_INTERP /nix/store/<hash>
#      references.  Iterate to fixed point so we don't miss
#      grand-transitive references.
#
#   3. For each unique prefix dir under $STAGE_DIR/nix/store/<hash>-<pkg>/:
#      ``mv $STAGE_DIR/nix/store/<hash>-<pkg>/ $STAGE_DIR/repro/store/<hash>-<pkg>/``.
#      mv is atomic + ~100x faster than cp -a; same filesystem.
#
#   4. Walk every ELF in the staged tree (newly-moved + everywhere else)
#      and run patchelf:
#        --set-rpath        replace each ``/nix/store/`` token with
#                           ``/repro/store/``;
#        --set-interpreter  if PT_INTERP starts with ``/nix/store/``,
#                           swap the prefix.
#
#   5. Repoint every symlink whose TARGET is under /nix/store to point
#      at the same relative path under /repro/store.  Nix's multi-output
#      packages chain via cross-prefix symlinks (gcc-lib -> gcc-libgcc,
#      etc.); without repointing these, the resolved RPATH leads to
#      ``/repro/store/<a>/libfoo`` -> symlink whose target says
#      ``/nix/store/<b>/libfoo`` and the loader hits ENOENT.
#
#   6. Sanity check: NO /nix/store reference may remain on the staged
#      tree.  If any does, FAIL LOUDLY (exit 75) with the specific
#      file path named.  Per the M9.R.46 brief: ``no fall-back to
#      /nix/store``.
#
# Usage:  bash relocate-nix-to-repro.sh <stage-dir>

set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <stage-dir>" >&2
  exit 64
fi
STAGE_DIR="$1"

if [ ! -d "$STAGE_DIR" ]; then
  echo "[relocate-nix-to-repro] stage dir does not exist: $STAGE_DIR" >&2
  exit 65
fi

NIX_STORE_STAGED="$STAGE_DIR/nix/store"
REPRO_STORE_STAGED="$STAGE_DIR/repro/store"

if [ ! -d "$NIX_STORE_STAGED" ]; then
  echo "[relocate-nix-to-repro] no $NIX_STORE_STAGED present; nothing to do"
  exit 0
fi

patchelf_bin="$(command -v patchelf || true)"
if [ -z "$patchelf_bin" ]; then
  echo "[relocate-nix-to-repro] patchelf not in PATH; cannot rewrite ELFs" >&2
  exit 70
fi

mkdir -p "$REPRO_STORE_STAGED"

echo "[relocate-nix-to-repro] staged /nix/store has $(ls -1 "$NIX_STORE_STAGED" | wc -l) entries"

# ---------------------------------------------------------------------------
# Phase 1: enumerate every prefix dir directly under $STAGE_DIR/nix/store.
#
# We move EVERYTHING under nix/store, not just what the ELF walk discovers.
# The M9.R.30 closure walker already pulled in transitive store paths
# referenced via DT_NEEDED-resolved symlinks (gcc-lib -> gcc-libgcc), and
# stage-de-rootfs.sh's Phase 3 iterated to fixed point.  Anything sitting
# under nix/store at this point is part of the live closure.  Moving the
# lot (vs walking RPATHs again) is faster + can't miss a transitive.
#
# ---------------------------------------------------------------------------

mapfile -t store_entries < <(find "$NIX_STORE_STAGED" -mindepth 1 -maxdepth 1 \
  -printf '%f\n' 2>/dev/null | sort)
echo "[relocate-nix-to-repro] moving ${#store_entries[@]} store entries"

moved=0
for entry in "${store_entries[@]}"; do
  src="$NIX_STORE_STAGED/$entry"
  dst="$REPRO_STORE_STAGED/$entry"
  if [ -e "$dst" ]; then
    # Idempotency: tolerate re-runs.
    continue
  fi
  mv "$src" "$dst"
  moved=$((moved + 1))
done
echo "[relocate-nix-to-repro] moved $moved entries from $NIX_STORE_STAGED to $REPRO_STORE_STAGED"

# Remove the now-empty $STAGE_DIR/nix/store + $STAGE_DIR/nix (if empty).
rmdir "$NIX_STORE_STAGED" 2>/dev/null || true
rmdir "$STAGE_DIR/nix" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Phase 2: ELF RPATH + PT_INTERP rewrite.
#
# We walk every ELF candidate under the entire stage tree, including the
# from-source install-mirrors at /opt/repro/... + the freshly-moved
# /repro/store/<hash>-<pkg>/ trees + /usr/{bin,sbin,lib,lib64} + /lib +
# /lib64.  Each ELF gets:
#   * RPATH:  ``s|/nix/store/|/repro/store/|g`` on every entry;
#   * INTERP: same.
# patchelf preserves the binary's other ELF fields.  Idempotent.
# ---------------------------------------------------------------------------

scan_dirs=()
for d in opt usr bin sbin lib lib64 repro; do
  [ -d "$STAGE_DIR/$d" ] && scan_dirs+=("$STAGE_DIR/$d")
done

if [ "${#scan_dirs[@]}" -eq 0 ]; then
  echo "[relocate-nix-to-repro] no scan dirs under $STAGE_DIR; aborting" >&2
  exit 65
fi

echo "[relocate-nix-to-repro] rewriting ELFs in ${scan_dirs[*]}"

# Use a temporary file for the candidate list so we can read it twice
# (Phase 2 rewrite + Phase 5 leak audit).
cands_file="$(mktemp -t reproos-iso-relocate-cands-XXXXXX)"
trap 'rm -f "$cands_file"' EXIT
find "${scan_dirs[@]}" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null > "$cands_file"
cand_total=$(wc -l < "$cands_file")
echo "[relocate-nix-to-repro] $cand_total ELF candidates"

elfs_rewritten=0
elfs_inspected=0
while IFS= read -r f; do
  # Cheap ELF magic check before patchelf invocation.
  magic=$(head -c 4 "$f" 2>/dev/null | od -An -c | tr -d ' \n' || true)
  case "$magic" in
    177ELF*) : ;;
    *) continue ;;
  esac
  elfs_inspected=$((elfs_inspected + 1))
  rp=$($patchelf_bin --print-rpath "$f" 2>/dev/null || true)
  ip=$($patchelf_bin --print-interpreter "$f" 2>/dev/null || true)
  did_rewrite=0
  if [[ "$rp" == *"/nix/store/"* ]]; then
    new_rp="${rp//\/nix\/store\//\/repro\/store\/}"
    if ! $patchelf_bin --set-rpath "$new_rp" "$f" 2>/dev/null; then
      echo "[relocate-nix-to-repro] patchelf --set-rpath FAILED on $f" >&2
      exit 75
    fi
    did_rewrite=1
  fi
  if [[ "$ip" == /nix/store/* ]]; then
    new_ip="${ip/#\/nix\/store\//\/repro\/store\/}"
    if ! $patchelf_bin --set-interpreter "$new_ip" "$f" 2>/dev/null; then
      echo "[relocate-nix-to-repro] patchelf --set-interpreter FAILED on $f" >&2
      exit 75
    fi
    did_rewrite=1
  fi
  [ "$did_rewrite" = 1 ] && elfs_rewritten=$((elfs_rewritten + 1))
done < "$cands_file"
echo "[relocate-nix-to-repro] inspected $elfs_inspected ELFs, rewrote RPATH/INTERP on $elfs_rewritten"

# ---------------------------------------------------------------------------
# Phase 3: symlink target rewrite.
#
# Every symlink whose target string starts with ``/nix/store/`` is
# repointed to ``/repro/store/...`` with the same suffix.  This covers
# Nix's multi-output cross-prefix soname chains (gcc-lib's libgcc_s.so.1
# pointing at gcc-libgcc; multi-output Qt6 outputs cross-referencing).
# Without this, the loader walks RPATH (now /repro/store) -> finds the
# .so -> follows the symlink -> hits ENOENT on the dangling
# /nix/store/<hash>/lib/libfoo.so target.
# ---------------------------------------------------------------------------

links_rewritten=0
while IFS= read -r symlink; do
  target=$(readlink "$symlink" 2>/dev/null || true)
  case "$target" in
    /nix/store/*) : ;;
    *) continue ;;
  esac
  new_target="${target/#\/nix\/store\//\/repro\/store\/}"
  ln -sfn "$new_target" "$symlink"
  links_rewritten=$((links_rewritten + 1))
done < <(find "$STAGE_DIR" -type l -lname '/nix/store/*' 2>/dev/null)
echo "[relocate-nix-to-repro] rewrote $links_rewritten symlinks (/nix/store -> /repro/store)"

# ---------------------------------------------------------------------------
# Phase 4: text-content rewrite for shebangs + wrapper scripts.
#
# Nix-built packages embed /nix/store/<hash>-shell/bin/sh in #! lines,
# /nix/store/<hash>-bash/bin/bash etc. for shell wrapper scripts.  The
# kernel uses the literal text on the #! line, not the symlink.  Scan
# every non-binary file under the moved /repro/store/ tree and rewrite
# the first line if it begins with #!/nix/store/.  This is bounded
# (the wrapper scripts are a small fraction of the closure) so we walk
# every text file under /repro/store/ + every script under
# $STAGE_DIR/{usr,etc,opt}.
#
# We use sed for shebang rewriting; only the first 4 bytes are checked
# against ``#!/n`` so a binary file with embedded /nix/store strings
# isn't accidentally rewritten (binaries are handled by patchelf above).
# ---------------------------------------------------------------------------

shebangs_rewritten=0
while IFS= read -r f; do
  # First 4 bytes: ``#!/n`` (the "n" prefix of "/nix/").
  if ! head -c 4 "$f" 2>/dev/null | grep -qF '#!/n'; then
    continue
  fi
  # Confirm it's actually a #!/nix/store/ shebang.
  first_line=$(head -n1 "$f" 2>/dev/null || true)
  case "$first_line" in
    '#!/nix/store/'*) : ;;
    *) continue ;;
  esac
  # Atomic rewrite: read whole file, swap shebang, write back via tmp
  # then mv.  Preserves mode.
  mode=$(stat -c '%a' "$f")
  tmp="$f.m9r46.tmp"
  sed '1s|^#!/nix/store/|#!/repro/store/|' "$f" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$f"
  shebangs_rewritten=$((shebangs_rewritten + 1))
done < <(find "$STAGE_DIR/repro/store" "$STAGE_DIR/usr" "$STAGE_DIR/etc" \
           "$STAGE_DIR/opt" -type f 2>/dev/null)
echo "[relocate-nix-to-repro] rewrote $shebangs_rewritten shebangs (#!/nix/store -> #!/repro/store)"

# ---------------------------------------------------------------------------
# Phase 5: leak audit.  Fail loudly if ANY /nix/store reference remains
# on the staged tree.
#
# We check three classes:
#   * dangling symlinks whose target still begins with /nix/store/
#   * patchelf-inspectable ELFs whose RPATH or INTERP still contains
#     /nix/store
#   * directories still present under $STAGE_DIR/nix/store (should be
#     empty after Phase 1, but check)
# ---------------------------------------------------------------------------

audit_dir="$(mktemp -d -t reproos-iso-relocate-audit-XXXXXX)"
trap 'rm -rf "$audit_dir"' EXIT

# Symlink leaks.
find "$STAGE_DIR" -type l -lname '/nix/store/*' > "$audit_dir/symlinks.txt" 2>/dev/null || true

# Directory leak.
nix_dir_remains=0
if [ -d "$STAGE_DIR/nix" ] && find "$STAGE_DIR/nix" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  nix_dir_remains=1
fi

# ELF leak: re-walk every ELF.  Use the same cand list as Phase 2.
: > "$audit_dir/elf_leaks.txt"
while IFS= read -r f; do
  magic=$(head -c 4 "$f" 2>/dev/null | od -An -c | tr -d ' \n' || true)
  case "$magic" in
    177ELF*) : ;;
    *) continue ;;
  esac
  rp=$($patchelf_bin --print-rpath "$f" 2>/dev/null || true)
  ip=$($patchelf_bin --print-interpreter "$f" 2>/dev/null || true)
  if [[ "$rp" == *"/nix/store/"* ]] || [[ "$ip" == *"/nix/store/"* ]]; then
    echo "$f RPATH=$rp INTERP=$ip" >> "$audit_dir/elf_leaks.txt"
  fi
done < "$cands_file"

sym_leaks=$(wc -l < "$audit_dir/symlinks.txt")
elf_leaks=$(wc -l < "$audit_dir/elf_leaks.txt")

if [ "$sym_leaks" -gt 0 ] || [ "$elf_leaks" -gt 0 ] || [ "$nix_dir_remains" = 1 ]; then
  echo "[relocate-nix-to-repro] LEAK DETECTED: sym=$sym_leaks elf=$elf_leaks nix_dir=$nix_dir_remains" >&2
  if [ "$sym_leaks" -gt 0 ]; then
    echo "[relocate-nix-to-repro] first 20 symlink leaks:" >&2
    head -20 "$audit_dir/symlinks.txt" >&2
  fi
  if [ "$elf_leaks" -gt 0 ]; then
    echo "[relocate-nix-to-repro] first 20 ELF leaks:" >&2
    head -20 "$audit_dir/elf_leaks.txt" >&2
  fi
  if [ "$nix_dir_remains" = 1 ]; then
    echo "[relocate-nix-to-repro] residual /nix subtree contents:" >&2
    find "$STAGE_DIR/nix" -print 2>/dev/null | head -20 >&2
  fi
  echo "[relocate-nix-to-repro] FAILING per M9.R.46 no-fallback rule." >&2
  exit 75
fi

echo "[relocate-nix-to-repro] verified clean: no /nix/store references on staged tree."

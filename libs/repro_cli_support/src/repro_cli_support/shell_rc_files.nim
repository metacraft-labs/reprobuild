## The rc and profile files `repro hooks` writes managed blocks into, and the
## guard every such write goes through.
##
## A shell rc file is often not the user's to edit in place: on a host whose
## home directory is managed by Home Manager or a dotfiles tool, `~/.bashrc`
## is a symlink into the Nix store, read-only, and replacing it with a regular
## file would silently detach it from the configuration that produces it. So
## the writers (the native shell hooks and shell completion) resolve the path
## they are about to edit here first, and refuse a Nix-store or read-only
## target with the remedy, instead of writing.

import std/os
from std/strutils import replace, startsWith, contains

from repro_core/paths import extendedPath
import repro_core/link_target

proc containsNixStoreSegment*(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized.startsWith("/nix/store/") or normalized.contains("/nix/store/")

proc absoluteSymlinkTarget(linkPath: string): string =
  let rawTarget = readSymlinkTarget(extendedPath(linkPath))
  if rawTarget.isAbsolute:
    os.normalizedPath(rawTarget)
  else:
    os.normalizedPath(parentDir(linkPath) / rawTarget)

proc inNixStore(path, root: string): bool =
  ## Whether writing `path` would write into the Nix store. Below a test root
  ## (`--system-root`) a path mirrors a system path (`<root>/nix/store/...`
  ## for a PowerShell installed by Nix) without being in the store, so only
  ## the root itself decides.
  if root.len > 0 and path.startsWith(root):
    root.containsNixStoreSegment()
  else:
    path.containsNixStoreSegment()

proc rcFileWritePath*(rcPath: string; root = ""): string =
  ## Return the file to edit for a shell rc managed block. Refuses Nix-managed
  ## read-only symlinks instead of replacing the symlink with a regular file.
  ## `root` is a test root the path may lie under (`--system-root`): a path
  ## below it is in the Nix store only when the root is.
  let expandedRc = extendedPath(rcPath)
  if symlinkExists(expandedRc):
    let target = absoluteSymlinkTarget(rcPath)
    if target.inNixStore(root):
      raise newException(ValueError,
        "refusing to write shell rc file " & rcPath &
          ": it is a Nix-managed symlink into the Nix store (" & target &
          "). Edit the source file in your dotfiles/home-manager " &
          "configuration and rebuild with home-switch.")
    if fileExists(extendedPath(target)):
      let permissions = getFilePermissions(extendedPath(target))
      if fpUserWrite notin permissions:
        raise newException(ValueError,
          "refusing to write shell rc file " & rcPath &
            ": it points at a read-only file (" & target &
            "). Edit the owning source file instead.")
    return target
  if rcPath.inNixStore(root):
    raise newException(ValueError,
      "refusing to write shell rc file in the Nix store: " & rcPath &
        ". Edit the source file in your dotfiles/home-manager configuration " &
        "and rebuild with home-switch.")
  if fileExists(expandedRc):
    let permissions = getFilePermissions(expandedRc)
    if fpUserWrite notin permissions:
      raise newException(ValueError,
        "refusing to write read-only shell rc file " & rcPath &
          ". Edit the owning source file instead.")
  rcPath

import std/os

proc enterDaemonRequestDirectory*(workingDir: string): string =
  ## Return the directory to restore, if it still has a name. A daemon may
  ## outlive the temporary project directory from which it was started.
  try:
    result = getCurrentDir()
  except OSError:
    if workingDir.len == 0:
      raise
  if workingDir.len > 0:
    setCurrentDir(workingDir)

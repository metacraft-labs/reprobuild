## Threat-model control C6: never write through a symbolic link while
## materializing untrusted entries under a directory.
##
## Shared by every extractor of untrusted archives: the binary cache client's
## `rbcarc` extraction (`repro_binary_cache_client/in_process`), the build
## action apply path that copies substituted bytes into a working directory,
## and the Nimble source fetch's tar extraction (`repro_nimble_fetch`). One
## rule in the lowest library they all see keeps them from drifting.

import std/[os, strutils]

const ExtractMutation {.strdefine: "reproAddonMutation".} = ""
  ## Only a falsifying test build of the static ReproOS add-on binary sets
  ## this (``-d:reproAddonMutation=agent-extract-follows-links``); see
  ## ``repro_addon/mutations``. Empty in every product build.

proc refuseWriteThroughSymlink*(outDir, rel: string) =
  ## Raise unless writing the entry ``rel`` under ``outDir`` stays inside
  ## ``outDir``.
  ##
  ## Rejecting absolute paths and ``..`` components (done by the caller) only
  ## constrains the entry's *text*. Archives also carry symbolic links, and
  ## every primitive an extractor uses (``createDir``, ``writeFile``,
  ## ``createSymlink`` into a parent) follows a link already on the path. An
  ## archive holding ``d -> /etc`` and then ``d/cron.d/job`` would therefore
  ## write ``/etc/cron.d/job``; one holding ``f -> /etc/passwd`` and then a
  ## file ``f`` would overwrite ``/etc/passwd``. Prefixes are materialised by
  ## privileged applies, so either is a write anywhere as root.
  ##
  ## The rule: no component of the entry's path that already exists may be a
  ## symbolic link, the entry itself included. Links the archive creates are
  ## still extracted -- real prefixes carry ``libfoo.so -> libfoo.so.1`` --
  ## but nothing is ever written *through* one. The extraction directory is
  ## private to the extracting process, so nothing else can add a link
  ## between this check and the write.
  when ExtractMutation == "agent-extract-follows-links":
    # Falsifying build of the ReproOS add-on gate
    # `e2e_addon_hostile_archive_cannot_escape_staging`: the check is gone.
    return
  var cur = outDir
  for part in rel.split('/'):
    cur = cur / part
    if symlinkExists(cur):
      raise newException(IOError,
        "rejected entry written through a symbolic link: " & rel &
        " (" & cur & " is a link)")

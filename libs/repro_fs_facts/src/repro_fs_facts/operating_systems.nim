## The operating-system fact table — Platform-And-Filesystem-Facts **F1**.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       §F1 "The fact tables".
##
## The second axis. A property belongs here when it is the OS that
## decides it — whether creating a symlink needs a privilege, how long a
## command line may be, what a path separator is — and in
## ``filesystems.nim`` when the filesystem decides it. A host is a
## *pair*, and the two are not interchangeable: "we are on Windows" says
## nothing about whether the store volume offers reflink, and "this is
## ReFS" says nothing about whether this process may create a symlink.
##
## Membership rule, from the milestone: cover what policy ALREADY
## branches on with ``when defined(...)``, and do not speculate. Every
## fact below names the concrete thing one or more of those branches is
## standing in for.
##
## The branching is pervasive rather than incidental, which is the point
## of the rule — counted across ``libs/`` on 2026-08-24: 574
## ``when defined(windows)``, 138 ``linux``, 87 ``posix``, 69
## ``macosx``. Those figures are a dated measurement of one subtree, not
## a repository-wide invariant (the whole checkout was 801 / 188 / 186 /
## 169 on the same day), and nothing checks them; treat them as scale,
## never as a fact in the sense this library defines.

import ./fact

type
  OsId* = enum
    osWindows
    osLinux
    osMacos

  OsFacts* = object
    id*: OsId
    names*: seq[string]
      ## Values Nim's ``hostOS`` may take for this OS.

    pathSeparator*: Fact[string]
    pathListSeparator*: Fact[string]
      ## The character that separates entries of ``$PATH`` — ``;`` on
      ## Windows, ``:`` elsewhere. Load-bearing wherever the engine
      ## composes an environment for a spawned action.
    executableSuffix*: Fact[string]

    pathLookupIsCaseSensitive*: Fact[Ternary]
      ## Note this is an OS fact distinct from the filesystem's
      ## ``caseSensitivity``: Windows applies case-insensitive matching
      ## in the object manager regardless of what NTFS could do, and
      ## macOS's answer is whatever the mounted volume was formatted as.

    defaultMaxPathChars*: Fact[Quantity]
      ## The longest path the OS's ordinary file API accepts WITHOUT an
      ## opt-in. On Windows this is ``MAX_PATH`` = 260 and the opt-in is
      ## the ``\\?\`` prefix — which is exactly what
      ## ``repro_core/paths.extendedPath`` exists to apply, and why this
      ## is an OS fact rather than an NTFS one.
    longPathPrefix*: Fact[string]
      ## The prefix that lifts ``defaultMaxPathChars``; empty where none
      ## is needed.

    symlinkCreationIsPrivileged*: Fact[Ternary]
    maxCommandLineBytes*: Fact[Quantity]

    hardlinkApi*: Fact[string]
    reflinkApi*: Fact[string]
      ## The call that performs a COW clone on this OS. Which
      ## FILESYSTEMS answer it is the other table's business; that split
      ## is the point — issuing the Windows FSCTL against NTFS is a
      ## known-failing call the constants can already rule out.

    honoursPosixModeBits*: Fact[Ternary]
      ## Whether the OS applies POSIX mode bits at all. The CAS
      ## campaign's ``applyPermissions`` block is POSIX-only for exactly
      ## this reason, and Local-CAS-Hardlink-Materialization M3 made the
      ## pairing normative.
    hasOTmpfile*: Fact[Ternary]
      ## ``O_TMPFILE`` — an unnamed file that can be linked into place
      ## once its contents are final. The milestone names it as the type
      ## case for an OS-axis fact.

const
  ObsSeparator* =
    "read the platform's own separator constant (Nim's DirSep / PathSep) " &
    "and confirm a path built with the other separator does not resolve"
  ObsExeSuffix* =
    "read Nim's ExeExt and confirm an executable built by this repository " &
    "carries it"
  ObsOsCase* =
    "create a file under one case and look it up under the other on a " &
    "filesystem whose own case sensitivity the filesystem table declares"
  ObsMaxPath* =
    "create a path longer than the declared limit without the opt-in " &
    "prefix and confirm it is refused, then create the same path WITH " &
    "the prefix and confirm it succeeds"
  ObsLongPrefix* =
    "create a path longer than defaultMaxPathChars using the prefix and " &
    "confirm it succeeds"
  ObsSymlinkPriv* =
    "attempt to create a symlink as the current user and read whether it " &
    "is refused for want of a privilege"
  ObsHardlinkApi* =
    "call the named API and confirm the inode's link count rises"
  ObsReflinkApi* =
    "call the named API against a filesystem the filesystem table says " &
    "implements it, and confirm the destination holds the source bytes"
  ObsModeBits* =
    "chmod a file and read the mode back"
  ObsOTmpfile* =
    "open a directory with O_TMPFILE|O_RDWR and confirm it does not fail " &
    "EOPNOTSUPP/EINVAL"

const
  # TWO pages, not one, and the split is the correction. The 260 half
  # is on "Naming Files, Paths, and Namespaces"; the 32,767 half is
  # NOT — that page states no extended figure anywhere, and an earlier
  # draft attributed one to it. The figure is on "Maximum Path Length
  # Limitation", which also immediately qualifies it. Same shape as the
  # CiExfatSpec §7.4 -> §7.4.9 correction: cite the page that carries
  # the sentence the claim rests on.
  CiWinNaming =
    "Microsoft, \"Naming Files, Paths, and Namespaces\" " &
    "(learn.microsoft.com/windows/win32/fileio/naming-a-file)"
  CiWinMaxPath260 =
    CiWinNaming & ": \"In editions of Windows before Windows 10 version " &
    "1607, the maximum length for a path is MAX_PATH, which is defined " &
    "as 260 characters\". That is the ONLY path length on this page; " &
    "its \\\\?\\ section says the prefix \"tells the Windows APIs to " &
    "disable all string parsing\" so a caller \"can exceed the MAX_PATH " &
    "limits that are otherwise enforced by the Windows APIs\", and gives " &
    "the raised limit no number"
  CiWinMaxPath =
    "Microsoft, \"Maximum Path Length Limitation\" (learn.microsoft.com/" &
    "windows/win32/fileio/maximum-file-path-limitation): Unicode " &
    "versions \"permit an extended-length path for a maximum total path " &
    "length of 32,767 characters\", and \"The maximum path of 32,767 " &
    "characters is approximate, because the '\\\\?\\' prefix may be " &
    "expanded to a longer string by the system at run time, and this " &
    "expansion applies to the total length\""
  CiWinCmdLine =
    "Microsoft, CreateProcessW reference, lpCommandLine: \"The maximum " &
    "length of this string is 32,767 characters, including the Unicode " &
    "terminating null character.\""
  # NOTE the citation this does NOT make. The conceptual page "Creating
  # Symbolic Links" no longer mentions privileges at all — it is now
  # about absolute versus relative link resolution — so citing it for a
  # privilege claim would be citing a page that does not say it. The two
  # pages below do.
  CiWinSymlink =
    "Microsoft, \"Privilege Constants\": SE_CREATE_SYMBOLIC_LINK_NAME, " &
    "TEXT(\"SeCreateSymbolicLinkPrivilege\") — \"Required to create a " &
    "symbolic link. User Right: Create symbolic links.\"; and " &
    "CreateSymbolicLinkW's dwFlags table: " &
    "SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE (0x2) \"Specify this " &
    "flag to allow creation of symbolic links when the process is not " &
    "elevated. Developer Mode must first be enabled on the machine " &
    "before this option will function.\""
  CiWinCase =
    "Microsoft, \"Case sensitivity\" (learn.microsoft.com/windows/wsl/" &
    "case-sensitivity): the Windows object manager matches paths without " &
    "regard to case; per-directory case sensitivity is opt-in"
  CiWinAcl =
    "Microsoft, \"File Security and Access Rights\": Windows authorises " &
    "with ACLs; there are no POSIX mode bits for the OS to honour"
  CiPosixPaths =
    "POSIX.1-2017 <limits.h> (PATH_MAX, NAME_MAX) and pathconf()"
  CiLinuxExec =
    "execve(2) man page: since Linux 2.6.23 the total argv+envp size is " &
    "bounded by RLIMIT_STACK/4 and each single argument by " &
    "MAX_ARG_STRLEN (131072)"
  CiLinuxOTmpfile =
    "open(2) man page: O_TMPFILE, available since Linux 3.11, supported " &
    "by ext2/3/4, XFS, Btrfs, F2FS, ubifs and tmpfs (not by every " &
    "filesystem, which is why this is an OS fact with a filesystem " &
    "caveat)"
  CiLinuxSymlink =
    "symlink(2) man page: no privilege is required; the protected_symlinks " &
    "sysctl restricts FOLLOWING symlinks, never creating them"
  CiMacExec =
    "Apple, execve(2)/sysctl kern.argmax: ARG_MAX is 1 MiB (1048576) on " &
    "macOS"
  CiMacCase =
    "Apple, \"About Apple File System\": case sensitivity is a property " &
    "of the mounted VOLUME, so the OS has no single answer"
  CiClonefileOs =
    "Apple, clonefile(2) man page"
  CiPosixLinkOs =
    "POSIX.1-2017 link()"
  CiWinLinkOs =
    "Microsoft, CreateHardLinkW reference"
  CiWinRefsOs =
    "Microsoft, \"Block cloning on ReFS\" (FSCTL_DUPLICATE_EXTENTS_TO_FILE)"
  CiPosixMode =
    "POSIX.1-2017 chmod() and <sys/stat.h> file mode bits"

const OsTable*: array[OsId, OsFacts] = [
  osWindows: OsFacts(
    id: osWindows,
    names: @["windows"],
    pathSeparator: fact("\\", CiWinNaming & ": \"Use a backslash (\\) to " &
                        "separate the components of a path\"", pvVendorDoc,
                        obQuery, ObsSeparator),
    pathListSeparator: fact(";",
      "Microsoft, \"Environment Variables\": PATH entries are separated " &
      "by semicolons", pvVendorDoc, obQuery, ObsSeparator),
    executableSuffix: fact(".exe", CiWinNaming, pvVendorDoc, obQuery,
                           ObsExeSuffix),
    pathLookupIsCaseSensitive: fact(tnNo, CiWinCase, pvVendorDoc,
                                    obOperation, ObsOsCase),
    defaultMaxPathChars: fact(exactly(260), CiWinMaxPath260, pvVendorDoc,
                              obOperation, ObsMaxPath),
    longPathPrefix: fact("\\\\?\\", CiWinMaxPath260 & "; " & CiWinMaxPath &
      ". This is the prefix repro_core/paths.extendedPath applies",
      pvVendorDoc, obOperation, ObsLongPrefix),
    # `varies`, not `yes`, and the difference is the point: Developer
    # Mode flips it, so a policy that hard-coded "yes" would refuse to
    # attempt a symlink that would have worked.
    symlinkCreationIsPrivileged: fact(tnVaries, CiWinSymlink, pvVendorDoc,
                                      obOperation, ObsSymlinkPriv),
    maxCommandLineBytes: fact(exactly(32767), CiWinCmdLine, pvVendorDoc,
                              obConsequence,
      "spawn a process with a command line of exactly the declared " &
      "length and one character more; the marker is obConsequence " &
      "because the refusal surfaces as a generic CreateProcess failure " &
      "rather than a distinguishable 'too long' error"),
    hardlinkApi: fact("CreateHardLinkW", CiWinLinkOs, pvVendorDoc,
                      obOperation, ObsHardlinkApi),
    reflinkApi: fact("FSCTL_DUPLICATE_EXTENTS_TO_FILE", CiWinRefsOs,
                     pvVendorDoc, obOperation, ObsReflinkApi),
    honoursPosixModeBits: fact(tnNo, CiWinAcl, pvVendorDoc, obOperation,
                               ObsModeBits),
    hasOTmpfile: fact(tnNo,
      "O_TMPFILE is a Linux open(2) flag; the Win32 near-equivalent, " &
      "FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE, is a " &
      "different thing — it cannot be linked into place afterwards",
      pvVendorDoc, obOperation, ObsOTmpfile)),

  osLinux: OsFacts(
    id: osLinux,
    names: @["linux"],
    pathSeparator: fact("/", CiPosixPaths, pvStandard, obQuery,
                        ObsSeparator),
    pathListSeparator: fact(":",
      "POSIX.1-2017 §8.3 Other Environment Variables: PATH is a " &
      "colon-separated list", pvStandard, obQuery, ObsSeparator),
    executableSuffix: fact("", CiPosixPaths, pvStandard, obQuery,
                           ObsExeSuffix),
    pathLookupIsCaseSensitive: fact(tnYes,
      CiPosixPaths & "; the VFS compares names byte-wise unless the " &
      "filesystem opts into casefolding", pvStandard, obOperation,
      ObsOsCase),
    defaultMaxPathChars: fact(exactly(4096),
      CiPosixPaths & "; Linux PATH_MAX is 4096 including the terminating " &
      "null", pvStandard, obOperation, ObsMaxPath),
    longPathPrefix: fact("",
      "Linux has no long-path opt-in prefix: PATH_MAX is enforced per " &
      "call, and a path longer than it is reachable only by walking it " &
      "in pieces (openat(2) from a directory fd)", pvStandard, obNone,
      "not observable: there is no prefix to apply, so there is nothing " &
      "for a test to exercise. The absence is what is declared."),
    symlinkCreationIsPrivileged: fact(tnNo, CiLinuxSymlink, pvStandard,
                                      obOperation, ObsSymlinkPriv),
    # Genuinely a range: it depends on RLIMIT_STACK, which a caller can
    # change. A single number would be wrong on any host that raised or
    # lowered the stack limit.
    maxCommandLineBytes: fact(varyingQuantity(), CiLinuxExec, pvStandard,
                              obConsequence,
      "read `getconf ARG_MAX` or spawn with progressively longer " &
      "command lines until E2BIG; either measures THIS host's " &
      "RLIMIT_STACK, not Linux's"),
    hardlinkApi: fact("link(2)", CiPosixLinkOs, pvStandard, obOperation,
                      ObsHardlinkApi),
    reflinkApi: fact("ioctl(FICLONE)",
      "Linux ioctl_ficlonerange(2) man page", pvStandard, obOperation,
      ObsReflinkApi),
    honoursPosixModeBits: fact(tnYes, CiPosixMode, pvStandard, obOperation,
                               ObsModeBits),
    hasOTmpfile: fact(tnYes, CiLinuxOTmpfile, pvStandard, obOperation,
                      ObsOTmpfile)),

  osMacos: OsFacts(
    id: osMacos,
    names: @["macosx"],
    pathSeparator: fact("/", CiPosixPaths, pvStandard, obQuery,
                        ObsSeparator),
    pathListSeparator: fact(":",
      "POSIX.1-2017 §8.3 Other Environment Variables", pvStandard, obQuery,
      ObsSeparator),
    executableSuffix: fact("", CiPosixPaths, pvStandard, obQuery,
                           ObsExeSuffix),
    # The OS has no single answer here, and saying `varies` is what
    # stops a caller assuming the POSIX default on a Mac.
    pathLookupIsCaseSensitive: fact(tnVaries, CiMacCase, pvVendorDoc,
                                    obOperation, ObsOsCase),
    defaultMaxPathChars: fact(exactly(1024),
      CiPosixPaths & "; macOS PATH_MAX is 1024", pvStandard, obOperation,
      ObsMaxPath),
    longPathPrefix: fact("",
      "macOS has no long-path opt-in prefix", pvStandard, obNone,
      "not observable: there is no prefix to apply. The absence is what " &
      "is declared."),
    symlinkCreationIsPrivileged: fact(tnNo,
      "Apple, symlink(2) man page: no privilege is required", pvVendorDoc,
      obOperation, ObsSymlinkPriv),
    maxCommandLineBytes: fact(exactly(1_048_576), CiMacExec, pvVendorDoc,
                              obConsequence,
      "read `sysctl kern.argmax`, or spawn with progressively longer " &
      "command lines until E2BIG"),
    hardlinkApi: fact("link(2)", CiPosixLinkOs, pvStandard, obOperation,
                      ObsHardlinkApi),
    reflinkApi: fact("clonefile(2)", CiClonefileOs, pvVendorDoc,
                     obOperation, ObsReflinkApi),
    honoursPosixModeBits: fact(tnYes, CiPosixMode, pvStandard, obOperation,
                               ObsModeBits),
    hasOTmpfile: fact(tnNo,
      "O_TMPFILE is Linux-specific; Apple's open(2) does not define it",
      pvVendorDoc, obOperation, ObsOTmpfile)),
]

func osFacts*(id: OsId): OsFacts =
  OsTable[id]

func osIdForName*(name: string): tuple[found: bool; id: OsId] =
  ## Map a ``hostOS``-style string to a table entry. As with the
  ## filesystem table, ``found = false`` is reportable rather than a
  ## silent fallback — a host OS with no entry is a gap, and F2 says so.
  for id in OsId:
    for candidate in OsTable[id].names:
      if candidate == name:
        return (true, id)
  (false, osLinux)

# ``HostOsId`` — the entry describing the OS this binary was compiled
# for. Resolved at compile time from the same ``when defined(...)`` the
# rest of the repository uses, so the fact table and the code it
# describes cannot disagree about which OS this is. A platform with no
# entry is a COMPILE ERROR rather than a silent default: adding the OS
# to the table is the smallest honest change, and a default would be a
# wrong fact.
const HostOsId*: OsId =
  when defined(windows): osWindows
  elif defined(macosx): osMacos
  elif defined(linux): osLinux
  else:
    {.error: "repro_fs_facts has no OS-table entry for this platform; " &
             "add one to libs/repro_fs_facts/src/repro_fs_facts/" &
             "operating_systems.nim rather than defaulting".}

func hostOsFacts*(): OsFacts =
  ## The declared facts for the OS this binary runs on.
  OsTable[HostOsId]

const HostHonoursPosixModeBits* =
  OsTable[HostOsId].honoursPosixModeBits.value == tnYes
  ## Whether this platform applies POSIX mode bits at all.
  ##
  ## Not a new fact — a compile-time READING of ``honoursPosixModeBits``,
  ## provided because it is the one OS fact a ``when`` needs to branch on
  ## and a `when` cannot be given a reason in its own line. Every
  ## ``when not defined(windows)`` that really meant "does chmod mean
  ## anything here?" should say this instead, which is what
  ## Platform-And-Filesystem-Facts F3 asks of a consumer: the branch
  ## names the property it depends on, so that a fourth OS is a table row
  ## rather than a search for every negated ``defined(windows)`` in the
  ## repository.
  ##
  ## It is deliberately a ``const`` rather than a runtime read: nothing
  ## about it can change while the process runs, and the branches it
  ## replaces were compile-time too, so no code that was elided before
  ## starts being compiled now.

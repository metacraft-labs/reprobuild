## The filesystem fact table — Platform-And-Filesystem-Facts **F1**.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       §F1 "The fact tables".
##
## One entry per filesystem, because "what can this filesystem do?" is an
## axis independent of "what can this OS do?" — a host is a *pair*, and
## conflating the two is how ``when defined(windows)`` ends up standing in
## for a question about NTFS.
##
## Every value here is a declared fact in the sense ``fact.nim`` defines:
## it carries the document that states it and the observation that would
## contradict it. ``libs/repro_fs_facts/tests/t_fs_facts_conformance.nim``
## (F2) drives those observations against whatever filesystems the host
## actually offers and fails loudly, naming both values, when a constant
## and reality disagree.
##
## **Adding an entry.** Add the enum member, add one `FilesystemFacts`
## literal to `FilesystemTable`, and list the strings the OS reports for
## it in `names`. The conformance suite picks it up with no further
## change; a fact whose observability is `obOperation` will then be
## driven for real the first time the suite meets that filesystem.
## Values you cannot source MUST be `tnUnknown` / `unknownQuantity()`
## with `pvUnestablished` — never a plausible guess.
##
## **Deciding NOT to add an entry** is also a recorded decision, and F4
## gives it a table of its own: `UnenteredFilesystems` at the bottom of
## this file names a filesystem the table deliberately does not describe,
## says why, and says what adding a row would take. Use it when the
## honest row cannot be written — never as a place to park a filesystem
## nobody has looked at, and never as a way to alias one filesystem onto
## a neighbouring row.

import ./fact

type
  FilesystemId* = enum
    ## Filesystems this table knows. Absence from this enum is not a
    ## claim that a filesystem is exotic — it is the gap F4 exists to
    ## make visible, and F2 reports a host filesystem with no entry
    ## rather than silently falling back.
    fsNtfs
    fsRefs
    fsFat32
    fsExfat
    fsExt4
    fsXfs
    fsBtrfs
    fsZfs
    fsApfs
    fsHfsPlus
    fsTmpfs
    fsNfs
    fsSmb
    fsOverlayfs

  CloneOperation* = enum
    ## The syscall/ioctl that produces a copy-on-write clone. Reflink is
    ## an *operation*, not a filesystem property, which is why the name
    ## of the operation is itself a fact: a caller that knows the
    ## filesystem still has to know which call to issue.
    clNone              ## no clone primitive reaches this filesystem.
    clFiclone           ## Linux ``ioctl(FICLONE)`` / ``FICLONERANGE``.
    clClonefile         ## macOS ``clonefile(2)``.
    clDuplicateExtents  ## Windows ``FSCTL_DUPLICATE_EXTENTS_TO_FILE``.
    clVaries            ## depends on the backing store or the server.
    clUnknown

  CaseSensitivity* = enum
    ## What a path lookup does with case.
    caSensitive     ## ``A`` and ``a`` are two different names.
    caInsensitive   ## ``A`` and ``a`` name the same file.
    caConfigurable  ## set at format or mount time; neither answer is
                    ## the filesystem's property.
    caUnknown

  FilesystemFacts* = object
    ## Every fact F1 requires for one filesystem. The grouping mirrors
    ## the milestone's own list so a reader can check coverage against
    ## it directly.
    id*: FilesystemId
    names*: seq[string]
      ## The strings an OS reports for this filesystem, lowercased:
      ## Windows ``GetVolumeInformationW``'s filesystem name, Linux's
      ## ``/proc/mounts`` type, macOS ``statfs.f_fstypename``. This is
      ## the ONLY use of a filesystem-type string in this library, and
      ## it is a table lookup — never a capability answer. See
      ## ``detect.nim``.

    # -- Linking ------------------------------------------------------
    hardlinks*: Fact[Ternary]
      ## Can a file have a second name on this filesystem at all?
    maxNamesPerFile*: Fact[Quantity]
      ## Maximum number of directory entries naming one file, COUNTING
      ## THE FIRST. Stated that way because the two conventions differ
      ## by one and the CAS campaign lost time to it: NTFS's cap is
      ## 1024 total names, which is 1023 further links after the first.
    hardlinksToDirectories*: Fact[Ternary]
      ## Can an unprivileged caller create a second name for a
      ## DIRECTORY? (Distinct from whether the on-disk format could
      ## represent one.)
    oneDeviceIsOneLinkDomain*: Fact[Ternary]
      ## Does sharing a device imply that ``link()`` will succeed? This
      ## is the fact Btrfs falsifies — subvolumes carry distinct
      ## ``st_dev`` and ``link()`` across them fails ``EXDEV`` on a
      ## single device. A ``tnNo`` here is the table telling policy that
      ## same-device is necessary but not sufficient and that only the
      ## probe can settle a specific pair.

    # -- Cloning ------------------------------------------------------
    reflink*: Fact[Ternary]
      ## Copy-on-write clone support.
    cloneOperation*: Fact[CloneOperation]
      ## Which call performs it.
    cloneIsCopyOnWrite*: Fact[Ternary]
      ## Is a successful clone GUARANTEED copy-on-write, or may the
      ## filesystem silently produce a full copy? This is the fact the
      ## CAS campaign's probe explicitly could not establish — it
      ## verifies bytes, so a silently-degraded clone reads as
      ## ``reflink = true`` — and it is the one that decides whether a
      ## cost claim is allowed.

    # -- Timestamps ---------------------------------------------------
    timestampGranularityNs*: Fact[Quantity]
      ## Resolution of the stored last-write time, in nanoseconds. A
      ## cache-correctness property, not trivia: an mtime-comparing
      ## fingerprint is exactly as sharp as this number, so FAT's two
      ## seconds and ext4's nanosecond are not interchangeable.

    # -- Naming -------------------------------------------------------
    caseSensitivity*: Fact[CaseSensitivity]
    casePreserving*: Fact[Ternary]
      ## Independent of sensitivity: FAT32 and NTFS both preserve the
      ## case they were given while matching without regard to it.
    maxComponentLength*: Fact[Quantity]
      ## Longest single path component, in characters.
    maxPathLength*: Fact[Quantity]
      ## Longest whole path the FILESYSTEM accepts. Deliberately
      ## separate from the OS table's ``defaultMaxPathChars``: Windows'
      ## 260 is an API default that ``\\?\`` lifts, not a property of
      ## NTFS.
    refusedCharacters*: Fact[string]
      ## Characters this filesystem refuses inside a path component,
      ## as reached through the platform's ordinary file API.

    # -- Metadata -----------------------------------------------------
    posixModeBits*: Fact[Ternary]
      ## Are POSIX mode bits stored?
    metadataIsPerInode*: Fact[Ternary]
      ## Do permissions/attributes live on the inode, so that a change
      ## through one name is visible through every other name? The CAS
      ## campaign found this load-bearing twice: it is why
      ## ``applyPermissions`` excludes the hardlink arm, and why the
      ## read-only-blob guard rail was rejected — a chmod through a
      ## hardlinked output moves the CAS blob's own mode.

    # -- Atomicity ----------------------------------------------------
    atomicRenameOverExisting*: Fact[Ternary]
      ## Does renaming onto an existing name replace it atomically, so
      ## that no observer ever sees the destination absent?

    # -- Sparseness ---------------------------------------------------
    sparseFiles*: Fact[Ternary]

# ---------------------------------------------------------------------------
# Observation recipes
#
# These are the ``falsifiedBy`` markers. They are named constants rather
# than repeated literals because the recipe belongs to the FACT, not to
# the filesystem — the same operation falsifies "NTFS has hardlinks" and
# "ext4 has hardlinks". Where a filesystem's observability genuinely
# differs (an unobservable value, a server-dependent one) the entry
# carries its own string instead.
# ---------------------------------------------------------------------------

const
  ObsHardlink* =
    "create a second name for a file (link(2) / CreateHardLinkW) and " &
    "read the inode's link count back through both names"
  ObsMaxNames* =
    "create names for one file until the operation refuses (EMLINK / " &
    "ERROR_TOO_MANY_LINKS) and compare the count at which it refused"
  ObsDirLink* =
    "attempt link(2) / CreateHardLinkW against a directory and read the " &
    "refusal"
  ObsLinkDomain* =
    "attempt a hardlink between two directories that share a device but " &
    "not a mount/subvolume, and read whether it answers EXDEV"
  ObsReflink* =
    "issue the clone operation and verify the destination holds the " &
    "source bytes"
  ObsCloneOp* =
    "issue the named operation; a filesystem that does not implement it " &
    "answers EOPNOTSUPP / ERROR_INVALID_FUNCTION"
  ObsCow* =
    "clone a file, write through ONE name, and read the other name back " &
    "unchanged"
  ObsTimestamp* =
    "set the last-write time to a value one granularity unit above a " &
    "base and read it back distinct; set it one unit BELOW and read it " &
    "back identical to the base"
  ObsCase* =
    "create a file under one case and look it up under the other"
  ObsCasePreserve* =
    "create a file under a mixed-case name and read the name back from " &
    "the directory listing"
  ObsComponentLen* =
    "create a component of exactly the declared length, then one " &
    "character longer, and read which of the two the filesystem refuses"
  ObsPathLen* =
    "create a path of exactly the declared length, then one character " &
    "longer, and read which of the two the filesystem refuses"
  ObsRefusedChars* =
    "attempt to create a component containing each declared character " &
    "and confirm no directory entry with that exact name appears; " &
    "confirm a character outside the set does produce one"
  ObsModeBits* =
    "chmod a file and read the mode back"
  ObsPerInode* =
    "change permissions/attributes through one name of a hardlinked " &
    "file and read them back through the other"
  ObsRenameOver* =
    "rename onto an existing destination and confirm it was replaced " &
    "rather than refused; the atomicity itself is NOT observable from " &
    "user space, which is why the marker is obConsequence"
  ObsSparse* =
    "mark a file sparse, extend it far beyond its written bytes, and " &
    "compare allocated size against logical size"

  # Recurring "why this cannot be observed / does not settle it" texts.
  WhyServerDependent =
    "not falsifiable as a filesystem property: the answer belongs to " &
    "the server and its export options, so an observation on one mount " &
    "says nothing about the protocol. Policy MUST probe."
  WhyUnionDependent =
    "not falsifiable as a filesystem property: the answer belongs to " &
    "the upper layer's filesystem, and overlayfs interposes copy-up " &
    "semantics on top of it. Policy MUST probe."

  # ``pathconf(_PC_LINK_MAX)`` is a falsifier ONLY on a filesystem glibc
  # knows. sysdeps/unix/sysv/linux/pathconf.c's __statfs_link_max()
  # switches on statfs.f_type against a fixed list (ext2/ext4, XFS,
  # btrfs, F2FS, reiserfs, minix, ...) and falls through to
  # ``LINUX_LINK_MAX``, which linux_fsinfo.h defines as **127**. So on
  # ZFS or tmpfs it does not fail, and it does not report the kernel's
  # answer either: it returns a wrong constant with every appearance of
  # success. A recipe that does that is not a falsification recipe, and
  # naming it as one is the exact defect this library exists to remove.
  WhyPathconfLies =
    "create names for one file until EMLINK. pathconf(_PC_LINK_MAX) MUST " &
    "NOT be used as the observation here: glibc's Linux implementation " &
    "switches on statfs f_type and returns LINUX_LINK_MAX (127) for every " &
    "filesystem it does not know, including this one, so it answers a " &
    "wrong constant instead of failing"

  # The mirror image of ``WhyPathconfLies``, and it has to be stated
  # separately rather than reusing ``ObsMaxNames``. On XFS the generic
  # "create names until it refuses" recipe is not a recipe at all: the
  # declared cap is 2^31-1, and no budget drives two billion links.
  # ``pathconf`` is the observation that DOES work here, for the exact
  # reason it fails on ZFS and tmpfs — glibc's ``__statfs_link_max``
  # carries an explicit ``case XFS_SUPER_MAGIC: return XFS_LINK_MAX;``
  # arm, so it never reaches the ``LINUX_LINK_MAX`` fallthrough, and
  # ``linux_fsinfo.h`` gives that constant the same 2147483647 that
  # ``xfs_super.c`` assigns to ``s_max_links``. Hence ``obQuery``.
  ObsXfsMaxNames* =
    "read pathconf(_PC_LINK_MAX) on an XFS mount and compare it with the " &
    "declared value: glibc answers from its explicit XFS_SUPER_MAGIC arm " &
    "(XFS_LINK_MAX = 2147483647 in " &
    "sysdeps/unix/sysv/linux/linux_fsinfo.h), not from the " &
    "LINUX_LINK_MAX fallthrough, so the query reports the filesystem's " &
    "own constant rather than a wrong default. Creating names until " &
    "EMLINK is NOT the recipe here and must not be named as one: 2^31-1 " &
    "links is not drivable by any test, so it would be an unrunnable " &
    "falsifier wearing a runnable one's clothes"

# ---------------------------------------------------------------------------
# Citations
#
# Grouped so a reader can see at a glance which document each family of
# claims rests on.
# ---------------------------------------------------------------------------

const
  CiNtfsLimits =
    "Microsoft, \"NTFS overview\" and \"Maximum file path limitation\" " &
    "(learn.microsoft.com/windows-server/storage/file-server/ntfs-overview); " &
    "CreateHardLinkW reference, Return value: \"The maximum number of hard " &
    "links that can be created with this function is 1023 per file. If " &
    "more than 1023 links are created for a file, an error results.\" " &
    "Microsoft names no error CONSTANT there; the 1142 " &
    "ERROR_TOO_MANY_LINKS this repository observed is a measurement, not " &
    "a quotation"
  CiNtfsTime =
    "Microsoft, FILETIME structure reference: a 64-bit count of 100-ns " &
    "intervals; NTFS stores $STANDARD_INFORMATION times in that unit"
  CiWinNaming =
    "Microsoft, \"Naming Files, Paths, and Namespaces\" " &
    "(learn.microsoft.com/windows/win32/fileio/naming-a-file)"
  # NOTE the claim CiWinNaming does NOT support, because a previous
  # round of this table attributed one to it. The only path length on
  # that page is "In editions of Windows before Windows 10 version
  # 1607, the maximum length for a path is MAX_PATH, which is defined
  # as 260 characters"; its \\?\ section says only that the prefix lets
  # a caller "exceed the MAX_PATH limits that are otherwise enforced by
  # the Windows APIs". The string "32,767" does not occur on it. The
  # page that states the figure is a DIFFERENT one, below.
  CiWinMaxPath =
    "Microsoft, \"Maximum Path Length Limitation\" (learn.microsoft.com/" &
    "windows/win32/fileio/maximum-file-path-limitation): \"The Windows " &
    "API has many functions that also have Unicode versions to permit " &
    "an extended-length path for a maximum total path length of 32,767 " &
    "characters\" — followed immediately by \"The maximum path of " &
    "32,767 characters is approximate, because the '\\\\?\\' prefix may " &
    "be expanded to a longer string by the system at run time, and this " &
    "expansion applies to the total length\""
  CiWinPathLen =
    CiWinMaxPath & ". Microsoft, \"NTFS overview\" (learn.microsoft.com/" &
    "windows-server/storage/file-server/ntfs-overview) carries the same " &
    "hedge on the filesystem side: \"Many Windows API functions have " &
    "Unicode versions that allow an extended-length path of " &
    "APPROXIMATELY 32,767 characters\". The ReFS overview's NTFS-vs-ReFS " &
    "limits table rounds it further still — \"Maximum path name length: " &
    "32K Unicode characters\", the same entry for BOTH filesystems. No " &
    "Microsoft page states an exact figure for either one"
  CiRefs =
    "Microsoft, \"Resilient File System (ReFS) overview\" and " &
    "\"ReFS block cloning\" (FSCTL_DUPLICATE_EXTENTS_TO_FILE)"
  CiRefsMeasured =
    "measured by this repository: Local-CAS-Hardlink-Materialization M0 " &
    "on the development host's ReFS volumes (M:, D:)"
  CiNtfsMeasured =
    "measured by this repository: Local-CAS-Hardlink-Materialization M0 " &
    "on the development host's NTFS volume (C: / %TEMP%)"
  CiFatSpec =
    "Microsoft, \"FAT32 File System Specification\" (fatgen103, hardware " &
    "white paper, rev 1.03): directory entries carry two-second " &
    "write-time resolution and one entry per file"
  CiFatLongNames =
    "Microsoft, fatgen103 §\"Long Directory Entries\": \"Long names are " &
    "limited to 255 characters, not including the trailing NUL. The total " &
    "path length of a long name cannot exceed 260 characters, including " &
    "the trailing NUL. ... The following six special characters are now " &
    "allowed in a long name. They are not legal in a short name. " &
    "+ , ; = [ ]\". The 8.3 DIR_Name set (0x22 0x2A 0x2B 0x2C 0x2E 0x2F " &
    "0x3A 0x3B 0x3C 0x3D 0x3E 0x3F 0x5B 0x5C 0x5D 0x7C) is therefore NOT " &
    "the set a long name is refused for"
  CiExfatSpec =
    "Microsoft, \"exFAT file system specification\" §7.4.9 " &
    "\"10msIncrement Fields\": \"10msIncrement fields shall provide " &
    "additional time resolution to their corresponding Timestamp fields " &
    "in ten-millisecond multiples\" (Create10msIncrement / " &
    "LastModified10msIncrement)"
  CiExt4 =
    "Linux kernel Documentation/filesystems/ext4/; EXT4_LINK_MAX = 65000 " &
    "in fs/ext4/ext4.h and fs/ext4/namei.c's ext4_link(): " &
    "`if (inode->i_nlink >= EXT4_LINK_MAX) return -EMLINK;`; inode " &
    "i_[cma]time_extra carry nanosecond bits"
  CiExt4Time =
    "fs/ext4/super.c: `s_time_gran` is set to 1 only when " &
    "`sbi->s_inode_size` leaves room for `i_atime_extra`, and to " &
    "NSEC_PER_SEC otherwise — so nanosecond resolution requires inodes " &
    "of at least 256 bytes, which mke2fs has defaulted to for ext4"
  CiXfs =
    "Linux kernel fs/xfs/libxfs/xfs_format.h: \"The 32 bit link count in " &
    "the inode theoretically maxes out at UINT_MAX. Since the pathconf " &
    "interface is signed, we use 2^31 - 1 instead.\" " &
    "`#define XFS_MAXLINK ((1U << 31) - 1U)` — ONE constant, and " &
    "fs/xfs/xfs_super.c sets `sb->s_max_links = XFS_MAXLINK;` with no " &
    "superblock-version guard (checked in v3.10 and v6.12). glibc's " &
    "sysdeps/unix/sysv/linux/linux_fsinfo.h agrees: XFS_LINK_MAX " &
    "2147483647"
  CiBtrfs =
    "Linux kernel include/uapi/linux/btrfs_tree.h: " &
    "`#define BTRFS_LINK_MAX 65535U`, enforced by fs/btrfs/inode.c's " &
    "btrfs_link() — `if (inode->i_nlink >= BTRFS_LINK_MAX) return " &
    "-EMLINK;` — before any b-tree work, unchanged from v3.10 to v6.12; " &
    "Documentation/filesystems/btrfs.rst; subvolumes present distinct " &
    "st_dev"
  CiZfs =
    "OpenZFS documentation (zfsprops(7) casesensitivity; zfs(4)); " &
    "datasets are separate mounts with distinct st_dev"
  CiZfsLinkMax =
    "OpenZFS source, and it is PLATFORM-DIVERGENT: " &
    "include/os/linux/zfs/sys/zfs_vfsops_os.h has " &
    "`#define ZFS_LINK_MAX ((1U << 31) - 1U)` (enforced by " &
    "module/os/linux/zfs/zpl_inode.c: `if (ip->i_nlink >= ZFS_LINK_MAX) " &
    "return -EMLINK`), while include/os/freebsd/zfs/sys/" &
    "zfs_znode_impl.h has `#define ZFS_LINK_MAX UINT64_MAX` (checked at " &
    "zfs-2.3.0)"
  CiApfs =
    "Apple, \"Apple File System Reference\" (j_inode_val_t.nlink is a " &
    "32-bit field; APFS volumes in one container are separate mounts)"
  CiClonefile =
    "Apple, clonefile(2) man page: \"The cloned file dst shares its data " &
    "blocks with the src file but has its own copy of attributes and " &
    "extended attributes\" and \"Subsequent writes to either the original " &
    "or cloned file are private to the file being modified " &
    "(copy-on-write)\"; COMPATIBILITY: \"Not all volumes support " &
    "clonefile(). A volume can be tested for clonefile() support by using " &
    "getattrlist(2) to get the volume capabilities attribute " &
    "ATTR_VOL_CAPABILITIES, and then testing the VOL_CAP_INT_CLONE " &
    "flag.\"; ERRORS: \"[ENOTSUP] The underlying filesystem does not " &
    "support this call.\""
  CiHfs =
    "Apple, \"HFS Plus Volume Format\" (Technical Note TN1150, 5 March " &
    "2004): dates are \"unsigned 32-bit integers (UInt32) containing the " &
    "number of seconds since midnight, January 1, 1904, GMT\", so the " &
    "stored resolution is one second"
  CiHfsDirLink =
    "TN1150 §Hard Links states the OPPOSITE of a directory hard link: " &
    "\"An indirect node file must be a file, not a directory. Hard links " &
    "to directories are not allowed because they could cause cycles in " &
    "the directory hierarchy if a hard link pointed to one of its " &
    "ancestor directories.\" TN1150 predates Time Machine, and the " &
    "directory hard link (ADL) is a LATER kernel feature, not an " &
    "on-disk-format one: Apple's hfs source core/hfs_link.c compiles it " &
    "under CONFIG_HFS_DIRLINK and returns EPERM unless the volume is " &
    "journaled and the private DIR_HARDLINKS directory exists; " &
    "core/hfs_vfsops.c then advertises VOL_CAP_FMT_DIR_HARDLINKS, which " &
    "xnu bsd/vfs/vfs_syscalls.c turns into MNTK_DIR_HARDLINKS and uses " &
    "to admit link(2) on a directory for its OWNER"
  CiHfsSparse =
    "Apple's hfs source core/hfs_vfsops.c advertises " &
    "VOL_CAP_FMT_ZERO_RUNS and NOT VOL_CAP_FMT_SPARSE_FILES, and xnu " &
    "bsd/sys/attr.h defines the difference: VOL_CAP_FMT_SPARSE_FILES is " &
    "\"files which can have 'holes' ... Sparse files may have an " &
    "allocated size that is less than the file's logical length\", while " &
    "VOL_CAP_FMT_ZERO_RUNS \"provides performance similar to sparse " &
    "files, but not the space savings\""
  CiTmpfs =
    "Linux kernel Documentation/filesystems/tmpfs.rst; mm/shmem.c"
  CiPosixRename =
    "POSIX.1-2017 rename(): \"if the link named by new exists ... this " &
    "rename() shall be atomic relative to other threads\""
  CiWinRename =
    "Microsoft, MoveFileExW reference (MOVEFILE_REPLACE_EXISTING) and " &
    "SetFileInformationByHandle(FileRenameInfo, ReplaceIfExists)"
  CiPosixLink =
    "POSIX.1-2017 link(): EPERM \"the path1 argument names a directory " &
    "and the implementation does not support link() for directories\"; " &
    "EMLINK when LINK_MAX would be exceeded"
  CiPosixNaming =
    "POSIX.1-2017 §3.170 Pathname: only the null byte and '/' may not " &
    "appear in a filename; NAME_MAX / PATH_MAX are reported by pathconf()"
  CiNfs =
    "RFC 7530 (NFSv4) / RFC 1813 (NFSv3): LINK, RENAME and attribute " &
    "semantics are the SERVER's, and support is advertised per-export"
  CiSmb =
    "MS-SMB2 / MS-FSCC: capabilities including hard-link and " &
    "block-refcount support are negotiated per share and belong to the " &
    "server's own filesystem"
  CiOverlay =
    "Linux kernel Documentation/filesystems/overlayfs.rst: metadata and " &
    "data copy-up change what a write through an existing name does"

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

const FilesystemTable*: array[FilesystemId, FilesystemFacts] = [
  # -------------------------------------------------------------------
  fsNtfs: FilesystemFacts(
    id: fsNtfs,
    names: @["ntfs"],
    hardlinks: fact(tnYes, CiNtfsLimits, pvVendorDoc, obOperation,
                    ObsHardlink),
    # 1024 TOTAL names. Measured as 1023 further CreateHardLinkW calls
    # after the first, then ERROR_TOO_MANY_LINKS (1142). The convention
    # matters: "1023 hardlinks" and "1024 names" are the same fact.
    maxNamesPerFile: fact(exactly(1024), CiNtfsLimits & "; " &
                          CiNtfsMeasured, pvMeasured, obOperation,
                          ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiNtfsLimits, pvVendorDoc,
                                 obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      "Microsoft, CreateHardLinkW: \"However, all hard links to a file " &
      "must be on the same volume.\"; \"Hard Links and Junctions\": " &
      "\"Hard links can't reference directories, only files, and they " &
      "can't reference files on different volumes.\" A Windows volume is " &
      "one link domain, and a volume mounted into a folder is a " &
      "DIFFERENT volume with its own serial", pvVendorDoc, obOperation,
      ObsLinkDomain),
    reflink: fact(tnNo,
      "Microsoft, \"Block cloning on ReFS\": block cloning is a ReFS " &
      "feature; NTFS answers ERROR_INVALID_FUNCTION to " &
      "FSCTL_DUPLICATE_EXTENTS_TO_FILE. " & CiNtfsMeasured,
      pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clNone, CiRefs, pvVendorDoc, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable,
      "no clone primitive reaches NTFS, so the question does not arise",
      pvVendorDoc, obNone,
      "not observable: there is no clone to inspect. The absence is " &
      "covered by the reflink fact instead."),
    timestampGranularityNs: fact(exactly(100), CiNtfsTime, pvVendorDoc,
                                 obOperation, ObsTimestamp),
    caseSensitivity: fact(caInsensitive,
      CiWinNaming & "; the per-directory FILE_CASE_SENSITIVE_INFORMATION " &
      "flag (Windows 10 1803+) is opt-in and off by default",
      pvVendorDoc, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiWinNaming, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiWinNaming, pvVendorDoc,
                             obQuery, ObsComponentLen),
    # NOT `exactly(32767)`, and the citation was worse than the value:
    # it named CiWinNaming, a page on which the figure does not appear
    # at all. Re-derived, no Microsoft page states it exactly. The one
    # that states it at all withdraws the precision in the next
    # paragraph ("The maximum path of 32,767 characters is
    # approximate"); "NTFS overview" says "approximately 32,767"; the
    # ReFS comparison table rounds to "32K". `atLeast` would be wrong
    # in the other direction — the approximation is an upper bound that
    # prefix expansion can LOWER, so a host refusing at 32,767 would
    # contradict a lower bound while agreeing with Microsoft. What is
    # left is `varies`, which is also what every other row here already
    # says, and for the same reason: the whole-path bound is the
    # caller's OS's, not the filesystem's. The OS table carries it
    # (defaultMaxPathChars = 260 plus longPathPrefix) and the OS suite
    # drives it.
    maxPathLength: fact(varyingQuantity(), CiWinPathLen, pvVendorDoc,
                        obQuery,
      "read the OS's bound rather than the filesystem's — MAX_PATH " &
      "without the \\\\?\\ prefix and the approximate 32,767 with it, " &
      "both declared in the OS table and driven by its suite. There is " &
      "no exact NTFS whole-path number for a test to drive to a " &
      "boundary, which is why this is `varies` rather than a number"),
    refusedCharacters: fact("\\/:*?\"<>|", CiWinNaming, pvVendorDoc,
                            obOperation, ObsRefusedChars),
    posixModeBits: fact(tnNo,
      "NTFS stores Windows ACLs, not POSIX mode bits; the mode a POSIX " &
      "subsystem reports is synthesised. " & CiNtfsLimits,
      pvVendorDoc, obQuery,
      "read the mode a POSIX layer reports and confirm it does not " &
      "round-trip a chmod"),
    metadataIsPerInode: fact(tnYes,
      "Microsoft, \"Hard Links and Junctions\": \"Any changes made to a " &
      "hard-linked file are instantly visible to applications that " &
      "access it through the links that reference it. The attributes on " &
      "the file are reflected in every hard link to that file, and " &
      "changes to that file's attributes propagate to all the hard " &
      "links.\" Measured by this repository in " &
      "Local-CAS-Hardlink-Materialization M3: clearing the read-only " &
      "attribute through a hardlinked OUTPUT clears it on the blob",
      pvMeasured, obOperation, ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiWinRename, pvVendorDoc,
                                   obConsequence, ObsRenameOver),
    sparseFiles: fact(tnYes,
      "Microsoft, \"Sparse Files\" (FSCTL_SET_SPARSE); " &
      "GetVolumeInformationW reports FILE_SUPPORTS_SPARSE_FILES",
      pvVendorDoc, obQuery, ObsSparse)),

  # -------------------------------------------------------------------
  fsRefs: FilesystemFacts(
    id: fsRefs,
    names: @["refs"],
    hardlinks: fact(tnYes, CiRefs & "; " & CiRefsMeasured, pvMeasured,
                    obOperation, ObsHardlink),
    # Microsoft documents no per-file link cap for ReFS, and this
    # repository's M0 run accepted 2000 names with no refusal. That is
    # an ``atLeast``, not an ``exact``: the honest statement is a lower
    # bound that a host refusing at 2000 would contradict.
    maxNamesPerFile: fact(atLeast(2000), CiRefs & "; " & CiRefsMeasured,
                          pvMeasured, obOperation, ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiRefs, pvVendorDoc, obOperation,
                                 ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      "Microsoft, CreateHardLinkW: same-volume requirement; ReFS has no " &
      "subvolume construct that would split one device into several " &
      "link domains", pvVendorDoc, obOperation, ObsLinkDomain),
    reflink: fact(tnYes, CiRefs & "; " & CiRefsMeasured, pvMeasured,
                  obOperation, ObsReflink),
    cloneOperation: fact(clDuplicateExtents, CiRefs, pvVendorDoc,
                         obOperation, ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnYes,
      "Microsoft, \"Block cloning on ReFS\": the regions are marked " &
      "copy-on-write and a write to either file breaks the sharing. " &
      CiRefsMeasured & " — a write through one clone left the other " &
      "unchanged", pvMeasured, obOperation, ObsCow),
    timestampGranularityNs: fact(exactly(100), CiNtfsTime &
      "; ReFS stores the same FILETIME unit", pvVendorDoc, obOperation,
      ObsTimestamp),
    caseSensitivity: fact(caInsensitive, CiWinNaming & "; " & CiRefs,
                          pvVendorDoc, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiWinNaming, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiRefs, pvVendorDoc, obQuery,
                             ObsComponentLen),
    # Same correction as NTFS above, and it has to be the same: the
    # ReFS overview's limits table gives ReFS and NTFS ONE shared entry
    # ("Maximum path name length: 32K Unicode characters"), so a table
    # that declared `varies` for one and `exactly(32767)` for the other
    # would be reading two different facts out of a single row.
    maxPathLength: fact(varyingQuantity(), CiWinPathLen & "; " & CiRefs,
                        pvVendorDoc, obQuery,
      "read the OS's bound rather than the filesystem's — MAX_PATH " &
      "without the \\\\?\\ prefix and the approximate 32,767 with it, " &
      "both declared in the OS table and driven by its suite. There is " &
      "no exact ReFS whole-path number for a test to drive to a " &
      "boundary, which is why this is `varies` rather than a number"),
    refusedCharacters: fact("\\/:*?\"<>|", CiWinNaming, pvVendorDoc,
                            obOperation, ObsRefusedChars),
    posixModeBits: fact(tnNo,
      "ReFS stores Windows ACLs, not POSIX mode bits. " & CiRefs,
      pvVendorDoc, obQuery,
      "read the mode a POSIX layer reports and confirm it does not " &
      "round-trip a chmod"),
    metadataIsPerInode: fact(tnYes,
      "Microsoft, \"Hard Links and Junctions\": changes made to a " &
      "hard-linked file are instantly visible through every link that " &
      "references it (paraphrase, not a quotation; the page speaks of " &
      "NTFS and this row's value is carried by measurement). " &
      CiRefsMeasured,
      pvMeasured, obOperation, ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiWinRename, pvVendorDoc,
                                   obConsequence, ObsRenameOver),
    sparseFiles: fact(tnYes,
      "Microsoft, ReFS supports sparse files; GetVolumeInformationW " &
      "reports FILE_SUPPORTS_SPARSE_FILES. " & CiRefs,
      pvVendorDoc, obQuery, ObsSparse)),

  # -------------------------------------------------------------------
  fsFat32: FilesystemFacts(
    id: fsFat32,
    names: @["fat32", "fat", "vfat", "msdos"],
    hardlinks: fact(tnNo,
      CiFatSpec & ": a FAT directory entry IS the file's metadata, so a " &
      "file cannot be named twice", pvVendorDoc, obOperation, ObsHardlink),
    maxNamesPerFile: fact(exactly(1), CiFatSpec, pvVendorDoc, obOperation,
                          ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiFatSpec, pvVendorDoc, obOperation,
                                 ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnNotApplicable,
      "no hardlinks exist on FAT32, so there is no link domain to " &
      "delimit. " & CiFatSpec, pvVendorDoc, obNone,
      "not observable: the operation whose reach would be measured is " &
      "unavailable on this filesystem"),
    reflink: fact(tnNo, CiFatSpec, pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clNone, CiFatSpec, pvVendorDoc, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable, CiFatSpec, pvVendorDoc,
                             obNone,
      "not observable: there is no clone primitive to inspect"),
    # The reason this fact exists at all. Two seconds is coarser than
    # most build steps, so an mtime-comparing fingerprint on FAT32
    # cannot distinguish two writes within the same two-second window.
    timestampGranularityNs: fact(exactly(2_000_000_000), CiFatSpec,
                                 pvVendorDoc, obOperation, ObsTimestamp),
    caseSensitivity: fact(caInsensitive, CiFatSpec, pvVendorDoc,
                          obOperation, ObsCase),
    casePreserving: fact(tnYes,
      CiFatSpec & "; the VFAT long-name extension preserves case while " &
      "the 8.3 short name does not", pvVendorDoc, obOperation,
      ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiFatLongNames, pvVendorDoc,
                             obQuery, ObsComponentLen),
    # NOT a number. The 32760 that stood here was in neither cited
    # document: fatgen103 says a long name's total path "cannot exceed
    # 260 characters, including the trailing NUL", and the Windows API
    # figure of 32,767 is on "Maximum Path Length Limitation"
    # (CiWinMaxPath — NOT on CiWinNaming, which states no such number;
    # an earlier draft of this very comment misattributed it, the same
    # way the NTFS row's citation did) — neither is 32760, and neither is a
    # property of FAT32 as opposed to of the caller's OS. Drivers do not
    # enforce the 260 as a filesystem limit (Linux's vfat imposes none
    # below PATH_MAX), so the honest type is `varies`, exactly as for
    # ext4/XFS/btrfs below.
    maxPathLength: fact(varyingQuantity(),
      CiFatLongNames & ". The on-disk format stores components, not " &
      "paths, so the effective whole-path bound is the OS's and not " &
      "FAT32's", pvVendorDoc, obQuery,
      "read pathconf(_PC_PATH_MAX) / the platform's MAX_PATH; the value " &
      "belongs to the OS, which is why this is `varies` rather than a " &
      "number"),
    # The six characters + , ; = [ ] are NOT refused. fatgen103 lists
    # them among the 8.3 DIR_Name illegals and then says explicitly that
    # they "are now allowed in a long name". Declaring them refused would
    # have produced a false CONTRADICTION against the first real VFAT
    # host the suite met.
    refusedCharacters: fact("\\/:*?\"<>|", CiFatLongNames & "; " &
                            CiWinNaming, pvVendorDoc, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnNo,
      CiFatSpec & ": the format stores DOS attribute bits only. Linux's " &
      "vfat driver synthesises a mode from the uid/gid/umask mount " &
      "options", pvVendorDoc, obOperation, ObsModeBits),
    metadataIsPerInode: fact(tnNotApplicable,
      "with one name per file the question is vacuous. " & CiFatSpec,
      pvVendorDoc, obNone,
      "not observable: a second name, which the observation compares " &
      "against, cannot exist on this filesystem"),
    atomicRenameOverExisting: fact(tnNo,
      CiFatSpec & "; MS-DOS/Windows rename onto an existing FAT name " &
      "fails rather than replacing, and Linux's vfat driver has no " &
      "journal with which to make the replacement atomic",
      pvVendorDoc, obConsequence, ObsRenameOver),
    sparseFiles: fact(tnNo,
      CiFatSpec & ": the FAT cluster chain has no representation for an " &
      "unallocated range inside a file", pvVendorDoc, obQuery, ObsSparse)),

  # -------------------------------------------------------------------
  fsExfat: FilesystemFacts(
    id: fsExfat,
    names: @["exfat"],
    hardlinks: fact(tnNo, CiExfatSpec, pvVendorDoc, obOperation,
                    ObsHardlink),
    maxNamesPerFile: fact(exactly(1), CiExfatSpec, pvVendorDoc,
                          obOperation, ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiExfatSpec, pvVendorDoc,
                                 obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnNotApplicable, CiExfatSpec,
                                   pvVendorDoc, obNone,
      "not observable: the operation whose reach would be measured is " &
      "unavailable on this filesystem"),
    reflink: fact(tnNo, CiExfatSpec, pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clNone, CiExfatSpec, pvVendorDoc, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable, CiExfatSpec, pvVendorDoc,
                             obNone,
      "not observable: there is no clone primitive to inspect"),
    timestampGranularityNs: fact(exactly(10_000_000), CiExfatSpec,
                                 pvVendorDoc, obOperation, ObsTimestamp),
    caseSensitivity: fact(caInsensitive, CiExfatSpec, pvVendorDoc,
                          obOperation, ObsCase),
    casePreserving: fact(tnYes, CiExfatSpec, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255),
      "Microsoft, \"exFAT file system specification\" §7.7.3 NameLength: " &
      "\"At most 255, which is the longest possible file name\"; §7.7.5 " &
      "FileName: \"Given the length of the FileName field, 15 " &
      "characters, and the maximum number of File Name directory " &
      "entries, 17, the maximum length of the final, concatenated file " &
      "name is 255.\"", pvVendorDoc, obQuery, ObsComponentLen),
    # Same correction as FAT32's: 32760 appears in neither cited
    # document. The exFAT specification states no whole-path bound at
    # all, so a number here would be invented.
    maxPathLength: fact(varyingQuantity(),
      "Microsoft, \"exFAT file system specification\": the specification " &
      "bounds a file NAME (255) and states no maximum path length; the " &
      "whole-path bound a caller meets is the OS's", pvVendorDoc, obQuery,
      "read pathconf(_PC_PATH_MAX) / the platform's MAX_PATH; the value " &
      "belongs to the OS"),
    refusedCharacters: fact("\\/:*?\"<>|", CiWinNaming & "; " &
                            CiExfatSpec, pvVendorDoc, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnNo, CiExfatSpec, pvVendorDoc, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnNotApplicable, CiExfatSpec, pvVendorDoc,
                             obNone,
      "not observable: a second name, which the observation compares " &
      "against, cannot exist on this filesystem"),
    atomicRenameOverExisting: fact(tnNo, CiExfatSpec, pvVendorDoc,
                                   obConsequence, ObsRenameOver),
    sparseFiles: fact(tnNo,
      CiExfatSpec & ": exFAT's NoFatChain allocation is contiguous and " &
      "carries no hole representation", pvVendorDoc, obQuery, ObsSparse)),

  # -------------------------------------------------------------------
  fsExt4: FilesystemFacts(
    id: fsExt4,
    # ``ext2`` and ``ext3`` were aliased onto this row and have been
    # REMOVED, because the aliasing made two of the row's facts false for
    # them:
    #   * include/linux/ext2_fs.h:28 defines EXT2_LINK_MAX as 32000 —
    #     NOT fs/ext2/ext2.h, which merely `#include
    #     <linux/ext2_fs.h>` and contains neither the identifier nor
    #     the number — and fs/ext2/super.c's ext2_fill_super sets
    #     `sb->s_max_links = EXT2_LINK_MAX;`, so `exactly(65000)` is
    #     wrong on an ext2 mount by a factor of two;
    #   * fs/ext4/super.c grants `s_time_gran = 1` only when the inode is
    #     large enough for `i_atime_extra` and NSEC_PER_SEC otherwise, and
    #     the ext2 driver sets no `s_time_gran` at all, so it inherits the
    #     VFS default of 1 000 000 000 ns from fs/super.c — `exactly(1)`
    #     is wrong there by nine orders of magnitude.
    # A host that mounts ext2 or ext3 now falls out of the table as an
    # UNKNOWN filesystem, which the suite reports loudly and F4 is about.
    # That is the honest outcome: the alternative was a row that answers
    # confidently and wrongly for two of the three names it claimed.
    names: @["ext4"],
    hardlinks: fact(tnYes, CiExt4, pvStandard, obOperation, ObsHardlink),
    maxNamesPerFile: fact(exactly(65000),
      CiExt4 & " (EXT4_LINK_MAX = 65000; the dir_nlink feature lifts the " &
      "limit for DIRECTORY subdirectory counts only)", pvStandard,
      obOperation, ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiPosixLink & "; " & CiExt4,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      CiExt4 & "; ext4 has no subvolume construct, so one device is one " &
      "link domain and a bind mount of it links freely", pvStandard,
      obOperation, ObsLinkDomain),
    reflink: fact(tnNo,
      CiExt4 & "; ext4 has no shared-extent representation and answers " &
      "EOPNOTSUPP to FICLONE", pvStandard, obOperation, ObsReflink),
    cloneOperation: fact(clNone, CiExt4, pvStandard, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable, CiExt4, pvStandard, obNone,
      "not observable: there is no clone primitive to inspect"),
    timestampGranularityNs: fact(exactly(1), CiExt4Time, pvStandard,
                                 obOperation, ObsTimestamp),
    caseSensitivity: fact(caSensitive,
      CiExt4 & "; the casefold feature (Linux 5.2+) makes a marked " &
      "directory insensitive and is opt-in at mkfs time", pvStandard,
      obOperation, ObsCase),
    casePreserving: fact(tnYes, CiExt4, pvStandard, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiExt4 & "; " & CiPosixNaming,
                             pvStandard, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; ext4 imposes no whole-path limit — the bound " &
      "is the OS's PATH_MAX, which is an OS-table fact, and a path " &
      "assembled by successive chdir() calls has no bound at all",
      pvStandard, obQuery,
      "read pathconf(_PC_PATH_MAX); the value belongs to the OS, not to " &
      "ext4, which is why this is `varies` rather than a number"),
    refusedCharacters: fact("\0/", CiPosixNaming, pvStandard, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnYes, CiExt4, pvStandard, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes,
      CiPosixLink & "; mode bits live in the inode and every name " &
      "reaches the same inode", pvStandard, obOperation, ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiExt4,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes, CiExt4, pvStandard, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  fsXfs: FilesystemFacts(
    id: fsXfs,
    names: @["xfs"],
    hardlinks: fact(tnYes, CiXfs, pvStandard, obOperation, ObsHardlink),
    # This was `varies` ("65535 on a v4 superblock, 2^31-1 on v5") and
    # that was WRONG. There is one constant, XFS_MAXLINK, and
    # xfs_super.c assigns it to s_max_links with no version guard — in
    # v3.10, before the v4/v5 split mattered, and in v6.12. The 65535
    # came from XFS_MAXLINK_1, the *v1 inode* di_onlink field's width,
    # which xfs_inode.c only ever ASSERTed while converting an inode
    # BACK to the v1 on-disk layout. It was never a superblock cap, and
    # the constant no longer exists in current kernels at all.
    maxNamesPerFile: fact(exactly(2_147_483_647), CiXfs, pvStandard,
                          obQuery, ObsXfsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiPosixLink & "; " & CiXfs,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      CiXfs & "; XFS has no subvolume construct", pvStandard, obOperation,
      ObsLinkDomain),
    reflink: fact(tnVaries,
      CiXfs & ": reflink is a mkfs-time feature flag (reflink=1, the " &
      "default since xfsprogs 5.1) and a filesystem formatted without " &
      "it answers EOPNOTSUPP forever", pvStandard, obOperation,
      ObsReflink),
    cloneOperation: fact(clFiclone, CiXfs, pvStandard, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnYes,
      CiXfs & "; a shared extent is marked in the refcount b-tree and " &
      "unshared on write", pvStandard, obOperation, ObsCow),
    timestampGranularityNs: fact(exactly(1), CiXfs, pvStandard,
                                 obOperation, ObsTimestamp),
    caseSensitivity: fact(caSensitive, CiXfs & "; " & CiPosixNaming,
                          pvStandard, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiXfs, pvStandard, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiXfs & "; " & CiPosixNaming,
                             pvStandard, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; XFS imposes no whole-path limit", pvStandard,
      obQuery,
      "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming, pvStandard, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnYes, CiXfs, pvStandard, obOperation, ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiXfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes, CiXfs, pvStandard, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  fsBtrfs: FilesystemFacts(
    id: fsBtrfs,
    names: @["btrfs"],
    hardlinks: fact(tnYes, CiBtrfs, pvStandard, obOperation, ObsHardlink),
    # This was `varies`, on the strength of the b-tree item size bounding
    # links from ONE directory. That is pre-`extref` history: btrfs_link
    # rejects at a FIXED count before it touches a b-tree, and `extref`
    # (which lifts the single-directory crowding) has long been a mkfs
    # default. glibc agrees — linux_fsinfo.h carries BTRFS_LINK_MAX
    # 65535 and pathconf(_PC_LINK_MAX) reports it.
    maxNamesPerFile: fact(exactly(65535), CiBtrfs, pvStandard, obOperation,
                          ObsMaxNames),
    hardlinksToDirectories: fact(tnNo, CiPosixLink & "; " & CiBtrfs,
                                 pvStandard, obOperation, ObsDirLink),
    # THE fact this axis exists for. See the milestone's introduction:
    # constants cannot answer pair reachability, and Btrfs is why.
    oneDeviceIsOneLinkDomain: fact(tnNo,
      CiBtrfs & ": subvolumes carry distinct st_dev, and link() across " &
      "two of them fails EXDEV on a SINGLE device. Policy MUST NOT " &
      "infer link reachability from same-device on btrfs; that is what " &
      "repro_local_store/link_capability's probe is for",
      pvStandard, obOperation, ObsLinkDomain),
    reflink: fact(tnYes, CiBtrfs, pvStandard, obOperation, ObsReflink),
    cloneOperation: fact(clFiclone, CiBtrfs, pvStandard, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnYes,
      CiBtrfs & "; btrfs is copy-on-write by construction and a cloned " &
      "extent is shared until either file writes to it", pvStandard,
      obOperation, ObsCow),
    timestampGranularityNs: fact(exactly(1), CiBtrfs, pvStandard,
                                 obOperation, ObsTimestamp),
    caseSensitivity: fact(caSensitive, CiBtrfs & "; " & CiPosixNaming,
                          pvStandard, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiBtrfs, pvStandard, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiBtrfs & "; " & CiPosixNaming,
                             pvStandard, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; btrfs imposes no whole-path limit", pvStandard,
      obQuery, "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming, pvStandard, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnYes, CiBtrfs, pvStandard, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiBtrfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes, CiBtrfs, pvStandard, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  fsZfs: FilesystemFacts(
    id: fsZfs,
    names: @["zfs"],
    hardlinks: fact(tnYes, CiZfs, pvVendorDoc, obOperation, ObsHardlink),
    # `varies`, not `unknown`: the previous entry said OpenZFS "documents
    # no per-file link cap", which overstated the silence. There IS a
    # constant, ZFS_LINK_MAX, and it is genuinely different per platform
    # — 2^31-1 on Linux, UINT64_MAX on FreeBSD — so no single number is
    # correct and the type must say so.
    maxNamesPerFile: fact(varyingQuantity(), CiZfsLinkMax, pvStandard,
                          obOperation, WhyPathconfLies),
    hardlinksToDirectories: fact(tnNo, CiPosixLink & "; " & CiZfs,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnNo,
      CiZfs & ": each dataset is its own mounted filesystem with its own " &
      "st_dev, so two directories in one POOL can still refuse link() " &
      "with EXDEV — the same shape as btrfs subvolumes",
      pvVendorDoc, obOperation, ObsLinkDomain),
    reflink: fact(tnVaries,
      CiZfs & ": block cloning (FICLONE) landed in OpenZFS 2.2.0, which " &
      "had NO zfs_bclone_enabled tunable at all. The tunable was added " &
      "in 2.2.1 (module/os/linux/zfs/zpl_file_range.c: " &
      "`int zfs_bclone_enabled = 0;`) and stayed OFF by default " &
      "throughout 2.2.x; it moved to module/zfs/zfs_vnops.c and became " &
      "`= 1` in 2.3.0. So the answer depends on the OpenZFS version, on " &
      "the tunable, AND on feature@block_cloning being enabled on the " &
      "pool — zfs(4): \"If this setting is 0, then even if " &
      "feature@block_cloning is enabled, using functions and system " &
      "calls that attempt to clone blocks will act as though the feature " &
      "is disabled.\"", pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clFiclone, CiZfs, pvVendorDoc, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnYes,
      CiZfs & "; ZFS is copy-on-write by construction and a cloned block " &
      "is refcounted in the BRT", pvVendorDoc, obOperation, ObsCow),
    timestampGranularityNs: fact(exactly(1), CiZfs, pvVendorDoc,
                                 obOperation, ObsTimestamp),
    caseSensitivity: fact(caConfigurable,
      CiZfs & ": the `casesensitivity` dataset property is set at " &
      "creation and may be sensitive, insensitive or mixed",
      pvVendorDoc, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiZfs, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiZfs & "; " & CiPosixNaming,
                             pvVendorDoc, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; ZFS imposes no whole-path limit", pvVendorDoc,
      obQuery, "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming, pvStandard, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnYes, CiZfs, pvVendorDoc, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiZfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes, CiZfs, pvVendorDoc, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  fsApfs: FilesystemFacts(
    id: fsApfs,
    names: @["apfs"],
    hardlinks: fact(tnYes, CiApfs, pvVendorDoc, obOperation, ObsHardlink),
    maxNamesPerFile: fact(unknownQuantity(),
      CiApfs & ": the on-disk nlink field is 32 bits wide, which bounds " &
      "the value but is not a statement of an enforced cap. Apple's " &
      "format reference states no per-file cap; that is NOT the same as " &
      "\"no cap is documented anywhere\" — xnu bsd/sys/syslimits.h " &
      "carries `#define LINK_MAX 32767`, the platform's POSIX " &
      "compile-time constant, and whether APFS enforces THAT or the " &
      "field width has not been established here. `unknown` rather than " &
      "either number", pvUnestablished, obQuery,
      "read pathconf(_PC_LINK_MAX) on an APFS volume — on macOS this " &
      "reaches the filesystem through VNOP_PATHCONF rather than a libc " &
      "lookup table, so it is a real observation — or create names until " &
      "EMLINK"),
    hardlinksToDirectories: fact(tnNo,
      CiApfs & "; " & CiPosixLink & ". APFS dropped the HFS+ directory " &
      "hard link entirely — Time Machine on APFS uses snapshots",
      pvVendorDoc, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnNo,
      CiApfs & ": volumes in one container share the device but are " &
      "separate mounts with distinct st_dev, so link() across two of " &
      "them fails EXDEV", pvVendorDoc, obOperation, ObsLinkDomain),
    reflink: fact(tnYes, CiClonefile, pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clClonefile, CiClonefile, pvVendorDoc,
                         obOperation, ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnYes, CiClonefile, pvVendorDoc, obOperation,
                             ObsCow),
    timestampGranularityNs: fact(exactly(1), CiApfs &
      ": APFS stores timestamps as nanoseconds since the Unix epoch, " &
      "which is the headline change from HFS+'s one second",
      pvVendorDoc, obOperation, ObsTimestamp),
    caseSensitivity: fact(caConfigurable,
      CiApfs & ": a volume is formatted case-sensitive or " &
      "case-insensitive; macOS system volumes are insensitive by " &
      "default and iOS volumes are sensitive", pvVendorDoc, obOperation,
      ObsCase),
    casePreserving: fact(tnYes, CiApfs, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiApfs &
      " (255 UTF-8 encoded characters)", pvVendorDoc, obQuery,
      ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; the bound is macOS's PATH_MAX (1024), an " &
      "OS-table fact, not an APFS one", pvVendorDoc, obQuery,
      "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming & "; " & CiApfs,
                            pvStandard, obOperation, ObsRefusedChars),
    posixModeBits: fact(tnYes, CiApfs, pvVendorDoc, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiApfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes,
      CiApfs & ": APFS added sparse-file support, which HFS+ lacked",
      pvVendorDoc, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  fsHfsPlus: FilesystemFacts(
    id: fsHfsPlus,
    names: @["hfs", "hfs+", "hfsplus"],
    hardlinks: fact(tnYes,
      CiHfs & ": implemented indirectly, through a link reference in a " &
      "private metadata directory rather than a shared catalog record",
      pvVendorDoc, obOperation, ObsHardlink),
    maxNamesPerFile: fact(unknownQuantity(),
      "TN1150 §Hard Links describes the indirect-node scheme and states " &
      "no cap on the number of links to one indirect node; xnu " &
      "bsd/sys/syslimits.h carries `#define LINK_MAX 32767` as the " &
      "platform's POSIX compile-time constant, and whether HFS+ enforces " &
      "it has not been established here", pvUnestablished, obQuery,
      "read pathconf(_PC_LINK_MAX) on an HFS+ volume — on macOS this " &
      "reaches the filesystem through VNOP_PATHCONF — or create names " &
      "until EMLINK"),
    # This was `no`, on a citation that claimed TN1150 said directory
    # hard links "exist but are created by the kernel". TN1150 says the
    # OPPOSITE, and the mechanism that does exist is a later kernel
    # feature which link(2) DOES expose to an ordinary owner on a
    # journaled volume. Neither `yes` nor `no` is true of HFS+ as such.
    hardlinksToDirectories: fact(tnVaries, CiHfsDirLink, pvVendorDoc,
                                 obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      CiHfs & ": an HFS+ volume is one catalog and one link domain",
      pvVendorDoc, obOperation, ObsLinkDomain),
    reflink: fact(tnNo,
      CiClonefile & "; clonefile(2) requires APFS and answers ENOTSUP on " &
      "HFS+", pvVendorDoc, obOperation, ObsReflink),
    cloneOperation: fact(clNone, CiClonefile, pvVendorDoc, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable, CiClonefile, pvVendorDoc,
                             obNone,
      "not observable: there is no clone primitive to inspect"),
    timestampGranularityNs: fact(exactly(1_000_000_000), CiHfs,
                                 pvVendorDoc, obOperation, ObsTimestamp),
    caseSensitivity: fact(caConfigurable,
      CiHfs & ": HFS+ and HFSX are the insensitive and sensitive " &
      "formats of the same volume layout", pvVendorDoc, obOperation,
      ObsCase),
    casePreserving: fact(tnYes, CiHfs, pvVendorDoc, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiHfs &
      " (255 UTF-16 code units)", pvVendorDoc, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; the bound is macOS's PATH_MAX", pvVendorDoc,
      obQuery, "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming & "; " & CiHfs,
                            pvStandard, obOperation, ObsRefusedChars),
    posixModeBits: fact(tnYes, CiHfs, pvVendorDoc, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiHfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    # `no` used to rest on TN1150 SILENCE — the note does not contain the
    # word "sparse" — which is not evidence. It now rests on a statement:
    # HFS+ advertises zero-runs and withholds the sparse-files capability.
    sparseFiles: fact(tnNo, CiHfsSparse, pvVendorDoc, obOperation,
                      ObsSparse)),

  # -------------------------------------------------------------------
  fsTmpfs: FilesystemFacts(
    id: fsTmpfs,
    names: @["tmpfs", "ramfs", "devtmpfs"],
    hardlinks: fact(tnYes, CiTmpfs, pvStandard, obOperation, ObsHardlink),
    # The reason here used to say the cap was "the VFS default". There is
    # no such default. mm/shmem.c never assigns s_max_links, so it keeps
    # the zero fs/super.c left it at, and fs/namei.c's vfs_link() reads
    # `else if (max_links && inode->i_nlink >= max_links)` — a zero means
    # the check is SKIPPED, i.e. no VFS cap at all. What actually bounds
    # tmpfs is then the inode's own link counter and inc_nlink()'s
    # overflow warning, which this repository has not measured. So the
    # value stays `unknown`; only the false reason is gone.
    maxNamesPerFile: fact(unknownQuantity(),
      CiTmpfs & ": mm/shmem.c sets no s_max_links, and fs/namei.c's " &
      "vfs_link() guards its EMLINK check with `max_links &&` — so a " &
      "zero s_max_links means NO VFS-imposed cap, not a default one. " &
      "What remains is whatever the inode link counter and inc_nlink() " &
      "permit, which this repository has not measured",
      pvUnestablished, obOperation, WhyPathconfLies),
    hardlinksToDirectories: fact(tnNo, CiPosixLink & "; " & CiTmpfs,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnYes,
      CiTmpfs & "; one tmpfs mount is one filesystem instance. Note that " &
      "two SEPARATE tmpfs mounts are separate filesystems, which is why " &
      "/tmp and /dev/shm never link to each other", pvStandard,
      obOperation, ObsLinkDomain),
    reflink: fact(tnNo,
      CiTmpfs & "; tmpfs answers EOPNOTSUPP to FICLONE — its pages are " &
      "page-cache pages with no extent sharing", pvStandard, obOperation,
      ObsReflink),
    cloneOperation: fact(clNone, CiTmpfs, pvStandard, obOperation,
                         ObsCloneOp),
    cloneIsCopyOnWrite: fact(tnNotApplicable, CiTmpfs, pvStandard, obNone,
      "not observable: there is no clone primitive to inspect"),
    timestampGranularityNs: fact(exactly(1), CiTmpfs &
      "; tmpfs inodes carry the kernel's full timespec64", pvStandard,
      obOperation, ObsTimestamp),
    caseSensitivity: fact(caSensitive, CiTmpfs & "; " & CiPosixNaming,
                          pvStandard, obOperation, ObsCase),
    casePreserving: fact(tnYes, CiTmpfs, pvStandard, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(exactly(255), CiTmpfs & "; " & CiPosixNaming,
                             pvStandard, obQuery, ObsComponentLen),
    maxPathLength: fact(varyingQuantity(),
      CiPosixNaming & "; tmpfs imposes no whole-path limit", pvStandard,
      obQuery, "read pathconf(_PC_PATH_MAX); the value belongs to the OS"),
    refusedCharacters: fact("\0/", CiPosixNaming, pvStandard, obOperation,
                            ObsRefusedChars),
    posixModeBits: fact(tnYes, CiTmpfs, pvStandard, obOperation,
                        ObsModeBits),
    metadataIsPerInode: fact(tnYes, CiPosixLink, pvStandard, obOperation,
                             ObsPerInode),
    atomicRenameOverExisting: fact(tnYes, CiPosixRename & "; " & CiTmpfs,
                                   pvStandard, obConsequence,
                                   ObsRenameOver),
    sparseFiles: fact(tnYes,
      CiTmpfs & "; an unwritten range simply has no page allocated",
      pvStandard, obOperation, ObsSparse)),

  # -------------------------------------------------------------------
  # The three below are the entries F4 will formalise: for a network or
  # union filesystem the honest answer to most of these is "probe, trust
  # nothing", and saying so IS the fact.
  # -------------------------------------------------------------------
  fsNfs: FilesystemFacts(
    id: fsNfs,
    names: @["nfs", "nfs4", "nfsd"],
    hardlinks: fact(tnVaries,
      CiNfs & ": the LINK operation is optional and its semantics are " &
      "the server's. A client that sees it succeed has learned about " &
      "one export, not about NFS", pvStandard, obOperation,
      WhyServerDependent),
    maxNamesPerFile: fact(varyingQuantity(),
      CiNfs & "; the cap is the server filesystem's, surfaced through " &
      "FATTR4_MAXLINK when the server chooses to report it",
      pvStandard, obQuery, WhyServerDependent),
    hardlinksToDirectories: fact(tnNo, CiNfs & "; " & CiPosixLink,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnVaries,
      CiNfs & ": one client-side st_dev may span several server " &
      "filesystems (and vice versa across referrals), so the mapping " &
      "between device identity and link reachability is not the " &
      "client's to know", pvStandard, obOperation, WhyServerDependent),
    reflink: fact(tnVaries,
      CiNfs & ": NFSv4.2 CLONE exists and is optional; server-side COPY " &
      "offload is a COPY, not sharing, and must not be counted as a " &
      "reflink", pvStandard, obOperation, WhyServerDependent),
    cloneOperation: fact(clVaries,
      CiNfs & "; the client maps FICLONE onto NFSv4.2 CLONE where the " &
      "server offers it", pvStandard, obOperation, WhyServerDependent),
    cloneIsCopyOnWrite: fact(tnUnknown,
      CiNfs & ": the protocol does not promise that CLONE shares " &
      "storage rather than copying, so a successful clone carries no " &
      "cost guarantee", pvUnestablished, obNone,
      "not observable from the client: sharing is a server-side storage " &
      "property with no wire representation the client can read"),
    timestampGranularityNs: fact(varyingQuantity(),
      CiNfs & ": nfstime4 carries nanoseconds, but the resolution the " &
      "client sees is the server filesystem's, and attribute caching " &
      "makes even that laggy", pvStandard, obOperation,
      WhyServerDependent),
    caseSensitivity: fact(caUnknown, CiNfs, pvUnestablished, obOperation,
                          WhyServerDependent),
    casePreserving: fact(tnVaries, CiNfs, pvStandard, obOperation,
                         WhyServerDependent),
    maxComponentLength: fact(varyingQuantity(),
      CiNfs & "; reported by the server as FATTR4_MAXNAME", pvStandard,
      obQuery, WhyServerDependent),
    maxPathLength: fact(varyingQuantity(),
      CiNfs & "; reported by the server as FATTR4_MAXFILESIZE's sibling " &
      "FATTR4_MAXLINK/MAXNAME family", pvStandard, obQuery,
      WhyServerDependent),
    refusedCharacters: fact("\0/", CiPosixNaming & "; " & CiNfs,
                            pvStandard, obOperation, ObsRefusedChars),
    posixModeBits: fact(tnVaries,
      CiNfs & ": mode is a well-defined NFSv4 attribute, but a server " &
      "backed by a filesystem without mode bits synthesises it",
      pvStandard, obOperation, WhyServerDependent),
    metadataIsPerInode: fact(tnVaries,
      CiNfs & ": the server's inode is shared, but attribute caching " &
      "means a client may not SEE a change made through the other name " &
      "until its cache expires — the fact holds on the server and is " &
      "laggy on the wire", pvStandard, obOperation, WhyServerDependent),
    atomicRenameOverExisting: fact(tnVaries,
      CiNfs & ": RENAME is atomic at the server; a client that lost the " &
      "reply cannot tell a completed rename from a lost one",
      pvStandard, obConsequence, WhyServerDependent),
    sparseFiles: fact(tnVaries,
      CiNfs & ": NFSv4.2 READ_PLUS/holes are optional", pvStandard,
      obQuery, WhyServerDependent)),

  # -------------------------------------------------------------------
  fsSmb: FilesystemFacts(
    id: fsSmb,
    names: @["smb", "smb2", "smb3", "cifs", "smbfs"],
    hardlinks: fact(tnVaries,
      CiSmb & ": SMB2 SET_INFO/FileLinkInformation exists, but whether " &
      "it succeeds is the server's filesystem's answer", pvStandard,
      obOperation, WhyServerDependent),
    maxNamesPerFile: fact(varyingQuantity(), CiSmb, pvStandard, obQuery,
                          WhyServerDependent),
    hardlinksToDirectories: fact(tnNo, CiSmb, pvStandard, obOperation,
                                 ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnVaries,
      CiSmb & ": one mounted share may be several server filesystems " &
      "behind a DFS namespace", pvStandard, obOperation,
      WhyServerDependent),
    reflink: fact(tnVaries,
      CiSmb & ": FSCTL_DUPLICATE_EXTENTS_TO_FILE can be forwarded over " &
      "SMB3 to a ReFS-backed share; FSCTL_SRV_COPYCHUNK is offloaded " &
      "COPY and must not be counted as sharing", pvStandard, obOperation,
      WhyServerDependent),
    cloneOperation: fact(clVaries, CiSmb, pvStandard, obOperation,
                         WhyServerDependent),
    cloneIsCopyOnWrite: fact(tnUnknown,
      CiSmb & ": sharing is a server-side storage property the client " &
      "cannot read", pvUnestablished, obNone,
      "not observable from the client: no wire field reports whether " &
      "the server shared storage or copied it"),
    timestampGranularityNs: fact(varyingQuantity(),
      CiSmb & ": the wire format is FILETIME (100 ns), but the stored " &
      "resolution is the server filesystem's", pvStandard, obOperation,
      WhyServerDependent),
    caseSensitivity: fact(caUnknown, CiSmb, pvUnestablished, obOperation,
                          WhyServerDependent),
    casePreserving: fact(tnVaries, CiSmb, pvStandard, obOperation,
                         WhyServerDependent),
    maxComponentLength: fact(varyingQuantity(), CiSmb, pvStandard, obQuery,
                             WhyServerDependent),
    maxPathLength: fact(varyingQuantity(), CiSmb, pvStandard, obQuery,
                        WhyServerDependent),
    refusedCharacters: fact("\\/:*?\"<>|", CiWinNaming & "; " & CiSmb,
                            pvStandard, obOperation, ObsRefusedChars),
    posixModeBits: fact(tnVaries,
      CiSmb & ": only with the SMB3 POSIX extensions or a UNIX-extensions " &
      "server", pvStandard, obOperation, WhyServerDependent),
    metadataIsPerInode: fact(tnVaries, CiSmb, pvStandard, obOperation,
                             WhyServerDependent),
    atomicRenameOverExisting: fact(tnVaries,
      CiSmb & ": FileRenameInformation carries ReplaceIfExists, but a " &
      "share may refuse to replace an open file", pvStandard,
      obConsequence, WhyServerDependent),
    sparseFiles: fact(tnVaries, CiSmb, pvStandard, obQuery,
                      WhyServerDependent)),

  # -------------------------------------------------------------------
  fsOverlayfs: FilesystemFacts(
    id: fsOverlayfs,
    names: @["overlay", "overlayfs"],
    hardlinks: fact(tnVaries,
      CiOverlay & ": a link within the upper layer works; a link whose " &
      "source is still in a lower layer triggers copy-up first, and the " &
      "index feature governs whether the link SURVIVES that copy-up as " &
      "one inode", pvStandard, obOperation, WhyUnionDependent),
    maxNamesPerFile: fact(varyingQuantity(),
      CiOverlay & "; inherited from the upper filesystem", pvStandard,
      obOperation, WhyUnionDependent),
    hardlinksToDirectories: fact(tnNo, CiOverlay & "; " & CiPosixLink,
                                 pvStandard, obOperation, ObsDirLink),
    oneDeviceIsOneLinkDomain: fact(tnNo,
      CiOverlay & ": upper and lower layers are different filesystems " &
      "presented under one st_dev, so same-device tells you nothing " &
      "about link reachability here", pvStandard, obOperation,
      WhyUnionDependent),
    reflink: fact(tnVaries,
      CiOverlay & "; inherited from the upper filesystem", pvStandard,
      obOperation, WhyUnionDependent),
    cloneOperation: fact(clVaries, CiOverlay, pvStandard, obOperation,
                         WhyUnionDependent),
    cloneIsCopyOnWrite: fact(tnVaries, CiOverlay, pvStandard, obOperation,
                             WhyUnionDependent),
    timestampGranularityNs: fact(varyingQuantity(),
      CiOverlay & "; inherited from the upper filesystem", pvStandard,
      obOperation, WhyUnionDependent),
    caseSensitivity: fact(caSensitive,
      CiOverlay & "; overlayfs itself compares names byte-wise, and " &
      "requires its layers to be case-sensitive", pvStandard, obOperation,
      ObsCase),
    casePreserving: fact(tnYes, CiOverlay, pvStandard, obOperation,
                         ObsCasePreserve),
    maxComponentLength: fact(varyingQuantity(),
      CiOverlay & "; inherited from the upper filesystem", pvStandard,
      obQuery, WhyUnionDependent),
    maxPathLength: fact(varyingQuantity(), CiOverlay, pvStandard, obQuery,
                        WhyUnionDependent),
    refusedCharacters: fact("\0/", CiPosixNaming & "; " & CiOverlay,
                            pvStandard, obOperation, ObsRefusedChars),
    posixModeBits: fact(tnYes,
      CiOverlay & ": overlayfs requires a POSIX-mode upper layer",
      pvStandard, obOperation, ObsModeBits),
    # The fact that makes overlayfs different in kind rather than in
    # degree: copy-up changes what a write through an existing name
    # does, so "one inode, N names" stops being reliable.
    metadataIsPerInode: fact(tnVaries,
      CiOverlay & ": a write or chmod through a name that is still in " &
      "the lower layer COPIES THE FILE UP first, so the change lands on " &
      "a new inode and is NOT visible through a name that was linked " &
      "earlier. This is the union case that breaks the per-inode " &
      "assumption the CAS campaign relies on elsewhere",
      pvStandard, obOperation, WhyUnionDependent),
    atomicRenameOverExisting: fact(tnVaries,
      CiOverlay & ": rename may require copy-up or a whiteout, which is " &
      "more than one operation on the underlying layers", pvStandard,
      obConsequence, WhyUnionDependent),
    sparseFiles: fact(tnVaries, CiOverlay, pvStandard, obQuery,
                      WhyUnionDependent)),
]

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

func filesystemFacts*(id: FilesystemId): FilesystemFacts =
  ## The declared facts for ``id``.
  FilesystemTable[id]

func normalizedFsName*(name: string): string =
  ## Lowercase ``name`` for table lookup. Deliberately ASCII-only and
  ## deliberately not trimming anything else: an OS-reported filesystem
  ## name that needs more normalisation than this is a name the table
  ## should learn, not one the lookup should paper over.
  result = newStringOfCap(name.len)
  for ch in name:
    if ch >= 'A' and ch <= 'Z':
      result.add(chr(ord(ch) + 32))
    else:
      result.add(ch)

func filesystemIdForName*(name: string): tuple[found: bool;
                                               id: FilesystemId] =
  ## Map an OS-reported filesystem name to a table entry.
  ##
  ## ``found = false`` is a REPORTABLE outcome, not a fallback: F2 fails
  ## a run that meets a filesystem the table does not know, because a
  ## silent fall-through is how a wrong policy decision hides.
  let needle = normalizedFsName(name)
  if needle.len == 0:
    return (false, fsNtfs)
  for id in FilesystemId:
    for candidate in FilesystemTable[id].names:
      if candidate == needle:
        return (true, id)
  (false, fsNtfs)

# ---------------------------------------------------------------------------
# Deliberate non-entries — Platform-And-Filesystem-Facts **F4**.
#
# There are two ways for a host filesystem to have no row, and policy
# behaves IDENTICALLY for both (see ``detect.nim``'s degradation rule:
# probe, assume nothing, report). What differs is what the report can
# say, and that difference is worth a table of its own:
#
#   * the table has never heard of the name. The report can only say
#     "add a row"; nobody has looked at the filesystem.
#   * the table knows the name, has looked, and has decided NOT to
#     write a row — because the facts it would have to state are not
#     established, or are genuinely a `varies` that a copied row would
#     misreport. The report can say WHY, and what would take to change
#     it.
#
# The second is not a gap in the table. It is a fact ABOUT the table,
# and recording it here is what stops the next reader "fixing" it by
# aliasing the name onto a neighbouring row — which is precisely the
# defect review round 2 removed from the ext4 row.
#
# INVARIANT, asserted by the tests: a name listed here MUST NOT appear
# in any row's ``names``. A deferral that shadows a real row would make
# ``filesystemIdForName`` and this list disagree about the same string.
# ---------------------------------------------------------------------------

type
  UnenteredFilesystem* = object
    ## A filesystem name the table knows it does not describe.
    name*: string
      ## The OS-reported name, lowercased, exactly as
      ## ``normalizedFsName`` would produce it.
    reason*: string
      ## Why there is no row. Sourced the same way a fact's citation
      ## is: a reader must be able to check it without a machine.
    toAdd*: string
      ## The small, documented change that would replace this deferral
      ## with a row — F4 requires that adding an entry be small, and
      ## this is where "small" is written down rather than assumed.

const UnenteredFilesystems*: array[2, UnenteredFilesystem] = [
  UnenteredFilesystem(
    name: "ext3",
    reason:
      "There is no ext3 driver on Linux 4.3 or later: CONFIG_EXT3_FS " &
      "was removed and fs/ext4 serves ext2- and ext3-formatted volumes " &
      "(fs/ext4/super.c registers the `ext2` and `ext3` filesystem types " &
      "under CONFIG_EXT4_USE_FOR_EXT23). /proc/self/mountinfo reports " &
      "the type the volume was mounted AS, so such a mount still says " &
      "`ext3` while the ext4 code is what answers every call. Aliasing " &
      "the name onto the ext4 row would nonetheless be wrong, and in " &
      "the exact way review round 2 already removed once: ext4's row " &
      "declares timestampGranularityNs = exactly(1), which " &
      "fs/ext4/super.c grants only when `sbi->s_inode_size` leaves room " &
      "for `i_atime_extra` (inodes of at least 256 bytes). An ext3 " &
      "volume made with the traditional 128-byte inode gets " &
      "`s_time_gran = NSEC_PER_SEC` instead — nine orders of magnitude " &
      "coarser — and the inode size is a mkfs-time choice, so no single " &
      "number is right. An ext3 row's honest value is `varies`, which " &
      "is not the ext4 row's value and cannot be borrowed from it.",
    toAdd:
      "add `fsExt3` to `FilesystemId`, one `FilesystemFacts` literal to " &
      "`FilesystemTable` with `names: @[\"ext3\"]`, and delete this " &
      "deferral. That is 17 facts, each needing its own citation and " &
      "falsification recipe; the conformance suite picks the row up with " &
      "no further change. The one fact that MUST NOT be copied from the " &
      "ext4 row is timestampGranularityNs — see the reason above."),
  UnenteredFilesystem(
    name: "ext2",
    reason:
      "The same driver story as ext3, plus a divergence that is not " &
      "even a `varies`: WHICH cap applies depends on which driver " &
      "mounted the volume. include/linux/ext2_fs.h has `#define " &
      "EXT2_LINK_MAX 32000` and fs/ext2/super.c's ext2_fill_super " &
      "assigns it to `s_max_links`, while fs/ext4 serving the same " &
      "volume under CONFIG_EXT4_USE_FOR_EXT23 assigns EXT4_LINK_MAX " &
      "(65000) — so ext4's `exactly(65000)` is wrong here by a factor " &
      "of two whenever the ext2 driver is the one in play. The ext2 " &
      "driver also sets no `s_time_gran` at all and inherits the VFS " &
      "default of one SECOND. Review round 2 removed `ext2` and `ext3` " &
      "from the ext4 row's `names` for exactly these two reasons; " &
      "re-adding either would restore the defect.",
    toAdd:
      "add `fsExt2` to `FilesystemId` and one `FilesystemFacts` literal " &
      "with `names: @[\"ext2\"]`, and delete this deferral. " &
      "maxNamesPerFile and timestampGranularityNs are the two facts " &
      "that cannot be copied from the ext4 row; both are driver- " &
      "dependent here, so `varies` with a citation naming both drivers " &
      "is likely the honest value rather than a number."),
]

func unenteredFilesystem*(name: string):
    tuple[found: bool; entry: UnenteredFilesystem] =
  ## Look a name up in the deliberate-non-entry table.
  ##
  ## ``found = true`` never means a fact is available — it means the
  ## report can say why one is not. Policy MUST treat this exactly as it
  ## treats a name nobody has heard of; see ``detect.nim``.
  let needle = normalizedFsName(name)
  if needle.len == 0:
    return (false, UnenteredFilesystem())
  for entry in UnenteredFilesystems:
    if entry.name == needle:
      return (true, entry)
  (false, UnenteredFilesystem())

func `$`*(op: CloneOperation): string =
  case op
  of clNone: "none"
  of clFiclone: "ioctl(FICLONE)"
  of clClonefile: "clonefile(2)"
  of clDuplicateExtents: "FSCTL_DUPLICATE_EXTENTS_TO_FILE"
  of clVaries: "varies"
  of clUnknown: "unknown"

func `$`*(c: CaseSensitivity): string =
  case c
  of caSensitive: "case-sensitive"
  of caInsensitive: "case-insensitive"
  of caConfigurable: "configurable"
  of caUnknown: "unknown"

func isDefinite*(op: CloneOperation): bool =
  op notin {clVaries, clUnknown}

func isDefinite*(c: CaseSensitivity): bool =
  c in {caSensitive, caInsensitive}

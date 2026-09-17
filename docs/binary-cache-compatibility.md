# Binary Cache Compatibility

A valid signature is necessary but not sufficient for substitution. The
client checks that the signed entry identity matches the requested key and
that its producer is trusted for the selected mirror. Manifest reuse is scoped
to that mirror, and the current trust policy is checked even for an in-memory
manifest.

The client also checks platform, ABI, CPU requirements, compression support and
relocation policy before reusing or downloading a payload. A local payload-index
hit does not bypass these checks.

Currently, only the `optional` relocation policy is supported. Entries marked
`required` are refused because the client has no relocation implementation.
Entries marked `forbidden` are refused because the signed manifest does not bind
the producer's required realization root. A cache server's storage directory is
not evidence of that root. These refusals allow another configured mirror or a
local build to be tried.

Do not relabel a payload as `optional` to bypass these checks. The publisher
remains responsible for whether the payload can actually be used at the
consumer's destination. This gate does not establish that arbitrary ELF files,
scripts or their dependencies are relocatable, and it does not authorize pending
source-package identities.

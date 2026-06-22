## Peer-cache key + signature byte types — BearSSL-free.
##
## These are the plain fixed-size ECDSA-P256 byte-array types and their
## length constants. They are split out of `auth.nim` so that modules
## which only need the *shapes* of producer public keys / signatures
## (notably `repro_binary_cache_server/types`, and transitively
## `repro_binary_cache_client/cache_key` and the project DSL) can depend
## on them WITHOUT pulling in the BearSSL FFI that `auth.nim`'s real
## sign / verify procedures require.
##
## Why this matters: the project DSL takes a hard dependency on the
## canonical `CacheEntryIdentity` / binary-cache type set so a single
## struct definition is shared end-to-end. Before this split, that pulled
## the whole `auth.nim -> bearssl/{rand,ec,hash}` chain into every recipe
## compile. The recipe-interface extraction (`--define:reproInterfaceMode`)
## runs from a staged source copy where the sibling `nim-bearssl` checkout
## is not present, so the extract failed with `cannot open file:
## bearssl/rand`. The byte-array types below depend on nothing but the
## P256 length constants, so hoisting them here removes BearSSL from the
## DSL's type-check closure entirely.
##
## `auth.nim` re-exports everything here, so its public API is unchanged.

const
  P256PrivLen* = 32
    ## Raw ECDSA-P256 private key (the secret scalar) length, in bytes.
  P256PubLen*  = 65
    ## Uncompressed ECDSA-P256 public key length, in bytes
    ## (``0x04 || X || Y``).
  P256SigLen*  = 64
    ## Raw ECDSA-P256 signature length, in bytes (``r || s``).

type
  PrivateKeyBytes* = array[P256PrivLen, byte]
  PublicKeyBytes*  = array[P256PubLen, byte]
  SignatureBytes*  = array[P256SigLen, byte]

  PeerKeypair* = object
    publicKey*: PublicKeyBytes
    privateKey*: PrivateKeyBytes

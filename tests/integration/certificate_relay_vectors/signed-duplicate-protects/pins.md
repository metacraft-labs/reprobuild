# notes/signed-duplicate-protects

**Pins:** a relay preserves every existing signed copy of a payload when adding
another signed copy; an earlier unsigned duplicate does not hide it.

**Derivation.** The signed record is `signed-and-unsigned`'s first record.
`add.txt` has the same payload and a deliberately damaged signature (the base64
prefix `AAAA` is inserted). The expected note is unchanged. The duplicate case
prepends that record without its signature table, retaining `key_id`.

**Would be wrong if:** presence of a signature block authorized a relay to
replace a signature it did not make, or only the first duplicate was examined.

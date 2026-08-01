// reprobuild.hcr.reference-corpus fixture: wild
// ELF relocation class marker for the HCR corpus.
pub fn elf_relocation_width(kind: &str) -> u8 {
    if kind == "relative" { 32 } else { 64 }
}

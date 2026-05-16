.section __DATA,__data
.globl _hcr_data_anchor
.p2align 3
_hcr_data_anchor:
  .quad 42

.section __TEXT,__text,regular,pure_instructions
.globl _hcr_changed_constant
.p2align 2
_hcr_changed_constant:
  .cfi_startproc
  mov w0, #1
  ret
  .cfi_endproc

.globl _hcr_changed_data_reader
.p2align 2
_hcr_changed_data_reader:
  .cfi_startproc
  adrp x0, _hcr_data_anchor@PAGE
  add x0, x0, _hcr_data_anchor@PAGEOFF
  ldr w0, [x0]
  ret
  .cfi_endproc

.globl _hcr_changed_external_call
.p2align 2
_hcr_changed_external_call:
  .cfi_startproc
  bl _hcr_external_target
  ret
  .cfi_endproc

.globl _hcr_unchanged_reloc_data
.p2align 2
_hcr_unchanged_reloc_data:
  .cfi_startproc
  adrp x0, _hcr_data_anchor@PAGE
  add x0, x0, _hcr_data_anchor@PAGEOFF
  ldr w0, [x0]
  ret
  .cfi_endproc

.globl _hcr_unchanged_leaf
.p2align 2
_hcr_unchanged_leaf:
  .cfi_startproc
  mov w0, #7
  ret
  .cfi_endproc

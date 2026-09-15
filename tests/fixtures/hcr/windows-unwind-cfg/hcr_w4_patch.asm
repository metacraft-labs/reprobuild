option casemap:none

.code

PUBLIC hx_w4_patch
hx_w4_patch PROC FRAME
    sub rsp, 68h
    .allocstack 68h
    .endprolog
    call rcx
    ; Raise the exception from this frame itself. The poisoned leaf-fallback
    ; slot stresses the missing-table arm; Windows documents that arm as
    ; unreliable, so the gate treats either fail-stop or survival with no
    ; RtlLookupFunctionEntry result as the required red outcome.
    mov qword ptr [rsp], 1
    int 3
    add rsp, 68h
    ret
hx_w4_patch ENDP

ALIGN 16
PUBLIC hx_w4_patch_second
hx_w4_patch_second PROC FRAME
    sub rsp, 28h
    .allocstack 28h
    .endprolog
    call rcx
    mov qword ptr [rsp], 1
    int 3
    add rsp, 28h
    ret
hx_w4_patch_second ENDP

END

#!/usr/bin/env python3
"""Check the guest shell strings of the add-on VM gates without a VM.

Every `nw|g|old .run(...)`/`.exec(...)` call of the given gate sources has
its first argument rebuilt from its Nim string literals (escapes decoded;
any other operand of `&` replaced by a placeholder word) and parsed with
`dash -n`, the shell the Debian and Ubuntu guests run commands with. A
quoting slip (an apostrophe inside a single-quoted printf, A13 review round
15) then fails in seconds instead of a whole VM cell. Exit 1 when any
string does not parse; needs `dash` on PATH (`nix shell nixpkgs#dash`).

Usage: check_addon_gate_shell.py <gate.nim>...
"""
import re, shutil, subprocess, sys
# Guest shell strings of the gates: each nw/g .run/.exec(...) call's first
# argument, with Nim string literals decoded and every other operand of `&`
# replaced by a placeholder word, checked with `dash -n`.
def literals(src, i):
    # parse first argument expression starting at i (after '('), stop at top-level ',' or ')'
    out=[]; depth=0; j=i
    while j < len(src):
        c=src[j]
        if c=='"':
            if src.startswith('"""', j):
                k=src.index('"""', j+3); out.append(('s', src[j+3:k])); j=k+3; continue
            k=j+1; buf=''
            while src[k]!='"':
                if src[k]=='\\':
                    n=src[k+1]
                    buf+={'n':'\n','t':'\t','\\':'\\','"':'"',"'":"'"}.get(n,'\\'+n); k+=2
                else: buf+=src[k]; k+=1
            out.append(('s',buf)); j=k+1; continue
        if c in '([': depth+=1
        elif c in ')]':
            if depth==0: return out, j
            depth-=1
        elif c==',' and depth==0: return out, j
        elif c=='&': out.append(('&',''))
        elif re.match(r'[A-Za-z_$]', c) and (not out or out[-1][0]=='&'):
            m=re.match(r'[$A-Za-z_][\w.]*(\([^()]*\))?', src[j:]); out.append(('v','XVAL')); j+=m.end(); continue
        j+=1
    return out, j
if shutil.which('dash') is None:
    sys.exit('check_addon_gate_shell: dash is not on PATH (nix shell nixpkgs#dash)')
bad=0; n=0
for f in sys.argv[1:]:
    src=open(f).read()
    for m in re.finditer(r'\b(nw|g|old)\.(run|exec)\(', src):
        parts,_=literals(src, m.end())
        s=''.join(p[1] if p[0]=='s' else ('XVAL' if p[0]=='v' else '') for p in parts)
        if not any(p[0]=='s' for p in parts): continue
        n+=1
        r=subprocess.run(['dash','-n'], input=s, capture_output=True, text=True)
        if r.returncode!=0:
            bad+=1
            line=src.count('\n',0,m.start())+1
            print(f"{f}:{line}: {r.stderr.strip()}\n   {s[:200]!r}")
print(f"checked {n}, bad {bad}")
sys.exit(1 if bad else 0)

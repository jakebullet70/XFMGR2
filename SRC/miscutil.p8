; miscutil - misc self-contained utility routines, run from a HIRAM bank overlay.
;
; Compiled as a %output library headerless blob (org $A000), loaded into reserved HIRAM
; bank 3 (MISC_BANK in xfmgr) at startup via diskio.loadlib, and called from the main
; program via `extsub @bank 3` (JSRFAR maps the bank around each call). Moving self-contained
; helpers here frees scarce main RAM (XFMGR is main-RAM constrained).
;
; Fixed entry offsets via %jmptable: $A000 = init (start), $A003 = wildcard_expand.
; Depends only on `strings` (its own private copy) + pointers passed in from main RAM (which
; stays mapped below $A000 while this bank is active). Touches NO xtree/xfiles/xarena state.

%import strings
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table so callable entry offsets stay fixed across rebuilds. The compiler prepends
    ; `jmp start` at $A000, so: $A000 = start (library init), $A003 = wildcard_expand.
    ; KEEP THIS BLOCK FREE OF INITIALIZED VARIABLES - prog8 emits a block's initialized vars
    ; inline BEFORE its code/jumptable, which would shove the table off $A003 (same gotcha as
    ; tview.p8). All locals below live inside subs (fine) or are uninitialized.
    %jmptable ( main.wildcard_expand )

    sub start() {
        ; library init entrypoint ($A000): the compiler emits the BSS-clear here. Do NO UI or
        ; system init (the caller owns the machine). Call ONCE after load.
    }

    sub wildcard_expand(uword origptr @R0, uword patptr @R1, uword outptr @R2) {
        ; real entry ($A003). Expand a DOS/XTree rename pattern (pat) against the original name
        ; (orig) into out. The call-site copies the three pointers into wildcard_name's params
        ; before its body runs, so the strings.* clobber of cx16.r0-r3 inside is harmless.
        wildcard_name(origptr, patptr, outptr)
    }

    ; ---- pure string helpers (ported verbatim from xfmgr.p8) ----

    sub last_dot(str s) -> ubyte {
        ; index of the last '.' in s, or 255 if none
        ubyte i = lsb(strings.length(s))
        while i != 0 {
            i--
            if s[i] == '.'
                return i
        }
        return 255
    }

    sub merge_seg(str pat, ubyte ps, ubyte pe, str orig, ubyte os, ubyte oe, str out, ubyte outpos) -> ubyte {
        ; merge one filename segment: pattern pat[ps..pe) against orig[os..oe), writing
        ; into out from outpos. '*' copies the rest of the original segment, '?' copies
        ; one original char, any other char is literal (and consumes one original char).
        ubyte pi = ps
        ubyte oi = os
        while pi < pe {
            ubyte pc = pat[pi]
            if pc == '*' {
                while oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                return outpos                    ; '*' ends this segment
            } else if pc == '?' {
                if oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                pi++
            } else {
                out[outpos] = pc
                outpos++
                if oi < oe
                    oi++
                pi++
            }
        }
        return outpos
    }

    sub wildcard_name(str orig, str pat, str out) {
        ; expand a DOS/XTree-style rename pattern (pat) against the original name (orig)
        ; into out, e.g. orig "test.dat" + pat "*.tmp" -> "test.tmp". Base and extension
        ; (split at the last '.') are merged independently.
        ubyte olen = lsb(strings.length(orig))
        ubyte plen = lsb(strings.length(pat))
        ubyte pd = last_dot(pat)
        ubyte pos
        if pd == 255 {
            ; no '.' in the pattern: treat the whole name as a single segment
            pos = merge_seg(pat, 0, plen, orig, 0, olen, out, 0)
        } else {
            ubyte obase_e = olen
            ubyte oext_s = olen
            ubyte od = last_dot(orig)
            if od != 255 {
                obase_e = od
                oext_s = od + 1
            }
            pos = merge_seg(pat, 0, pd, orig, 0, obase_e, out, 0)
            out[pos] = '.'
            pos++
            pos = merge_seg(pat, pd+1, plen, orig, oext_s, olen, out, pos)
        }
        out[pos] = 0
    }
}

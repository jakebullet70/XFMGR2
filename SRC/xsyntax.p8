; xsyntax - syntax coloring for XFMGR2's banked text viewer (tview).
;
; Ported from x16-MSEDIT's SRC/syntax.p8. classify() scans ONE line of text and writes a
; per-column color byte into a caller buffer (one txt.setclr attribute per document column).
; Highlighting is STATELESS per line - strings, REM comments and ## comments all end at
; end-of-line - so no state carries between lines. That keeps this a pure leaf module: it
; reads the line via a pointer, writes colors via a pointer, and needs nothing else.
;
; WHY ITS OWN BANK: tview (bank 2) is full - ~424 bytes free to $C000, and this needs ~1.5 KB.
; A banked overlay CAN call another bank: the X16 KERNAL's JSRFAR "works independently of which
; RAM or ROM bank the currently executing code is residing in" (X16 Reference - 05 - KERNAL,
; JSRFAR at $FF6E), which is what prog8's `extsub @bank` emits. So tview JSRFARs in here once
; per rendered line. Cost is ~28 cross-bank calls per page - nothing next to the disk read.
;
; THE CATCH, and why the buffers are main-RAM pointers: while THIS bank is mapped at $A000,
; tview's own bank-2 RAM is NOT visible. So the source line and the color buffer cannot live
; in either overlay - they are main-RAM buffers owned by xfmgr.p8 and handed to tview at
; startup, and main RAM stays mapped below $A000 no matter which bank is active.
;
; ASCII, NOT PETSCII. tview renders RAW FILE BYTES, so the text arriving here is ASCII - unlike
; MSEDIT, which classifies its PETSCII editor buffer. `%encoding iso` below makes every literal
; in this module ASCII (iso-8859-15 agrees with ASCII across A-Z/a-z/0-9/punctuation), so the
; keyword tables are stored as the bytes a real file actually contains. Without it, prog8's
; default PETSCII literals would encode A-Z as $C1-$DA and NOTHING would ever match - silently.
; This module does no diskio and prints nothing, so it has no reason to want PETSCII anywhere
; (contrast SRC/themes.p8, which must stay PETSCII for its literal filename).

%encoding iso
%import textio             ; this overlay paints its own color pass - see syn_paint()
%import strings            ; strings.length, for the extension match in detect()
%import "shared-const"

; --- loadable-library overlay: headerless blob loaded at $A000 into a HIRAM bank and called
;     via `extsub @bank`. %output library => no zeropage / no sysinit / jmp start entry;
;     %memtop hard-fails the build if the overlay outgrows the $A000-$BFFF window.
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table so callable entry offsets stay fixed across rebuilds. The compiler prepends
    ; `jmp start` at $A000 (library init), so: $A000 = start, $A003/$A006/$A009 = the entries.
    ;
    ; The real code lives in the `syntax` block below, per the two-block library pattern in the
    ; prog8 manual (docs/source/binlibrary.rst). That is deliberate and load-bearing here: the
    ; keyword tables are INITIALIZED data, and prog8 emits a block's initialized variables inline
    ; BEFORE its code - which would shove this jump table off $A003 if they shared a block.
    ; Keeping `main` var-free means only `syntax` gets that inline data, safely after the table.
    ; $A003 = setbufs, $A006 = paint, $A009 = probe, $A00C = detect, $A00F = read_find,
    ; $A012 = draw_footer, $A015 = draw_zsm.
    ; (Appending is safe - a new entry goes on the END, so no existing offset moves.)
    %jmptable ( syntax.setbufs, syntax.paint, syntax.probe, syntax.detect, syntax.read_find, syntax.draw_footer, syntax.draw_zsm )

    sub start() {
        ; library init entrypoint ($A000). The compiler emits the BSS-clear here; this must do
        ; NO UI or system init (the caller owns the screen). Call ONCE after load.
    }
}

syntax {
    %option ignore_unused

    const ubyte PROBE_MAGIC = $5a       ; probe() returns this; see the note on probe() below

    ; REM is matched specially (it comments the rest of the line), so it's kept out of the tables.
    str rem_kw = "REM"

    ; X16 BASIC keyword sets: Commodore BASIC V2 + the Commander X16 additions. Statements are
    ; colored as keywords; value-returning functions get their own color (like sub names in an
    ; IDE theme). Stored as space-delimited blobs and matched case-insensitively (fold/eq), which
    ; costs far less than uword[] tables (those add ~188 bytes of lsb/msb pointers on top of the
    ; same string bytes). Function forms keep any trailing '$'. Statements are split CBM/X16 only
    ; to keep each str under the 255-char limit; both classify as keywords.
    str kw_stmt  = "END FOR NEXT DATA INPUT DIM READ LET GOTO RUN IF RESTORE GOSUB RETURN STOP ON WAIT LOAD SAVE VERIFY DEF POKE PRINT CONT LIST CLR CMD SYS OPEN CLOSE GET NEW TO THEN NOT STEP AND OR GO ELSE"
    str kw_stmtx = "VPOKE SCREEN PSET LINE FRAME RECT CIRCLE CHAR MOUSE COLOR LOCATE CLS DOS OLD MON VLOAD BLOAD BSAVE BVERIFY BOOT RESET KEY BANK MENU FONT"
    str kw_func  = "SGN INT ABS USR FRE POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN VAL ASC TAB SPC FN STR$ CHR$ LEFT$ RIGHT$ MID$ VPEEK HEX$ BIN$"

    sub probe() -> ubyte {
        ; entry ($A009). Returns PROBE_MAGIC and nothing else. tview calls this ONCE after load
        ; and only enables coloring if it gets the magic back, which proves three things at once:
        ; the .ovl loaded, the jump table really is at its fixed offsets, and the bank-to-bank
        ; JSRFAR works on this machine. Any of those failing degrades to plain text instead of
        ; JSRFARing into an unloaded bank.
        return PROBE_MAGIC
    }

    ; shared input-history ring lives in the miscutil overlay (bank 3); bank-to-bank JSRFAR is legal
    ; (the limit is data visibility, not the call). We use ONLY the two cwd-SAFE ops - hist_get
    ; (recall) and hist_store (accept). hist_load/hist_save chdir, which would pull the cwd out from
    ; under the viewer's relative f_open(namebuf), so MAIN runs those around view_file and hands us
    ; the primed count.
    extsub @bank 3 $A00C = hist_store(uword sptr @R0) -> ubyte @A
    extsub @bank 3 $A012 = hist_get(ubyte slot @R0, uword out @R1)

    sub find_recall_hint() {
        ; UP-arrow = recall hint, right-justified on the Find row. Drawn ONLY when history exists, so
        ; we never advertise a key that would do nothing. The caller re-plots to the field afterwards.
        txt.plot(70, shared.VIEW_BOT)
        txt.print(petscii:"↑ Recent")
    }

    sub read_find(uword outptr @R0, ubyte histcount @R1) -> ubyte {
        ; entry ($A00F). Read a search term on the viewer's footer row and write it to outptr
        ; (MAIN RAM - tview's own buffers are in bank 2 and invisible here). Returns the length;
        ; 0 means cancelled or empty. Lives in this bank purely to reclaim space in tview's, which
        ; ran out entirely; it is viewer chrome, not syntax coloring.
        ;
        ; histcount = primed "viewfind" history entries (main called hist_load first), or 255 when
        ; history is unavailable (bank 3 not loaded) -> UP does nothing and we never call into it.
        ; Capture BOTH @Rn params up front, before any strings/txt call clobbers r0-r3.
        ;
        ; Keys are stored RAW, exactly as tview did it. They arrive as PETSCII, while file content
        ; is ASCII - tview's view_fold reconciles the two (PETSCII 'a' $41 +$20 -> $61 = ASCII 'a',
        ; and ASCII $61 is already $61). Folding here would break that.
        uword outp = outptr
        ubyte hcount = histcount
        bool hist_on = hcount != 255
        if not hist_on
            hcount = 0
        ubyte hsel = 255                ; recall cursor: 255 = nothing recalled yet
        ; Clear BOTH footer bars, not just the prompt row: leaving the key bar above it made the
        ; prompt look like it had been dropped on top of the footer. The caller (tview) repaints
        ; the whole footer when we return, so blanking here costs nothing.
        bar_fill(FOOT1)
        bar_fill(shared.VIEW_BOT)
        txt.plot(0, shared.VIEW_BOT)
        ; petscii: overrides this module's iso default - the viewer runs in the PETSCII charset,
        ; so an ISO-encoded literal would come out as garbage glyphs through txt.print.
        txt.print(petscii:" Find: ")
        if hist_on and hcount != 0
            find_recall_hint()          ; advertise UP=recall when there's something to recall
        ubyte n = 0
        @(outp) = 0
        txt.plot(7, shared.VIEW_BOT)
        repeat {
            ubyte k = wait_key()
            if k == 13 {
                @(outp + n) = 0
                if hist_on and n != 0
                    void hist_store(outp)   ; add to the ring (bank 3, in-memory, cwd-safe); main saves
                return n
            }
            if k == 27 or k == 3 {
                @(outp) = 0                 ; cancelled -> no active term (hides the Space hint)
                return 0
            }
            if k == 20 {                    ; backspace
                if n != 0 {
                    n--
                    @(outp + n) = 0
                    txt.plot(7 + n, shared.VIEW_BOT)
                    txt.spc()
                    txt.plot(7 + n, shared.VIEW_BOT)
                }
            } else if k == 145 {            ; up-arrow: recall an earlier find term (inline cycle)
                if hist_on and hcount != 0 {
                    if hsel == 255
                        hsel = 0
                    else {
                        hsel++
                        if hsel >= hcount
                            hsel = 0
                    }
                    hist_get(hsel, outp)    ; bank 3: copy ring slot -> outp (cwd-safe memory copy)
                    n = 0
                    while @(outp + n) != 0 and n < 32
                        n++
                    bar_fill(shared.VIEW_BOT)          ; repaint prompt + recalled term
                    txt.plot(0, shared.VIEW_BOT)
                    txt.print(petscii:" Find: ")
                    find_recall_hint()                 ; still recalling -> history exists, always show
                    txt.plot(7, shared.VIEW_BOT)
                    ubyte pi = 0
                    while pi < n {
                        txt.chrout(@(outp + pi))
                        pi++
                    }
                }
            } else {
                if k >= $c1 and k <= $da
                    k -= $80
                if n < 32 and k >= 32 and k < 127 {
                    @(outp + n) = k
                    txt.chrout(k)
                    n++
                }
            }
        }
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    ; ---- viewer footer (both bars) --------------------------------------------------------------
    ; Lives here for the same reason read_find does: it is viewer CHROME, not syntax coloring, and
    ; tview's bank is completely full. All the label text, the status block and their layout are in
    ; this bank; tview just reports its state and we paint. Freed ~980 bytes of bank 2.
    ;
    ; EVERY literal below needs the `petscii:` prefix: this module is %encoding iso (for the ASCII
    ; source it colorizes), but the viewer's screen runs the PETSCII charset, where the letter cases
    ; are swapped relative to ISO. Without it the footer comes out as "pGdN/pGuP  tOP  bOTTOM".
    ;
    ; flags bits: 0 = hex mode, 1 = at EOF, 2 = coloring available (advertise C), 3 = walking a
    ; tagged set (SPACE steps files), 4 = ZSM breakout page.
    const ubyte FOOT1 = shared.VIEW_FOOT1
    const ubyte FOOT2 = shared.VIEW_FOOT2
    const ubyte FF_HEX   = %00000001
    const ubyte FF_EOF   = %00000010
    const ubyte FF_COLOR = %00000100
    const ubyte FF_SET   = %00001000
    const ubyte FF_ZSM   = %00010000
    const ubyte FF_WRAP  = %01100000    ; 2-bit wrap mode in bits 5-6 (0 char, 1 word, 2 off), NOT a
                                        ; flag - it rides the spare bits of this byte so the entry
                                        ; keeps its parameter list and its jmptable slot unchanged

    sub draw_footer(ubyte flags @R0, ubyte setnum @R1, ubyte settot @R2,
                    uword offlo @R3, ubyte offhi @R4, uword blocks @R5) {
        ; entry ($A012). Capture every @Rn param before the first txt call clobbers r0-r5.
        ; The position is a BYTE OFFSET (top of the current page, or the hex cursor) - not a page
        ; number. A page index is meaningless in a binary dump and barely moves while reading, and
        ; tracking a true page number across the viewer's sliding page cache needed a whole extra
        ; counter; an offset is exact, self-evident and free. `blocks` (the directory entry's size,
        ; 0 = unknown) turns it into a percentage as well, which is what you actually read while
        ; paging - a bare hex offset gives no sense of how far in you are or when you are at the end.
        ubyte fl = flags
        ubyte snum = setnum
        ubyte stot = settot
        uword olo = offlo
        ubyte ohi = offhi
        uword blks = blocks

        bar_fill(FOOT1)
        txt.plot(0, FOOT1)
        txt.spc()
        bar_key(petscii:"PgDn/PgUp")
        txt.print(petscii:"  ")
        bar_key(petscii:"T")
        txt.print(petscii:"op  ")
        bar_key(petscii:"B")
        txt.print(petscii:"ottom  ")
        bar_key(petscii:"H")                        ; H toggles hex<->text in BOTH directions (T is Top!)
        if fl & FF_HEX != 0
            txt.print(petscii:" text  ")
        else
            txt.print(petscii:"ex  ")
        bar_key(petscii:"I")
        txt.print(petscii:"SO  ")
        ; Wrap only means something on the TEXT page - the hex dump and the ZSM header are fixed
        ; layouts - so the key is advertised only where it does something.
        if fl & (FF_HEX | FF_ZSM) == 0 {
            bar_key(petscii:"W")
            when (fl & FF_WRAP) >> 5 {
                1 -> txt.print(petscii:"rap word  ")
                2 -> txt.print(petscii:"rap off  ")
                else -> txt.print(petscii:"rap char  ")
            }
        }
        if fl & FF_COLOR != 0 {
            bar_key(petscii:"C")
            txt.print(petscii:"olor  ")
        }
        bar_key(petscii:"Esc")
        txt.print(petscii:" Quit")

        bar_fill(FOOT2)
        txt.plot(0, FOOT2)
        txt.spc()
        bar_key(petscii:"F")
        txt.print(petscii:"ind  ")
        bar_key(petscii:"N")
        txt.print(petscii:"/")
        bar_key(petscii:"Space")
        txt.print(petscii:" Next match")
        if fl & FF_SET != 0 {                   ; walking a tagged set: +/- step between FILES
            txt.print(petscii:"  ")
            bar_key(petscii:"+/-")
            txt.print(petscii:" File")
        }

        ; Status block, RIGHT-JUSTIFIED so it ends at col 77 (never 79 - that would auto-scroll the
        ; bottom row). Reads "File 2/6  Ofs $01a2f0" - no padding inside the numbers.
        bool zsm = fl & FF_ZSM != 0 and fl & FF_HEX == 0
        ubyte pct = 255                                 ; 255 = no size known -> print no percentage
        if not zsm and blks != 0
            pct = percent_of(olo, ohi, blks)
        ubyte w = 0
        if fl & FF_SET != 0
            w = 8 + uwidth(snum) + uwidth(stot)         ; "File " 5 + '/' 1 + the 2 spaces after it
        if zsm {
            w += 5                                      ; "[ZSM]" - the breakout is one static page
        } else {
            w += 11                                     ; "Ofs $" + 6 hex digits
            if pct != 255
                w += 3 + uwidth(pct)                    ; "  nn%"
        }
        if fl & FF_EOF != 0 and not zsm
            w += 6                                      ; " (END)"
        txt.plot(78 - w, FOOT2)
        if fl & FF_SET != 0 {
            txt.print(petscii:"File ")
            txt.print_uw(snum)
            txt.chrout('/')
            txt.print_uw(stot)
            txt.print(petscii:"  ")
        }
        if zsm {
            txt.print(petscii:"[ZSM]")
        } else {
            txt.print(petscii:"Ofs $")
            put_hex8(ohi)                   ; 24-bit offset: enough for any X16 file (< 16 MB)
            put_hex8(msb(olo))
            put_hex8(lsb(olo))
            if pct != 255 {
                txt.print(petscii:"  ")
                txt.print_uw(pct)
                txt.chrout(petscii:'%')
            }
        }
        if fl & FF_EOF != 0 and not zsm
            txt.print(petscii:" (END)")
    }

    sub percent_of(uword olo, ubyte ohi, uword blks) -> ubyte {
        ; How far into the file the given 24-bit byte offset is, 0..100.
        ;
        ; Everything is done in 256-BYTE units so it fits uword math: the offset's top two bytes ARE
        ; that value, for free. `blks` is CBM blocks of 254 bytes, so the file is blks*254/256 units
        ; = blks - blks/128. Then both sides are halved until the numerator can take a *100 without
        ; overflowing a uword (any file over ~166 KB), which costs at most a percent of resolution -
        ; invisible in a two-digit readout.
        uword pos = mkword(ohi, msb(olo))
        uword tot = blks - (blks >> 7)
        if tot == 0
            return 0
        if pos >= tot
            return 100                  ; block count is only an estimate - never print 137%
        while tot > 650 {
            tot >>= 1
            pos >>= 1
        }
        if tot == 0
            return 100
        return lsb(pos * 100 / tot)
    }

    sub uwidth(uword v) -> ubyte {
        ; printed decimal width of v, for right-justifying the status block
        if v >= 10000
            return 5
        if v >= 1000
            return 4
        if v >= 100
            return 3
        if v >= 10
            return 2
        return 1
    }

    sub draw_zsm(uword hdrptr @R0) {
        ; A one-screen breakout of a ZSM file's parsed 16-byte header. It lives HERE and not in
        ; tview because bank 2 is full to the byte; this bank had ~3.5 KB spare. It is a pure
        ; drawing routine over 16 bytes of input, which is what makes it movable at all - the
        ; other fat routines in tview (hex render, the find scanner) all read tview's viewbuf,
        ; and that bank's RAM is NOT visible while this one is mapped.
        ;
        ; So the 16 header bytes arrive via a MAIN-RAM pointer: tview stages them in the shared
        ; line buffer it already hands us for syntax coloring. Main RAM stays mapped below $A000
        ; whatever bank is active - the same reason setbufs takes pointers rather than copying.
        ;
        ; Every literal below needs the petscii: prefix. This module is %encoding iso so its
        ; strings are ASCII for the classifier's keyword tables; txt.print wants PETSCII, and
        ; without the prefix the text comes out case-swapped.
        ubyte br
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)     ; content: white on gray, as tview draws it
        for br in shared.VIEW_TOP to shared.VIEW_TOP + shared.VIEW_ROWS - 1
            blank_row(br)

        txt.plot(2, shared.VIEW_TOP + 0)
        txt.print(petscii:"ZSM music file - parsed header")

        txt.plot(2, shared.VIEW_TOP + 2)
        txt.print(petscii:"Version .......... ")
        txt.print_ub(@(hdrptr + 2))

        txt.plot(2, shared.VIEW_TOP + 3)
        txt.print(petscii:"Tick rate ........ ")
        txt.print_uw(mkword(@(hdrptr + 13), @(hdrptr + 12)))     ; LE 16-bit at 0x0c..0d
        txt.print(petscii:" Hz")

        txt.plot(2, shared.VIEW_TOP + 4)
        txt.print(petscii:"Loop point ....... ")
        zsm_addr(hdrptr + 3)

        txt.plot(2, shared.VIEW_TOP + 5)
        txt.print(petscii:"PCM data ......... ")
        zsm_addr(hdrptr + 6)

        txt.plot(2, shared.VIEW_TOP + 6)
        txt.print(petscii:"FM voices (YM) ... ")
        txt.print_ub(popcount(@(hdrptr + 9)))
        txt.print(petscii:"  (mask $")
        put_hex8(@(hdrptr + 9))
        txt.chrout(')')

        txt.plot(2, shared.VIEW_TOP + 7)
        txt.print(petscii:"PSG voices (VERA)  ")
        txt.print_ub(popcount(@(hdrptr + 10)) + popcount(@(hdrptr + 11)))
        txt.print(petscii:"  (mask $")
        put_hex8(@(hdrptr + 11))                                 ; high byte first
        put_hex8(@(hdrptr + 10))
        txt.chrout(')')

        txt.plot(2, shared.VIEW_TOP + 9)
        txt.print(petscii:"Press H for raw hex bytes.")
    }

    sub zsm_addr(uword p) {
        ; "none", or the 24-bit little-endian address at p printed big-endian so it reads normally.
        ; Loop point and PCM offset are the same shape, so they share this.
        if @(p) == 0 and @(p + 1) == 0 and @(p + 2) == 0 {
            txt.print(petscii:"none")
            return
        }
        txt.print(petscii:"yes  ($")
        put_hex8(@(p + 2))
        put_hex8(@(p + 1))
        put_hex8(@(p))
        txt.chrout(')')
    }

    sub blank_row(ubyte row) {
        ; clear cols 0..78 in the CURRENT color (bar_fill above forces the status-bar colors, which
        ; is wrong for the content area). Col 79 is left alone so chrout can't auto-scroll.
        txt.plot(0, row)
        ubyte c
        for c in 0 to 78
            txt.spc()
    }

    sub popcount(ubyte v) -> ubyte {
        ; count the 1-bits in v (the FM/PSG "N voices" come from the channel masks)
        ubyte n = 0
        while v != 0 {
            n += v & 1
            v >>= 1
        }
        return n
    }

    sub put_hex8(ubyte b) {
        txt.chrout(hexdig(b >> 4))
        txt.chrout(hexdig(b & 15))
    }

    sub hexdig(ubyte n) -> ubyte {
        ; petscii: literals - this module defaults to %encoding iso, where 'a' is $61; the viewer's
        ; screen is the PETSCII charset, in which lowercase 'a' is $41. Digits are $30-$39 in both.
        if n < 10
            return petscii:'0' + n
        return petscii:'a' + n - 10
    }

    sub bar_key(str s) {
        ; print a highlighted hotkey (accent on blue), then revert to white-on-blue text
        txt.color2(shared.BAR_KEY, shared.BAR_BG)
        txt.print(s)
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub bar_fill(ubyte row) {
        ; paint a full-width status bar in the viewer's standard blue. setchr/setclr (no cursor
        ; move) so filling col 79 / the bottom row can't trigger the auto-scroll chrout would.
        ubyte c
        for c in 0 to 79 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, (shared.BAR_BG << 4) | shared.BAR_FG)
        }
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub detect(uword nameptr @R0) -> ubyte {
        ; entry ($A00C). Pick a coloring mode from the FILENAME: 0 = off, 1 = BASIC, 2 = Markdown.
        ; nameptr must point into MAIN RAM - tview's own copy of the name is in bank 2, invisible
        ; from here, so it copies the name across before calling.
        ;
        ; This cannot use magic bytes the way tview's ZSM sniffer (or xfmgr's sniff_kind) does:
        ; BASIC source and Markdown are plain text with no signature. A suffix match is the only
        ; option, which is exactly the thing that has bitten this codebase before on filename
        ; encoding - hence name_fold below, and hence the C key, which lets the user override a
        ; wrong guess. It lives in THIS bank purely for space: tview had ~424 bytes to spare.
        uword np = nameptr
        ; ".bas.txt" must be tested FIRST and on its own: a name ending ".bas.txt" does NOT end
        ; with ".bas", so the general BASIC case below would miss it.
        if ends_ci(np, ".bas.txt") or ends_ci(np, ".bas") or ends_ci(np, ".basl") or ends_ci(np, ".bl")
            return 1
        if ends_ci(np, ".md")
            return 2
        return 0
    }

    sub name_fold(ubyte b) -> ubyte {
        ; Canonicalise a FILENAME letter to ASCII lowercase across every encoding the name might
        ; arrive in, so the iso: literals above (already ASCII lowercase) compare equal to all of
        ; them. Deliberately separate from fold(): that one canonicalises file CONTENT, which is
        ; always ASCII, and must not start treating high bytes as letters.
        ;   ascii A-Z ($41-$5a) and petscii a-z (the same $41-$5a) -> +$20
        ;   petscii A-Z ($c1-$da)                                  -> -$60
        ;   ascii a-z ($61-$7a)                                    -> already canonical
        if b >= $41 and b <= $5a
            return b + $20
        if b >= $c1 and b <= $da
            return b - $60
        return b
    }

    sub ends_ci(uword name, str suffix) -> bool {
        ; case- and encoding-insensitive "does name end with suffix?"
        ubyte nl = lsb(strings.length(name))
        ubyte sl = lsb(strings.length(suffix))
        if sl > nl
            return false
        uword np = name + nl - sl
        ubyte i
        for i in 0 to sl - 1 {
            if name_fold(@(np + i)) != name_fold(suffix[i])
                return false
        }
        return true
    }

    sub fold(ubyte b) -> ubyte {
        ; ASCII letters -> lowercase so either case matches; everything else is returned as-is.
        if b >= 'A' and b <= 'Z'
            return b + $20
        return b
    }

    sub is_letter(ubyte b) -> bool {
        return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')
    }

    sub is_digit(ubyte b) -> bool {
        return b >= '0' and b <= '9'
    }

    sub eq(uword a, uword b, ubyte n) -> bool {
        ; compare n bytes case-insensitively (letters folded; '$' etc. compared literally)
        ubyte i
        for i in 0 to n - 1 {
            if fold(@(a + i)) != fold(@(b + i))
                return false
        }
        return true
    }

    sub in_blob(uword blob, uword tp, ubyte tlen) -> bool {
        ; true if token tp[0..tlen) matches a whole space-delimited word in blob (folded).
        ; (s is hoisted - prog8 vars are function-scoped, there is no block scope.)
        ubyte i = 0
        ubyte s
        while @(blob + i) != 0 {
            s = i                                   ; word start
            while @(blob + i) != 0 and @(blob + i) != ' '
                i++
            if (i - s) == tlen and eq(blob + s, tp, tlen)
                return true
            while @(blob + i) == ' '                ; skip the separator(s)
                i++
        }
        return false
    }

    sub lookup(uword tp, ubyte tlen) -> ubyte {
        ; classify an identifier token: 2 = REM (comment), 1 = statement keyword,
        ; 3 = built-in function, 0 = plain.
        if tlen == 3 and eq(tp, rem_kw, 3)
            return 2
        if in_blob(kw_stmt, tp, tlen)
            return 1
        if in_blob(kw_stmtx, tp, tlen)
            return 1
        if in_blob(kw_func, tp, tlen)
            return 3
        return 0
    }

    ; Buffer pointers, handed over once by tview at startup. Both point into MAIN RAM (see the
    ; module header): src_p is the line tview accumulated, col_p is where we write the colors.
    uword src_p
    uword col_p

    sub setbufs(uword src @R0, uword dest @R1) {
        ; entry ($A003), called ONCE. Capture the @Rn params immediately - they ARE cx16.r0-r1.
        src_p = src
        col_p = dest
    }

    sub paint(ubyte slen @R0, ubyte mode @R1, ubyte row @R2, ubyte col @R3, uword mrange @R4) {
        ; entry ($A006). Classify the accumulated line AND paint it. Both halves live here rather
        ; than in tview because tview's bank has ~424 bytes free and this one has ~6 KB - and the
        ; screen is VERA, which is I/O and therefore reachable whichever RAM bank is mapped.
        ;
        ; row/col are where the line's FIRST character was drawn; we re-walk from there with the
        ; same wrap rule tview used, so cell k of the line is cell k of the color buffer.
        ; mrange packs the find-highlight run as line-relative columns (msb = first, lsb = one
        ; past last, equal = no overlap): that highlight is painted by tview's character pass and
        ; must stay ON TOP of syntax color, so those columns are skipped here. Packing it as one
        ; uword keeps the whole thing byte math - the 32-bit file offsets stay on tview's side.
        ubyte nchars = slen             ; not `len` - that is a prog8 builtin
        ubyte m0 = msb(mrange)
        ubyte m1 = lsb(mrange)
        if nchars == 0
            return
        ; `mode` carries the syntax mode in the low nibble and tview's WRAP_* in the high one. The
        ; wrap rule matters here because this walk has to retrace EXACTLY the cells tview drew - it
        ; re-derives each character's screen position rather than being told, so a different rule
        ; here paints the right colors onto the wrong cells.
        ubyte wrapmode = mode >> 4
        ; Word wrap breaks at spaces, and only tview knows where - it decided using a lookahead over
        ; the raw file bytes, which are gone by now. A line that never reached the right edge did not
        ; wrap at all, so it is safe; a longer one is left uncolored rather than colored wrongly.
        if wrapmode == 1 and nchars > shared.VIEW_WIDTH
            return
        if mode & 15 == 2
            md_line(src_p, nchars, col_p)
        else
            basic_line(src_p, nchars, col_p)
        ubyte r = row
        ubyte c = col
        ubyte k
        for k in 0 to nchars - 1 {
            if r >= shared.VIEW_ROWS
                break                       ; the rest of the line is off the bottom of the page
            ; Skip default-colored cells - the row was already blanked to the content color, so
            ; rewriting it would only cost time - and skip the active find hit.
            ubyte a = @(col_p + k)
            if a != shared.SYN_DEFAULT and not (k >= m0 and k < m1)
                txt.setclr(c, shared.VIEW_TOP + r, a)
            c++
            if c >= shared.VIEW_WIDTH {
                if wrapmode == 2
                    break                   ; WRAP_OFF: one row per line, the rest is off-screen
                c = 0
                r++
            }
        }
    }

    sub md_line(uword src, ubyte slen, uword dest) {
        ; Markdown coloring: minimal, two colors. A line whose FIRST character
        ; is '#' (so '#', '##', '###' ... all count) is a heading; every other line is plain body
        ; text. Line-oriented and stateless, like the BASIC path.
        ;
        ; '#' (H1) and '##'-or-deeper (H2) get DIFFERENT colors. The "/#" ESCAPE needs no special
        ; case: an escaped heading starts with '/', not '#', so the first-char test leaves it body-
        ; colored. The '/' is shown verbatim - this is a file VIEWER, so what is on disk is what
        ; is shown; dropping a real byte belongs to a rendered view, not here.
        if slen == 0
            return                          ; guard: `for i in 0 to slen-1` would wrap to 0..255
        ubyte col = shared.SYN_DEFAULT
        if @(src) == '#' {
            col = shared.SYN_KEYWORD                ; '#'  heading
            if slen > 1 and @(src + 1) == '#'
                col = shared.SYN_FUNCTION           ; '##' (or deeper) subheading
        }
        ubyte i
        for i in 0 to slen - 1
            @(dest + i) = col
    }

    sub basic_line(uword src, ubyte slen, uword dest) {
        ; Fill dest[0..slen) with a per-column color byte for the BASIC line at src.
        ubyte i = 0
        ubyte d                             ; scratch lookahead byte (function-scoped in prog8)
        while i < slen {
            ubyte c = @(src + i)
            if c == '"' {                       ; string literal, to the closing quote or EOL
                @(dest + i) = shared.SYN_STRING
                i++
                bool closed = false
                while i < slen and not closed {
                    @(dest + i) = shared.SYN_STRING
                    if @(src + i) == '"'
                        closed = true
                    i++
                }
            } else if c == '#' and i + 1 < slen and @(src + i + 1) == '#' {
                while i < slen {                ; ## -> BASLOAD comment: color the rest of the line
                    @(dest + i) = shared.SYN_COMMENT
                    i++
                }
            } else {
                if is_letter(c) {               ; identifier / keyword / BASLOAD label
                    ubyte ts = i
                    i++
                    while i < slen {
                        d = @(src + i)
                        ; '.' is a legal char INSIDE a BASLOAD label (DIR.READ.BIN.NUM16), so it
                        ; keeps the whole dotted name as ONE token. No keyword contains a '.', so a
                        ; label can never match the tables -> it stays default-colored, and an
                        ; embedded keyword-like fragment (the READ in DIR.READ) is not mis-colored
                        ; as the READ statement.
                        if is_letter(d) or is_digit(d) or d == '.'
                            i++
                        else
                            break
                    }
                    if i < slen and @(src + i) == '$'    ; trailing '$' (string func / var)
                        i++
                    ubyte kind = lookup(src + ts, i - ts)
                    if kind == 2 {              ; REM -> color the rest of the line
                        while ts < slen {
                            @(dest + ts) = shared.SYN_COMMENT
                            ts++
                        }
                        i = slen
                    } else {
                        ubyte col = shared.SYN_DEFAULT
                        if kind == 1
                            col = shared.SYN_KEYWORD
                        if kind == 3
                            col = shared.SYN_FUNCTION
                        while ts < i {
                            @(dest + ts) = col
                            ts++
                        }
                    }
                } else {
                    if is_digit(c) {            ; numeric constant / line number
                        while i < slen {
                            d = @(src + i)
                            if is_digit(d) or d == '.' {
                                @(dest + i) = shared.SYN_NUMBER
                                i++
                            } else
                                break
                        }
                    } else {                    ; operator / punctuation / space
                        @(dest + i) = shared.SYN_DEFAULT
                        i++
                    }
                }
            }
        }
    }
}

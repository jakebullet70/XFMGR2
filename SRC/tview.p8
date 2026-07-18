; tview - standalone read-only paged text/hex file viewer for the Commander X16.
;
; Extracted from XFMGR2's internal viewer (was SRC/xviewer.p8) so XFMGR can drop the
; ~3.1 KB of viewer code from main RAM. Now built as a %output library overlay that XFMGR
; loads into a HIRAM bank and calls via `extsub @bank` (see the overlay notes below).
;
; Controls:  PgDn/PgUp page   T/Home top   H hex<->text   F find   N find-next   Q quit
; The pager uses 32-bit (long) file offsets: hex mode reaches any offset; text mode caches up
; to 64 page-tops (~140 KB of dense content) for backward paging.
;
; Call contract: the caller (XFMGR) chdir's into the file's directory, keeps the screen in
; mode $01, then calls view_file(nameptr @R0); the filename is copied in on entry. On return
; the caller repaints. Text mode caches 64 page-tops (backward paging spans ~140 KB of dense
; content); hex mode reaches any offset in the file.

%import textio
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header
%import strings
%import "shared-const"
; --- loadable-library overlay: headerless blob loaded at $A000 into a HIRAM bank and
;     called via `extsub @bank`. %output library => no zeropage / no sysinit / jmp start
;     entry; %memtop hard-fails the build if the overlay outgrows the $A000-$BFFF window.
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table so callable entry offsets stay fixed across rebuilds. The compiler prepends
    ; `jmp start` at $A000 (library init), so: $A000 = start (init), $A003 = view_file,
    ; $A006 = view_set_syn.
    %jmptable ( main.view_file, main.view_set_syn )

    ; --- syntax coloring, in ANOTHER bank (xsyntax.p8, bank 9) ---
    ; We are ourselves a bank overlay, and we call out to a second one. That is legal: the X16
    ; KERNAL's JSRFAR - which is what prog8 emits for `extsub @bank` - "works independently of
    ; which RAM or ROM bank the currently executing code is residing in" (X16 Reference - 05 -
    ; KERNAL, $FF6E). It is done ONCE PER RENDERED LINE (<=28 per page), so the cost is noise
    ; next to the disk read this renderer already does.
    ;
    ; WHY NOT JUST PUT IT IN HERE: this overlay has ~424 bytes free to $C000 and the colorizer
    ; is ~1.8 KB. Bank 9 also gives it room to grow.
    ;
    ; THE RULE THAT SHAPES EVERYTHING BELOW: while bank 9 is mapped, OUR OWN bank-2 RAM is not
    ; visible - so viewbuf and friends are unreachable from there. The line and color buffers
    ; must therefore live in MAIN RAM (mapped below $A000 regardless of bank); xfmgr owns them
    ; and hands us the pointers via view_set_syn.
    const ubyte SYN_BANK = 9
    extsub @bank 9 $A003 = syn_setbufs(uword src @R0, uword dest @R1)
    extsub @bank 9 $A006 = syn_paint(ubyte slen @R0, ubyte mode @R1, ubyte row @R2, ubyte col @R3, uword mrange @R4)
    extsub @bank 9 $A009 = syn_probe() -> ubyte @A
    extsub @bank 9 $A00C = syn_detect_ovl(uword nameptr @R0) -> ubyte @A
    extsub @bank 9 $A00F = syn_read_find(uword outptr @R0) -> ubyte @A
    const ubyte SYN_PROBE_MAGIC = $5a   ; must match syntax.PROBE_MAGIC in xsyntax.p8

    ; Geometry now lives in shared-const so xsyntax's color pass walks the SAME cells this
    ; renderer drew (it re-derives the wrap from these); aliased here to keep the short names.
    const ubyte VTOP   = shared.VIEW_TOP    ; first text row (row 0 = header)
    const ubyte VROWS  = shared.VIEW_ROWS   ; text rows 1..28
    const ubyte VWIDTH = shared.VIEW_WIDTH  ; wrap column (keep off col 79 to avoid auto-scroll)
    const ubyte SCR_BOT = 29           ; footer row
    const uword HEXPAGE = VROWS * 16   ; bytes shown per hex page (VROWS rows x 16 bytes)

    ; status-bar + content colors now live in SRC/shared-const.p8 (block `shared`), shared
    ; with XFMGR; referenced as shared.* below. Standard blue bar, white text; the bottom-menu
    ; hotkey highlight is BLACK.

    ; --- shared scratch (in XFMGR these lived in the main module) ---
    ; NOTE: these MUST stay uninitialized (no "= ..."). %jmptable relies on `jmp view_file`
    ; landing at $A003 (right after the compiler's `jmp start` at $A000). prog8 emits a
    ; block's INITIALIZED variables inline BEFORE its code/jumptable, which would shove the
    ; jump table down and make extsub $A003 call into the data. Uninitialized vars go to the
    ; relocated BSS section at the tail instead, keeping the jump table at $A003.
    ubyte[256] viewbuf                 ; read buffer (viewer reads up to 250 bytes/call)
    ubyte[81] namebuf                  ; the file to view (80 chars + NUL); filled per call
    ubyte g_key                        ; last key read

    ; --- viewer state ---
    ; file offset of the top of each visited page, so paging can go both forward and backward by
    ; re-reading from a known offset. 32-bit (long) offsets; prog8 caps long arrays at 64, so text
    ; mode caches up to 64 page-tops (~140 KB of dense content). Hex mode uses a single long -> no cap.
    long[64] view_pages
    bool view_eof                      ; the last rendered page reached end-of-file
    bool view_hex                      ; viewer showing hex dump (vs text)
    long view_off                      ; hex-mode current page top offset
    ubyte view_page                    ; text-mode current page index
    ubyte view_known                   ; text-mode highest page index with a known offset
    ubyte[34] view_find                ; in-file search term (<= 32 chars + NUL); uninit -> BSS
    long view_next                     ; offset to resume "find next" from
    long view_match                    ; offset of the last search hit
    ubyte saved_page                   ; text page stashed across a hex excursion (H toggle)
    long hex_entry_off                 ; view_off on entering hex; unchanged on return -> restore saved_page

    ; --- ZSM header breakout (parsed music-file view) ---
    ; is_zsm/zsm_hdr MUST stay uninitialized (no "= ...") like the buffers above, so they land in
    ; the relocated BSS tail and don't shove the jmptable off $A003. zsm_detect() sets them.
    bool is_zsm                        ; current file starts with the ZSM 'zm' magic
    ubyte[16] zsm_hdr                  ; the 16 raw header bytes, read once per file

    ; --- syntax coloring state (all UNINITIALIZED -> BSS tail, per the jmptable rule above) ---
    bool syn_avail                     ; xsyntax.ovl loaded AND its probe answered -> safe to call
    uword syn_line_p                   ; main-RAM buffer we accumulate one logical line into
                                       ; (the color buffer's pointer is forwarded straight to
                                       ; xsyntax, which is the only side that ever reads it)
    ubyte syn_mode                     ; 0 = off, 1 = BASIC/BASLOAD, 2 = Markdown
    ubyte syn_auto                     ; mode C switches back ON to: the detected one, else BASIC
    ; per-logical-line accumulator. The anchor (row/col/off) is captured lazily at the line's FIRST
    ; drawn character, which is what makes CR/LF pairs, blank lines and a page-boundary split all
    ; fall out correctly without special cases.
    ubyte ln_len                       ; bytes accumulated so far (capped at shared.SYN_LINE_MAX)
    ubyte ln_row                       ; screen row (0-based within the text area) of the line's 1st char
    ubyte ln_col                       ; screen column of the line's 1st char
    ; Find-highlight run for the current line, as line-relative COLUMNS (m0 == m1 -> none). The
    ; draw loop already does a 32-bit "is this byte inside the search hit?" test per character to
    ; paint that highlight, so we just piggyback on its answer and note the column. That keeps ALL
    ; the syntax path's arithmetic 8-bit - the 32-bit version of this cost ~600 bytes of an overlay
    ; that only had 424 to spare.
    ubyte syn_m0
    ubyte syn_m1

    sub start() {
        ; library init entrypoint ($A000). The compiler emits the BSS-clear here; this must
        ; do NO UI or system init (the caller/XFMGR owns the screen). Call ONCE after load.
    }

    sub view_file(uword nameptr @R0) {
        ; real entry ($A003 via the jmptable). Copy the filename FIRST - diskio/strings
        ; calls clobber cx16.r0-r3, so consume the @R0 pointer before anything else.
        ; The caller keeps XFMGR in screen mode $01 and repaints after we return.
        void strings.copy(nameptr, namebuf)
        zsm_detect()                    ; set is_zsm + fill zsm_hdr before the view loop
        syn_detect()                    ; pick BASIC/Markdown/off from the file extension
        view_run()
    }

    sub view_set_syn(ubyte ok @R0, uword lineptr @R1, uword colptr @R2) {
        ; entry ($A006), called ONCE at startup. Capture the @Rn params before anything else (they
        ; ARE cx16.r0-r2). `ok` is xfmgr's loadlib result for xsyntax.ovl - we must not JSRFAR into
        ; bank 9 unless it says the blob is there. Given that, we then ask the overlay to identify
        ; itself: only a correct magic proves the jump table really is at its fixed offsets AND
        ; that a bank-to-bank call works on this machine. Anything else -> plain text, no color.
        ubyte lok = ok
        uword lcol = colptr
        syn_line_p = lineptr
        syn_avail = false
        syn_mode = 0
        if lok != 0 and syn_line_p != 0 and lcol != 0 {
            syn_avail = syn_probe() == SYN_PROBE_MAGIC
            if syn_avail
                syn_setbufs(syn_line_p, lcol)   ; hand the overlay the shared buffers once
        }
    }

    sub syn_detect() {
        ; Ask xsyntax to pick the coloring mode from the extension. The matching itself lives in
        ; bank 9 (space - this overlay had ~424 bytes free), and since bank 9 cannot see OUR RAM,
        ; the name has to be staged into the shared main-RAM buffer first. Safe to borrow it here:
        ; it only holds accumulated lines during a render, and nothing has rendered yet.
        syn_mode = 0
        syn_auto = 1                ; unrecognised extension -> C forces BASIC, the useful default
        if syn_avail {
            void strings.copy(namebuf, syn_line_p)
            syn_mode = syn_detect_ovl(syn_line_p)
            if syn_mode != 0
                syn_auto = syn_mode
        }
    }

    sub syn_flush() {
        ; Hand the logical line we just drew to xsyntax, which classifies AND paints it. The
        ; find-highlight columns were recorded by the draw loop as it went (see syn_m0/syn_m1),
        ; so there is nothing to compute here.
        if ln_len != 0
            syn_paint(ln_len, syn_mode, ln_row, ln_col, mkword(syn_m0, syn_m1))
        ln_len = 0
        syn_m0 = 0
        syn_m1 = 0
    }

    sub zsm_detect() {
        ; Read the first 16 bytes of namebuf into zsm_hdr and set is_zsm if the file starts with
        ; the ZSM magic (0x7A 0x6D = "zm"). A file that won't open or is shorter than 16 bytes is
        ; treated as non-ZSM. Hex literals (not 'z'/'m') dodge any PETSCII/ASCII source ambiguity.
        is_zsm = false
        ubyte i
        for i in 0 to 15                ; deterministic bytes even on a short read
            zsm_hdr[i] = 0
        if not diskio.f_open(namebuf)
            return
        ubyte got = lsb(diskio.f_read(&zsm_hdr, 16))
        diskio.f_close()
        if got >= 16 and zsm_hdr[0] == $7a and zsm_hdr[1] == $6d
            is_zsm = true
    }

    ; ---------- shared helpers (ported from XFMGR's main module) ----------

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
    }

    sub bar_fill(ubyte row) {
        ; paint a full-width status bar (cols 0..79) in our standard blue. Uses setchr/setclr
        ; (direct, no cursor move) so it can safely fill col 79 / the bottom row without the
        ; auto-scroll that chrout would cause there. Leaves the cursor color at white-on-blue.
        ubyte c
        for c in 0 to 79 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, (shared.BAR_BG << 4) | shared.BAR_FG)   ; $e1 = blue bg / white fg
        }
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub bar_key(str s) {
        ; print a highlighted hotkey (accent on blue), then revert to white-on-blue text
        txt.color2(shared.BAR_KEY, shared.BAR_BG)
        txt.print(s)
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub print_trunc(str s, ubyte maxlen) {
        ubyte i = 0
        while i < maxlen and s[i] != 0 {
            txt.chrout(s[i])
            i++
        }
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub scr_of(ubyte b) -> ubyte {
        ; ASCII (already clamped to $20..$7E) -> screen code for setchr, which writes the screen
        ; matrix directly (no PETSCII interpretation -> no control-code scroll). The viewer runs
        ; in the PETSCII-LOWERCASE charset (txt.lowercase), where sc $01..$1A are lowercase a-z and
        ; sc $41..$5A are uppercase A-Z. So: a-z fold DOWN to $01..$1A, A-Z are already their own
        ; screen codes ($41..$5A) and stay put, and space/digits/punctuation ($20..$3F) map 1:1.
        ; (The old blanket "$40-$5F -$40 / $60-$7E -$20" fold SWAPPED letter case.)
        if b >= $61 and b <= $7A
            return b - $60              ; a-z -> $01..$1A (lowercase glyphs)
        if b >= $41 and b <= $5A
            return b                    ; A-Z -> $41..$5A (uppercase glyphs, unchanged)
        if b < $40
            return b                    ; $20..$3F: space, digits, punctuation - identical
        return b - $40                  ; @ ($40->$00), [ \ ] ^ _ ($5B-$5F -> $1B-$1F)
    }

    ; ---------- text page render ----------

    sub view_render(long start_off, bool draw) -> long {
        ; Walk one page of text starting at byte offset start_off; return the offset where
        ; the next page begins, and set view_eof if end-of-file was reached on this page.
        ; When draw is false this only MEASURES the page (no screen output) - used to rebuild
        ; the page chain when jumping to a search hit, so PgUp still works afterwards.
        view_eof = false
        ubyte br
        if draw {
            txt.color2(shared.BAR_FG, shared.CONTENT_BG)  ; content: white on gray
            for br in VTOP to VTOP + VROWS - 1
                blank_span(0, 78, br)
        }

        if not diskio.f_open(namebuf) {
            if draw {
                txt.plot(0, VTOP)
                txt.print("cannot open file.")
            }
            view_eof = true
            return start_off
        }
        ; skip to start_off by reading and discarding; remember the last skipped byte so a CR/LF
        ; line ending straddling the page boundary is handled (see the prev_cr priming below)
        long toskip = start_off
        ubyte lastskip = 0
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            lastskip = viewbuf[lsb(got) - 1]
            toskip -= got
        }

        long consumed = start_off
        ubyte row = 0
        ubyte col = 0
        ; if the previous page ended on a CR, a leading LF here is that CR/LF pair's tail - prime
        ; prev_cr so it is swallowed instead of drawing a blank first content line
        bool prev_cr = lastskip == 13
        bool full = false
        ; found-text highlight: bytes [view_match, view_match+plen) get the find color via setclr
        ubyte plen = lsb(strings.length(view_find))
        long mend = view_match + plen
        ; syntax coloring: on only for a real draw of a recognised file type. Cached into module
        ; vars because syn_flush() runs outside this sub's scope.
        ; (syn_m0/syn_m1 need no reset here - syn_flush clears them after every line, and every
        ; page ends with a flush, so they are already zero on entry.)
        bool docolor = draw and syn_avail and syn_mode != 0
        ln_len = 0
        repeat {
            uword n = diskio.f_read(&viewbuf, 250)
            if n == 0 {
                view_eof = true
                break
            }
            ubyte cnt = lsb(n)
            ubyte j
            for j in 0 to cnt-1 {
                ubyte ch = viewbuf[j]
                consumed++
                if ch == 10 and prev_cr {
                    prev_cr = false             ; swallow the LF of a CR/LF pair
                    continue
                }
                prev_cr = false
                if ch == 13 or ch == 10 {
                    if ch == 13
                        prev_cr = true
                    if docolor
                        syn_flush()         ; end of a logical line -> color what we just drew
                    row++
                    col = 0
                    if row >= VROWS {
                        full = true
                        break
                    }
                } else {
                    if ch < 32 or ch > 126
                        ch = '.'
                    if docolor {
                        ; Anchor the line lazily at its FIRST drawn char. Doing it here rather than
                        ; at the CR/LF handler is what makes CR/LF pairs (the LF is swallowed
                        ; earlier by `continue`), blank lines, and a page starting mid-line all work
                        ; without special-casing any of them.
                        if ln_len == 0 {
                            ln_row = row
                            ln_col = col
                        }
                        ; Store the CLAMPED byte so column k of the buffer is exactly the glyph in
                        ; column k on screen. Past the cap we keep drawing; the tail stays default.
                        if ln_len < shared.SYN_LINE_MAX {
                            @(syn_line_p + ln_len) = ch
                            ln_len++
                        }
                    }
                    if draw {
                        ; setchr writes the screen code straight to VRAM - no PETSCII control-code
                        ; interpretation, so no byte value can scroll the view. setclr paints only
                        ; the find-highlight cells; the rest keep the blanked content color.
                        txt.setchr(col, VTOP + row, scr_of(ch))
                        if plen != 0 and consumed-1 >= view_match and consumed-1 < mend {
                            txt.setclr(col, VTOP + row, (shared.FIND_BG << 4) | shared.FIND_FG)
                            ; Reuse this 32-bit verdict to note the hit's line-relative columns, so
                            ; the syntax pass can leave those cells alone without repeating the math.
                            ; ln_len was already bumped for this byte, so its index is ln_len-1.
                            if docolor and ln_len != 0 {
                                if syn_m0 == syn_m1
                                    syn_m0 = ln_len - 1     ; first hit cell on this line
                                syn_m1 = ln_len             ; one past the last so far
                            }
                        }
                    }
                    col++
                    if col >= VWIDTH {
                        row++
                        col = 0
                        if row >= VROWS {
                            full = true
                            break
                        }
                    }
                }
            }
            if full
                break
        }
        ; Color the last line, which ends at EOF or at the page break rather than a CR/LF (a line
        ; terminated normally has already flushed itself, leaving ln_len 0 -> this is a no-op).
        if docolor
            syn_flush()
        diskio.f_close()
        return consumed
    }

    ; ---------- hex dump ----------

    sub hex_digit(ubyte v) -> ubyte {
        if v < 10
            return '0' + v
        return 'a' + (v - 10)           ; source 'a' = $41 -> shows as A..F
    }

    sub put_hex8(ubyte b) {
        txt.chrout(hex_digit(b >> 4))
        txt.chrout(hex_digit(b & 15))
    }

    sub put_hex16(uword w) {
        put_hex8(msb(w))
        put_hex8(lsb(w))
    }

    sub put_hex24(long v) {
        ; 6 hex digits (24-bit) - enough for any X16 file offset (< 16 MB)
        put_hex8((v >> 16) as ubyte)
        put_hex8((v >> 8) as ubyte)
        put_hex8(v as ubyte)
    }

    sub view_render_hex(long start_off) -> long {
        ; draw one hex page (VROWS rows of 16 bytes) from start_off; return the next page
        ; offset and set view_eof at end-of-file. Header/footer untouched (no flicker).
        view_eof = false
        ubyte br
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)     ; content: white on gray
        for br in VTOP to VTOP + VROWS - 1
            blank_span(0, 78, br)
        if not diskio.f_open(namebuf) {
            txt.plot(0, VTOP)
            txt.print("cannot open file.")
            view_eof = true
            return start_off
        }
        long toskip = start_off
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        long off = start_off
        ubyte row = 0
        repeat {
            ubyte cnt = lsb(diskio.f_read(&viewbuf, 16))
            if cnt == 0 {
                view_eof = true
                break
            }
            txt.plot(0, VTOP + row)
            put_hex24(off)
            txt.print(": ")
            ubyte i
            for i in 0 to 15 {
                if i < cnt {
                    put_hex8(viewbuf[i])
                    txt.spc()
                } else {
                    txt.print("   ")
                }
            }
            txt.spc()
            for i in 0 to cnt-1 {
                ubyte ch = viewbuf[i]
                if ch < 32 or ch > 126
                    ch = '.'
                txt.setchr(57 + i, VTOP + row, scr_of(ch))   ; ascii col = 57 (6+2+48+1); setchr, not chrout
            }
            off += cnt
            row++
            if cnt < 16 {                   ; short read = end of file
                view_eof = true
                break
            }
            if row >= VROWS
                break
        }
        diskio.f_close()
        return off
    }

    sub popcount(ubyte v) -> ubyte {
        ; count the 1-bits in v (used for the FM/PSG "N voices" from the channel masks)
        ubyte n = 0
        while v != 0 {
            n += v & 1
            v >>= 1
        }
        return n
    }

    sub view_render_zsm() -> long {
        ; Draw a single-screen "header breakout" of the parsed 16-byte ZSM header already captured
        ; in zsm_hdr[]. A static page: set view_eof so the paging keys are no-ops (PgDn is guarded
        ; by 'if not view_eof'; PgUp/Top land back here). The return value is unused.
        view_eof = true
        ubyte br
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)     ; content: white on gray (matches the other renderers)
        for br in VTOP to VTOP + VROWS - 1
            blank_span(0, 78, br)

        txt.plot(2, VTOP + 0)
        txt.print("ZSM music file - parsed header")

        txt.plot(2, VTOP + 2)
        txt.print("Version .......... ")
        txt.print_ub(zsm_hdr[2])

        txt.plot(2, VTOP + 3)
        txt.print("Tick rate ........ ")
        txt.print_uw(mkword(zsm_hdr[13], zsm_hdr[12]))   ; LE 16-bit at 0x0c..0d
        txt.print(" Hz")

        txt.plot(2, VTOP + 4)
        txt.print("Loop point ....... ")
        if zsm_hdr[3] == 0 and zsm_hdr[4] == 0 and zsm_hdr[5] == 0 {
            txt.print("none")
        } else {
            txt.print("yes  ($")
            put_hex8(zsm_hdr[5])                          ; high->low so the hex reads big-endian
            put_hex8(zsm_hdr[4])
            put_hex8(zsm_hdr[3])
            txt.chrout(')')
        }

        txt.plot(2, VTOP + 5)
        txt.print("PCM data ......... ")
        if zsm_hdr[6] == 0 and zsm_hdr[7] == 0 and zsm_hdr[8] == 0 {
            txt.print("none")
        } else {
            txt.print("yes  ($")
            put_hex8(zsm_hdr[8])
            put_hex8(zsm_hdr[7])
            put_hex8(zsm_hdr[6])
            txt.chrout(')')
        }

        txt.plot(2, VTOP + 6)
        txt.print("FM voices (YM) ... ")
        txt.print_ub(popcount(zsm_hdr[9]))
        txt.print("  (mask $")
        put_hex8(zsm_hdr[9])
        txt.chrout(')')

        txt.plot(2, VTOP + 7)
        txt.print("PSG voices (VERA)  ")
        txt.print_ub(popcount(zsm_hdr[10]) + popcount(zsm_hdr[11]))
        txt.print("  (mask $")
        put_hex8(zsm_hdr[11])                             ; high byte first
        put_hex8(zsm_hdr[10])
        txt.chrout(')')

        txt.plot(2, VTOP + 9)
        txt.print("Press H for raw hex bytes.")
        return 0
    }

    ; ---------- search ----------

    sub view_fold(ubyte b) -> ubyte {
        ; ASCII case fold A-Z -> a-z (file bytes and search term are both ASCII)
        if b >= $41 and b <= $5a
            return b + $20
        return b
    }

    sub view_find_at(long from) -> bool {
        ; scan the file from byte offset `from` for view_find (case-insensitive). On a hit
        ; set view_match and return true; else false. Naive matcher (fine for short terms).
        ubyte plen = lsb(strings.length(view_find))
        if plen == 0
            return false
        ; scanning the whole file can take a moment on big files - show progress
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Working...")
        if not diskio.f_open(namebuf)
            return false
        long toskip = from
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        long pos = from
        ubyte mi = 0
        bool found = false
        repeat {
            ubyte cnt = lsb(diskio.f_read(&viewbuf, 250))
            if cnt == 0
                break
            ubyte j
            for j in 0 to cnt-1 {
                ubyte b = view_fold(viewbuf[j])
                if b == view_fold(view_find[mi]) {
                    mi++
                    if mi == plen {
                        view_match = pos - plen + 1
                        found = true
                        break
                    }
                } else {
                    mi = 0
                    if b == view_fold(view_find[0])
                        mi = 1
                }
                pos++
            }
            if found
                break
        }
        diskio.f_close()
        return found
    }

    sub view_read_find() -> bool {
        ; Read a search term on the footer row; false if cancelled or empty. The prompt itself
        ; lives in bank 9 (see syn_read_find) - this overlay had literally run out of space. It
        ; writes into the shared main-RAM buffer, which is the only memory both banks can see, and
        ; we copy the result into view_find here.
        ;
        ; Borrowing syn_line_p is safe: it only holds accumulated lines DURING a render, and F is
        ; dispatched from view_run's key loop, between renders.
        view_find[0] = 0
        if not syn_avail
            return false            ; no bank 9 -> no prompt (F silently does nothing)
        if syn_read_find(syn_line_p) == 0
            return false
        void strings.copy(syn_line_p, view_find)
        return true
    }

    sub view_notify(str m) {
        ; brief footer message (auto-dismissed by the next footer repaint)
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(m)
        sys.wait(75)
    }

    sub view_jump() {
        ; point the current view (hex or text) at the last search hit
        view_next = view_match + 1
        if view_hex {
            view_off = view_match - (view_match & 15)   ; align down to the 16-byte hex row
        } else {
            view_seek_page(view_match)
        }
    }

    sub view_seek_page(long target) {
        ; Rebuild the text page chain from the top of the file up to the page that contains
        ; byte offset `target`, leaving view_page on that page. This keeps every earlier page
        ; known, so PgUp still scrolls back above a search hit (instead of dead-ending).
        view_pages[0] = 0
        view_page = 0
        view_known = 0
        repeat {
            long nxt = view_render(view_pages[view_page], false)
            if view_eof
                break
            if target < nxt
                break
            if view_page + 1 >= 64
                break
            view_pages[view_page+1] = nxt
            view_known = view_page + 1
            view_page++
        }
    }

    sub file_len() -> long {
        ; total file size in bytes (32-bit). Used to land hex mode on the last page.
        if not diskio.f_open(namebuf)
            return 0
        long total = 0
        repeat {
            uword n = diskio.f_read(&viewbuf, 250)
            if n == 0
                break
            total += n
        }
        diskio.f_close()
        return total
    }

    sub view_bottom() {
        ; jump to the last page. Text: walk the page chain (measuring, no draw) until EOF and
        ; stop on the last page that holds content. Hex: align view_off to the final page.
        ; This re-reads the whole file, so on a big file it takes a moment - show a "Working"
        ; note on the footer so the viewer doesn't look hung. It stays up through the scan and
        ; the final page render, then the main loop's footer repaint clears it.
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Working...")
        if view_hex {
            long sz = file_len()
            view_off = 0
            while sz - view_off > HEXPAGE
                view_off += HEXPAGE
        } else {
            view_pages[0] = 0
            view_page = 0
            view_known = 0
            long nxt
            repeat {
                nxt = view_render(view_pages[view_page], false)
                if view_eof {
                    ; an empty trailing page (prev page ended exactly on a boundary) -> back up
                    if nxt == view_pages[view_page] and view_page != 0
                        view_page--
                    break
                }
                if view_page + 1 >= 64
                    break
                view_pages[view_page+1] = nxt
                view_known = view_page + 1
                view_page++
            }
        }
    }

    ; ---------- main view loop ----------

    sub view_run() {
        ; clear once on entry and draw the static header bar (row 0); per-page renders
        ; only repaint the body + footer, so the header doesn't flicker.
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)     ; content bg = gray (header bar drawn over row 0 next)
        txt.clear_screen()
        bar_fill(0)                        ; full-width blue header bar
        txt.plot(0, 0)
        txt.print(" VIEW: ")
        print_trunc(namebuf, 60)
        view_hex = false
        view_off = 0
        view_page = 0
        view_known = 0
        view_next = 0
        view_find[0] = 0
        view_pages[0] = 0
        repeat {
            long nxt
            if view_hex
                nxt = view_render_hex(view_off)
            else if is_zsm
                nxt = view_render_zsm()         ; ZSM file: parsed header breakout (static page)
            else
                nxt = view_render(view_pages[view_page], true)
            ; footer status bar (repainted per page): full-width blue, white text, accent keys
            bar_fill(SCR_BOT)
            txt.plot(0, SCR_BOT)
            txt.spc()
            bar_key("PgDn/PgUp")
            txt.print("  ")
            bar_key("T")
            txt.print("op  ")
            bar_key("B")
            txt.print("ottom  ")
            bar_key("H")                    ; H toggles hex<->text in BOTH directions (T is Top!)
            if view_hex
                txt.print(" text  ")        ; in hex mode, H returns to text
            else
                txt.print("ex  ")           ; in text mode, H shows hex
            bar_key("F")
            txt.print("ind  ")
            bar_key("N")
            txt.print("ext  ")
            ; Color toggle, advertised whenever the overlay is loaded - including in hex mode,
            ; where it still works and simply takes effect on return to the text page.
            if syn_avail {
                bar_key("C")
                txt.print("olor  ")
            }
            bar_key("Q")
            txt.print("uit")
            ; Space=find-next hint, shown only while a search term is active (view_find non-empty)
            if view_find[0] != 0 {
                txt.print("   (")
                bar_key("Space")
                txt.print(":Next)")
            }
            ; right-justify the position indicator (page/offset [+ END]) against the right edge.
            ; w = width of what we print; start col 79-w ends it at col 78 - never col 79, which
            ; would auto-scroll the bottom row.
            bool zsm_text = is_zsm and not view_hex     ; showing the parsed ZSM breakout page
            ubyte w
            if view_hex {
                w = 7                        ; "$" + 6 hex digits
            } else if zsm_text {
                w = 5                        ; "[ZSM]"
            } else {
                ubyte pg = view_page + 1     ; pages shown 1-based (index 0..99 -> 1..100)
                w = 4                        ; "pg " + 1 digit
                if pg >= 10
                    w = 5
                if pg >= 100
                    w = 6
            }
            if view_eof and not zsm_text
                w += 6                       ; " (END)" - meaningless for the one-screen breakout
            txt.plot(79 - w, SCR_BOT)
            if view_hex {
                txt.chrout('$')
                put_hex24(view_off)
            } else if zsm_text {
                txt.print("[ZSM]")
            } else {
                txt.print("Pg:")
                txt.print_uw(view_page + 1)
            }
            if view_eof and not zsm_text
                txt.print(" (END)")

            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3, 'q' -> return
                2 -> {                          ; PgDn: next page
                    if not view_eof {
                        if view_hex {
                            view_off += VROWS * 16
                        } else if view_page >= view_known {
                            if view_page + 1 < 64 {
                                view_pages[view_page+1] = nxt
                                view_known = view_page + 1
                                view_page++
                            }
                        } else {
                            view_page++
                        }
                    }
                }
                130 -> {                        ; PgUp ($82): previous page
                    if view_hex {
                        if view_off >= VROWS * 16
                            view_off -= VROWS * 16
                        else
                            view_off = 0
                    } else if view_page != 0 {
                        view_page--
                    }
                }
                't', 19 -> {                    ; T / Home: back to the top
                    if view_hex
                        view_off = 0
                    else
                        view_page = 0
                }
                'b' -> {                        ; B: jump to the last page
                    if not (is_zsm and not view_hex)    ; the ZSM breakout is a single static page
                        view_bottom()
                }
                'h' -> {                        ; toggle hex / text, keeping position
                    if view_hex {
                        ; hex -> text. If the hex offset is untouched since we entered hex, restore
                        ; the exact text page (correct page number + PgUp history preserved). If the
                        ; user paged around in hex, recompute the text page holding the current offset.
                        view_hex = false
                        if view_off == hex_entry_off
                            view_page = saved_page
                        else
                            view_seek_page(view_off)
                    } else {
                        ; text -> hex. Stash the page so a straight there-and-back is exact; align the
                        ; offset down to the 16-byte hex row for display and remember it as the anchor.
                        saved_page = view_page
                        view_off = view_pages[view_page]
                        view_off = view_off - (view_off & 15)
                        hex_entry_off = view_off
                        view_hex = true
                    }
                }
                'f' -> {                        ; find: prompt, ALWAYS search from the top of the file
                    if view_read_find() {
                        if view_find_at(0)
                            view_jump()
                        else
                            view_notify(" not found")
                    }
                }
                'n', ' ' -> {                   ; N or Space: find next, wrapping at end-of-file
                    ; On reaching EOF with no further hit, retry from offset 0 so a search cycles
                    ; round the file instead of dead-ending. After a successful F the term is known
                    ; to be present, so this second scan all but always succeeds; the only case that
                    ; scans twice for nothing is N pressed after an F that already found nothing.
                    if view_find_at(view_next)
                        view_jump()
                    else if view_find_at(0) {
                        view_jump()
                        view_notify(" wrapped to top")
                    } else
                        view_notify(" not found")
                }
                'c' -> {                        ; C: cycle syntax coloring off -> BASIC -> md -> off
                    ; Offered on ANY text file, not just recognised ones: detection is a suffix
                    ; match, so this is the escape hatch when it guesses wrong (or when a BASIC
                    ; listing is saved under some extension we don't know).
                    ; Straight ON/OFF, deliberately NOT a 3-way off/BASIC/Markdown cycle: on a
                    ; BASIC file the Markdown step colors nothing (no leading '#' lines), so it
                    ; looked identical to "off" and the key appeared to need two presses to do
                    ; anything. Switching back on uses the extension's mode, or BASIC if the
                    ; extension was unrecognised - which is what forcing color on is usually for.
                    ; No hex/ZSM guard: those renderers ignore syn_mode entirely, so toggling
                    ; while one is showing is harmless and takes effect on return to the text page.
                    ; No syn_avail test: the render gate (docolor) already requires it, so
                    ; toggling with no overlay loaded just has no effect - and the footer
                    ; doesn't advertise the key in that case anyway.
                    if syn_mode != 0
                        syn_mode = 0
                    else
                        syn_mode = syn_auto
                }
            }
        }
    }
}

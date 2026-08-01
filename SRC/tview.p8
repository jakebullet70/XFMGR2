; tview - standalone read-only paged text/hex file viewer for the Commander X16.
;
; Extracted from XFMGR2's internal viewer (was SRC/xviewer.p8) so XFMGR can drop the
; ~3.1 KB of viewer code from main RAM. Now built as a %output library overlay that XFMGR
; loads into a HIRAM bank and calls via `extsub @bank` (see the overlay notes below).
;
; Controls:  PgDn/PgUp page   T/Home top   H hex<->text   F find   N find-next   Q quit
;            SPACE = find-next (same as N, as in native XTree). When called as part of a
;            tagged-file SET walk (setmode 1), +/- step to the next/previous file.
; The pager uses 32-bit (long) file offsets: hex mode reaches any offset; text mode pages
; forward through any size, and caches VPAGES page-tops for backward paging.
; The two-line footer is drawn by the xsyntax bank (syn_draw_footer) - see the note there.
;
; Call contract: the caller (XFMGR) chdir's into the file's directory, keeps the screen in
; mode $01, then calls view_file(nameptr @R0, histcount @R1, setmode @R2, termptr @R3); the
; filename is copied in on entry. Returns 0 = quit, 1 = step to the next file of the set.
; termptr (or 0) pre-seeds the find term so the file opens on its first hit, highlighted.
; On return the caller repaints; hex mode reaches any offset in the file.

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
    extsub @bank 9 $A00F = syn_read_find(uword outptr @R0, ubyte histcount @R1) -> ubyte @A
    extsub @bank 9 $A012 = syn_draw_footer(ubyte flags @R0, ubyte setnum @R1, ubyte settot @R2, uword offlo @R3, ubyte offhi @R4, uword blocks @R5)
    extsub @bank 9 $A015 = syn_draw_zsm(uword hdrptr @R0)
    ; flag bits for syn_draw_footer - keep in step with xsyntax's FF_* constants
    const ubyte FF_HEX   = %00000001
    const ubyte FF_EOF   = %00000010
    const ubyte FF_COLOR = %00000100
    const ubyte FF_SET   = %00001000
    const ubyte FF_ZSM   = %00010000
    const ubyte FF_WRAP  = %01100000    ; wrap mode in bits 5-6, not a flag - see xsyntax's FF_WRAP
    const ubyte SYN_PROBE_MAGIC = $5a   ; must match syntax.PROBE_MAGIC in xsyntax.p8

    ; Geometry now lives in shared-const so xsyntax's color pass walks the SAME cells this
    ; renderer drew (it re-derives the wrap from these); aliased here to keep the short names.
    const ubyte VTOP   = shared.VIEW_TOP    ; first text row (row 0 = header)
    const ubyte VROWS  = shared.VIEW_ROWS   ; text rows 1..28
    const ubyte VWIDTH = shared.VIEW_WIDTH  ; wrap column (keep off col 79 to avoid auto-scroll)
    const ubyte SCR_BOT = 29           ; last screen row
    ; The footer is TWO bars: FOOT1 = keys for paging/display, FOOT2 = search + set-walk keys and
    ; the right-justified position indicator. Transient one-line notices (find prompt, "Working...",
    ; view_notify) still draw on SCR_BOT == FOOT2 and are wiped by the next per-page repaint.
    const ubyte FOOT1 = 28
    const ubyte FOOT2 = 29
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
    ubyte[64] namebuf                  ; the file to view (63 chars + NUL); filled per call. Only ever a
                                       ; FILENAME, never a path - the caller chdir's into the file's dir
                                       ; first - and every name reaching us is capped at 51 (NAME_RD_CAP).
    ubyte g_key                        ; last key read

    ; --- viewer state ---
    ; file offset of the top of each visited page, so paging can go both forward and backward by
    ; re-reading from a known offset. 32-bit (long) offsets; prog8 caps long arrays at 64, so PgUp
    ; reaches 64 pages back (~140 KB of dense content). Paging FORWARD is not limited by it at all:
    ; pages_push restarts the window rather than stopping, which is what makes a search hit deep in
    ; a big file reachable (and highlightable). Hex mode uses a single long -> no cap.
    const ubyte VPAGES = 64            ; page-top cache depth; MUST match view_pages' length
    ; { | } ~ _ \ have NO glyph in the PETSCII font, and scr_of's blanket "-$40" fold used to land
    ; them on ; < = > £ ← - REAL characters, so a source line READ as correct while saying something
    ; else. main.patch_font now DRAWS those six into the charset in VRAM (slots $74-$78 and $1C),
    ; and scr_of below maps each character onto its slot. See main.patch_font for how the slots
    ; were chosen. If that patch ever fails the characters simply revert to the old wrong glyphs -
    ; a display fault, never a crash, since these are only ever screen codes.
    ; TAB stop width. The text renderer advances to the next multiple of this, so tab-indented
    ; source (BASLOAD, prog8) lines up the way its author saw it. Must be a POWER OF TWO - the
    ; column math uses a mask, not a divide.
    const ubyte TAB_W = 4

    ; How a logical line longer than the screen is laid out. ONE setting, not two toggles: "wrap at
    ; a word boundary" and "do not wrap at all" are answers to the same question, and cycling one
    ; key through them costs a third of the code two independent flags would.
    ;   WRAP_CHAR  break anywhere - every byte is on screen, words get split (the original)
    ;   WRAP_WORD  break at spaces, so prose reads properly
    ;   WRAP_OFF   one logical line = one screen row, truncated; left/right pan across it. This is
    ;              the mode for long lines: minified JSON, one-line CSV, generated source.
    const ubyte WRAP_CHAR = 0
    const ubyte WRAP_WORD = 1
    const ubyte WRAP_OFF  = 2
    ubyte view_wrap                    ; one of WRAP_*; reset per file in view_file
    ubyte view_hscroll                 ; WRAP_OFF only: how many columns we are panned right
    const ubyte HSCROLL_STEP = 16
    const long NO_MATCH = $7f000000    ; "no hit in this file": past any real file, and far enough
                                       ; below the 32-bit ceiling that view_match+termlen can't wrap
    long[64] view_pages
    bool view_eof                      ; the last rendered page reached end-of-file
    bool view_hex                      ; viewer showing hex dump (vs text)
    bool view_pet                      ; text encoding: false = ASCII/ISO (default), true = PETSCII.
                                       ; A DISPLAY switch only (read-only viewer) - see content_scr.
    long view_off                      ; hex-mode current page top offset
    ubyte view_page                    ; text-mode current page index
    ubyte view_known                   ; text-mode highest page index with a known offset
    ubyte[34] view_find                ; in-file search term (<= 32 chars + NUL); uninit -> BSS
    ubyte vhist                        ; viewfind history entry count for read_find (255 = history off)
    ubyte view_inset                   ; 1 = viewing as part of a SET (tagged-file walk): enable the > file-step
    uword view_seed                    ; main-RAM ptr to a term to pre-search on open (0 = none). Set by the
                                       ; tagged-file walk so every file opens ON its first hit, highlighted.
    ubyte view_setnum                  ; "File N of M" during a set walk: our 1-based position ...
    ubyte view_settot                  ; ... and the size of the tagged set. Display only.
    uword view_blocks                  ; file size in CBM blocks (254 bytes each), taken from the
                                       ; caller's directory entry - 0 = unknown. Feeds the footer's
                                       ; "n%" only: measuring it here would mean reading the whole
                                       ; file on every open, which is exactly what we page to avoid.
    long view_next                     ; offset to resume "find next" from
    long view_match                    ; offset of the last search hit
    long view_pgend                    ; one past the last byte of the page on screen, from the last
                                       ; render. Lets view_jump skip the page-chain rebuild when the
                                       ; new hit is already on this page - the common case when you
                                       ; step matches with N, and the one that was doing the most
                                       ; needless work.
    bool view_hit_vis                  ; the page on screen actually PAINTED the find highlight. The
                                       ; renderer knows this for free (it is the same test that sets
                                       ; the highlight color), which beats having the footer compare
                                       ; view_match against the page bounds - two 32-bit compares
                                       ; cost 69 bytes this overlay does not have, and a flag set by
                                       ; the draw itself cannot disagree with what is on screen.
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

    sub view_file(uword nameptr @R0, ubyte histcount @R1, ubyte setmode @R2, uword termptr @R3,
                  ubyte setnum @R4, ubyte settot @R5, uword blocks @R6) -> ubyte {
        ; real entry ($A003 via the jmptable). Copy the filename FIRST - diskio/strings
        ; calls clobber cx16.r0-r3, so consume the @Rn params before anything else.
        ; The caller keeps XFMGR in screen mode $01 and repaints after we return.
        ; histcount = primed viewfind-history entries for the F prompt (255 = history off); main
        ; loaded the ring before this call and saves it after, so we just carry the count to read_find.
        ; setmode = 1 when viewing as part of a tagged-file SET walk: +/- step between files and
        ; paging past EOF advances to the next one.
        ; Returns: 0 = quit (Q/ESC), 1 = step to the NEXT file, 2 = step to the PREVIOUS file
        ; (1 and 2 only ever happen when setmode is set).
        vhist = histcount               ; capture @R1..@R6 before strings.copy clobbers r0-r3
        view_inset = setmode
        view_seed = termptr
        view_setnum = setnum
        view_settot = settot
        view_blocks = blocks
        void strings.copy(nameptr, namebuf)
        zsm_detect()                    ; set is_zsm + fill zsm_hdr before the view loop
        syn_detect()                    ; pick BASIC/Markdown/off from the file extension
        return view_run()
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
        ; Skipped while PANNED RIGHT: syn_paint colors buffer index i at screen column ln_col+i, and
        ; a panned row's first visible character is not buffer index 0 - the colors would land on the
        ; wrong columns. Leaving the row plain is the honest answer; scrolling back to column 0
        ; brings the coloring back.
        ; The wrap mode rides the high nibble: syn_paint retraces the cells we drew, so it needs the
        ; same wrap rule we used or the colors land on the wrong columns.
        if ln_len != 0 and view_hscroll == 0
            syn_paint(ln_len, syn_mode | (view_wrap << 4), ln_row, ln_col, mkword(syn_m0, syn_m1))
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
        ; Tested high-to-low ON PURPOSE: ruling out $7B-$7E first means the a-z test below needs
        ; only its LOWER bound, one compare instead of two. This bank has no spare bytes.
        if b > $7a
            return b - 7                ; { | } ~ ($7B-$7E) -> the custom glyphs at $74-$77.
                                        ; content_scr bounds b to $7E, so nothing else gets here.
        if b >= $61
            return b - $60              ; a-z -> $01..$1A (upper bound implied by the test above)
        if b == $5f
            return $78                  ; _ -> custom glyph. Cannot ride the -$40 fold below: that
                                        ; lands on $1F, the ← the command menu draws.
        if b >= $41 and b <= $5A
            return b                    ; A-Z -> $41..$5A (uppercase glyphs, unchanged)
        if b < $40
            return b                    ; $20..$3F: space, digits, punctuation - identical
        return b - $40                  ; @ ($40->$00), [ \ ] ^ _ ($5B-$5F -> $1B-$1F)
    }

    sub content_scr(ubyte b) -> ubyte {
        ; Map a file byte to a screen code for the CURRENT text encoding - this one branch IS the
        ; ISO<->PETSCII display switch. Default (view_pet false) reads the file as ASCII/ISO via
        ; scr_of; view_pet true reads it as PETSCII via txt.petscii2scr. Codes that aren't printable
        ; in the active encoding show as '.'. The machine charset NEVER changes (that would garble
        ; XFMGR's own PETSCII UI + box chrome and break the Alt/Ctrl command keys - see the ISO
        ; memory note); only how each content byte is interpreted onto the shared PETSCII font.
        ; No TAB case here on purpose: the TEXT renderer expands tabs to spaces before it calls us
        ; (see TAB_W), so a tab only ever reaches this point from the HEX sidebar - where '.' is
        ; the right answer, and the byte column already shows the authoritative 09.
        if view_pet {
            if b < 32 or (b >= 128 and b < 160)
                return $2e              ; PETSCII control / color codes -> '.' (screencode $2E)
            return txt.petscii2scr(b)
        }
        if b < 32 or b > 126
            return $2e                  ; non-ASCII-printable -> '.'
        return scr_of(b)
    }

    ; ---------- text page render ----------

    sub view_render(long start_off, bool draw) -> long {
        ; Walk one page of text starting at byte offset start_off; return the offset where
        ; the next page begins, and set view_eof if end-of-file was reached on this page.
        ; When draw is false this only MEASURES the page (no screen output) - used to rebuild
        ; the page chain when jumping to a search hit, so PgUp still works afterwards.
        view_eof = false
        view_hit_vis = false            ; set below iff this page actually paints the find highlight
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
        ; Jump to start_off with a real SEEK. This used to read-and-discard from byte 0 on every
        ; render, which made one page cost O(start_off) of disk I/O - a page 120 KB into a file
        ; re-read all 120 KB on EVERY keypress, and view_seek_page (which renders each page from the
        ; top of the file in turn) made that quadratic. f_open already opens the channel with the
        ; Channel,x,Channel SETLFS form precisely so f_seek works; nothing here ever used it.
        ;
        ; We seek to start_off-1 and read that ONE byte rather than seeking to start_off, because the
        ; byte before the page still matters: it primes prev_cr so a CR/LF pair split across the page
        ; boundary is swallowed instead of drawing a blank first line.
        ubyte lastskip = 0
        if start_off != 0 {
            if diskio.f_seek(start_off - 1) {
                if diskio.f_read(&viewbuf, 1) == 1
                    lastskip = viewbuf[0]
            }
        }

        long consumed = start_off
        ubyte row = 0
        ubyte col = 0
        ; if the previous page ended on a CR, a leading LF here is that CR/LF pair's tail - prime
        ; prev_cr so it is swallowed instead of drawing a blank first content line
        bool prev_cr = lastskip == 13
        bool full = false
        bool prev_blank = true          ; WRAP_WORD: was the previous char whitespace? true at a page
                                        ; start so the first word is never mistaken for mid-word
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
                    ; A TAB is ONE byte occupying SEVERAL columns. Rather than a branch of its own,
                    ; it runs the emit path below N times - so the anchor / wrap / highlight logic
                    ; is written once. Duplicating it instead cost 170 bytes, which bank 2 did not
                    ; have until the ZSM page moved to bank 9.
                    ubyte outch = ch
                    ubyte reps = 1
                    if ch == 9 {
                        outch = ' '
                        reps = TAB_W - (col & (TAB_W - 1))      ; advance to the next stop
                    }
                    ; WORD WRAP: break BEFORE a word that would not fit, instead of mid-word. Only
                    ; at the first character of a word, and only when there is something on this row
                    ; already (a word longer than the whole row must still be split, or we would
                    ; loop forever on it).
                    ;
                    ; The lookahead reads viewbuf directly, which is why this needs no line buffer:
                    ; the bytes after j are already in the chunk we read. A word running past the
                    ; end of the chunk is simply treated as fitting - it falls back to a character
                    ; break for that one word, which is rare and harmless.
                    if view_wrap == WRAP_WORD and col != 0 and outch > ' ' and prev_blank {
                        ubyte wlen = 0
                        while j + wlen < cnt and viewbuf[j + wlen] > ' '
                            wlen++
                        if col + wlen > VWIDTH and wlen <= VWIDTH {
                            if docolor
                                syn_flush()     ; this screen row is finished - color it now
                            row++
                            col = 0
                            if row >= VROWS {
                                full = true
                                break
                            }
                        }
                    }
                    prev_blank = outch <= ' '
                    repeat reps {
                    if docolor {
                        ; Anchor the line lazily at its FIRST drawn char. Doing it here rather than
                        ; at the CR/LF handler is what makes CR/LF pairs (the LF is swallowed
                        ; earlier by `continue`), blank lines, and a page starting mid-line all work
                        ; without special-casing any of them.
                        if ln_len == 0 {
                            ln_row = row
                            ln_col = col
                        }
                        ; Store the ASCII-CLAMPED byte so classify (which expects ASCII) sees stable
                        ; input regardless of the display encoding - the ISO/PETSCII toggle is a glyph
                        ; flip, not a re-encode - and so column k of the buffer is column k on screen.
                        if ln_len < shared.SYN_LINE_MAX {
                            ubyte sc = outch
                            if sc < 32 or sc > 126
                                sc = ' '        ; was '.': this buffer feeds the CLASSIFIER, never
                                                ; the screen, and a TAB (or any stray control byte)
                                                ; is whitespace to a tokenizer, not a token char
                            @(syn_line_p + ln_len) = sc
                            ln_len++
                        }
                    }
                    ; Screen column. Only WRAP_OFF ever differs from the line column: there the row
                    ; is a window onto a longer line, panned right by view_hscroll, and everything
                    ; left of the window is consumed but not drawn.
                    ubyte scol = col
                    bool onscreen = true
                    if view_wrap == WRAP_OFF {
                        onscreen = col >= view_hscroll and col - view_hscroll < VWIDTH
                        if onscreen
                            scol = col - view_hscroll
                    }
                    if draw and onscreen {
                        ; content_scr maps the RAW byte to a screen code for the current encoding
                        ; (ASCII/ISO or PETSCII). setchr writes it straight to VRAM - no PETSCII
                        ; control-code interpretation, so no byte value can scroll the view. setclr
                        ; paints only the find-highlight cells; the rest keep the content color.
                        txt.setchr(scol, VTOP + row, content_scr(outch))
                        if plen != 0 and consumed-1 >= view_match and consumed-1 < mend {
                            txt.setclr(scol, VTOP + row, (shared.FIND_BG << 4) | shared.FIND_FG)
                            view_hit_vis = true     ; the hit is ON SCREEN -> the footer reports the
                                                    ; hit's offset, not this page's top
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
                    ; WRAP_OFF never breaks a line: the row ends only at the newline, so the rest
                    ; of a long line is consumed off-screen and reachable by panning.
                    if col >= VWIDTH and view_wrap != WRAP_OFF {
                        row++
                        col = 0
                        if row >= VROWS {
                            full = true
                            break       ; leaves the tab repeat; the check below leaves the page
                        }
                    }
                    }
                    if full
                        break
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
        if start_off != 0
            void diskio.f_seek(start_off)       ; see the note in view_render - this was an O(n) skip
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
                ; content_scr clamps + maps for the active encoding, so the hex sidebar reads the
                ; same way (ASCII/ISO or PETSCII) the text page does.
                txt.setchr(57 + i, VTOP + row, content_scr(viewbuf[i]))   ; ascii col = 57 (6+2+48+1); setchr
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
        ; The ZSM header page is DRAWN BY THE XSYNTAX BANK (syn_draw_zsm). It moved there for the
        ; same reason the footer and the Find prompt did: bank 2 is full to the byte, and this is
        ; ~370 bytes of pure chrome that reads only 16 bytes of input. Bank 9 had room to spare.
        ;
        ; It could move BECAUSE its input is tiny. zsm_hdr lives in THIS bank, which is unmapped
        ; while bank 9 runs, so the bytes are staged in syn_line_p - the main-RAM line buffer both
        ; banks already share for syntax coloring (main RAM stays mapped below $A000 regardless of
        ; bank). It is only ever used one line at a time during a render, and no render is in
        ; flight here, so borrowing it costs nothing.
        ;
        ; A static page: set view_eof so the paging keys are no-ops (PgDn is guarded by
        ; 'if not view_eof'; PgUp/Top land back here). The return value is unused.
        view_eof = true
        if not syn_avail or syn_line_p == 0
            return 0                    ; no overlay -> no page, the same degradation F already has
        ubyte hi
        for hi in 0 to 15
            @(syn_line_p + hi) = zsm_hdr[hi]
        syn_draw_zsm(syn_line_p)
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
        working_note()
        if not diskio.f_open(namebuf)
            return false
        if from != 0
            void diskio.f_seek(from)            ; see the note in view_render - this was an O(n) skip
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
        ubyte got = syn_read_find(syn_line_p, vhist)
        paint_footer()              ; the prompt drew over the second bar - put the footer back now
        if got == 0
            return false
        void strings.copy(syn_line_p, view_find)
        return true
    }

    sub working_note() {
        ; "Working..." over the footer while a whole-file scan runs (search, jump-to-bottom) so the
        ; viewer doesn't look hung. Clears BOTH bars: blanking only the bottom one left the key bar
        ; stranded above the message, which read as a half-drawn footer. paint_footer() (called at
        ; the top of every main-loop pass) puts it back.
        bar_fill(FOOT1)
        bar_fill(FOOT2)
        txt.plot(0, FOOT2)
        txt.print(" Working...")
    }

    sub paint_footer() {
        ; Both footer bars, drawn by the xsyntax bank (see syntax.draw_footer). ALL the label text
        ; and the status layout live there - bank 2 is completely full, and this is viewer chrome,
        ; not syntax coloring, so it moved for the same reason the Find prompt did. We just report
        ; state. Without that overlay there is no footer, the same degradation F already has.
        ;
        ; Its own sub so anything that writes over the bottom row (view_notify, the find prompt) can
        ; put BOTH bars back immediately, instead of leaving a half-drawn footer until the next page
        ; render finishes - that render re-reads the file, so the gap was long enough to see.
        if not syn_avail
            return
        ubyte fflags = FF_COLOR             ; syn_avail is implied by the guard above
        if view_hex
            fflags |= FF_HEX
        if view_eof
            fflags |= FF_EOF
        if view_inset != 0
            fflags |= FF_SET
        if is_zsm
            fflags |= FF_ZSM
        fflags |= view_wrap << 5        ; wrap mode rides bits 5-6 (see FF_WRAP)
        ; Position shown is a BYTE OFFSET: normally the top of what is on screen (the hex cursor, or
        ; the current text page's first byte).
        ;
        ; EXCEPT when the find highlight is on screen - then we report the HIT's offset instead. The
        ; page top is the honest answer to "where does this screen start", but it is the wrong answer
        ; to the question the reader is actually asking, and it made the indicator look broken:
        ; stepping N/Space through several matches inside ONE page moved the highlight every time and
        ; never moved the number. view_hit_vis comes from the renderer, so it is true exactly when a
        ; highlight was painted - not when we merely have a stale hit somewhere off screen.
        ; (Hex mode needs none of this: view_jump aligns view_off to the hit's own 16-byte row, so
        ; the page top already moves with every match.)
        ;
        ; hoist every argument into a local first: narrowing a `long` straight into an @Rn parameter
        ; is a codegen error ("invalid register for lsw"), and computing in the call risks
        ; clobbering r0-r5 mid-setup
        long fpos = view_off
        if not view_hex {
            fpos = view_pages[view_page]
            if view_hit_vis
                fpos = view_match
        }
        uword folo = (fpos & $0000ffff) as uword
        ubyte fohi = ((fpos >> 16) & 255) as ubyte
        uword fblk = view_blocks
        syn_draw_footer(fflags, view_setnum, view_settot, folo, fohi, fblk)
    }

    sub view_notify(str m) {
        ; Brief message on the bottom bar, or any key to cut it short. Drain first - the key that
        ; opened this message is often still queued (see the note in xfmgr.wait_or_key).
        ;
        ; It overwrites the SECOND footer bar, so it restores the footer itself on the way out
        ; rather than leaving one bar showing until the next page render (which re-reads the file,
        ; so the half-drawn footer was on screen long enough to look like a glitch).
        bar_fill(FOOT1)                 ; both bars, so the message never sits under a stray key bar
        bar_fill(FOOT2)
        txt.plot(0, FOOT2)
        txt.print(m)
        while cbm.GETIN2() != 0 {
        }
        ubyte n
        for n in 0 to 74 {
            sys.waitvsync()
            if cbm.GETIN2() != 0
                break
        }
        paint_footer()
    }

    sub find_next() -> ubyte {
        ; Advance to the next hit. Returns 1 when the caller should step to the NEXT FILE.
        ;
        ; During a tagged-set walk, running out of hits in THIS file continues the search in the
        ; next one rather than wrapping - that is the whole point of the walk: keep pressing Next
        ; and you travel through every file the text was found in, each opening on its first hit.
        ; Outside a walk there is nowhere to go, so it wraps to the top of the file instead.
        ; In a walk with NO search term there is nothing to chase, so "Next" plainly means the next
        ; FILE. Without this, N/Space scanned for an empty term, failed, and put a " not found"
        ; message over the footer on every press.
        ;
        ; EVERY dead end says so. Silently wrapping to the first match, or silently re-opening the
        ; last file of a set, is indistinguishable from the viewer ignoring the key - which is
        ; exactly how it got reported ("seems to get stuck on the last item").
        if view_inset != 0 and view_find[0] == 0 {
            if view_setnum < view_settot
                return 1
            view_notify(" All done - last file of the set")
            return 0
        }
        if view_find_at(view_next) {
            view_jump()
            return 0
        }
        ; Hits exhausted here. In a set walk that means continue in the next file - but on the LAST
        ; file of the set there is no next one, so fall through to the wrap below and announce it,
        ; rather than returning 1 and letting the caller silently re-open this same file.
        if view_inset != 0 and view_setnum < view_settot
            return 1
        if view_find_at(0) {
            view_notify(" All done - back to the first match")
            view_jump()                 ; wrapped: the notice above is what makes that readable
        } else {
            view_find[0] = 0            ; miss -> drop the term so no stale highlight is painted
            view_notify(" Not found")
        }
        return 0
    }

    sub view_jump() {
        ; point the current view (hex or text) at the last search hit
        view_next = view_match + 1
        if view_hex {
            view_off = view_match - (view_match & 15)   ; align down to the 16-byte hex row
        } else if view_match < view_pages[view_page] or view_match >= view_pgend {
            ; Only rebuild the page chain when the hit is NOT already on screen. Stepping matches
            ; inside one page is the common case, and view_seek_page re-renders every page from the
            ; top of the file to get here - by far the most expensive thing the viewer does.
            view_seek_page(view_match)
        }
    }

    sub pages_push(long nxt) {
        ; Advance one page, recording its top offset.
        ;
        ; The cache cap used to be a HARD STOP: on a file longer than the cache, view_seek_page
        ; could not reach a search hit past it and silently parked on the last cached page, so the
        ; hit was never on screen and never highlighted (the "Pg:44 with VPAGES=44, no highlight"
        ; symptom). Now a full cache RESTARTS its window at the current page instead of refusing to
        ; advance. Sliding the window one slot would preserve more PgUp history, but a 256-byte
        ; overlapping move costs far more code than this overlay has left; restarting is a few
        ; assignments. Cost: past the cap, PgUp dead-ends at the restart point. The footer shows a
        ; byte OFFSET, not a page number, so nothing has to track pages across a restart.
        if view_page + 1 < VPAGES {
            view_pages[view_page+1] = nxt
            view_known = view_page + 1
            view_page++
            return
        }
        view_pages[0] = nxt
        view_page = 0
        view_known = 0
    }

    sub view_seek_page(long target) {
        ; Rebuild the text page chain from the top of the file up to the page that contains
        ; byte offset `target`, leaving view_page on that page. Earlier pages stay known (as far
        ; back as the sliding window reaches), so PgUp still scrolls above a search hit.
        view_pages[0] = 0
        view_page = 0
        view_known = 0
        repeat {
            long nxt = view_render(view_pages[view_page], false)
            if view_eof
                break
            if target < nxt
                break
            pages_push(nxt)
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
        ; note so the viewer doesn't look hung. It stays up through the scan and the final page
        ; render, then the main loop's footer repaint clears it.
        working_note()
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
                pages_push(nxt)
            }
        }
    }

    ; ---------- main view loop ----------

    sub view_run() -> ubyte {
        ; clear once on entry and draw the static header bar (row 0); per-page renders
        ; only repaint the body + footer, so the header doesn't flicker.
        ; Returns 0 (quit), or 1 (step to next file) when view_inset + paged past EOF - see view_file.
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)     ; content bg = gray (header bar drawn over row 0 next)
        txt.clear_screen()
        bar_fill(0)                        ; full-width blue header bar
        txt.plot(0, 0)
        txt.print(" VIEW: ")
        print_trunc(namebuf, 60)
        view_hex = false
        view_pet = false                   ; every file opens in the default ASCII/ISO reading; I toggles
        ; Wrap is a per-file setting, not a sticky mode: in a tagged-set walk a leftover pan would
        ; open the next file scrolled sideways for no visible reason.
        ;
        ; WRAP_OFF is the DEFAULT because it is the one mode that never lies about the file. Wrapping
        ; invents line breaks that are not in the bytes, and on source or data the eye reads those as
        ; real - a wrapped line looks like two. Off, one file line is one screen row; anything past
        ; column 78 is reached by panning, which is at least honest about being hidden.
        view_wrap = WRAP_OFF
        view_hscroll = 0
        view_off = 0
        view_page = 0
        view_known = 0
        view_next = 0
        view_match = 0                     ; stale hit offsets must not survive into a new file
        view_pages[0] = 0
        view_pgend = 0                     ; nothing rendered for THIS file yet. Must be cleared: the
                                           ; seed jump below runs before any render, and view_jump
                                           ; tests the hit against it - the previous file's value
                                           ; would make it skip the seek and leave us on page 0.
        ; THE FIND TERM TRAVELS WITH YOU through a tagged-set walk. Only a plain single-file view
        ; (or the first file of a walk) starts clean and takes the seeded term; after that whatever
        ; is in view_find carries forward, so a term typed with F in file 1 still highlights in
        ; file 2. Wiping it on every entry meant Space rolled into the next file with nothing to
        ; chase - the file opened at offset 0 with no highlight, which is how it was reported.
        ; view_seed is XFMGR's content-search term and is 0 when the walk began with a plain Tag,
        ; so it cannot be the only way a term gets in here.
        if view_inset == 0 or view_setnum <= 1 {
            view_find[0] = 0
            if view_seed != 0
                void strings.copy(view_seed, view_find)   ; empty seed -> still empty, handled below
        }
        ; Open ON the first hit, highlighted, so the page and the footer offset agree with what the
        ; eye lands on. N/Space then step through the rest as usual.
        if view_find[0] != 0 {
            if view_find_at(0)
                view_jump()
            else
                view_match = NO_MATCH   ; not in THIS file: KEEP the term for the next file of the
                                        ; walk, but park the hit offset out past any real file so
                                        ; the renderer highlights nothing. Clearing view_find here
                                        ; instead would lose the term at the first file that
                                        ; happens not to contain it; leaving view_match at 0 would
                                        ; paint a bogus highlight over the first bytes of the file.
        }
        repeat {
            long nxt
            if view_hex
                nxt = view_render_hex(view_off)
            else if is_zsm
                nxt = view_render_zsm()         ; ZSM file: parsed header breakout (static page)
            else
                nxt = view_render(view_pages[view_page], true)
            view_pgend = nxt            ; what is on screen now - view_jump tests hits against it
            paint_footer()
            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3, 'q' -> return 0
                2 -> {                          ; PgDn: next page - or, at EOF in a browser walk, next file
                    if not view_eof {
                        if view_hex {
                            view_off += VROWS * 16
                        } else if view_page >= view_known {
                            pages_push(nxt)
                        } else {
                            view_page++
                        }
                    } else if view_inset != 0 {
                        return 1                 ; paged past the end of a set member -> step to NEXT file
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
                    if view_hex {
                        view_off = 0
                    } else {
                        ; back to page 1: the window may have slid, so rebuild the chain from the
                        ; file's start rather than just indexing to 0 (which would be mid-file)
                        view_pages[0] = 0
                        view_page = 0
                        view_known = 0
                                    }
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
                        if view_find_at(0) {
                            view_jump()
                        } else {
                            ; Drop the term on a miss. The renderer highlights view_match..+len
                            ; whenever view_find is non-empty, and a failed search leaves view_match
                            ; at whatever the LAST hit was - so keeping the term would paint a
                            ; bogus highlight over unrelated text.
                            view_find[0] = 0
                            view_notify(" Not found")
                        }
                    }
                }
                ; N and SPACE both advance to the next occurrence of the search term - as in native
                ; XTree. In a tagged-set walk they roll on into the NEXT FILE once this file's hits
                ; are used up; +/- step between files directly, regardless of the search.
                'n', ' ' -> {
                    if find_next() != 0
                        return 1
                }
                '+' -> {                        ; + : next file of a tagged-set walk
                    if view_inset != 0
                        return 1
                }
                '-' -> {                        ; - : previous file of a tagged-set walk
                    if view_inset != 0
                        return 2
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
                'i' -> view_pet = not view_pet  ; I: read the file as ASCII/ISO <-> PETSCII. Page
                                                ; boundaries are byte-based (CR/LF), so they don't move -
                                                ; the loop just re-renders this page with the new glyphs.
                'w' -> {                        ; W: cycle wrap - char -> word -> off
                    ; Unlike I, this DOES move page boundaries: how many screen rows a logical line
                    ; takes is exactly what decides where a page ends, so every cached page offset
                    ; below this point is now wrong and the chain has to be dropped.
                    ;
                    ; But it is re-anchored HERE, not at byte 0. Restarting the chain at the top of
                    ; the file re-read from the beginning and threw away your place - on a long file
                    ; that is both a visible pause and a lost position. The current page's top offset
                    ; is a perfectly good page start under any wrap rule (a page may begin mid-line
                    ; already), so it becomes the new page 0 and the re-render reads from there.
                    ; Cost: PgUp dead-ends at this point, the same as the cache-restart in pages_push.
                    view_wrap++
                    if view_wrap > WRAP_OFF
                        view_wrap = WRAP_CHAR
                    view_hscroll = 0            ; panning is meaningless once the text wraps again
                    view_pages[0] = view_pages[view_page]
                    view_page = 0
                    view_known = 0
                }
                29 -> {                         ; cursor-right: pan right (WRAP_OFF only)
                    if view_wrap == WRAP_OFF and view_hscroll < 240
                        view_hscroll += HSCROLL_STEP
                }
                157 -> {                        ; cursor-left: pan back toward column 0
                    if view_hscroll >= HSCROLL_STEP
                        view_hscroll -= HSCROLL_STEP
                    else
                        view_hscroll = 0
                }
            }
        }
    }
}

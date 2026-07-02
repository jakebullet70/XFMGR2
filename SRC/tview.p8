; tview - standalone read-only paged text/hex file viewer for the Commander X16.
;
; Extracted from XFMGR2's internal viewer (was SRC/xviewer.p8) so XFMGR can drop the
; ~3.1 KB of viewer code from main RAM. Now built as a %output library overlay that XFMGR
; loads into a HIRAM bank and calls via `extsub @bank` (see the overlay notes below).
;
; Controls:  PgDn/PgUp page   T/Home top   H hex<->text   F find   N find-next   Q quit
; The pager uses 16-bit file offsets, so it pages within the first 64 KB of a file.
;
; Call contract: the caller (XFMGR) chdir's into the file's directory, keeps the screen in
; mode $01, then calls view_file(nameptr @R0); the filename is copied in on entry. On return
; the caller repaints. Known limitation: files > 64 KB only page within their first 64 KB.

%import textio
%import diskio
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
    ; `jmp start` at $A000 (library init), so: $A000 = start (init), $A003 = view_file.
    %jmptable ( main.view_file )

    const ubyte VTOP   = 1             ; first text row (row 0 = header)
    const ubyte VROWS  = 28            ; text rows 1..28
    const ubyte VWIDTH = 79            ; wrap column (keep off col 79 to avoid auto-scroll)
    const ubyte SCR_BOT = 29           ; footer row
    const uword HEXPAGE = VROWS * 16   ; bytes shown per hex page (VROWS rows x 16 bytes)

    ; status-bar + content colours now live in SRC/shared-const.p8 (block `shared`), shared
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
    ; file offset of the top of each visited page, so paging can go both forward and
    ; backward by re-reading from a known offset (offsets are 16-bit -> first 64 KB only).
    uword[100] view_pages
    bool view_eof                      ; the last rendered page reached end-of-file
    bool view_hex                      ; viewer showing hex dump (vs text)
    uword view_off                     ; hex-mode current page top offset
    ubyte view_page                    ; text-mode current page index
    ubyte view_known                   ; text-mode highest page index with a known offset
    ubyte[34] view_find                ; in-file search term (<= 32 chars + NUL); uninit -> BSS
    uword view_next                    ; offset to resume "find next" from
    uword view_match                   ; offset of the last search hit

    sub start() {
        ; library init entrypoint ($A000). The compiler emits the BSS-clear here; this must
        ; do NO UI or system init (the caller/XFMGR owns the screen). Call ONCE after load.
    }

    sub view_file(uword nameptr @R0) {
        ; real entry ($A003 via the jmptable). Copy the filename FIRST - diskio/strings
        ; calls clobber cx16.r0-r3, so consume the @R0 pointer before anything else.
        ; The caller keeps XFMGR in screen mode $01 and repaints after we return.
        void strings.copy(nameptr, namebuf)
        view_run()
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
        ; auto-scroll that chrout would cause there. Leaves the cursor colour at white-on-blue.
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

    ; ---------- text page render ----------

    sub view_render(uword start_off, bool draw) -> uword {
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
        ; skip to start_off by reading and discarding
        uword toskip = start_off
        while toskip != 0 {
            uword want = 250
            if toskip < want
                want = toskip
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }

        uword consumed = start_off
        ubyte row = 0
        ubyte col = 0
        bool prev_cr = false
        bool full = false
        if draw
            txt.plot(0, VTOP)
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
                    row++
                    col = 0
                    if row >= VROWS {
                        full = true
                        break
                    }
                    if draw
                        txt.plot(0, VTOP + row)
                } else {
                    if ch < 32 or ch > 126
                        ch = '.'
                    if draw
                        txt.chrout(ch)
                    col++
                    if col >= VWIDTH {
                        row++
                        col = 0
                        if row >= VROWS {
                            full = true
                            break
                        }
                        if draw
                            txt.plot(0, VTOP + row)
                    }
                }
            }
            if full
                break
        }
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

    sub view_render_hex(uword start_off) -> uword {
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
        uword toskip = start_off
        while toskip != 0 {
            uword want = 250
            if toskip < want
                want = toskip
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        uword off = start_off
        ubyte row = 0
        repeat {
            ubyte cnt = lsb(diskio.f_read(&viewbuf, 16))
            if cnt == 0 {
                view_eof = true
                break
            }
            txt.plot(0, VTOP + row)
            put_hex16(off)
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
                txt.chrout(ch)
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

    ; ---------- search ----------

    sub view_fold(ubyte b) -> ubyte {
        ; ASCII case fold A-Z -> a-z (file bytes and search term are both ASCII)
        if b >= $41 and b <= $5a
            return b + $20
        return b
    }

    sub view_find_at(uword from) -> bool {
        ; scan the file from byte offset `from` for view_find (case-insensitive). On a hit
        ; set view_match and return true; else false. Naive matcher (fine for short terms).
        ubyte plen = lsb(strings.length(view_find))
        if plen == 0
            return false
        if not diskio.f_open(namebuf)
            return false
        uword toskip = from
        while toskip != 0 {
            uword want = 250
            if toskip < want
                want = toskip
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        uword pos = from
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
        ; read a search term on the footer row; false if cancelled or empty
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Find: ")
        ubyte n = 0
        view_find[0] = 0
        txt.plot(7, SCR_BOT)
        repeat {
            g_key = wait_key()
            if g_key == 13 {
                view_find[n] = 0
                return n != 0
            }
            if g_key == 27 or g_key == 3
                return false
            if g_key == 20 {                    ; backspace
                if n != 0 {
                    n--
                    view_find[n] = 0
                    txt.plot(7 + n, SCR_BOT)
                    txt.spc()
                    txt.plot(7 + n, SCR_BOT)
                }
            } else {
                if g_key >= $c1 and g_key <= $da
                    g_key -= $80
                if n < 32 and g_key >= 32 and g_key < 127 {
                    view_find[n] = g_key
                    txt.chrout(g_key)
                    n++
                }
            }
        }
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
            view_off = view_match & $fff0
        } else {
            view_seek_page(view_match)
        }
    }

    sub view_seek_page(uword target) {
        ; Rebuild the text page chain from the top of the file up to the page that contains
        ; byte offset `target`, leaving view_page on that page. This keeps every earlier page
        ; known, so PgUp still scrolls back above a search hit (instead of dead-ending).
        view_pages[0] = 0
        view_page = 0
        view_known = 0
        repeat {
            uword nxt = view_render(view_pages[view_page], false)
            if view_eof
                break
            if target < nxt
                break
            if view_page + 1 >= 100
                break
            view_pages[view_page+1] = nxt
            view_known = view_page + 1
            view_page++
        }
    }

    sub file_len() -> uword {
        ; total file size in bytes, as a 16-bit value (wraps past 64 KB - the viewer only
        ; pages within the first 64 KB anyway). Used to land hex mode on the last page.
        if not diskio.f_open(namebuf)
            return 0
        uword total = 0
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
            uword sz = file_len()
            view_off = 0
            while sz - view_off > HEXPAGE
                view_off += HEXPAGE
        } else {
            view_pages[0] = 0
            view_page = 0
            view_known = 0
            uword nxt
            repeat {
                nxt = view_render(view_pages[view_page], false)
                if view_eof {
                    ; an empty trailing page (prev page ended exactly on a boundary) -> back up
                    if nxt == view_pages[view_page] and view_page != 0
                        view_page--
                    break
                }
                if view_page + 1 >= 100
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
            uword nxt
            if view_hex
                nxt = view_render_hex(view_off)
            else
                nxt = view_render(view_pages[view_page], true)
            ; footer status bar (repainted per page): full-width blue, white text, accent keys
            bar_fill(SCR_BOT)
            txt.plot(0, SCR_BOT)
            txt.spc()
            bar_key("PgDn/PgUp   ")
            txt.spc()
            bar_key("T")
            txt.print("op ")
            bar_key("B")
            txt.print("ottom ")
            if view_hex {
                bar_key("T")
                txt.print("ext ")
            } else {
                bar_key("H")
                txt.print("ex ")
            }
            bar_key("F")
            txt.print("ind ")
            bar_key("N")
            txt.print("ext ")
            bar_key("Q")
            txt.print("uit")
            ; right-justify the position indicator (page/offset [+ END]) against the right edge.
            ; w = width of what we print; start col 79-w ends it at col 78 - never col 79, which
            ; would auto-scroll the bottom row.
            ubyte w
            if view_hex {
                w = 5                        ; "$" + 4 hex digits
            } else {
                ubyte pg = view_page + 1     ; pages shown 1-based (index 0..99 -> 1..100)
                w = 4                        ; "pg " + 1 digit
                if pg >= 10
                    w = 5
                if pg >= 100
                    w = 6
            }
            if view_eof
                w += 6                       ; " (END)"
            txt.plot(79 - w, SCR_BOT)
            if view_hex {
                txt.chrout('$')
                put_hex16(view_off)
            } else {
                txt.print("Pg:")
                txt.print_uw(view_page + 1)
            }
            if view_eof
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
                            if view_page + 1 < 100 {
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
                'b' -> view_bottom()            ; B: jump to the last page
                'h' -> {                        ; toggle hex / text, keeping position
                    if view_hex {
                        view_pages[0] = view_off
                        view_page = 0
                        view_known = 0
                        view_hex = false
                    } else {
                        view_off = view_pages[view_page] & $fff0
                        view_hex = true
                    }
                }
                'f' -> {                        ; find: prompt, search from current top
                    if view_read_find() {
                        uword sfrom = view_off
                        if not view_hex
                            sfrom = view_pages[view_page]
                        if view_find_at(sfrom)
                            view_jump()
                        else
                            view_notify(" not found")
                    }
                }
                'n' -> {                        ; find next
                    if view_find_at(view_next)
                        view_jump()
                    else
                        view_notify(" not found")
                }
            }
        }
    }
}

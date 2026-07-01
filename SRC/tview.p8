; tview - standalone read-only paged text/hex file viewer for the Commander X16.
;
; Extracted from XFMGR2's internal viewer (was SRC/xviewer.p8) so XFMGR can drop the
; ~3.1 KB of viewer code and this can grow into a separate, CALLABLE viewer program.
;
; Controls:  PgDn/PgUp page   T/Home top   H hex<->text   F find   N find-next   Q quit
; The pager uses 16-bit file offsets, so it pages within the first 64 KB of a file.
;
; STANDALONE SEED - still TODO before it's a finished callable program:
;   * Receive the target filename from the caller (XFMGR) instead of the hardcoded
;     default below. Options: a fixed RAM hand-off area, a tiny param file, or args.
;   * Decide large-file (>64 KB) behaviour (XFMGR used to bounce those to X16 Edit).
;   * Optionally restore path handling (chdir into the file's directory).

%import textio
%import diskio
%import strings
%zeropage basicsafe

main {
    %option ignore_unused

    const ubyte SCREEN_MODE = $01      ; 80x30 text (matches XFMGR)
    const ubyte VTOP   = 1             ; first text row (row 0 = header)
    const ubyte VROWS  = 28            ; text rows 1..28
    const ubyte VWIDTH = 79            ; wrap column (keep off col 79 to avoid auto-scroll)
    const ubyte SCR_BOT = 29           ; footer row

    ; --- shared scratch (in XFMGR these lived in the main module) ---
    ubyte[256] viewbuf                 ; read buffer (viewer reads up to 250 bytes/call)
    str namebuf = "?" * 80             ; the file to view
    ubyte g_key                        ; last key read
    ubyte saved_mode                   ; screen mode to restore on exit

    ; --- viewer state ---
    ; file offset of the top of each visited page, so paging can go both forward and
    ; backward by re-reading from a known offset (offsets are 16-bit -> first 64 KB only).
    uword[100] view_pages
    bool view_eof                      ; the last rendered page reached end-of-file
    bool view_hex                      ; viewer showing hex dump (vs text)
    uword view_off                     ; hex-mode current page top offset
    ubyte view_page                    ; text-mode current page index
    ubyte view_known                   ; text-mode highest page index with a known offset
    str view_find = "?" * 33           ; in-file search term (<= 32 chars)
    uword view_next                    ; offset to resume "find next" from
    uword view_match                   ; offset of the last search hit

    sub start() {
        ; TODO: receive this from the caller. Hardcoded for now so the program is testable
        ; standalone (XFMGR's run\ folder ships a README.TXT).
        void strings.copy("README.TXT", namebuf)

        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        cx16.set_screen_mode(SCREEN_MODE)
        view_run()
        cx16.set_screen_mode(saved_mode)
        txt.clear_screen()
    }

    ; ---------- shared helpers (ported from XFMGR's main module) ----------

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
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
        blank_span(0, 78, SCR_BOT)
        txt.chrout($12)
        txt.plot(0, SCR_BOT)
        txt.print(" Find: ")
        txt.chrout($92)
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
        blank_span(0, 78, SCR_BOT)
        txt.chrout($12)
        txt.plot(0, SCR_BOT)
        txt.print(m)
        txt.chrout($92)
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

    ; ---------- main view loop ----------

    sub view_run() {
        ; clear once on entry and draw the static header bar (row 0); per-page renders
        ; only repaint the body + footer, so the header doesn't flicker.
        txt.clear_screen()
        txt.chrout($12)
        txt.plot(0, 0)
        txt.print("VIEW: ")
        print_trunc(namebuf, 60)
        txt.chrout($92)
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
            ; footer bar (only this row is repainted per page)
            blank_span(0, 78, SCR_BOT)
            txt.chrout($12)
            txt.plot(0, SCR_BOT)
            if view_hex {
                txt.print(" PgDn/Up T:top H:text F:find N:next Q:quit  $")
                put_hex16(view_off)
            } else {
                txt.print(" PgDn/Up T:top H:hex F:find N:next Q:quit  pg ")
                txt.print_uw(view_page + 1)
            }
            if view_eof
                txt.print(" (END)")
            txt.chrout($92)

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

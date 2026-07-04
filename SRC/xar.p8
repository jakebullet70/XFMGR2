; xar - .XAR archive engine overlay for XFMGR2 (create / browse / extract).
;
; A custom, X16-native archive format. Two block codecs, distinguished by the magic's 4th byte:
; "XAR1" = ByteRun1 / PackBits RLE (vendored prog8 `compression` module) - what CREATE writes and
; the X16 can both compress AND decompress. "XAR2" = LZSA2 blocks - EXTRACT-ONLY (decoded via the
; X16 ROM `memory_decompress` $FEED; the X16 has no LZSA2 compressor, so XAR2 files are authored
; off-device, e.g. with `lzsa -r -f2` per block). Same framing for both. X16-to-X16; no DEFLATE/ARC.
; Built as a %output library headerless blob (org $A000), loaded into reserved HIRAM
; bank 6 (XAR_BANK in xfmgr) at startup via diskio.loadlib, called via `extsub @bank 6`
; (JSRFAR maps the bank around each call). Keeps the codec + all archive logic out of
; scarce main RAM - same overlay pattern as SRC/miscutil.p8 (see its header).
;
; --- .XAR ON-DISK FORMAT (all little-endian, fully sequential - NO seek needed) ---
;   "XAR1"/"XAR2"             magic (4 bytes: $58 $41 $52, then $31=RLE or $32=LZSA2)
;   member_count             (1 byte, 1..MEMBER_MAX)
;   then member_count PAYLOADS in order, each a stream of BLOCKS (codec per the magic):
;        raw_len (2)          uncompressed length of this block (1..CHUNK); 0 ends the payload
;        enc_len (2)          length of the compressed data that follows (only if raw_len != 0)
;        enc[enc_len]         one self-contained block: PackBits stream (XAR1) or LZSA2 raw block
;                             (XAR2, `lzsa -r -f2`), each decoding to exactly raw_len bytes
;      ...payload terminated by a raw_len==0 word.
;   then the DIRECTORY: member_count entries, each:
;        blocks (2)           member's uncompressed size in 256-byte blocks (for the size column)
;        name_len (1)
;        name[name_len]       PETSCII, no NUL
;
; Per-block framing (each block an independent PackBits unit of known raw size <= CHUNK) is
; what lets extract decode block-by-block into a fixed CHUNK-sized buffer regardless of file
; size - the buffer codec can't resume a stream mid-way to spill output to disk.
;
; Browse/extract re-read from the front (skip payloads to reach the target member / directory);
; O(archive size) but seek-free and robust on hostfs. Archives are small (X16-to-X16), so fine.

%import textio             ; the browser modal draws here (UI-in-overlay pattern; keeps it off main RAM)
%import strings
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); own private copy
%import compression        ; prog8 stdlib: encode_rle / decode_rle (ByteRun1 / PackBits)
%import "shared-const"     ; CONSTANTS ONLY (zero bytes) - the app colour theme (shared.*)
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Fixed callable offsets via %jmptable (compiler prepends `jmp start` at $A000):
    ;   $A000 start(init) $A003 xar_browse $A006 xar_create_begin $A009 xar_create_add
    ;   $A00C xar_create_end $A00F xar_lz_decompress
    ; The whole browse modal (frame + key loop + extract) is self-contained here now: main just
    ; calls xar_browse(nameptr) and repaints on return. KEEP ALL MODULE VARS UNINITIALIZED
    ; (no "= ..."): prog8 emits a block's initialized vars inline BEFORE its jumptable, which
    ; would shove the table off $A003 (same gotcha as tview). NEW entries go at the END of the
    ; jmptable so the existing offsets never move.
    %jmptable ( main.xar_browse, main.xar_create_begin, main.xar_create_add, main.xar_create_end, main.xar_lz_decompress )

    const ubyte CHUNK      = 250       ; per-block raw size (<255 so f_read/f_write take one call)
    const ubyte MEMBER_MAX = 64        ; max members held for browse/create (bank-space bound)
    const ubyte NAME_CELL  = 24        ; bytes per member-name cell (23 chars + NUL)

    ; browser modal geometry (mirrors xfmgr's show_find_results window)
    const ubyte SF_TOP  = 2            ; first list row (row 0 = header bar, row 1 = col headers)
    const ubyte SF_VIS  = 27           ; visible list rows 2..28
    const ubyte SCR_BOT = 29           ; footer bar row

    ; --- shared state (ALL uninitialized -> BSS tail) ---
    ubyte[256] bufA                    ; raw (encode) / compressed (decode) staging
    ubyte[256] bufB                    ; compressed (encode) / raw (decode) staging
    ubyte[2]   w2                      ; 2-byte read/write scratch
    ubyte      rb                      ; 1-byte read scratch
    ubyte[68]  arcname                 ; archive filename copied in on entry
    uword      names_ptr               ; -> reserved name slab (cell k at names_ptr + k*NAME_CELL);
                                        ; a memory() block since a 1536-byte array exceeds prog8's 256 cap
    uword[MEMBER_MAX] m_blocks         ; per-member uncompressed size in blocks
    ubyte      member_count            ; members currently held (browse) / added (create)
    ubyte      xar_count_v             ; count byte written to / read from the archive header
    ubyte      trunc_flag              ; 1 if an opened archive had more members than MEMBER_MAX
    ubyte      xf_top                  ; browser: index of the row at the top of the window
    ubyte[NAME_CELL] outname           ; browser: extract target filename (kept out of shared bufs)

    sub start() {
        ; library init ($A000): compiler emits the BSS clear here. Do NO UI/system init.
        names_ptr = memory("xarnames", NAME_CELL * MEMBER_MAX, 0)   ; reserve the member-name slab
        member_count = 0
    }

    ; ---------- low-level sequential read/write helpers ----------

    sub rd8() -> ubyte {
        void diskio.f_read(&rb, 1)
        return rb
    }

    sub rd16() -> uword {
        void diskio.f_read(&w2, 2)
        return mkword(w2[1], w2[0])    ; little-endian
    }

    sub wr16(uword v) {
        w2[0] = lsb(v)
        w2[1] = msb(v)
        void diskio.f_write(&w2, 2)
    }

    sub skip_payload() {
        ; consume one member's payload (blocks up to the raw_len==0 terminator) on the READ channel
        repeat {
            uword raw = rd16()
            if raw == 0
                break
            uword enc = rd16()
            void diskio.f_read(&bufA, enc)     ; enc <= 253 < 255 -> one call; bytes discarded
        }
    }

    ; ---------- browse: open + validate + load directory ----------

    sub do_open(uword nameptr) -> ubyte {
        void strings.copy(nameptr, &arcname)
        member_count = 0
        trunc_flag = 0
        if not diskio.f_open(&arcname)
            return 0
        ; verify magic: "XAR1" (RLE blocks) or "XAR2" (LZSA2 blocks) - the 4th byte is the block codec
        if diskio.f_read(&bufA, 4) != 4 or bufA[0] != $58 or bufA[1] != $41 or bufA[2] != $52 or (bufA[3] != $31 and bufA[3] != $32) {
            diskio.f_close()
            return 0
        }
        xar_count_v = rd8()
        if xar_count_v == 0 {
            diskio.f_close()
            return 0
        }
        ; walk past every payload to reach the trailing directory
        ubyte k
        for k in 0 to xar_count_v - 1
            skip_payload()
        ; read the directory (cap at MEMBER_MAX; note truncation if the archive holds more)
        ubyte held = xar_count_v
        if held > MEMBER_MAX {
            held = MEMBER_MAX
            trunc_flag = 1
        }
        for k in 0 to held - 1 {
            m_blocks[k] = rd16()
            ubyte nlen = rd8()
            ubyte c = 0
            uword cell = names_ptr +k * NAME_CELL
            while c < nlen {
                ubyte ch = rd8()
                if c < NAME_CELL - 1 {
                    @(cell + c) = ch
                }
                c++
            }
            ; NUL-terminate (nlen may exceed the cell; extra chars were consumed but dropped)
            ubyte t = nlen
            if t > NAME_CELL - 1
                t = NAME_CELL - 1
            @(cell + t) = 0
        }
        diskio.f_close()
        member_count = held
        return held
    }

    sub do_name(ubyte idx, uword dest) {
        if idx >= member_count {
            @(dest) = 0
            return
        }
        void strings.copy(names_ptr + idx * NAME_CELL, dest)
    }

    ; ---------- extract one member to a file in the current dir ----------

    sub do_extract(ubyte idx, uword destname) -> ubyte {
        ; caller has chdir'd into the destination dir; destname is a bare name written there.
        ; returns 0=ok, 1=archive open, 2=bad header, 3=dest open, 4=write.
        if not diskio.f_open(&arcname)
            return 1
        if diskio.f_read(&bufA, 4) != 4 or bufA[0] != $58 or bufA[1] != $41 {
            diskio.f_close()
            return 2
        }
        ubyte codec = 0                    ; magic 4th byte: '1'=RLE, '2'=LZSA2
        if bufA[3] == $32
            codec = 1
        void rd8()                         ; member_count byte (already known)
        ; skip the payloads before the one we want
        if idx != 0 {
            ubyte k
            for k in 0 to idx - 1
                skip_payload()
        }
        ; open the output and decode our payload's blocks into it
        diskio.delete(destname)            ; hostfs won't truncate on open
        if not diskio.f_open_w(destname) {
            diskio.f_close()
            return 3
        }
        ubyte fail = 0
        repeat {
            uword raw = rd16()
            if raw == 0
                break
            uword enc = rd16()
            void diskio.f_read(&bufA, enc)               ; compressed block (<= 253 bytes)
            if codec == 0
                void compression.decode_rle(&bufA, &bufB, raw)      ; RLE: target @R0, maxsize @R1
            else
                void cx16.memory_decompress(&bufA, &bufB)           ; LZSA2 raw block -> ROM $FEED
            if not diskio.f_write(&bufB, raw) {
                fail = 4
                break
            }
        }
        diskio.f_close_w()
        diskio.f_close()
        return fail
    }

    ; ---------- LZSA2 decompression primitive ----------
    sub xar_lz_decompress(uword input @R0, uword output @R1) -> uword {
        ; Decompress ONE raw LZSA2 block from `input` into `output` via the X16 ROM ($FEED).
        ; Returns the end address (output + decompressed length), i.e. `output`+size.
        ;
        ; DECOMPRESS-ONLY: the X16 ROM has no LZSA2 compressor, so LZSA2 payloads must be produced
        ; off-device (the desktop `lzsa` tool / the LZ16 pipeline - see tools/CPLZ-APPS). XAR CREATE
        ; still uses RLE (compression.encode_rle); this is the standalone primitive for a future
        ; LZSA2 EXTRACT path. `output` may be &cx16.VERA_DATA0 to stream straight into VRAM (the
        ; return value is then meaningless - track the expected size yourself, as XCPLZ does).
        return cx16.memory_decompress(input, output)
    }

    ; ---------- browser modal (self-contained UI-in-overlay) ----------
    ; Small local copies of the textio helpers the modal needs (the overlay is a separate blob and
    ; can't call main's textio helpers; textio itself is cheap after dead-code elimination).

    sub px_wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub px_blank_span(ubyte col0, ubyte col1, ubyte row) {
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
    }

    sub px_hilite_row(ubyte x0, ubyte x1, ubyte row, ubyte color) {
        ubyte c
        for c in x0 to x1
            txt.setclr(c, row, color)
    }

    sub px_bar_fill(ubyte row) {
        ubyte c
        for c in 0 to 79 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, (shared.BAR_BG << 4) | shared.BAR_FG)
        }
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub px_bar_key(str s) {
        txt.color2(shared.BAR_KEY, shared.BAR_BG)
        txt.print(s)
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub px_print_trunc(uword s, ubyte maxlen) {
        ubyte i = 0
        while i < maxlen and @(s + i) != 0 {
            txt.chrout(@(s + i))
            i++
        }
    }

    sub draw_row(ubyte i, ubyte cursor) {
        ubyte srow = SF_TOP + (i - xf_top)
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)    ; white on gray body
        px_blank_span(0, 79, srow)
        if i < member_count {
            txt.plot(0, srow)
            if i == cursor
                txt.chrout('>')
            else
                txt.spc()
            px_print_trunc(names_ptr + i * NAME_CELL, 60)
            txt.plot(73, srow)
            txt.print_uw(m_blocks[i])
            if i == cursor
                px_hilite_row(0, 78, srow, shared.HILITE)
        }
    }

    sub draw_page(ubyte cursor) {
        ubyte row
        for row in 0 to SF_VIS-1
            draw_row(xf_top + row, cursor)
    }

    sub set_footer() {
        px_bar_fill(SCR_BOT)
        txt.plot(2, SCR_BOT)
        px_bar_key("Up/Dn")
        txt.print(" Move  ")
        px_bar_key(petscii:"┘")
        txt.print(" Extract  ")
        px_bar_key("A")
        txt.print(" Extract-all  ")
        px_bar_key("ESC")
        txt.print(" Close")
    }

    sub note(str m) {
        ; transient status on the footer bar (replaces the hotkeys until the next redraw)
        px_bar_fill(SCR_BOT)
        txt.plot(2, SCR_BOT)
        txt.print(m)
    }

    sub draw_frame() {
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)
        txt.clear_screen()
        px_bar_fill(0)                                  ; header bar
        txt.plot(2, 0)
        txt.print("XAR ")
        px_print_trunc(&arcname, 40)
        txt.print("  members: ")
        txt.print_ub(member_count)
        if trunc_flag != 0
            txt.print("  (capped)")
        txt.color2(shared.CLR_ACCENT, shared.CONTENT_BG)  ; column headers over the gray body
        txt.plot(2, 1)
        txt.print("Name")
        txt.plot(73, 1)
        txt.print("Size")
        set_footer()
    }

    sub extract_one(ubyte idx) {
        void strings.copy(names_ptr + idx * NAME_CELL, &outname)   ; member name = output filename
        if do_extract(idx, &outname) == 0
            note("extracted ok")
        else
            note("extract failed")
    }

    sub extract_all() {
        ubyte i
        ubyte fails = 0
        for i in 0 to member_count-1 {
            void strings.copy(names_ptr + i * NAME_CELL, &outname)
            if do_extract(i, &outname) != 0
                fails++
        }
        if fails == 0
            note("all members extracted")
        else
            note("some members failed")
    }

    sub xar_browse(uword nameptr @R0) -> ubyte {
        return do_browse(nameptr)
    }

    sub do_browse(uword nameptr) -> ubyte {
        ; open+validate the archive (arcname is stored), load its directory, then run the modal.
        ; The caller has chdir'd into the archive's directory; extraction writes members there.
        ; Returns 0 if the file was not a valid .xar (caller flashes), 1 after a normal close.
        if do_open(nameptr) == 0
            return 0

        xf_top = 0
        ubyte cursor = 0
        ubyte oldc

        draw_frame()
        draw_page(cursor)

        repeat {
            ubyte key = px_wait_key()
            if key >= $c1 and key <= $da
                key -= $80
            when key {
                27, 3, 'q' -> return 1
                13 -> extract_one(cursor)
                'a' -> extract_all()
                17 -> {                     ; down
                    if cursor + 1 < member_count {
                        oldc = cursor
                        cursor++
                        if cursor >= xf_top + SF_VIS {
                            xf_top++
                            draw_page(cursor)
                        } else {
                            draw_row(oldc, cursor)
                            draw_row(cursor, cursor)
                        }
                    }
                }
                145 -> {                    ; up
                    if cursor != 0 {
                        oldc = cursor
                        cursor--
                        if cursor < xf_top {
                            xf_top = cursor
                            draw_page(cursor)
                        } else {
                            draw_row(oldc, cursor)
                            draw_row(cursor, cursor)
                        }
                    }
                }
                2 -> {                      ; PgDn
                    if xf_top + SF_VIS < member_count {
                        xf_top += SF_VIS
                        cursor = xf_top
                        draw_page(cursor)
                    } else if cursor + 1 != member_count {
                        cursor = member_count - 1
                        draw_page(cursor)
                    }
                }
                130 -> {                    ; PgUp
                    if xf_top != 0 {
                        if xf_top >= SF_VIS
                            xf_top -= SF_VIS
                        else
                            xf_top = 0
                        cursor = xf_top
                        draw_page(cursor)
                    } else if cursor != 0 {
                        cursor = 0
                        draw_page(cursor)
                    }
                }
            }
        }
    }

    ; ---------- create: begin / add-one / end ----------

    sub xar_create_begin(uword nameptr @R0, ubyte count @R1) -> ubyte {
        return do_begin(nameptr, count)
    }

    sub do_begin(uword nameptr, ubyte count) -> ubyte {
        ; open a fresh archive and write the header (magic + member_count). count MUST equal the
        ; number of xar_create_add calls that follow (the caller's tagged-file count). Returns
        ; 0=ok, 1=open failed.
        void strings.copy(nameptr, &arcname)
        member_count = 0
        xar_count_v = count
        diskio.delete(&arcname)
        if not diskio.f_open_w(&arcname)
            return 1
        bufA[0] = $58                      ; "XAR1"
        bufA[1] = $41
        bufA[2] = $52
        bufA[3] = $31
        bufA[4] = count
        void diskio.f_write(&bufA, 5)
        return 0
    }

    sub xar_create_add(uword srcpath @R0, uword membername @R1) -> ubyte {
        return do_add(srcpath, membername)
    }

    sub do_add(uword srcpath, uword membername) -> ubyte {
        ; compress one source file into the open archive as the next payload, and record its
        ; directory entry (blocks + name) in memory for xar_create_end. Returns 0=ok,
        ; 2=source open failed (an empty payload is written so the count stays consistent).
        ; record the name now (cell is capped at NAME_CELL-1)
        if member_count < MEMBER_MAX {
            uword cell = names_ptr +member_count * NAME_CELL
            ubyte c = 0
            while c < NAME_CELL - 1 and @(membername + c) != 0 {
                @(cell + c) = @(membername + c)
                c++
            }
            @(cell + c) = 0
        }

        ubyte rc = 0
        uword mblk = 0
        uword mpart = 0
        if not diskio.f_open(srcpath) {
            rc = 2                         ; can't read source: emit an empty payload below
        } else {
            repeat {
                uword n = diskio.f_read(&bufA, CHUNK)
                if n == 0
                    break
                mpart += n
                while mpart >= 256 {
                    mblk++
                    mpart -= 256
                }
                uword enc = compression.encode_rle(&bufA, n, &bufB, true)
                wr16(n)
                wr16(enc)
                void diskio.f_write(&bufB, enc)
            }
            diskio.f_close()
            if mpart != 0
                mblk++
        }
        wr16(0)                            ; payload terminator (raw_len == 0)
        if member_count < MEMBER_MAX
            m_blocks[member_count] = mblk
        member_count++
        return rc
    }

    sub xar_create_end() -> ubyte {
        return do_end()
    }

    sub do_end() -> ubyte {
        ; append the directory (blocks + name per member) and close the write channel.
        ubyte k
        ubyte held = member_count
        if held > MEMBER_MAX
            held = MEMBER_MAX
        if held != 0 {
            for k in 0 to held - 1 {
                uword cell = names_ptr +k * NAME_CELL
                ubyte nlen = lsb(strings.length(cell))
                wr16(m_blocks[k])
                bufA[0] = nlen
                void diskio.f_write(&bufA, 1)
                if nlen != 0
                    void diskio.f_write(cell, nlen)
            }
        }
        diskio.f_close_w()
        return 0
    }
}

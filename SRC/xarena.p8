; xarena - banked "bump" allocator for the X16 HIRAM window ($A000-$BFFF).
;
; Why a bump allocator and not malloc/free:
;   XTree's data lifetime is append-only during a scan, then bulk-freed on rescan.
;   We never free a single record, so a bump pointer is all we need: O(1) alloc,
;   zero per-record header, zero fragmentation, "free" = reset the pointer.
;
; Storage spans many 8KB banks (FIRST_BANK..max_bank, the latter detected at runtime from
; the installed RAM so we never write a bank that doesn't exist). A 16-bit pointer can only see the
; one 8KB window that is currently mapped, so an arena location is a FAR pointer:
;   (bank: ubyte, offset: uword).   No record straddles a bank boundary - if it
;   would not fit in the remaining space, we waste the tail and roll to the next
;   bank (tail waste < ~3% for small records).

%import strings

xarena {
    %option ignore_unused

    const ubyte FIRST_BANK = 3          ; bank 0 = Kernal; bank 1 = xtree dir-extras;
                                        ; bank 2 = tview viewer overlay (VIEW_BANK in xfmgr)
    const uword WIN_START  = $a000
    const uword WIN_END    = $bf00      ; reserve $bf00-$bfff as scratch / guard

    ; --- allocator state ---
    ubyte max_bank                      ; highest usable RAM bank on THIS machine; set in
                                        ; reset() from cx16.numbanks(). A 512 KB X16 has 64
                                        ; banks (0..63) -> max_bank 63; a 2 MB machine -> 255.
                                        ; Banks wrap/alias above this, so we must never roll
                                        ; past it (silent corruption otherwise).
    ubyte cur_bank
    uword cur_ptr
    ubyte high_bank                     ; highest bank touched (for stats / eviction)

    ; --- result of the last alloc(): a far pointer to the reserved space ---
    ubyte result_bank
    uword result_off

    sub reset() {
        ; Bulk-free everything. No traversal needed.
        ; Detect the installed RAM so we never allocate into banks that don't exist on this
        ; machine. numbanks() returns the COUNT (1..256); highest valid index = count-1.
        max_bank  = lsb(cx16.numbanks() - 1)
        cur_bank  = FIRST_BANK
        cur_ptr   = WIN_START
        high_bank = FIRST_BANK
    }

    sub alloc(uword nbytes) -> bool {
        ; Reserve nbytes; on success result_bank/result_off point at the space.
        ; nbytes must be <= (WIN_END - WIN_START); callers only store small records.
        if cur_ptr + nbytes > WIN_END {
            ; won't fit in the current bank -> roll to the next one (but not past the last
            ; bank this machine actually has - rolling further would alias and corrupt)
            if cur_bank >= max_bank
                return false
            cur_bank++
            cur_ptr = WIN_START
            if cur_bank > high_bank
                high_bank = cur_bank
        }
        result_bank = cur_bank
        result_off  = cur_ptr
        cur_ptr += nbytes
        return true
    }

    sub add_str(str s) -> bool {
        ; Allocate len+1 bytes and copy the NUL-terminated string into the arena.
        ; On success the far pointer is in result_bank/result_off.
        if not alloc(strings.length(s) + 1)
            return false
        cx16.push_rambank(result_bank)
        uword dst = result_off
        ubyte ix = 0
        ubyte c
        repeat {
            c = s[ix]
            @(dst) = c
            dst++
            ix++
            if c == 0
                break
        }
        cx16.pop_rambank()
        return true
    }

    ; ---- far accessors (caller passes the far pointer) ----

    sub far_peek(ubyte bank, uword off) -> ubyte {
        cx16.push_rambank(bank)
        ubyte v = @(off)
        cx16.pop_rambank()
        return v
    }

    sub far_poke(ubyte bank, uword off, ubyte value) {
        cx16.push_rambank(bank)
        @(off) = value
        cx16.pop_rambank()
    }

    sub read_str(ubyte bank, uword off, str dest) {
        ; Copy a NUL-terminated string from the arena into a main-RAM buffer.
        cx16.push_rambank(bank)
        uword src = off
        ubyte ix = 0
        ubyte c
        repeat {
            c = @(src)
            dest[ix] = c
            src++
            ix++
            if c == 0
                break
        }
        cx16.pop_rambank()
    }
}

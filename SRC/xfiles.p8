; xfiles - per-directory FILE entries, stored in the banked arena (xarena).
;
; A file record is a length-prefixed, variable-length blob:
;   [0] reclen   (1 byte, = 6 + namelen)   -- a value of 0 is a SENTINEL meaning
;                                              "this bank is done, continue at $A000
;                                              of the next bank"
;   [1] blocksLo
;   [2] blocksHi
;   [3] ftype    (0=seq/file, 1=prg, 2=other)
;   [4] flags    (bit0 = tagged)
;   [5..] name bytes + NUL
;
; Records of one directory are written in one uninterrupted pass, so they form a
; contiguous run (possibly spanning a bank boundary, bridged by a sentinel). We
; never move a stored name: to show a directory we build a small main-RAM index
; of far pointers (ft_bank/ft_off) by walking the run.

%import strings
%import xarena

xfiles {
    %option ignore_unused

    const ubyte FILE_VIS_MAX = 255      ; max files indexed for one displayed dir
    const ubyte NAME_CAP     = 249      ; longest filename we store (keeps reclen<256)
    const ubyte GLOBAL_MAX   = 255      ; max tagged files collected for ShowAll

    ; bits in a record's flags byte (record offset +4)
    const ubyte REC_TAGGED = %00000001
    const ubyte REC_HIDDEN = %00000010  ; deleted: kept in the run but skipped on display

    ; bank-roll bookkeeping for the append side
    ubyte prev_bank
    uword prev_end

    ; far ptr of the most recently added record (scan links a dir to its first file)
    ubyte last_bank
    uword last_off

    ; display index for the currently shown directory
    ubyte[FILE_VIS_MAX] ft_bank
    uword[FILE_VIS_MAX] ft_off
    ubyte ft_count

    ; scratch buffers for name comparison while sorting
    str cmpa = "?" * 52
    str cmpb = "?" * 52
    str exa  = "?" * 20             ; extension scratch (sort by ext)
    str exb  = "?" * 20

    ; file sort order: 0 = name, 1 = extension, 2 = size
    ubyte sort_mode

    ; FileSpec display filter (XTreeGold): a wildcard, stored lowercased for
    ; case-insensitive matching. "*" means "show everything".
    str spec_lc = "?" * 32

    ; ShowAll: tagged files gathered from every logged directory
    ubyte[GLOBAL_MAX] sa_bank
    uword[GLOBAL_MAX] sa_off
    ubyte[GLOBAL_MAX] sa_dir
    ubyte sa_count

    sub reset() {
        prev_bank = 0
        prev_end  = 0
        spec_lc[0] = '*'                    ; default FileSpec: show everything
        spec_lc[1] = 0
    }

    sub set_spec(str pattern) {
        ; install a new FileSpec. Empty -> "*" (all). Stored lowercased for nocase match.
        if strings.length(pattern) == 0 {
            spec_lc[0] = '*'
            spec_lc[1] = 0
        } else {
            void strings.copy(pattern, spec_lc)
            void strings.lower(spec_lc)
        }
    }

    sub spec_all() -> bool {
        ; true when the FileSpec is the match-everything pattern "*"
        return spec_lc[0] == '*' and spec_lc[1] == 0
    }

    sub add_file(uword blocks, ubyte ftype, str name) -> bool {
        ubyte namelen = lsb(strings.length(name))
        if strings.length(name) > NAME_CAP
            namelen = NAME_CAP
        ubyte reclen = namelen + 6

        if not xarena.alloc(reclen)
            return false

        ; if the allocator rolled to a new bank, drop a sentinel at the tail of
        ; the previous bank so the walker knows to jump banks here
        if prev_bank != 0 and xarena.result_bank != prev_bank
            xarena.far_poke(prev_bank, prev_end, 0)

        cx16.push_rambank(xarena.result_bank)
        uword p = xarena.result_off
        @(p) = reclen
        p++
        @(p) = lsb(blocks)
        p++
        @(p) = msb(blocks)
        p++
        @(p) = ftype
        p++
        @(p) = 0                            ; flags
        p++
        ubyte ix = 0
        while ix < namelen {
            @(p) = name[ix]
            p++
            ix++
        }
        @(p) = 0                            ; NUL terminator
        cx16.pop_rambank()

        prev_bank = xarena.result_bank
        prev_end  = xarena.result_off + reclen
        last_bank = xarena.result_bank
        last_off  = xarena.result_off
        return true
    }

    sub build_index(ubyte dir_idx) -> ubyte {
        ; Walk dir's file run, filling ft_bank[]/ft_off[]. Returns count indexed.
        ft_count = 0
        uword remaining = xtree.dx_fcount(dir_idx)
        ubyte bank = xtree.dx_fbank(dir_idx)
        uword off  = xtree.dx_foff(dir_idx)
        while remaining != 0 and ft_count < FILE_VIS_MAX {
            ubyte rl = xarena.far_peek(bank, off)
            if rl == 0 {
                ; sentinel: jump to the next bank
                bank++
                off = xarena.WIN_START
                continue
            }
            ; include the record only if it isn't flagged deleted/hidden, and (when a
            ; FileSpec is active) only if its name matches the wildcard
            if xarena.far_peek(bank, off + 4) & REC_HIDDEN == 0 {
                bool keep = true
                if not spec_all() {
                    xarena.read_str(bank, off + 5, cmpa)
                    keep = strings.pattern_match_nocase(cmpa, spec_lc, false)
                }
                if keep {
                    ft_bank[ft_count] = bank
                    ft_off[ft_count]  = off
                    ft_count++
                }
            }
            off += rl
            remaining--
        }
        sort_index()
        return ft_count
    }

    sub blocks_at(ubyte bank, uword off) -> uword {
        cx16.push_rambank(bank)
        uword b = peekw(off + 1)
        cx16.pop_rambank()
        return b
    }

    sub ext_of(str name, str dest) {
        ; copy the extension (chars after the last '.') of name into dest; empty if none
        ubyte n = lsb(strings.length(name))
        ubyte dot = 255
        ubyte i = n
        while i != 0 {
            i--
            if name[i] == '.' {
                dot = i
                break
            }
        }
        ubyte j = 0
        if dot != 255 {
            i = dot + 1
            while i < n {
                dest[j] = name[i]
                j++
                i++
            }
        }
        dest[j] = 0
    }

    sub sort_index() {
        ; Insertion sort of the far-pointer index, keyed by sort_mode (0=name, 1=ext,
        ; 2=size). The stored records never move - only ft_bank[]/ft_off[].
        if ft_count < 2
            return
        ubyte i
        for i in 1 to ft_count-1 {
            ubyte b = ft_bank[i]
            uword o = ft_off[i]
            xarena.read_str(b, o + 5, cmpa)         ; name of the element to place
            uword ablocks = blocks_at(b, o)
            ubyte j = i
            while j != 0 {
                xarena.read_str(ft_bank[j-1], ft_off[j-1] + 5, cmpb)
                bool pred_le
                when sort_mode {
                    2 -> pred_le = blocks_at(ft_bank[j-1], ft_off[j-1]) <= ablocks
                    1 -> {
                        ext_of(cmpb, exb)
                        ext_of(cmpa, exa)
                        byte c = strings.compare_nocase(exb, exa)
                        if c == 0
                            c = strings.compare_nocase(cmpb, cmpa)
                        pred_le = c <= 0
                    }
                    else -> pred_le = strings.compare_nocase(cmpb, cmpa) <= 0
                }
                if pred_le
                    break                            ; predecessor already <= it
                ft_bank[j] = ft_bank[j-1]
                ft_off[j]  = ft_off[j-1]
                j--
            }
            ft_bank[j] = b
            ft_off[j]  = o
        }
    }

    sub tag_by_spec(str lc_pattern, ubyte dir_idx) -> ubyte {
        ; tag every visible file whose name matches the (lowercased) wildcard. The
        ; per-dir tagged count is bumped for each newly-tagged file. Returns the count
        ; of files that matched.
        ubyte cnt = 0
        if ft_count == 0
            return 0
        ubyte i
        for i in 0 to ft_count-1 {
            get_name(i, cmpa)
            if strings.pattern_match_nocase(cmpa, lc_pattern, false) {
                if not is_tagged(i) {
                    ubyte fl = xarena.far_peek(ft_bank[i], ft_off[i] + 4)
                    fl |= REC_TAGGED
                    xarena.far_poke(ft_bank[i], ft_off[i] + 4, fl)
                    xtree.dx_inc_tag(dir_idx)
                }
                cnt++
            }
        }
        return cnt
    }

    sub get_name(ubyte i, str dest) {
        xarena.read_str(ft_bank[i], ft_off[i] + 5, dest)
    }

    sub get_blocks(ubyte i) -> uword {
        cx16.push_rambank(ft_bank[i])
        uword b = peekw(ft_off[i] + 1)
        cx16.pop_rambank()
        return b
    }

    sub is_tagged(ubyte i) -> bool {
        return xarena.far_peek(ft_bank[i], ft_off[i] + 4) & 1 != 0
    }

    sub toggle_tag(ubyte i, ubyte dir_idx) {
        ubyte fl = xarena.far_peek(ft_bank[i], ft_off[i] + 4)
        if fl & 1 != 0 {
            fl &= %11111110
            xtree.dx_dec_tag(dir_idx)
        } else {
            fl |= %00000001
            xtree.dx_inc_tag(dir_idx)
        }
        xarena.far_poke(ft_bank[i], ft_off[i] + 4, fl)
    }

    sub tag_all(ubyte dir_idx) {
        ; tag every (visible) file in the current index
        if ft_count == 0
            return
        ubyte i
        for i in 0 to ft_count-1 {
            if not is_tagged(i) {
                ubyte fl = xarena.far_peek(ft_bank[i], ft_off[i] + 4)
                fl |= REC_TAGGED
                xarena.far_poke(ft_bank[i], ft_off[i] + 4, fl)
                xtree.dx_inc_tag(dir_idx)
            }
        }
    }

    sub untag_all(ubyte dir_idx) {
        if ft_count == 0
            return
        ubyte i
        for i in 0 to ft_count-1 {
            ubyte fl = xarena.far_peek(ft_bank[i], ft_off[i] + 4)
            fl &= %11111110              ; clear REC_TAGGED (bit 0)
            xarena.far_poke(ft_bank[i], ft_off[i] + 4, fl)
        }
        xtree.dx_set_tag(dir_idx, 0)
    }

    sub collect_tagged() {
        ; gather every tagged (non-hidden) file across all LOGGED directories into
        ; the sa_* arrays. Walks each dir's record run exactly like build_index.
        sa_count = 0
        ubyte d
        for d in 0 to xtree.dir_count-1 {
            if xtree.d_flags[d] & xtree.FL_SCANNED == 0
                continue
            uword remaining = xtree.dx_fcount(d)
            ubyte bank = xtree.dx_fbank(d)
            uword off  = xtree.dx_foff(d)
            while remaining != 0 and sa_count < GLOBAL_MAX {
                ubyte rl = xarena.far_peek(bank, off)
                if rl == 0 {
                    bank++
                    off = xarena.WIN_START
                    continue
                }
                ubyte fl = xarena.far_peek(bank, off + 4)
                if fl & REC_TAGGED != 0 and fl & REC_HIDDEN == 0 {
                    sa_bank[sa_count] = bank
                    sa_off[sa_count]  = off
                    sa_dir[sa_count]  = d
                    sa_count++
                }
                off += rl
                remaining--
            }
        }
    }

    sub sa_name(ubyte i, str dest) {
        xarena.read_str(sa_bank[i], sa_off[i] + 5, dest)
    }

    sub sa_blocks(ubyte i) -> uword {
        cx16.push_rambank(sa_bank[i])
        uword b = peekw(sa_off[i] + 1)
        cx16.pop_rambank()
        return b
    }

    sub sa_untag(ubyte i) {
        ; untag a ShowAll entry and decrement its owning directory's tagged count
        ubyte fl = xarena.far_peek(sa_bank[i], sa_off[i] + 4)
        if fl & REC_TAGGED != 0 {
            fl &= %11111110
            xarena.far_poke(sa_bank[i], sa_off[i] + 4, fl)
            xtree.dx_dec_tag(sa_dir[i])
        }
    }

    sub invert_all(ubyte dir_idx) {
        ; flip the tag state of every visible file
        if ft_count == 0
            return
        ubyte i
        for i in 0 to ft_count-1
            toggle_tag(i, dir_idx)
    }

    sub name_cap(ubyte i) -> ubyte {
        ; how many name characters fit in this record's slot (reclen - 6)
        return xarena.far_peek(ft_bank[i], ft_off[i]) - 6
    }

    sub hide(ubyte i, ubyte dir_idx) {
        ; mark a record deleted: it stays in the run (so the walker still advances
        ; by reclen) but build_index skips it. Untag first so counts stay correct.
        ubyte fl = xarena.far_peek(ft_bank[i], ft_off[i] + 4)
        if fl & REC_TAGGED != 0
            xtree.dx_dec_tag(dir_idx)
        fl |= REC_HIDDEN
        xarena.far_poke(ft_bank[i], ft_off[i] + 4, fl)
    }

    sub rename_inplace(ubyte i, str newname) -> bool {
        ; overwrite the name in the existing slot; fails if the new name is longer
        ; than the slot (the arena is append-only, so we can't grow a record).
        if strings.length(newname) > name_cap(i)
            return false
        cx16.push_rambank(ft_bank[i])
        uword p = ft_off[i] + 5
        ubyte ix = 0
        ubyte c
        repeat {
            c = newname[ix]
            @(p) = c
            p++
            ix++
            if c == 0
                break
        }
        cx16.pop_rambank()
        return true
    }
}

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
; never move a stored name: to show a list of files we build an index of far
; pointers by walking the run(s). That index lives in BANKED RAM - see THE FILE
; INDEX below - and is shared by directory listings, scoped views and Find.

%import strings
%import xarena

xfiles {
    %option ignore_unused

    const ubyte NAME_CAP     = 249      ; longest filename we store (keeps reclen<256)
    const uword INDEX_MAX    = 1024     ; max rows the file index holds (past it -> "(partial)")
                                        ; 1024 * 4-byte rows = the full $b000..$bfff of INDEX_BANK

    ; bits in a record's flags byte (record offset +4)
    const ubyte REC_TAGGED = %00000001
    const ubyte REC_HIDDEN = %00000010  ; deleted: kept in the run but skipped on display

    ; bank-roll bookkeeping for the append side
    ubyte prev_bank
    uword prev_end

    ; far ptr of the most recently added record (scan links a dir to its first file)
    ubyte last_bank
    uword last_off

    ; Row count of the file index (see the index block below). uword, because a whole-disk
    ; scope routinely runs past 255 and a truncated list that cannot say so is worse than useless.
    uword ft_count

    ; Which set of files the pane is listing. Set by main when entering/leaving a scoped view.
    ;   0 = SCOPE_DIR    - the current directory (classic behaviour)
    ;   1 = SCOPE_BRANCH - the current directory AND everything logged below it (XTree "Branch")
    ;   2 = SCOPE_DISK   - every logged file on the disk (XTree "Showall")
    ; The order matters only in that SCOPE_DIR is 0, so a zeroed BSS starts in the normal view.
    const ubyte SCOPE_DIR    = 0
    const ubyte SCOPE_BRANCH = 1
    const ubyte SCOPE_DISK   = 2
    ubyte file_scope
    bool scope_partial              ; more files matched than INDEX_MAX rows, so the list is truncated

    ; scratch buffers for name comparison while sorting
    str cmpa = "?" * 52
    str cmpb = "?" * 52
    str exa  = "?" * 20             ; extension scratch (sort by ext)
    str exb  = "?" * 20

    ; max chars any name read from the arena into a RAM buffer may occupy (all such buffers -
    ; cmpa/cmpb here, plus main's namebuf - are 52 bytes). read_str caps at this so a stored
    ; name longer than the buffer (up to NAME_CAP=249) truncates the copy instead of overrunning.
    const ubyte NAME_RD_CAP = 51

    ; file sort order: 0 = name, 1 = extension, 2 = size
    ubyte sort_mode

    ; FileSpec display filter (XTreeGold): a wildcard, stored lowercased for
    ; case-insensitive matching. "*" means "show everything".
    str spec_lc = "?" * 32

    ; ---- THE FILE INDEX ----
    ;
    ; One index serves every file list: a single directory, a scoped view (Showall/Branch), and the
    ; Find results browser. It lives in BANKED RAM, not main RAM. That is what lets it hold 1024 rows
    ; instead of 255 - three main-RAM arrays of 1024 rows would be 4 KB, which this program does not
    ; have, and truncating a Showall to 255 rows produced an ARBITRARY 255 (whatever the directory
    ; walk reached first, sorted among themselves), not the first 255 alphabetically.
    ;
    ; It shares bank 1 with xtree's dir-extras: those sit at $a000..~$a6f2, so the index is parked at
    ; $b000..$bfff (4 KB = INDEX_MAX rows), well clear. Per-row 4-byte record:
    ;     +0 bank(ubyte)  +1 off(uword)  +3 dir(ubyte)
    ; `dir` is the directory that row came from. A single-directory listing sets it to the same value
    ; on every row, so scoped and normal views are one code path, not two.
    ;
    ; Rows are read through row_load(), which fills fr_bank/fr_off/fr_dir in ONE bank switch - every
    ; caller wants at least two of the three. INVARIANT: fr_* is a single staging buffer, so a caller
    ; must consume it before the next row_load() (same rule as xtree's name_ptr).
    const ubyte INDEX_BANK = 1
    const uword INDEX_BASE = $b000
    const ubyte INDEX_REC  = 4
    uword match_total               ; files that MATCHED, counted past INDEX_MAX - what the header
                                    ; reports, so a truncated list can say how much it truncated

    ubyte fr_bank                   ; far pointer + owning dir of the row last row_load()ed
    uword fr_off
    ubyte fr_dir

    sub row_addr(uword i) -> uword {
        return INDEX_BASE + i * INDEX_REC
    }
    sub row_load(uword i) {
        cx16.push_rambank(INDEX_BANK)
        uword p = row_addr(i)
        fr_bank = @(p)
        fr_off  = peekw(p + 1)
        fr_dir  = @(p + 3)
        cx16.pop_rambank()
    }
    sub row_set(uword i, ubyte bank, uword off, ubyte dir) {
        cx16.push_rambank(INDEX_BANK)
        uword p = row_addr(i)
        @(p)     = bank
        pokew(p + 1, off)
        @(p + 3) = dir
        cx16.pop_rambank()
    }
    sub row_dir(uword i) -> ubyte {
        ; the owning directory of one row, for callers that want only that
        cx16.push_rambank(INDEX_BANK)
        ubyte v = @(row_addr(i) + 3)
        cx16.pop_rambank()
        return v
    }

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
        ; true when the FileSpec matches everything: bare "*" or the DOS-style "*.*".
        ; Treating "*.*" as show-all means files WITHOUT an extension aren't hidden by the
        ; literal '.' in the pattern (op_filespec inserts "*.*" on a blank-line ENTER).
        if spec_lc[0] == '*' and spec_lc[1] == 0
            return true
        return spec_lc[0] == '*' and spec_lc[1] == '.' and spec_lc[2] == '*' and spec_lc[3] == 0
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

    sub build_index(ubyte dir_idx) -> uword {
        ; Walk dir's file run, filling the index. Returns the row count.
        ft_count = 0
        match_total = 0
        scope_partial = false
        uword remaining = xtree.dx_fcount(dir_idx)
        ubyte bank = xtree.dx_fbank(dir_idx)
        uword off  = xtree.dx_foff(dir_idx)
        while remaining != 0 {
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
                    xarena.read_str(bank, off + 5, cmpa, NAME_RD_CAP)
                    keep = strings.pattern_match_nocase(cmpa, spec_lc, false)
                }
                if keep {
                    match_total++
                    if ft_count < INDEX_MAX {
                        row_set(ft_count, bank, off, dir_idx)   ; a normal view: same dir on every row
                        ft_count++
                    }
                }
            }
            off += rl
            remaining--
        }
        scope_partial = match_total > ft_count
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
        ; Shell sort of the index, keyed by sort_mode (0=name, 1=ext, 2=size). The stored file
        ; records never move - only the index rows.
        ;
        ; Why not the insertion sort this replaced: EVERY comparison costs a far string read out of
        ; the arena, and insertion sort needs n(n-1)/4 of them on average - about 16k at 255 rows and
        ; 262k at 1024, which is seconds of "Working...". The Knuth gap sequence gets the same result
        ; from a few thousand comparisons using the same comparison code, for about 60 extra bytes.
        ; It is what makes a 1024-row index sortable at all.
        if ft_count < 2
            return
        uword gap = 1
        while gap < ft_count / 3
            gap = gap * 3 + 1                  ; 1, 4, 13, 40, 121, 364, 1093
        while gap != 0 {
            uword i = gap
            while i < ft_count {
                row_load(i)
                ubyte hold_bank = fr_bank      ; the row being placed - consume fr_* immediately
                uword hold_off  = fr_off
                ubyte hold_dir  = fr_dir
                xarena.read_str(hold_bank, hold_off + 5, cmpa, NAME_RD_CAP)
                uword ablocks = blocks_at(hold_bank, hold_off)
                uword j = i
                while j >= gap {
                    row_load(j - gap)
                    ubyte pred_bank = fr_bank      ; the row `gap` places back, ditto
                    uword pred_off  = fr_off
                    ubyte pred_dir  = fr_dir
                    xarena.read_str(pred_bank, pred_off + 5, cmpb, NAME_RD_CAP)
                    bool pred_le
                    when sort_mode {
                        2 -> pred_le = blocks_at(pred_bank, pred_off) <= ablocks
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
                        break                  ; predecessor already <= it
                    row_set(j, pred_bank, pred_off, pred_dir)
                    j -= gap
                }
                row_set(j, hold_bank, hold_off, hold_dir)
                i++
            }
            gap /= 3
        }
    }

    sub tag_by_spec(str lc_pattern) -> uword {
        ; tag every visible file whose name matches the (lowercased) wildcard. The
        ; per-dir tagged count is bumped for each newly-tagged file. Returns the count
        ; of files that matched.
        uword cnt = 0
        uword i = 0
        while i < ft_count {
            get_name(i, cmpa)
            if strings.pattern_match_nocase(cmpa, lc_pattern, false) {
                if not is_tagged(i)
                    set_tag(i)
                cnt++
            }
            i++
        }
        return cnt
    }

    sub get_name(uword i, str dest) {
        ; dest is always a >=52-byte buffer (namebuf / cmpa / pathbuf); cap keeps long names in bounds
        row_load(i)
        xarena.read_str(fr_bank, fr_off + 5, dest, NAME_RD_CAP)
    }

    sub get_blocks(uword i) -> uword {
        row_load(i)
        cx16.push_rambank(fr_bank)
        uword b = peekw(fr_off + 1)
        cx16.pop_rambank()
        return b
    }

    sub is_tagged(uword i) -> bool {
        row_load(i)
        return xarena.far_peek(fr_bank, fr_off + 4) & REC_TAGGED != 0
    }

    ; Tagging credits each file to ITS OWN row's directory (fr_dir), never to one directory passed
    ; in by the caller. In a single-directory listing those are the same value; in a scoped listing
    ; they are not, and using a single index would corrupt the per-directory tag counters that drive
    ; the tree display and the "N Tagged" header.
    sub set_tag(uword i) {
        ; tag row i (no-op if already tagged, so the dir counter cannot double-count)
        row_load(i)
        ubyte fl = xarena.far_peek(fr_bank, fr_off + 4)
        if fl & REC_TAGGED != 0
            return
        xarena.far_poke(fr_bank, fr_off + 4, fl | REC_TAGGED)
        xtree.dx_inc_tag(fr_dir)
    }

    sub clear_tag(uword i) {
        ; untag row i (no-op if not tagged)
        row_load(i)
        ubyte fl = xarena.far_peek(fr_bank, fr_off + 4)
        if fl & REC_TAGGED == 0
            return
        xarena.far_poke(fr_bank, fr_off + 4, fl & %11111110)
        xtree.dx_dec_tag(fr_dir)
    }

    sub toggle_tag(uword i) {
        row_load(i)
        ubyte fl = xarena.far_peek(fr_bank, fr_off + 4)
        if fl & REC_TAGGED != 0 {
            xarena.far_poke(fr_bank, fr_off + 4, fl & %11111110)
            xtree.dx_dec_tag(fr_dir)
        } else {
            xarena.far_poke(fr_bank, fr_off + 4, fl | REC_TAGGED)
            xtree.dx_inc_tag(fr_dir)
        }
    }

    sub tag_all() {
        ; tag every (visible) file in the current index
        uword i = 0
        while i < ft_count {
            set_tag(i)
            i++
        }
    }

    sub untag_all() {
        uword i = 0
        while i < ft_count {
            clear_tag(i)
            i++
        }
    }

    ; ---- one shared arena walker for the multi-directory gathers (Showall / Branch / Find) ----
    ; The collectors differ only in the per-record test, so they share this walker to keep code
    ; size down (main RAM is scarce). It walks every LOGGED directory's record run (bridging bank
    ; sentinels like build_index) and fills the index, capped at INDEX_MAX.
    ;   mode 0 = tagged only            (tagged-file consolidation)
    ;   mode 1 = NAME matches `pat`     (Find-file results)
    ;   mode 2 = all files passing the FileSpec `pat` (Showall/Branch; '*' short-circuits the match)
    ; `collect_root` narrows WHICH directories are walked: xtree.NONE = every logged one (Showall,
    ; Find), otherwise only that directory and its descendants (Branch).
    ; NOTE this REPLACES whatever the file pane was listing - it is the same index. Callers that
    ; gather for a modal list (Find) must rebuild the pane's view when they are done.
    ubyte collect_root

    sub in_branch(ubyte d) -> bool {
        ; is directory d inside the collect_root subtree? Walks parents, so it costs the depth of
        ; d - a handful of banked reads per directory, once per gather, not per file.
        ubyte ancestor = d
        while ancestor != xtree.NONE {
            if ancestor == collect_root
                return true
            ancestor = xtree.dx_parent(ancestor)
        }
        return false
    }

    sub collect(ubyte mode, str pat) {
        ft_count = 0
        match_total = 0
        bool takeall = mode == 2 and spec_all()
        ubyte d
        for d in 0 to xtree.dir_count-1 {
            if xtree.d_flags[d] & xtree.FL_SCANNED == 0
                continue
            if collect_root != xtree.NONE and not in_branch(d)
                continue                        ; Branch: outside the subtree we were asked for
            uword remaining = xtree.dx_fcount(d)
            ubyte bank = xtree.dx_fbank(d)
            uword off  = xtree.dx_foff(d)
            ; The walk runs to the END even once the index is full: storing stops at INDEX_MAX
            ; but counting does not, because a truncated list still has to be able to say how much
            ; it truncated. Walking records is cheap - it is the sort afterwards that costs.
            while remaining != 0 {
                ubyte rl = xarena.far_peek(bank, off)
                if rl == 0 {
                    bank++
                    off = xarena.WIN_START
                    continue
                }
                ubyte fl = xarena.far_peek(bank, off + 4)
                if fl & REC_HIDDEN == 0 {
                    bool take = false
                    if mode == 0 {
                        take = fl & REC_TAGGED != 0
                    } else if takeall {
                        take = true
                    } else {
                        xarena.read_str(bank, off + 5, cmpa, NAME_RD_CAP)
                        take = strings.pattern_match_nocase(cmpa, pat, false)
                    }
                    if take {
                        match_total++
                        if ft_count < INDEX_MAX {
                            row_set(ft_count, bank, off, d)
                            ft_count++
                        }
                    }
                }
                off += rl
                remaining--
            }
        }
        scope_partial = match_total > ft_count
    }

    sub build_scoped_index(ubyte branch_root) -> uword {
        ; Fill the index from a SCOPED gather (Showall/Branch) instead of one directory. collect()
        ; already walks the logged directories' record runs, applies the FileSpec and records the
        ; owning directory per row, straight into the index - so all that is left is the sort.
        ; branch_root = xtree.NONE for the whole disk, else the subtree to stay inside.
        collect_root = branch_root
        collect_all()
        sort_index()
        return ft_count
    }

    sub collect_tagged()               { collect_root = xtree.NONE  collect(0, spec_lc) }
    sub collect_matching(str lc_pat)   { collect_root = xtree.NONE  collect(1, lc_pat)  }  ; Find: whole disk
    sub collect_all()                  { collect(2, spec_lc) }    ; caller sets collect_root first

    sub invert_all() {
        ; flip the tag state of every visible file
        uword i = 0
        while i < ft_count {
            toggle_tag(i)
            i++
        }
    }

    sub name_cap(uword i) -> ubyte {
        ; how many name characters fit in this record's slot (reclen - 6)
        row_load(i)
        return xarena.far_peek(fr_bank, fr_off) - 6
    }

    sub hide(uword i) {
        ; mark a record deleted: it stays in the run (so the walker still advances
        ; by reclen) but build_index skips it. Untag first so counts stay correct.
        row_load(i)
        ubyte fl = xarena.far_peek(fr_bank, fr_off + 4)
        if fl & REC_TAGGED != 0
            xtree.dx_dec_tag(fr_dir)
        xarena.far_poke(fr_bank, fr_off + 4, fl | REC_HIDDEN)
    }

    sub rename_inplace(uword i, str newname) -> bool {
        ; overwrite the name in the existing slot; fails if the new name is longer
        ; than the slot (the arena is append-only, so we can't grow a record).
        if strings.length(newname) > name_cap(i)
            return false
        row_load(i)                    ; name_cap above did its own row_load - reload before use
        cx16.push_rambank(fr_bank)
        uword p = fr_off + 5
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

; xtree - the directory tree, kept entirely in MAIN RAM.
;
; The tree holds DIRECTORIES ONLY (files live in the banked arena, see xfiles).
; There are far fewer directories than files, so the always-on-screen, redraw-hot
; tree pane can afford to stay in main RAM where no bank switching is needed.
;
; Nodes are a fixed pool addressed by a BYTE index (Prog8 array indices are bytes),
; not by pointer. Indices are bank-agnostic and never dangle. NONE = 255 ($FF)
; terminates every link, so the pool is capped below 255 nodes.
; Directory NAMES go in a small main-RAM bump arena, referenced by byte offset.

%import strings
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header

xtree {
    %option ignore_unused

    const ubyte NONE     = 255
    const ubyte DIR_MAX  = 254          ; max directories logged; the ceiling - node ids are a ubyte
                                        ; and NONE=255 terminates links, so 254 is the hard max
    const uword DNAME_SZ = 3072         ; bytes of directory-name storage
    const ubyte MAXDEPTH = 16           ; deepest path we build

    ; flag bits in d_flags
    const ubyte FL_EXPANDED = %00000001
    const ubyte FL_SCANNED  = %00000010 ; children already read from disk
    const ubyte FL_HASKIDS  = %00000100 ; has at least one child directory
    const ubyte FL_DENIED   = %00001000

    ; --- the node pool (parallel arrays, indexed by a byte node id) ---
    ; The redraw-hot fields (links, name offset, flags, depth) stay in MAIN RAM. The
    ; "cold" per-directory fields (file location + tagged count) are touched only on
    ; scan / file-load / tagging ops - never in the per-row redraw loop - so they live
    ; in BANKED RAM (see the dir-extras block below) to reclaim ~1.3 KB of main RAM.
     ; d_parent (+10) moved to the DX_BANK record; see dx_parent
    ubyte[DIR_MAX] d_first_child        ; node id
    ubyte[DIR_MAX] d_next_sibling       ; node id
    ubyte[DIR_MAX] d_flags
    ; d_name_off (+7) and d_depth (+9) moved to the DX_BANK record; see dx_noff/dx_depth

    ubyte dir_count

    ; --- per-directory extras, kept in BANKED RAM to save main RAM ---
    ; A fixed 14-byte record per node id, packed into bank DX_BANK at DX_BASE + id*DX_REC:
    ;   +0 file_count (uword)  +2 file_off (uword)  +4 file_bank (ubyte)  +5 tagged (uword)
    ;   +7 name_off (uword)  +9 depth (ubyte)  +10 parent  +11 first_child  +12 next_sibling  +13 flags
    ; The +7.. fields were formerly the d_* main-RAM node-pool arrays; they moved here to reclaim
    ; ~1.7 KB of main RAM (the 1024-entry ShowAll snapshot needed uword indices, which cost it).
    ; DX_BANK is the LOWEST arena bank (always present, even on a 512 KB machine); the
    ; file arena starts one bank higher (xarena.FIRST_BANK = DX_BANK + 1), so the bump
    ; allocator and its reset() never disturb this table. 254 nodes * 14 = 3556 B ($a000..$ade4),
    ; clear of the sa index at $b000, both inside this 8 KB bank.
    const ubyte DX_BANK = 1
    const uword DX_BASE = $a000
    const ubyte DX_REC  = 14

    sub dx_off(ubyte idx) -> uword {
        return DX_BASE + (idx as uword) * DX_REC
    }

    sub dx_clear(ubyte idx) {
        ; zero the WHOLE record - for a FRESH node only (new_node re-sets name_off/depth/parent after)
        uword o = dx_off(idx)
        cx16.push_rambank(DX_BANK)
        ubyte i
        for i in 0 to DX_REC - 1
            @(o + i) = 0
        cx16.pop_rambank()
    }

    sub dx_clear_files(ubyte idx) {
        ; zero ONLY the cold file fields (+0..+6: file_count/off/bank/tagged), leaving the structural
        ; name_off(+7)/depth(+9)/parent(+10) intact - for unlog(), which resets a STILL-LIVE node's
        ; scan state without detaching it from the tree.
        uword o = dx_off(idx)
        cx16.push_rambank(DX_BANK)
        ubyte i
        for i in 0 to 6
            @(o + i) = 0
        cx16.pop_rambank()
    }

    sub dx_fcount(ubyte idx) -> uword {
        cx16.push_rambank(DX_BANK)
        uword v = peekw(dx_off(idx))
        cx16.pop_rambank()
        return v
    }
    sub dx_set_fcount(ubyte idx, uword v) {
        cx16.push_rambank(DX_BANK)
        pokew(dx_off(idx), v)
        cx16.pop_rambank()
    }
    sub dx_inc_fcount(ubyte idx) {
        dx_set_fcount(idx, dx_fcount(idx) + 1)
    }

    sub dx_foff(ubyte idx) -> uword {
        cx16.push_rambank(DX_BANK)
        uword v = peekw(dx_off(idx) + 2)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_foff(ubyte idx, uword v) {
        cx16.push_rambank(DX_BANK)
        pokew(dx_off(idx) + 2, v)
        cx16.pop_rambank()
    }

    sub dx_fbank(ubyte idx) -> ubyte {
        cx16.push_rambank(DX_BANK)
        ubyte v = @(dx_off(idx) + 4)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_fbank(ubyte idx, ubyte v) {
        cx16.push_rambank(DX_BANK)
        @(dx_off(idx) + 4) = v
        cx16.pop_rambank()
    }

    sub dx_tag(ubyte idx) -> uword {
        cx16.push_rambank(DX_BANK)
        uword v = peekw(dx_off(idx) + 5)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_tag(ubyte idx, uword v) {
        cx16.push_rambank(DX_BANK)
        pokew(dx_off(idx) + 5, v)
        cx16.pop_rambank()
    }
    sub dx_inc_tag(ubyte idx) {
        dx_set_tag(idx, dx_tag(idx) + 1)
    }
    sub dx_dec_tag(ubyte idx) {
        uword t = dx_tag(idx)
        if t != 0
            dx_set_tag(idx, t - 1)
    }

    ; +7 name_off: byte offset of this node's name in the NAME_BANK arena (was d_name_off[])
    sub dx_noff(ubyte idx) -> uword {
        cx16.push_rambank(DX_BANK)
        uword v = peekw(dx_off(idx) + 7)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_noff(ubyte idx, uword v) {
        cx16.push_rambank(DX_BANK)
        pokew(dx_off(idx) + 7, v)
        cx16.pop_rambank()
    }

    ; +9 depth: tree indentation level, 0 at root (was d_depth[])
    sub dx_depth(ubyte idx) -> ubyte {
        cx16.push_rambank(DX_BANK)
        ubyte v = @(dx_off(idx) + 9)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_depth(ubyte idx, ubyte v) {
        cx16.push_rambank(DX_BANK)
        @(dx_off(idx) + 9) = v
        cx16.pop_rambank()
    }

    ; +10 parent: node id of this node's parent, NONE at root (was d_parent[])
    sub dx_parent(ubyte idx) -> ubyte {
        cx16.push_rambank(DX_BANK)
        ubyte v = @(dx_off(idx) + 10)
        cx16.pop_rambank()
        return v
    }
    sub dx_set_parent(ubyte idx, ubyte v) {
        cx16.push_rambank(DX_BANK)
        @(dx_off(idx) + 10) = v
        cx16.pop_rambank()
    }

    ; --- directory-name bump arena (BANKED: reserved bank 8, NAME_BANK) ---
    ; Names live in NAME_BANK at NAME_BASE+offset, NOT main RAM - this reclaimed the 3072-byte
    ; main-RAM slab. dx_noff(idx) is still a byte offset into the arena; the name's far address
    ; is NAME_BASE + dx_noff(idx). name_ptr() far-reads the requested name into name_stage (main
    ; RAM) and returns that pointer, so every reader keeps its plain str API unchanged. ONE staging
    ; buffer is safe: no code holds a name_ptr result across another name_ptr call (draw_tree /
    ; build_path / the name compares all consume it immediately, one node at a time).
    const ubyte NAME_BANK = 8
    const uword NAME_BASE = $a000
    uword dname_next
    str name_stage = "?" * 63           ; name_ptr's far-read landing buffer (dir names are <= ~49)

    ; --- flattened "visible" list, rebuilt when expand state changes ---
    ubyte[DIR_MAX] vis_idx              ; node ids in display order
    ubyte vis_count

    str base_path = "?" * 64            ; path of the root node on the drive

    sub init() {
        dir_count = 0
        dname_next = 0
        ; the tree is always anchored at the drive root, so paths built from node 0 are
        ; absolute regardless of which subdirectory XFMGR was launched from
        void strings.copy("/", base_path)
        ; create the root node. Its on-screen name is just "/" (the drive root): on the emulator
        ; host-fs diskio.diskname() returns the CURRENT folder (the launch dir, e.g. "1111"), not a
        ; volume label, so it mislabels the root. build_path stops at node 0 and prefixes base_path
        ; ("/"), so this name is display-only and never enters a path.
        ubyte root = new_node("/", NONE)
        d_flags[root] |= FL_EXPANDED
        rebuild_visible()
    }

    sub dname_store(str s) -> uword {
        ; returns byte offset into the name bank, or $ffff if the arena is full
        uword off = dname_next
        uword n = strings.length(s) + 1
        if off + n > DNAME_SZ
            return $ffff
        xarena.far_write_str(NAME_BANK, NAME_BASE + off, s)
        dname_next += n
        return off
    }

    sub name_ptr(ubyte idx) -> str {
        ; far-read the banked name into the shared staging buffer; valid until the NEXT call
        xarena.read_str(NAME_BANK, NAME_BASE + dx_noff(idx), name_stage, 63)
        return name_stage
    }

    sub rename_node(ubyte idx, str newname) {
        ; change a directory node's stored name. Fits the old slot -> overwrite in place;
        ; longer -> append a fresh copy to the name arena (the old bytes leak, like unlink()).
        if strings.length(newname) <= strings.length(name_ptr(idx)) {
            ; fits the old slot: overwrite in place (far-write into the name bank)
            xarena.far_write_str(NAME_BANK, NAME_BASE + dx_noff(idx), newname)
        } else {
            uword noff = dname_store(newname)               ; longer: append (old bytes leak)
            if noff != $ffff
                dx_set_noff(idx, noff)
        }
    }

    sub new_node(str name, ubyte parent) -> ubyte {
        if dir_count >= DIR_MAX
            return NONE
        uword noff = dname_store(name)      ; reserve the name FIRST; if the name arena is full
        if noff == $ffff                    ; ($ffff) don't create a half-built node whose
            return NONE                     ; name_ptr would dereference dname_buf+$ffff
        ubyte idx = dir_count
        dir_count++
        dx_clear(idx)                       ; zero the WHOLE banked record FIRST (it now holds name_off too)
        dx_set_noff(idx, noff)              ; ...then write the banked fields
        dx_set_parent(idx, parent)
        d_first_child[idx]   = NONE
        d_next_sibling[idx]  = NONE
        d_flags[idx]         = 0
        if parent == NONE
            dx_set_depth(idx, 0)
        else
            dx_set_depth(idx, dx_depth(parent) + 1)
        return idx
    }

    sub add_child(ubyte parent, str name) -> ubyte {
        ubyte idx = new_node(name, parent)
        if idx == NONE
            return NONE
        ; link as the LAST sibling under parent
        if d_first_child[parent] == NONE {
            d_first_child[parent] = idx
        } else {
            ubyte s = d_first_child[parent]
            while d_next_sibling[s] != NONE
                s = d_next_sibling[s]
            d_next_sibling[s] = idx
        }
        d_flags[parent] |= FL_HASKIDS
        return idx
    }

    sub unlink(ubyte idx) {
        ; detach idx from its parent's child chain (used after a directory is pruned on
        ; disk). The node slot itself is NOT reclaimed - the pool is append-only, so it
        ; just leaks until the next full reset(); its now-unreachable subtree leaks too.
        ubyte parent = dx_parent(idx)
        if parent == NONE
            return                          ; root has no parent; never unlinked
        if d_first_child[parent] == idx {
            d_first_child[parent] = d_next_sibling[idx]
        } else {
            ubyte s = d_first_child[parent]
            while s != NONE and d_next_sibling[s] != idx
                s = d_next_sibling[s]
            if s != NONE
                d_next_sibling[s] = d_next_sibling[idx]
        }
        if d_first_child[parent] == NONE
            d_flags[parent] &= ~FL_HASKIDS  ; parent lost its last child: drop the +/- marker
    }

    sub unlog(ubyte idx) {
        ; Return a directory to its just-created, UNSCANNED state (the inverse of a scan):
        ; cut its whole logged child subtree loose and clear the scan/expand flags, so the
        ; pane shows "(Enter to log)" again and it will re-scan fresh on the next Enter.
        ; Like unlink(), the orphaned child slots (and their name-arena bytes) LEAK - the
        ; node pool and name arena are append-only - but they drop out of the visible tree
        ; and are reclaimed on the next full reset(). The banked file records this dir
        ; pointed at are likewise abandoned as dead space (see xarena; reset() reclaims).
        d_first_child[idx] = NONE
        d_flags[idx] &= ~(FL_SCANNED | FL_EXPANDED | FL_HASKIDS | FL_DENIED)
        dx_clear_files(idx)                 ; reset file_count/off/bank/tagged ONLY - the node stays
                                            ; live, so its banked name_off/depth/parent MUST survive
        rebuild_visible()
    }

    sub is_expanded(ubyte idx) -> bool {
        return d_flags[idx] & FL_EXPANDED != 0
    }

    sub has_kids(ubyte idx) -> bool {
        return d_flags[idx] & FL_HASKIDS != 0
    }

    sub toggle_expand(ubyte idx) {
        d_flags[idx] ^= FL_EXPANDED
        rebuild_visible()
    }

    sub rebuild_visible() {
        ; iterative pre-order walk (child / sibling / backtrack via parent),
        ; descending only into expanded directories. No recursion.
        vis_count = 0
        ubyte node = 0                  ; root is always index 0
        while node != NONE {
            vis_idx[vis_count] = node
            vis_count++

            if is_expanded(node) and d_first_child[node] != NONE {
                node = d_first_child[node]
            } else {
                ; next sibling, or climb until a sibling exists
                while node != NONE and d_next_sibling[node] == NONE
                    node = dx_parent(node)
                if node != NONE
                    node = d_next_sibling[node]
            }
        }
    }

    sub build_path(ubyte idx, str dest) {
        ; absolute path of node 'idx' = base_path + name/ + name/ + ...
        ubyte[MAXDEPTH] stack
        ubyte sp = 0
        ubyte n = idx
        while n != 0 and n != NONE {     ; stop at root (index 0)
            if sp < MAXDEPTH {
                stack[sp] = n
                sp++
            }
            n = dx_parent(n)
        }
        void strings.copy(base_path, dest)
        ; ensure a trailing slash on the base
        ubyte l = lsb(strings.length(dest))
        if l == 0 or dest[l-1] != '/' {
            dest[l] = '/'
            dest[l+1] = 0
        }
        while sp > 0 {
            sp--
            void strings.append(dest, name_ptr(stack[sp]))
            void strings.append(dest, "/")
        }
    }
}

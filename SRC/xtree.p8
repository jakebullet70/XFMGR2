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
%import diskio

xtree {
    %option ignore_unused

    const ubyte NONE     = 255
    const ubyte DIR_MAX  = 192          ; max directories logged (< NONE)
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
    ubyte[DIR_MAX] d_parent             ; node id, NONE for root
    ubyte[DIR_MAX] d_first_child        ; node id
    ubyte[DIR_MAX] d_next_sibling       ; node id
    uword[DIR_MAX] d_name_off           ; offset into dname_buf
    ubyte[DIR_MAX] d_flags
    ubyte[DIR_MAX] d_depth

    ubyte dir_count

    ; --- per-directory "cold" extras, kept in BANKED RAM to save main RAM ---
    ; A fixed 7-byte record per node id, packed into bank DX_BANK at DX_BASE + id*DX_REC:
    ;   +0 file_count (uword)  +2 file_off (uword)  +4 file_bank (ubyte)  +5 tagged (uword)
    ; DX_BANK is the LOWEST arena bank (always present, even on a 512 KB machine); the
    ; file arena starts one bank higher (xarena.FIRST_BANK = DX_BANK + 1), so the bump
    ; allocator and its reset() never disturb this table. 192 nodes * 7 = 1344 B, well
    ; inside one 8 KB bank.
    const ubyte DX_BANK = 1
    const uword DX_BASE = $a000
    const ubyte DX_REC  = 7

    sub dx_off(ubyte idx) -> uword {
        return DX_BASE + (idx as uword) * DX_REC
    }

    sub dx_clear(ubyte idx) {
        uword o = dx_off(idx)
        cx16.push_rambank(DX_BANK)
        ubyte i
        for i in 0 to DX_REC - 1
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

    ; --- directory-name bump arena (main RAM) ---
    ; backed by a reserved memory slab (arrays are capped at 256 elements, so we
    ; address this by pointer arithmetic instead).
    uword dname_buf = memory("dnames", DNAME_SZ, 0)
    uword dname_next

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
        ; create the root node (its on-screen name is the disk/volume name)
        ubyte root = new_node(diskio.diskname(), NONE)
        d_flags[root] |= FL_EXPANDED
        rebuild_visible()
    }

    sub dname_store(str s) -> uword {
        ; returns byte offset into dname_buf, or $ffff if the arena is full
        uword off = dname_next
        uword n = strings.length(s) + 1
        if off + n > DNAME_SZ
            return $ffff
        void strings.copy(s, dname_buf + off)
        dname_next += n
        return off
    }

    sub name_ptr(ubyte idx) -> str {
        return dname_buf + d_name_off[idx]
    }

    sub new_node(str name, ubyte parent) -> ubyte {
        if dir_count >= DIR_MAX
            return NONE
        uword noff = dname_store(name)      ; reserve the name FIRST; if the name arena is full
        if noff == $ffff                    ; ($ffff) don't create a half-built node whose
            return NONE                     ; name_ptr would dereference dname_buf+$ffff
        ubyte idx = dir_count
        dir_count++
        d_name_off[idx]      = noff
        d_parent[idx]        = parent
        d_first_child[idx]   = NONE
        d_next_sibling[idx]  = NONE
        dx_clear(idx)                       ; file_count/off/bank + tagged (banked extras)
        d_flags[idx]         = 0
        if parent == NONE
            d_depth[idx] = 0
        else
            d_depth[idx] = d_depth[parent] + 1
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
        ubyte parent = d_parent[idx]
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
        dx_clear(idx)                       ; file_count / off / bank + tagged -> 0
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
                    node = d_parent[node]
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
            n = d_parent[n]
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

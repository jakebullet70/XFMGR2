; xscan - log (scan) one directory on demand.
;
; Adds each subdirectory as a collapsed child DirNode (main RAM) and appends each
; file as a banked record (xfiles). diskio allows only one listing session at a
; time; we never start another listing inside the loop, so the rule is respected.

%import diskio
%import strings
%import xtree
%import xfiles

xscan {
    %option ignore_unused

    str path = "?" * 80
    uword free_blocks                       ; disk blocks free (from the listing footer)

    ; --- path scratch: open_path() reuses pr_leaf as per-segment scratch during the startup
    ;     descent. The recursive prune engine that also used these buffers now lives in the
    ;     miscutil overlay (bank 3), which keeps its own copies. ---
    str pr_leaf = "?" * 40                  ; per-segment scratch (open_path)

    sub scan_dir(ubyte dir_idx) -> bool {
        if xtree.d_flags[dir_idx] & xtree.FL_SCANNED != 0
            return true                         ; already logged

        xtree.build_path(dir_idx, path)
        diskio.chdir(path)

        if not diskio.lf_start_list("*") {
            xtree.d_flags[dir_idx] |= xtree.FL_DENIED
            xtree.d_flags[dir_idx] |= xtree.FL_SCANNED
            return false
        }

        bool got_first_file = false
        while diskio.lf_next_entry() {
            ; skip hidden entries and the . / .. pseudo dirs
            if diskio.list_filename[0] == '.'
                continue

            if diskio.list_filetype == "dir" {
                void xtree.add_child(dir_idx, diskio.list_filename)
            } else {
                ubyte ftype = 0
                if diskio.list_filetype == "prg"
                    ftype = 1
                if xfiles.add_file(diskio.list_blocks, ftype, diskio.list_filename) {
                    if not got_first_file {
                        xtree.dx_set_fbank(dir_idx, xfiles.last_bank)
                        xtree.dx_set_foff(dir_idx, xfiles.last_off)
                        got_first_file = true
                    }
                    xtree.dx_inc_fcount(dir_idx)
                }
            }
        }
        ; once the listing ends, diskio.list_blocks holds the footer's "BLOCKS FREE"
        free_blocks = diskio.list_blocks
        diskio.lf_end_list()

        xtree.d_flags[dir_idx] |= xtree.FL_SCANNED
        return true
    }

    sub open_path(str fullpath) -> ubyte {
        ; Descend the tree from the root (node 0) following the absolute path 'fullpath'
        ; (diskio.curdir() format: leading '/', no trailing slash, root = "/"), logging
        ; and expanding each directory on the way down. Returns the deepest node that
        ; matched an on-disk segment; if a segment can't be found the descent stops there.
        ; Reuses pr_leaf as per-segment scratch (nothing else in xscan uses it now).
        ubyte node = 0
        uword p = fullpath as uword
        if @(p) == '/'
            p++                                     ; skip the leading slash
        while @(p) != 0 {
            ; copy one '/'-delimited segment into pr_leaf
            ubyte n = 0
            while @(p) != 0 and @(p) != '/' {
                if n < 39 {
                    pr_leaf[n] = @(p)
                    n++
                }
                p++
            }
            pr_leaf[n] = 0
            if @(p) == '/'
                p++
            if n == 0
                continue                            ; tolerate an empty segment ("//")
            void scan_dir(node)                     ; ensure this level's children are logged
            ; find the child directory whose name matches the segment
            ubyte ch = xtree.d_first_child[node]
            bool found = false
            while ch != xtree.NONE {
                if strings.compare(xtree.name_ptr(ch), pr_leaf) == 0 {
                    found = true
                    break
                }
                ch = xtree.d_next_sibling[ch]
            }
            if not found
                break                               ; path diverges from the tree; stop here
            xtree.d_flags[node] |= xtree.FL_EXPANDED  ; expand this level so the child shows
            node = ch
        }
        return node
    }

    sub dir_is_empty(str dirpath) -> bool {
        ; true if dirpath holds no files and no subdirectories (ignoring . / ..). Used to
        ; check a folder BEFORE offering to delete it, so a non-empty one is refused up front.
        diskio.chdir(dirpath)
        if not diskio.lf_start_list("*")
            return true                         ; can't list -> let rmdir be the final judge
        bool empty = true
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue                        ; skip . / .. / hidden
            empty = false
            break
        }
        diskio.lf_end_list()
        return empty
    }

    sub refresh_files(ubyte dir_idx) -> bool {
        ; Re-read ONLY the file records of an already-logged directory (after a copy/
        ; move/rename/delete). Child directories are left untouched. The directory's
        ; previous file run is abandoned in the arena (dead space, reclaimed on a full
        ; reset) and a fresh contiguous run is appended and re-pointed. Resets the
        ; per-dir tagged count, since the fresh records start untagged.
        xtree.build_path(dir_idx, path)
        diskio.chdir(path)

        if not diskio.lf_start_list("*")
            return false

        xtree.dx_set_fcount(dir_idx, 0)
        xtree.dx_set_tag(dir_idx, 0)
        bool got_first_file = false
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue
            if diskio.list_filetype == "dir"
                continue                        ; children already in the tree
            ubyte ftype = 0
            if diskio.list_filetype == "prg"
                ftype = 1
            if xfiles.add_file(diskio.list_blocks, ftype, diskio.list_filename) {
                if not got_first_file {
                    xtree.dx_set_fbank(dir_idx, xfiles.last_bank)
                    xtree.dx_set_foff(dir_idx, xfiles.last_off)
                    got_first_file = true
                }
                xtree.dx_inc_fcount(dir_idx)
            }
        }
        free_blocks = diskio.list_blocks
        diskio.lf_end_list()
        return true
    }

    sub refresh_dirs(ubyte dir_idx) -> ubyte {
        ; Re-list an already-logged directory and add any SUBDIRECTORIES that aren't
        ; already children (picks up folders created since the last log). Existing
        ; children and all file records are left untouched. add_child / name_ptr touch
        ; only main RAM, so no second listing session is opened. Returns # added.
        ; (Folders deleted on disk are not pruned - the pool is append-only.)
        xtree.build_path(dir_idx, path)
        diskio.chdir(path)

        if not diskio.lf_start_list("*")
            return 0

        ubyte added = 0
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue
            if diskio.list_filetype != "dir"
                continue
            ; is this subdirectory already a child?
            bool found = false
            ubyte ch = xtree.d_first_child[dir_idx]
            while ch != xtree.NONE {
                if strings.compare(xtree.name_ptr(ch), diskio.list_filename) == 0 {
                    found = true
                    break
                }
                ch = xtree.d_next_sibling[ch]
            }
            if not found {
                if xtree.add_child(dir_idx, diskio.list_filename) != xtree.NONE
                    added++
            }
        }
        free_blocks = diskio.list_blocks
        diskio.lf_end_list()
        return added
    }
}

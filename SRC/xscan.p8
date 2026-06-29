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

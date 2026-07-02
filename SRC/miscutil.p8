; miscutil - misc self-contained utility routines, run from a HIRAM bank overlay.
;
; Compiled as a %output library headerless blob (org $A000), loaded into reserved HIRAM
; bank 3 (MISC_BANK in xfmgr) at startup via diskio.loadlib, and called from the main
; program via `extsub @bank 3` (JSRFAR maps the bank around each call). Moving self-contained
; helpers here frees scarce main RAM (XFMGR is main-RAM constrained).
;
; Fixed entry offsets via %jmptable: $A000 = init (start), $A003 = wildcard_expand,
; $A006 = prune_dir.
; Depends only on `strings` + `diskio` (its own private copies) + pointers passed in from main
; RAM (which stays mapped below $A000 while this bank is active). Touches NO xtree/xfiles/xarena
; state: prune walks the disk with diskio only and returns pass/fail; the caller mutates the
; tree afterwards. The overlay's diskio is a SEPARATE copy from main's - it uses the default
; drive (device 8, same as main) and keeps its own listing/cwd state, so prune fully opens and
; closes each listing before returning and never collides with main's diskio.

%import strings
%import diskio
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table so callable entry offsets stay fixed across rebuilds. The compiler prepends
    ; `jmp start` at $A000, so: $A000 = start (library init), $A003 = wildcard_expand,
    ; $A006 = prune_dir.
    ; KEEP THIS BLOCK FREE OF INITIALIZED VARIABLES - prog8 emits a block's initialized vars
    ; inline BEFORE its code/jumptable, which would shove the table off $A003 (same gotcha as
    ; tview.p8). All module vars below (pr_*) are UNINITIALIZED (-> BSS tail) and all other
    ; locals live inside subs.
    %jmptable ( main.wildcard_expand, main.prune_dir )

    sub start() {
        ; library init entrypoint ($A000): the compiler emits the BSS-clear here. Do NO UI or
        ; system init (the caller owns the machine). Call ONCE after load.
    }

    sub wildcard_expand(uword origptr @R0, uword patptr @R1, uword outptr @R2) {
        ; real entry ($A003). Expand a DOS/XTree rename pattern (pat) against the original name
        ; (orig) into out. The call-site copies the three pointers into wildcard_name's params
        ; before its body runs, so the strings.* clobber of cx16.r0-r3 inside is harmless.
        wildcard_name(origptr, patptr, outptr)
    }

    sub prune_dir(uword parptr @R0, uword nameptr @R1) -> ubyte {
        ; real entry ($A006). Recursively delete <parent>/<name>/ and everything under it, using
        ; diskio only. Returns 1 on success, 0 on failure (a partial delete is possible - the
        ; caller should rescan). parent must be absolute and end with '/'. As with
        ; wildcard_expand, the two pointers are copied into prune's params before its body runs,
        ; so the diskio/strings clobber of cx16.r0-r3 inside is harmless.
        if prune(parptr, nameptr)
            return 1
        return 0
    }

    ; ---- pure string helpers (ported verbatim from xfmgr.p8) ----

    sub last_dot(str s) -> ubyte {
        ; index of the last '.' in s, or 255 if none
        ubyte i = lsb(strings.length(s))
        while i != 0 {
            i--
            if s[i] == '.'
                return i
        }
        return 255
    }

    sub merge_seg(str pat, ubyte ps, ubyte pe, str orig, ubyte os, ubyte oe, str out, ubyte outpos) -> ubyte {
        ; merge one filename segment: pattern pat[ps..pe) against orig[os..oe), writing
        ; into out from outpos. '*' copies the rest of the original segment, '?' copies
        ; one original char, any other char is literal (and consumes one original char).
        ubyte pi = ps
        ubyte oi = os
        while pi < pe {
            ubyte pc = pat[pi]
            if pc == '*' {
                while oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                return outpos                    ; '*' ends this segment
            } else if pc == '?' {
                if oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                pi++
            } else {
                out[outpos] = pc
                outpos++
                if oi < oe
                    oi++
                pi++
            }
        }
        return outpos
    }

    sub wildcard_name(str orig, str pat, str out) {
        ; expand a DOS/XTree-style rename pattern (pat) against the original name (orig)
        ; into out, e.g. orig "test.dat" + pat "*.tmp" -> "test.tmp". Base and extension
        ; (split at the last '.') are merged independently.
        ubyte olen = lsb(strings.length(orig))
        ubyte plen = lsb(strings.length(pat))
        ubyte pd = last_dot(pat)
        ubyte pos
        if pd == 255 {
            ; no '.' in the pattern: treat the whole name as a single segment
            pos = merge_seg(pat, 0, plen, orig, 0, olen, out, 0)
        } else {
            ubyte obase_e = olen
            ubyte oext_s = olen
            ubyte od = last_dot(orig)
            if od != 255 {
                obase_e = od
                oext_s = od + 1
            }
            pos = merge_seg(pat, 0, pd, orig, 0, obase_e, out, 0)
            out[pos] = '.'
            pos++
            pos = merge_seg(pat, pd+1, plen, orig, oext_s, olen, out, pos)
        }
        out[pos] = 0
    }

    ; ---- recursive directory prune (ported from xscan.p8; diskio + strings only) ----
    ; Scratch buffers. KEEP UNINITIALIZED (no "= ...") so they land in the relocated BSS at the
    ; tail and don't shove the %jmptable off its fixed offsets (same rule as tview's buffers).
    const ubyte PRUNE_MAXDEPTH = 24         ; abort if we descend deeper than this
    ubyte[101] pr_cur                       ; path of the directory currently being examined
    ubyte[101] pr_par                       ; path of its parent (where the rmdir is issued)
    ubyte[41]  pr_leaf                      ; segment to rmdir / next subdir while descending
    ubyte[41]  pr_file                      ; last filename deleted in a leaf's file sweep (loop guard)
    ubyte[81]  pr_path                      ; filename scratch for delete_all_files

    sub prune(str parent_path, str name) -> bool {
        ; Recursively delete <parent_path><name>/ and EVERYTHING under it, then the directory
        ; itself. parent_path is absolute and ends with '/'.
        ;
        ; Prog8 locals are statically allocated (no safe recursion), and diskio allows only one
        ; listing at a time, so we do this iteratively: repeatedly descend from the target to a
        ; directory that has no subdirectories (a leaf), scratch all its files, rmdir it, and
        ; start over. Each pass removes exactly one directory, so it terminates; any rmdir
        ; failure aborts with false rather than looping forever. On false the on-disk tree may
        ; be partly deleted - the caller should rescan.
        repeat {
            ; start each pass at the target, descend to a leaf, tracking parent + leaf name
            void strings.copy(parent_path, pr_par)
            void strings.copy(name, pr_leaf)
            join_path(pr_par, pr_leaf, pr_cur)          ; pr_cur = target dir path
            bool descended = false
            ubyte guard = 0
            repeat {
                if not first_subdir(pr_cur, pr_leaf)    ; subdir name goes straight into pr_leaf
                    break                               ; (untouched if none) pr_cur is a leaf dir
                void strings.copy(pr_cur, pr_par)       ; its parent is the current dir
                join_path(pr_par, pr_leaf, pr_cur)      ; descend into the subdirectory
                descended = true
                guard++
                if guard >= PRUNE_MAXDEPTH or strings.length(pr_cur) >= 95
                    return false                        ; too deep / path too long
            }
            ; leaf = pr_cur, its parent = pr_par, its name = pr_leaf
            delete_all_files(pr_cur)                    ; scratch every file in the leaf (by name)
            diskio.chdir(pr_par)
            diskio.rmdir(pr_leaf)
            if diskio.status_code() != 0
                return false                            ; rmdir failed -> stop (don't spin)
            if not descended
                return true                             ; the leaf WAS the target: done
        }
    }

    sub join_path(str base, str seg, str out) {
        ; out = base + seg + '/'   (base already ends with '/')
        void strings.copy(base, out)
        void strings.append(out, seg)
        void strings.append(out, "/")
    }

    sub first_subdir(str dirpath, str out) -> bool {
        ; list dirpath and copy the name of its FIRST real subdirectory into out. Returns false
        ; if it has none (or the listing can't be opened). Respects the one-listing-at-a-time
        ; rule: opens, reads, closes before returning.
        diskio.chdir(dirpath)
        if not diskio.lf_start_list("*")
            return false
        bool found = false
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue                        ; skip . / .. / hidden
            if diskio.list_filetype == "dir" {
                void strings.copy(diskio.list_filename, out)
                found = true
                break
            }
        }
        diskio.lf_end_list()
        return found
    }

    sub delete_all_files(str dirpath) {
        ; Delete every (non-dir) file in dirpath. The emulator's HOSTFS ignores a wildcard
        ; scratch ("s:*" removes only ONE match), so enumerate and delete each by name. diskio
        ; allows one listing at a time, so per pass: list, grab the first file, close the
        ; listing, delete it, repeat until none. pr_file remembers the last name so a file that
        ; refuses to delete can't spin forever.
        pr_file[0] = 0
        repeat {
            diskio.chdir(dirpath)
            if not diskio.lf_start_list("*")
                return
            bool got = false
            while diskio.lf_next_entry() {
                if diskio.list_filename[0] == '.'
                    continue                        ; skip . / .. / hidden
                if diskio.list_filetype == "dir"
                    continue                        ; leave subdirs for the prune descent
                void strings.copy(diskio.list_filename, pr_path)
                got = true
                break
            }
            diskio.lf_end_list()
            if not got
                return                              ; no files left in this directory
            if strings.compare(pr_path, pr_file) == 0
                return                              ; same file reappeared -> can't delete it; bail
            void strings.copy(pr_path, pr_file)
            diskio.chdir(dirpath)
            diskio.delete(pr_path)
        }
    }
}

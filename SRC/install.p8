; install - self-installer for XFMGR2, run once from the unpacked release folder.
;
; A normal $0801 PRG (not an overlay). The user copies the release files (the app .prg,
; the .ovl overlays, xfsetup.prg, zsmkit.bin, xfmgr.hlp) plus this installer into ONE
; folder on their SD card, boots the X16, CDs into that folder and runs it. The installer:
;   * reports the folder it is running from,
;   * picks the install folder (see below) and creates it if needed,
;   * copies the app files into it (255-byte stream copy, same pump XFMGR uses),
;   * writes the tiny root launcher /XT ("10 LOAD \"<folder>/XFMGR.PRG\""),
; so the app can then be launched from anywhere with the caret-run command:  ^/xt
;
; WHERE IT INSTALLS: /XFMGR by default, but an EXISTING /XT already names the folder a
; previous install used - and XFMGR itself resolves its overlays + cfg from exactly that
; path at runtime (themes.find_progdir). So if /XT is present and points somewhere else,
; we offer to update THAT install in place rather than silently scattering a second copy
; into /XFMGR and leaving the launcher pointing at the old one. Answer N to install to
; /XFMGR anyway - the launcher is then repointed there.
;
; If it is run from a folder that IS the install target (e.g. the user copied a ready-made
; XFMGR folder to the root), the copy step is skipped - source==dest would truncate the
; files - and only the /XT launcher is written.
;
; All filename literals are lowercase: uppercase A-Z would encode to $C1-DA, which the
; filesystem won't match (see docs/memory prog8-filename-literals-lowercase).

%import textio
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio')
%import strings
%zeropage basicsafe

main {
    ; files copied into /XFMGR. xfmgr.prg is MANDATORY (checked up front); the rest are optional -
    ; a missing file is reported and skipped, not fatal. xfmgr.cfg ships a default (Classic) theme so
    ; a fresh install has one, but an EXISTING /xfmgr/xfmgr.cfg is PRESERVED on reinstall (see the
    ; copy loop) so a user's saved theme survives an update.
    str[11] FILES = ["xfmgr.prg", "tview.ovl", "miscutil.ovl", "uiutil.ovl",
                     "ximgview.ovl", "xmusic.ovl", "xsyntax.ovl", "xfsetup.prg", "zsmkit.bin",
                     "xfmgr.hlp", "xfmgr.cfg"]

    str  DEF_TARGET = "/xfmgr"   ; where we install when no /xt says otherwise
    const ubyte TARGET_MAX = 48  ; cap on a path parsed out of /xt (keeps the buffers below sane)

    ubyte[80] cur                ; folder we were launched from (copied out of curdir's transient buffer)
    ubyte[96] srcabs             ; absolute source path built per file: cur + "/" + name
    ubyte[255] cpbuf             ; stream-copy chunk buffer
    ubyte[210] hbuf              ; scratch for reading a readme's "(Build N)" line (padded for safety)
    ubyte[64] target             ; chosen install folder, absolute, NO trailing slash
    ubyte[64] xtdir              ; install folder parsed out of an existing /xt
    ubyte[64] xtbuf              ; /xt load buffer (the launcher is ~28 bytes)
    ubyte[96] xtline             ; "<target>/xfmgr.prg" while building the launcher
    ubyte[112] xtout             ; the launcher image we write back out

    ; ask_action() return codes
    const ubyte ACT_CANCEL  = 0
    const ubyte ACT_INSTALL = 1
    const ubyte ACT_TEST    = 2
    ; prior-install scenario codes (see the classify block in start())
    const ubyte SC_FRESH    = 0        ; no /xfmgr on the drive
    const ubyte SC_OLDER    = 1        ; installed build < release  -> upgrade
    const ubyte SC_NEWER    = 2        ; installed build > release  -> downgrade
    const ubyte SC_SAME     = 3        ; installed build == release
    const ubyte SC_UNKNOWN  = 4        ; /xfmgr exists but a build number can't be compared

    sub start() {
        ; We stay in the boot (uppercase) charset and write every message in lowercase SOURCE, which
        ; renders as clean ALL-CAPS - so there's no charset change to save/restore. We DO set a
        ; white-on-blue scheme (prog8's init_system leaves the screen yellow-on-black); we don't
        ; restore it on exit, matching the deliberately simple no-save/restore approach.
        txt.color2(1, 6)          ; 1 = white text, 6 = blue field; clear_screen paints it full-screen
        txt.clear_screen()
        txt.print("\n\n")
        txt.print("xfmgr2 installer (a08)\n\n")

        ; curdir() points into a transient shared buffer - copy it out before any other disk call.
        void strings.copy(diskio.curdir(), cur)
        ubyte cl = strings.length(cur)
        if cl > 1 and cur[cl-1] == '/'      ; normalise: drop a trailing slash (keep bare root "/")
            cur[cl-1] = 0

        txt.print("running from: ")
        txt.print(cur)
        txt.nl()

        ; ---- pick the install folder ----
        ; Default /xfmgr, unless an existing /xt names a different one - in which case offer to
        ; update that install where it already lives. Asked BEFORE the build comparison below,
        ; because the answer decides which folder we go and read a build number out of.
        void strings.copy(DEF_TARGET, target)
        if read_xt_dir() and strings.compare_nocase(xtdir, DEF_TARGET) != 0 {
            txt.print("found /xt -> ")
            txt.print(xtdir)
            txt.nl()
            txt.nl()
            txt.print("install there?  ")
            if ask_yes(true)
                void strings.copy(xtdir, target)
            txt.nl()
        }
        txt.print("install to:   ")
        txt.print(target)
        txt.nl()

        ; are we already sitting IN the install folder? (source==dest -> skip the copy)
        bool already = strings.compare_nocase(cur, target) == 0

        ; the version we are about to install: build number stamped in THIS folder's xfmgr.hlp
        ; readme (0 if the readme is missing or has no "(Build N)" marker).
        uword rel_build = read_build("xfmgr.hlp")
        if rel_build != 0 {
            txt.print("this release:  build ")
            txt.print_uw(rel_build)
            txt.nl()
        } else {
            txt.print("this release:  (no build marker in xfmgr.hlp)\n")
        }

        bool test_mode = false
        ubyte act                            ; ask_action() result (declared once; sub-wide scope)

        if already {
            ; launched from INSIDE /xfmgr: source==dest would truncate the files, so we skip the
            ; copy and only (re)write the /xt launcher. Confirm, default Yes.
            txt.nl()
            txt.print("files are already in the target folder.\n")
            txt.print("write the /xt launcher?  ")
            act = ask_action(true)
            txt.nl()
            txt.nl()
            if act == ACT_CANCEL {
                txt.print("cancelled.\n")
                return
            }
            test_mode = act == ACT_TEST
        } else {
            ; must be run from the folder that actually holds the release files
            if not diskio.f_open("xfmgr.prg") {
                txt.nl()
                txt.print("xfmgr.prg not found here.\n")
                txt.print("run this from the folder that holds the\n")
                txt.print("unpacked xfmgr release files.\n")
                return
            }
            diskio.f_close()

            ; Detect any prior install: CD into the target and read its BARE "xfmgr.hlp" (OPEN takes
            ; a plain filename - no path resolution - so we must be IN the dir; the app chdir's before
            ; every f_open for the same reason). A CD onto a MISSING dir is a silent no-op, so gate
            ; on status_code()==0 (the app's dir-exists probe) - else we'd re-read the release
            ; folder's own xfmgr.hlp and report a phantom install. read_build returns 0 for a
            ; folder with no readable xfmgr.hlp.
            uword inst_build = 0
            diskio.chdir(target)
            bool have_xfmgr = diskio.status_code() == 0     ; did the CD land? -> target exists
            if have_xfmgr
                inst_build = read_build("xfmgr.hlp")
            diskio.chdir(cur)                               ; back to the launch folder

            ; classify: fresh / older(upgrade) / newer(downgrade) / same / unknown
            ubyte scen
            if not have_xfmgr
                scen = SC_FRESH
            else if inst_build == 0 or rel_build == 0
                scen = SC_UNKNOWN
            else if rel_build > inst_build
                scen = SC_OLDER
            else if rel_build < inst_build
                scen = SC_NEWER
            else
                scen = SC_SAME

            ; one concise status line about the target folder
            txt.print("target:        ")
            if scen == SC_FRESH
                txt.print("not found  (fresh install)\n")
            else if scen == SC_UNKNOWN
                txt.print("found, build unknown\n")
            else {
                txt.print("build ")
                txt.print_uw(inst_build)
                if scen == SC_OLDER
                    txt.print("  (older - upgrade)\n")
                else if scen == SC_NEWER
                    txt.print("  (newer than this release!)\n")
                else
                    txt.print("  (same - already installed)\n")
            }
            txt.nl()

            ; scenario-specific confirmation. ENTER defaults Yes for fresh/upgrade, No otherwise.
            bool def_yes = scen == SC_FRESH or scen == SC_OLDER
            if scen == SC_FRESH {
                txt.print("install build ")
                txt.print_uw(rel_build)
                txt.print("?  ")
            } else if scen == SC_OLDER {
                txt.print("upgrade to build ")
                txt.print_uw(rel_build)
                txt.print("?  ")
            } else if scen == SC_NEWER {
                txt.print("downgrade to build ")
                txt.print_uw(rel_build)
                txt.print("?  ")
            } else if scen == SC_SAME {
                txt.print("reinstall build ")
                txt.print_uw(rel_build)
                txt.print("?  ")
            } else {
                txt.print("reinstall?  ")
            }
            act = ask_action(def_yes)
            txt.nl()
            txt.nl()
            if act == ACT_CANCEL {
                txt.print("cancelled.\n")
                return
            }
            test_mode = act == ACT_TEST
        }

        if test_mode
            txt.print("** test mode - no files copied **\n\n")

        if not already {
            ; Make the target the copy destination, creating it if it isn't there.
            ; mkdir MUST be relative: CMDR-DOS is MD[path]:name (the path goes BEFORE the colon)
            ; and diskio.mkdir only ever emits "md:"+name, so mkdir("/a/b") would ask for a folder
            ; whose NAME contains slashes. That limits creation to a DIRECT child of the root -
            ; which is all we need, because a deeper target can only have come from an existing
            ; /xt, and that means the folder is already there. If the chdir still fails we bail
            ; rather than dumping the copies into the launch folder.
            diskio.chdir(target)
            if diskio.status_code() != 0 {
                ubyte si
                bool nested
                si, nested = strings.rfind(&target[1], '/')     ; another '/' past the leading one?
                if not nested {
                    diskio.chdir("/")
                    diskio.mkdir(&target[1])                    ; skip the leading '/' -> bare name
                    diskio.chdir(target)
                }
                if diskio.status_code() != 0 {
                    txt.print("cannot open or create ")
                    txt.print(target)
                    txt.print("\n\nnothing was installed.\n")
                    return
                }
            }

            ubyte i
            for i in 0 to len(FILES) - 1 {
                build_src(FILES[i])
                txt.print("  ")
                txt.print(FILES[i])
                pad_to(FILES[i], 16)
                if test_mode {
                    txt.print("test (skipped)\n")
                } else {
                    ; preserve a user's saved theme: don't overwrite an EXISTING /xfmgr/xfmgr.cfg
                    ; with the shipped default (only matters on a reinstall / update).
                    bool keep = false
                    if strings.compare_nocase(FILES[i], "xfmgr.cfg") == 0
                        keep = dest_exists(FILES[i])
                    if keep {
                        txt.print("kept (existing)\n")
                    } else {
                        if copy_one(srcabs, FILES[i])
                            txt.print("ok\n")
                        else
                            txt.print("skip (not found)\n")
                    }
                }
            }
            txt.nl()
        }

        ; write the root launcher /xt
        diskio.chdir("/")
        txt.print("  xt")
        pad_to("xt", 16)
        if write_xt()
            txt.print("ok\n")
        else
            txt.print("failed\n")

        txt.print("\ndone. launch from anywhere with:\n\n   ^/xt\n")
    }

    ;====================================================================

    ; Parse the install folder out of an existing root launcher /xt into `xtdir`, WITHOUT a
    ; trailing slash (so it drops straight into chdir and the compare in start()). Returns false
    ; if /xt is missing, unparsable, or names a bare root path. This is the same parse XFMGR
    ; itself does at runtime (themes.find_progdir) - the launcher is a tokenized
    ; `10 LOAD "<path>/XFMGR.PRG"`, so we take what is between the quotes up to the last '/'.
    ;
    ; The bytes inside /xt are the same PETSCII our string literals compile to (both put a-z at
    ; $41-$5A), so the path copies straight across with no re-encoding.
    sub read_xt_dir() -> bool {
        xtdir[0] = 0
        uword endaddr = diskio.load_raw("/xt", &xtbuf)
        if endaddr == 0 {
            void diskio.status()                ; drop the FILE NOT FOUND (else the LED blinks)
            return false
        }
        ubyte n = lsb(endaddr - &xtbuf)
        if n > len(xtbuf)
            n = len(xtbuf)
        ubyte i = 0
        while i < n and xtbuf[i] != $22         ; opening quote
            i++
        if i >= n
            return false
        i++
        ubyte j = 0
        ubyte cut = 0                           ; chars up to and including the LAST '/'
        while i < n and xtbuf[i] != $22 and j < TARGET_MAX {
            xtdir[j] = xtbuf[i]
            j++
            if xtbuf[i] == '/'
                cut = j
            i++
        }
        if cut < 2                              ; "" or a bare "/" - nothing useful to offer
            return false
        xtdir[cut-1] = 0                        ; drop the filename AND the trailing slash
        return true
    }

    ; srcabs = cur + "/" + name  (cur is normalised; bare root "/" yields "/name")
    sub build_src(str name) {
        void strings.copy(cur, srcabs)
        ubyte l = strings.length(srcabs)
        if l == 0 or srcabs[l-1] != '/'
            void strings.append(srcabs, "/")
        void strings.append(srcabs, name)
    }

    ; print spaces after `name` so the following status column lines up at `col`
    sub pad_to(str name, ubyte col) {
        ubyte n = strings.length(name)
        while n < col {
            txt.spc()
            n++
        }
    }

    ; stream-copy the file at absolute path `src` into bare `dst` in the current dir.
    ; returns false only if the source doesn't open (missing optional file); the dest is
    ; left untouched in that case. Mirrors miscutil.do_stream_copy.
    sub copy_one(str src, str dst) -> bool {
        if not diskio.f_open(src)
            return false                    ; source absent - skip, don't disturb dest
        diskio.delete(dst)                  ; clear any existing dest (open won't truncate)
        if not diskio.f_open_w(dst) {
            diskio.f_close()
            return false
        }
        repeat {
            uword nread = diskio.f_read(&cpbuf, 255)
            if nread == 0
                break
            if not diskio.f_write(&cpbuf, nread)
                break
        }
        diskio.f_close()
        diskio.f_close_w()
        return true
    }

    ; true if `name` already exists in the current dir (used to preserve a user's xfmgr.cfg on reinstall)
    sub dest_exists(str name) -> bool {
        if diskio.f_open(name) {
            diskio.f_close()
            return true
        }
        return false
    }

    ; Write the /xt launcher into the current dir, pointed at the chosen target: a tokenized
    ; $0801 BASIC program holding  10 LOAD "<target>/XFMGR.PRG".  Built rather than shipped as a
    ; fixed blob because the path length varies with the install folder.
    ;
    ;   $0801: <next-line ptr>   = $0809 + pathlen (the address of the trailing $00 $00)
    ;   $0803: $0a $00           line number 10
    ;   $0805: $93               LOAD token
    ;   $0806: $22 <path> $22    the quoted path
    ;          $00               end of line
    ;          $00 $00           end of program
    ; total on disk = 2 (load address) + pathlen + 10
    sub write_xt() -> bool {
        void strings.copy(target, xtline)
        void strings.append(xtline, "/xfmgr.prg")
        ubyte plen = strings.length(xtline)
        uword nxt = $0809 + plen
        xtout[0] = $01              ; load address $0801
        xtout[1] = $08
        xtout[2] = lsb(nxt)
        xtout[3] = msb(nxt)
        xtout[4] = $0a              ; line 10
        xtout[5] = $00
        xtout[6] = $93              ; LOAD
        xtout[7] = $22
        ubyte i
        for i in 0 to plen - 1
            xtout[8 + i] = xtline[i]
        xtout[8 + plen] = $22
        xtout[9 + plen] = $00       ; end of line
        xtout[10 + plen] = $00      ; end of program
        xtout[11 + plen] = $00
        diskio.delete("xt")
        if not diskio.f_open_w("xt")
            return false
        void diskio.f_write(&xtout, plen + 12)
        diskio.f_close_w()
        return true
    }

    ; plain yes/no prompt (no dry-run option). `def` is what ENTER selects; ESC = no.
    sub ask_yes(bool def) -> bool {
        if def
            txt.print("[y]/n ")
        else
            txt.print("y/[n] ")
        repeat {
            ubyte k = getkey()
            when k {
                'y', 'Y' -> return true
                'n', 'N', 27 -> return false
                13 -> return def
                else -> { }
            }
        }
    }

    ; parse the "(Build N)" marker out of an xfmgr.hlp readme (it sits on line 2). Returns the
    ; build number, or 0 if the file is missing or has no marker. Read-only - reads just the first
    ; chunk (marker is near the top), scans for "Build ", then reads the trailing decimal number.
    ;
    ; ENCODING: xfmgr.hlp is a PLAIN ASCII text file. We must match its raw ASCII byte codes, NOT
    ; prog8 char literals: this program's default PETSCII encoding maps 'B'->$C2, 'u'->$55, 'i'->$49,
    ; 'l'->$4C, 'd'->$44, none of which equal the file's ASCII $42,$75,$69,$6C,$64 - so 'Build' never
    ; matched and the build number never showed (for BOTH this release and any installed copy). Digits
    ; ($30-$39) and space ($20) happen to coincide in ASCII and PETSCII, so only the letters were wrong.
    sub read_build(str path) -> uword {
        const ubyte A_B = $42               ; ASCII 'B'
        const ubyte A_U = $75               ; ASCII 'u'
        const ubyte A_I = $69               ; ASCII 'i'
        const ubyte A_L = $6c               ; ASCII 'l'
        const ubyte A_D = $64               ; ASCII 'd'
        const ubyte A_SP = $20              ; ASCII ' '
        const ubyte A_0 = $30               ; ASCII '0'
        const ubyte A_9 = $39               ; ASCII '9'
        if not diskio.f_open(path)
            return 0
        uword got = diskio.f_read(&hbuf, 200)
        diskio.f_close()
        ubyte n = lsb(got)
        ubyte i = 0
        while i + 6 < n {
            if hbuf[i] == A_B and hbuf[i+1] == A_U and hbuf[i+2] == A_I and hbuf[i+3] == A_L and hbuf[i+4] == A_D {
                ubyte j = i + 5
                while j < n and hbuf[j] == A_SP
                    j++
                uword val = 0
                bool any = false
                while j < n and hbuf[j] >= A_0 and hbuf[j] <= A_9 {
                    val = val * 10 + (hbuf[j] - A_0)
                    any = true
                    j++
                }
                if any
                    return val
            }
            i++
        }
        return 0
    }

    ; print the "[Y]/N  (T=dry run)" tail, then read one decision key. `default_install` is what
    ; ENTER selects. Returns ACT_INSTALL / ACT_TEST / ACT_CANCEL; unrecognized keys are ignored.
    ; (Key codes are PETSCII from the keyboard, so plain char literals match here - unlike the
    ; ASCII file bytes in read_build.)
    sub ask_action(bool default_install) -> ubyte {
        if default_install
            txt.print("[y]/n  (t=dry run) ")
        else
            txt.print("y/[n]  (t=dry run) ")
        repeat {
            ubyte k = getkey()
            when k {
                'y', 'Y' -> return ACT_INSTALL
                't', 'T' -> return ACT_TEST
                'n', 'N', 27 -> return ACT_CANCEL          ; N or ESC cancels
                13 -> {                                     ; ENTER = the default action
                    if default_install
                        return ACT_INSTALL
                    return ACT_CANCEL
                }
                else -> { }                                 ; ignore anything else
            }
        }
    }

    sub getkey() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }
}

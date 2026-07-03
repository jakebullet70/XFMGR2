; ximgview - standalone banked BMX image viewer overlay for XFMGR2.
;
; Displays a Commander X16 native "BMX" bitmap file full-screen (320x240) or centered as a
; smaller "stamp". Built as a %output library headerless blob (org $A000) and loaded into a
; reserved HIRAM bank at startup, called via `extsub @bank` - the same overlay pattern as
; SRC/tview.p8 (see its header for the JSRFAR / jmptable / %memtop notes). This keeps the
; bitmap-loader code (bmx + diskio) out of main RAM.
;
; The display recipe is adapted from the vendored Prog8 example docs/prog8/examples/showbmx.p8.
; bmx.p8 loads bitmap AND palette data straight into VRAM (palette_buffer_ptr stays 0), so no
; main-RAM framebuffer or palette buffer is needed.
;
; Call contract (mirrors tview): the caller (XFMGR) chdir's into the file's directory, keeps the
; screen in text mode, then calls view_image(nameptr @R0); the filename is copied in on entry.
; This routine switches VERA to bitmap mode, shows the image, waits for a key, then cbm.CINT()'s
; back to text mode (which also restores the default text palette 0-15 that bmx overwrote). On
; return the caller re-sets its 80x30 mode + theme and repaints.

%import textio
%import strings
%import bmx
; --- loadable-library overlay: headerless blob loaded at $A000 into a HIRAM bank and called via
;     `extsub @bank`. %output library => no zeropage / no sysinit / jmp start entry; %memtop
;     hard-fails the build if the overlay outgrows the $A000-$BFFF window.
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table so callable entry offsets stay fixed across rebuilds. The compiler prepends
    ; `jmp start` at $A000 (library init), so: $A000 = start (init), $A003 = view_image.
    %jmptable ( main.view_image )

    ; --- shared scratch ---
    ; MUST stay uninitialized (no "= ...") so it lands in the relocated BSS tail and does not
    ; shove the jump table off $A003 (same rule as tview.p8; see its notes).
    ubyte[81] namebuf                 ; the file to view (80 chars + NUL); filled per call

    sub start() {
        ; library init entrypoint ($A000). The compiler emits the BSS-clear here; this must do
        ; NO UI or system init (the caller/XFMGR owns the screen). Call ONCE after load.
    }

    sub view_image(uword nameptr @R0) {
        ; real entry ($A003 via the jmptable). Copy the filename FIRST - diskio/bmx calls
        ; clobber cx16.r0-r3, so consume the @R0 pointer before anything else.
        void strings.copy(nameptr, namebuf)

        if bmx.open(8, namebuf) {
            ; switch to 320x240 bitmap mode and set the file's color depth + border.
            ; palette loads directly into VRAM (palette_buffer_ptr stays 0).
            cx16.set_screen_mode($80)
            cx16.VERA_L0_CONFIG = cx16.VERA_L0_CONFIG & %11111100 | bmx.vera_colordepth
            cx16.VERA_DC_BORDER = bmx.border

            if bmx.width==320 {
                ; fast full-screen load straight into VRAM at bank 0, addr 0
                if bmx.continue_load(0, 0) {
                    if bmx.height<240 {
                        ; fill the unused bottom strip with the border color
                        cx16.GRAPH_set_colors(bmx.border, bmx.border, 99)
                        cx16.GRAPH_draw_rect(0, bmx.height, 320, 240-bmx.height, 0, true)
                    }
                    void txt.waitkey()
                }
            } else {
                ; smaller image: clear to border, center it, and use the padded ("stamp") loader
                cx16.GRAPH_set_colors(0, 0, bmx.border)
                cx16.GRAPH_clear()
                uword offset = (320-bmx.width)/2 + (240-bmx.height)/2*320
                when bmx.bitsperpixel {
                    1 -> offset /= 8
                    2 -> offset /= 4
                    4 -> offset /= 2
                    else -> {}
                }
                if bmx.continue_load_stamp(0, offset, 320) {
                    void txt.waitkey()
                }
            }
        }

        cbm.CINT()      ; back to text mode; also restores the default text palette (indices 0-15)

        if bmx.error_message!=0 {
            txt.print("\n image load error: ")
            txt.print(bmx.error_message)
            txt.nl()
            sys.wait(120)
        }
    }
}

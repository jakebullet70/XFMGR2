; xmusic - banked WAV (PCM) player overlay for XFMGR2 (bank 7 = MUS_BANK).
;
; Compiled as a %output library headerless blob (org $A000), loaded into reserved HIRAM bank 7
; at startup via diskio.loadlib, and called from XFMGR via `extsub @bank 7`. Moving the WAV
; streaming here keeps ~all of it out of scarce main RAM. Streaming recipe transcribed from
; docs/prog8/examples/pcmaudio/stream-simple-poll.p8 + stream-wav.p8: POLL the AFLOW flag (no
; IRQ, so VERA_IEN is untouched and the KERNAL IRQ / GETIN keep running), refill the 4 KB FIFO
; 1 KB at a time from an in-bank staging buffer.
;
; Contract (uiutil-style): XFMGR has already chdir'd into the file's dir and drawn a status line
; into the bottom box; we only stream (no drawing). Returns: 0 = played/stopped, 1 = open error,
; 2 = unsupported/for-not-a-wav.
;
; Fixed entry offsets via %jmptable: $A000 = start (init), $A003 = play_wav.

%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio')
%import strings
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; KEEP MODULE VARS UNINITIALIZED (same %jmptable gotcha as tview/uiutil): an initialized var
    ; (including a memory() slab address) is emitted before the code and shoves the table off its
    ; fixed offsets. wavbuf is assigned its slab in start(); everything else is plain BSS.
    %jmptable ( main.play_wav )

    uword wavbuf                    ; 1 KB disk-staging buffer (assigned in start())
    ubyte[53] namebuf              ; XFMGR's namebuf is 52 chars + NUL

    ; parsed WAV header fields
    ubyte w_fmt
    ubyte w_ch
    uword w_rate
    ubyte w_bits
    uword w_dataoff
    ubyte vera_rate
    bool  eightbit

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Grab the staging slab
        ; (a slab address is "initialized" data, so it must be taken here, not at module level).
        wavbuf = memory("wavbuf", 1024, 0)
    }

    ; ---------------------------------------------------------------- public entry ($A003)

    sub play_wav(uword nameptr @R0) -> ubyte {      ; returns in A by convention; main's extsub names @A
        void strings.copy(nameptr, namebuf)             ; consume @R0 FIRST (diskio clobbers r0-r3)
        ; --- read + parse the header ---
        if not diskio.f_open(namebuf)
            return 1
        void diskio.f_read(wavbuf, 256)
        bool ok = parse_wav()
        diskio.f_close()
        if not ok or unsupported()
            return 2
        ; --- set up VERA PCM and stream ---
        setup_vera()
        stream_loop()
        cx16.VERA_AUDIO_RATE = 0
        cx16.VERA_AUDIO_CTRL = %10100000                ; FIFO reset, muted: clean for a later ZSM-PCM
        return 0
    }

    ; ---------------------------------------------------------------- header parse (in wavbuf)

    sub parse_wav() -> bool {
        ; wavbuf holds the first 256 bytes. Validate RIFF/WAVE/fmt, pull the fields we need, and
        ; walk the chunk list to the 'data' chunk. (Assumes header+chunks fit in the first 256 B,
        ; which holds for normal PCM/ADPCM wavs.)
        if wavbuf[0]!=$52 or wavbuf[1]!=$49 or wavbuf[2]!=$46 or wavbuf[3]!=$46      ; "RIFF"
            return false
        if wavbuf[8]!=$57 or wavbuf[9]!=$41 or wavbuf[10]!=$56 or wavbuf[11]!=$45    ; "WAVE"
            return false
        if wavbuf[12]!=$66 or wavbuf[13]!=$6d or wavbuf[14]!=$74 or wavbuf[15]!=$20  ; "fmt "
            return false
        uword fmtsize = peekw(wavbuf + 16)
        w_fmt  = wavbuf[20]
        w_ch   = wavbuf[22]
        w_rate = peekw(wavbuf + 24)                     ; assume sample rate <= 65535
        w_bits = wavbuf[34]
        ; the fmt body is fmtsize bytes starting at offset 20; chunks follow, each 8-byte header
        uword p = 20 + fmtsize
        while p < 248 {
            if wavbuf[p]==$64 and wavbuf[p+1]==$61 and wavbuf[p+2]==$74 and wavbuf[p+3]==$61 {  ; "data"
                w_dataoff = p + 8
                return true
            }
            p += 8 + peekw(wavbuf + p + 4)              ; skip this chunk (id+size+body)
        }
        return false
    }

    sub unsupported() -> bool {
        ; M3: uncompressed PCM only, mono/stereo, <= 48828 Hz, 8 or 16 bit. (ADPCM added later.)
        return w_fmt != 1 or w_ch > 2 or w_rate > 48828 or w_bits > 16 or w_bits < 8
    }

    ; ---------------------------------------------------------------- VERA setup + streaming

    sub setup_vera() {
        eightbit = w_bits == 8
        cx16.VERA_AUDIO_RATE = 0                        ; halt while we set up
        ubyte ctrl = %10101011                          ; mono, 16-bit, volume 11
        if w_ch == 2
            ctrl = %10111011                            ; stereo, 16-bit, volume 11
        if eightbit
            ctrl &= %11011111                           ; clear bit5 -> 8-bit
        cx16.VERA_AUDIO_CTRL = ctrl                     ; (bit7 also resets the FIFO)
        repeat 1024
            cx16.VERA_AUDIO_DATA = 0                    ; prefill ~silence
        ; integer VERA rate: 25_000_000 / 65536 = 381 (approx 381.47); +1; hardware max = 128
        uword r = w_rate / 381 + 1
        if r > 128
            r = 128
        vera_rate = lsb(r)
    }

    sub stream_loop() {
        if not diskio.f_open(namebuf)
            return
        void diskio.f_read(wavbuf, w_dataoff)           ; skip the header, land on sample data
        uword got = diskio.f_read(wavbuf, 1024)         ; pre-read the first block
        cx16.VERA_AUDIO_RATE = vera_rate                ; start playback
        ubyte k
        while got != 0 {
            ; wait for AFLOW (FIFO < 1 KB), polling keys meanwhile
            repeat {
                k = cbm.GETIN2()
                if k != 0 and handle_key(k) {
                    diskio.f_close()
                    return
                }
                if cx16.VERA_ISR & %00001000 != 0
                    break
            }
            fill(got)                                   ; push the buffered block into the FIFO
            if got < 1024
                break                                   ; that was the (partial) final block
            got = diskio.f_read(wavbuf, 1024)           ; read the next block for the next AFLOW
        }
        ; drain: hold until the FIFO empties (bit6) or a key
        repeat {
            k = cbm.GETIN2()
            if k != 0 and handle_key(k)
                break
            if cx16.VERA_AUDIO_CTRL & %01000000 != 0
                break
        }
        diskio.f_close()
    }

    sub handle_key(ubyte kk) -> bool {
        ; true = quit. Q/ESC/STOP quit; SPACE pauses (RATE=0) and blocks until SPACE or quit.
        ubyte k = fold(kk)
        if k == 'q' or k == 27 or k == 3
            return true
        if k == ' ' {
            cx16.VERA_AUDIO_RATE = 0                    ; pause: FIFO stops draining
            repeat {
                ubyte k2 = cbm.GETIN2()
                if k2 != 0 {
                    k2 = fold(k2)
                    if k2 == ' ' {
                        cx16.VERA_AUDIO_RATE = vera_rate    ; resume
                        return false
                    }
                    if k2 == 'q' or k2 == 27 or k2 == 3
                        return true
                }
            }
        }
        return false
    }

    sub fold(ubyte k) -> ubyte {
        ; fold a SHIFTed letter ($C1..$DA) down onto the unshifted range, like main's cmd_key()
        if k >= $c1 and k <= $da
            return k - $80
        return k
    }

    sub fill(uword n) {
        ; copy n bytes from wavbuf into the FIFO. Full 1 KB blocks go through the fast unrolled
        ; asm; a short final block uses the slow prog8 tail. 8-bit wav samples are UNSIGNED, so
        ; XOR $80 to the signed values VERA wants; 16-bit wav samples are already signed.
        if n == 1024 {
            if eightbit
                fifo8()
            else
                fifo16()
            return
        }
        uword ptr = wavbuf
        uword i
        if eightbit {
            for i in 0 to n-1 {
                cx16.VERA_AUDIO_DATA = @(ptr) ^ $80
                ptr++
            }
        } else {
            for i in 0 to n-1 {
                cx16.VERA_AUDIO_DATA = @(ptr)
                ptr++
            }
        }
    }

    asmsub fifo16() {
        ; blast 1024 bytes wavbuf -> VERA FIFO (16-bit samples, copied as-is). Self-modifying so it
        ; needs no zeropage. (wavbuf is a uword pointer var, so p8v_wavbuf holds its slab address.)
        %asm {{
            lda  p8v_wavbuf
            sta  _loop+1
            sta  _lp2+1
            lda  p8v_wavbuf+1
            sta  _loop+2
            sta  _lp2+2
            ldx  #4
            ldy  #0
_loop       lda  $ffff,y            ; self-modified base
            sta  cx16.VERA_AUDIO_DATA
            iny
_lp2        lda  $ffff,y            ; self-modified base
            sta  cx16.VERA_AUDIO_DATA
            iny
            bne  _loop
            inc  _loop+2
            inc  _lp2+2
            dex
            bne  _loop
            rts
        }}
    }

    asmsub fifo8() {
        ; blast 1024 bytes wavbuf -> VERA FIFO, converting UNSIGNED 8-bit wav to signed (eor #$80).
        %asm {{
            lda  p8v_wavbuf
            sta  _loop+1
            sta  _lp2+1
            lda  p8v_wavbuf+1
            sta  _loop+2
            sta  _lp2+2
            ldx  #4
            ldy  #0
_loop       lda  $ffff,y            ; self-modified base
            eor  #$80
            sta  cx16.VERA_AUDIO_DATA
            iny
_lp2        lda  $ffff,y            ; self-modified base
            eor  #$80
            sta  cx16.VERA_AUDIO_DATA
            iny
            bne  _loop
            inc  _loop+2
            inc  _lp2+2
            dex
            bne  _loop
            rts
        }}
    }
}

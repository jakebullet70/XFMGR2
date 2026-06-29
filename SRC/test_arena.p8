; test_arena - verifies the banked bump allocator survives a bank roll.
; Stores ~1000 strings (enough to overflow bank 1 into bank 2), remembers the
; far pointer of several probe entries, then reads them back and compares.

%import textio
%import strings
%import conv
%import xarena
%zeropage basicsafe
%option no_sysinit

main {
    const uword N = 1000

    ; probe indices we will verify after all allocations
    ubyte[5] probe_bank
    uword[5] probe_off
    uword[5] probe_idx = [0, 600, 700, 900, 999]

    str expected = "?"*24
    str got      = "?"*24

    sub make_name(uword i) {
        ; build "e<decimal>" padded with '.' to 17 chars, so each record is ~18
        ; bytes -- 1000 of them overflow bank 1 into banks 2 and 3, exercising the roll.
        expected[0] = 'e'
        void strings.copy(conv.str_uw(i), &expected[1])
        ubyte l = strings.length(expected)
        while l < 17 {
            expected[l] = '.'
            l++
        }
        expected[17] = 0
    }

    sub start() {
        txt.lowercase()
        txt.print("xarena bank-roll test\n\n")

        xarena.reset()

        ubyte p
        uword i
        for i in 0 to N-1 {
            make_name(i)
            if not xarena.add_str(expected) {
                txt.print("alloc failed at ")
                txt.print_uw(i)
                txt.nl()
                break
            }
            ; record far pointer if this index is a probe
            for p in 0 to len(probe_idx)-1 {
                if probe_idx[p] == i {
                    probe_bank[p] = xarena.result_bank
                    probe_off[p]  = xarena.result_off
                }
            }
        }

        txt.print("stored ")
        txt.print_uw(N)
        txt.print(" strings, high bank = ")
        txt.print_ub(xarena.high_bank)
        txt.nl()
        txt.nl()

        ubyte fails = 0
        for p in 0 to len(probe_idx)-1 {
            make_name(probe_idx[p])                 ; expected[] = correct value
            xarena.read_str(probe_bank[p], probe_off[p], got)

            txt.print("idx ")
            txt.print_uw(probe_idx[p])
            txt.print(" bank ")
            txt.print_ub(probe_bank[p])
            txt.print(" off $")
            txt.print_uwhex(probe_off[p], false)
            txt.print("  got '")
            txt.print(got)
            txt.print("' ")
            if strings.compare(got, expected) == 0 {
                txt.print("OK\n")
            } else {
                txt.print("FAIL exp '")
                txt.print(expected)
                txt.print("'\n")
                fails++
            }
        }

        txt.nl()
        if fails == 0
            txt.print("ALL PROBES PASSED\n")
        else {
            txt.print_ub(fails)
            txt.print(" PROBES FAILED\n")
        }
    }
}

%import textio
%zeropage basicsafe

main {
    sub start() {
        txt.clear_screen()
        txt.plot(0, 10)
        txt.print("hello from a real prg!\n")
        txt.print("alt-x execute works.\n\n")
        txt.print("press a key...\n")
        void cbm.GETIN2()
        repeat {
            if cbm.GETIN2() != 0
                break
        }
    }
}

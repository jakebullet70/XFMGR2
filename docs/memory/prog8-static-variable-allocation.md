---
name: prog8-static-variable-allocation
description: Prog8 gives every local its own static byte - no stack, no auto-overlap
metadata:
  type: reference
---

Prog8 allocates ALL variables statically - there is no stack and no heap. Per the manual:
"All variables are allocated statically ... essentially all variables are global (but
scoped)." Subroutine-local variables are hoisted to subroutine scope and each gets its OWN
fixed address; the compiler does NOT overlap/share the memory of locals belonging to
different subroutines, even ones that can never be active at the same time. Consequence:
subroutines are non-reentrant (no recursion / no calling a main-program sub from an IRQ).

Verified empirically in this project: the generated xfmgr.asm contained 12 separate
`p8v_k .byte ?` allocations - one per `ubyte k` declaration across different subs. So
declaring the same throwaway local in N routines costs N bytes, and consolidating them into
ONE module-level global reclaims N-1 bytes (confirmed: merging 6 keystroke locals + trimming
one array dropped the BSS high-water by exactly the predicted bytes).

Implications for memory tuning here:
- Sharing a single global for a throwaway temp IS a real (if small) saving, but only safe
  when no routine re-reads the temp across a nested call that also writes it. We did this for
  the keystroke dispatch var `g_key` (see [[xfmgr-architecture]]). Loop counters (i/j/row)
  are NOT safe to share - they nest across calls (draw_tree -> build_tree_line).
- Bigger wins come from right-sizing fixed arrays (e.g. view_pages), not from temp locals.
- `build.bat` now prints the main-RAM high-water after each compile - watch it to measure
  any allocation change. See [[xfmgr-run-and-persistence]].

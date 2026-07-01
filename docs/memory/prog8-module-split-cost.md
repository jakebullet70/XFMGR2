---
name: prog8-module-split-cost
description: What it actually costs to move prog8 code into a separate block/module
metadata:
  type: reference
---

Moving code from `main` into its own prog8 block/module (e.g. extracting the viewer into
`xviewer.p8`) costs only a small FIXED overhead, NOT a per-call tax.

Verified empirically (xfmgr.asm): a cross-module call compiles to `jsr p8b_main.p8s_<name>`
— an **absolute symbol**, byte-identical to an intra-block call. Likewise `main.var`
accesses are plain absolute addressing. So calling "up" into `main` from another module is
free vs. calling within `main`.

The real cost of a split is **per-block structural overhead**: each block gets its own
`prog8_init_vars` routine (zeroing its vars + building its string initializers), its own
`.block`/`.proc` framing, and a startup JSR to that init — plus the optimizer has a smaller
block to work across. Measured: extracting the ~12-sub viewer added ~122 B of code.

**How to apply:** don't try to "reduce boundary crossings" to recover those bytes — moving
shared helpers into a third leaf module that both `main` and the module call just ADDS
another block's overhead while the calls stay identical-cost JSRs (net worse). The choice is
binary: keep the split (pay ~100-340 B for separation) or inline it back. See
[[prog8-static-variable-allocation]] and [[xfmgr-architecture]].

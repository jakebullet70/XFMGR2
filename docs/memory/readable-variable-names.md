---
name: readable-variable-names
description: User wants readable variable names in XFMGR2 code - no one/two-letter locals in new code
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T17:25:37.243Z
---

Told to me 2026-07-31 while building the scoped file views: **"remember to use readible var names"**,
after I wrote locals called `sc`, `dsave` and `k`.

**Why:** this codebase is dense 6502-targeted Prog8 with heavy commenting, and it gets read long after
it is written. A one-letter local costs nothing to type and everything to re-read. The existing code
does use short names in places (`fi`, `dd`, `i`, and the shared [[xfmgr-g-ndx-loop-counter]]), so the
rule is about what I ADD, not a mandate to go rename what is there.

**How to apply:** name new locals for what they hold - `owner_dir`, `gathered_row`, `new_scope`,
`tagged`, `saved_page` - not `d`, `k`, `sc`, `n`. Plain loop counters over a file list read fine as
`row`/`i`; anything carrying meaning gets a real name.

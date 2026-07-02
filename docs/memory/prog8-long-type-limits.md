---
name: prog8-long-type-limits
description: "prog8 long: arrays cap at 64 elems, index must be a byte, narrowing needs 'as'"
metadata:
  node_type: memory
  type: project
  originSessionId: f57043d0-c280-46a9-ba6d-9010f3f42cb2
---

prog8 12.2.1 supports `long` (32-bit) fully — `diskio` uses it (`f_seek(long)`,
`f_tell()->long,long`) — but three limits bite when widening file offsets from `uword`:

1. **`long[]` arrays cap at 64 elements**, not the usual 256. `long[100] view_pages` fails
   the build: `ERROR long array length must be 1-64`. (Separate limit from the general 256
   *byte* array cap in [[prog8-jmptable-init-vars-gotcha]].) For >64 32-bit entries: use two
   parallel `uword[]` (hi/lo words) or a `memory()` slab with `pokel`/`peekl`.
2. **Array index must be a byte (0..255).** `viewbuf[got - 1]` where `got` is `uword` fails:
   `ERROR array indexing is limited to byte size 0..255`. Cast the index: `viewbuf[lsb(got) - 1]`.
3. **Narrowing long -> uword/ubyte needs an explicit `as` cast.** `want = toskip` (uword = long)
   won't compile; write `want = toskip as uword`. Byte extraction from a long for a hex dump:
   `put_hex8((v >> 16) as ubyte)` etc. (long `>>`, `&`, `-`, `==`, `<` all compile fine).

**Context that found it:** giving the tview banked viewer >64 KB paging — offsets
(`view_pages`, `view_off`, `view_match/next`, skip counters, `file_len`) went `uword`->`long`.
`view_pages` had to drop from `[100]` to `[64]`, so text mode caches 64 page-tops (~140 KB of
dense content) for backward paging; hex mode uses a single `long` so it reaches any offset.
See [[xfmgr-architecture]] and [[prog8-static-variable-allocation]].

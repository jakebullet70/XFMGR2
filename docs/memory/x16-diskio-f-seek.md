---
name: x16-diskio-f-seek
description: diskio.f_seek(long) works on the X16 and f_open is already set up for it - never read-and-discard to reach a file offset
metadata: 
  node_type: memory
  type: reference
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T16:00:18.967Z
---

Learned 2026-07-31 (build 230) while fixing the viewer feeling "stuck" on big files.

**`diskio.f_seek(long position) -> bool` exists and works** in the vendored
[[prog8-diskio-vendored-patch]]. It issues a CMDR-DOS `P` (position) command on the command
channel, then restores the read channel. `f_open` already opens with
`cbm.SETLFS(READ_IO_CHANNEL, drive, READ_IO_CHANNEL)` — the `Channel,x,Channel` form — and its
own comment says that shape is required *precisely so f_seek works*. So seeking is available
after any `f_open`; nothing extra is needed.

**The trap:** the obvious way to reach offset N is a read-and-discard loop (`f_read` 250 bytes
at a time until `toskip` hits 0). tview did that in three places for months. It makes one page
render O(offset) — a page 120 KB into a file re-read 120 KB **per keypress** — and anything that
walks pages from the start of the file (rebuilding a page-top chain) becomes O(n²), moving
megabytes to land on a match deep in a file. Replacing all three with `f_seek` also made the
overlay **139 bytes smaller**: the loops cost more code than the seeks.

Two caveats, both real:
- **Do not seek after reading the last byte** — diskio's own comment: you must close and reopen
  first. Seeking right after `f_open` (before any read) is always safe.
- **To keep the byte BEFORE a page**, seek to `start_off - 1` and read one byte. tview needs
  this to prime its CR/LF-straddling-a-page-boundary check; a plain seek to `start_off` loses it.

If a seek is silently ignored by some filesystem, the symptom is **wrong content on the page**,
not slowness — so it fails loudly enough to catch in one page-down.

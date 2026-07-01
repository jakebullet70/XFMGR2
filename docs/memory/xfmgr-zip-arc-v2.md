---
name: xfmgr-zip-arc-v2
description: Backlog — add ZIP / ARC archive support (browse + extract) in XFMGR2 V2
metadata: 
  node_type: memory
  type: project
  originSessionId: b8fa7cc6-ce21-49c0-9d7e-f50a35429b63
---

**Feature note (ZIP / ARC support — V2).** The user wants archive support added in
XFMGR2 **V2**: handle ZIP / ARC files as first-class citizens. Captured 2026-07-01.

**Intent:** treat an archive like a browsable container — ideally ENTER on a `.ZIP`/
`.ARC` in the file pane opens it as a pseudo-directory (list entries, view, extract
one/tagged/all to a chosen dir), mirroring the XTree "open archive" experience.

**Constraints to weigh when it's picked up:**
- Decompression is the hard part on a 65C02. Prog8 ships a compression module
  (`docs/prog8/compression.p8`, `docs/prog8/shared_compression.p8`) but that's LZSA/
  RLE-style, **not** DEFLATE (ZIP) or the classic ARC codecs (crunch/squeeze). A ZIP
  inflate + CRC32, or ARC's methods, would need porting/writing.
- Memory: file records already live in the banked arena (see [[xfmgr-architecture]]).
  An archive's central directory / member list would want the same banked-arena
  treatment, not main RAM. Extraction buffers must fit the $A000-$BFFF window.
- Scope options, smallest→largest: (1) list-only (parse ZIP central dir / ARC headers,
  show names+sizes, no extract); (2) STORE-only extract (uncompressed members);
  (3) full DEFLATE/ARC decompress. (1)+(2) are achievable; (3) is the real work.
- UX hook: reuse the file pane + ENTER-drills convention already in place, and the
  existing copy/extract-to-dir picker (`pick_dir`).

Related: [[xfmgr-architecture]], [[xfmgr-showall-revisit]].

---
name: xfmgr-viewer-line-gutter
description: DROPPED 2026-08-01 - a line-number gutter in the text viewer was rejected because real XTree has none; kept as the record of that decision
metadata: 
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T05:49:02.527Z
---

**DROPPED 2026-08-01, by the user: "skip the gutter, there is not one in xtree."**

An optional line-number gutter for the text viewer sat on the backlog from 2026-07-24, ported from
MSEDIT's `ln_on` / `gutter_w`. It is NOT being built. Do not re-propose it.

**The reason is the project's standing tiebreaker**: XFMGR is an XTree clone, and where a feature has
no XTree counterpart it needs a separate justification to exist. XTree's file viewer has no line
numbers, so the gutter fails that test on its own. This is the same principle that PULLED the
standalone global browser at build 214 and rebuilt Showall/Branch as a scope flag instead
([[xfmgr-showall-revisit]]) - "is this how XTree does it" beats "is this a nice feature".

**Contrast with what DID ship** the same day (build 249): wrap modes - `W` cycles char / word / off,
with left-right panning in off mode. Those earn their place because a file whose lines run past 78
columns is otherwise UNREADABLE, not merely less convenient. That is the bar.

Worth knowing if this ever comes back: the plumbing is the expensive half, not the digits. Line
numbers have to survive paging, which means caching the line number at each page top alongside
`view_pages[]` and threading it through `pages_push`, `view_seek_page` and `view_jump`. The render
side (offset the text by `gutter_w`, print the number on a logical line's FIRST row only) is the easy
part - which is why this looked smaller than it was.

Related: [[xfmgr-viewer-iso-pet-toggle]], [[xfmgr-syntax-coloring]], [[xfmgr-showall-revisit]].

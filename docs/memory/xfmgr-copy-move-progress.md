---
name: xfmgr-copy-move-progress
description: "backlog — show 'Working... (N of N)' progress during copy/move of multiple files"
metadata: 
  node_type: memory
  type: project
  originSessionId: bd1a090e-2c8b-4d29-a3b0-e992481b15dd
---

Backlog: during copy and move operations over a tagged/multi-file set, show a
`Working...  (N of N)` progress indicator so the user has feedback on long runs.

**Why:** batch copy/move currently gives no per-file feedback; a running count
reassures on large operations and matches the DOS/XTree feel.

**How to apply:** in the copy and move command loops, print/update a status line
`Working...  (<current> of <total>)` as each file is processed. Relates to the
tagged-file operations in [[xfmgr-architecture]].

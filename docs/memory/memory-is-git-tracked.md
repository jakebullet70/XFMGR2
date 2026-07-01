---
name: memory-is-git-tracked
description: "This project's memory folder is a junction into the repo (docs/memory), so notes are git-tracked"
metadata: 
  node_type: memory
  type: reference
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

The auto-memory folder for this project is a **directory junction**, not a plain
folder:

- Link: `C:\Users\Admin\.claude\projects\c--dev-CmdrX16-dos-tools-XFMGR2\memory`
- Target: `C:\dev\CmdrX16\dos_tools\XFMGR2\docs\memory` (inside the git repo)

So every memory note written through the normal `~/.claude` path lands in
`docs/memory/` and is **version-controlled with the project** — no manual resync.
Set up 2026-07-01 (verified read + write-through).

**How to apply:** memory changes here are also repo changes. When the user wants
them on GitHub, `git add docs/memory && git commit` (only when they ask). Keep notes
clean/committable. A one-time safety backup of the pre-junction folder sits at
`...\c--dev-CmdrX16-dos-tools-XFMGR2\memory.prejunction.bak` and can be deleted once
the junction is trusted.

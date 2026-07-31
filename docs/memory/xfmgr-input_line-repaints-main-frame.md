---
name: xfmgr-input_line-repaints-main-frame
description: "Gotcha: input_line() calls box_close()->draw_frame(), repainting the NORMAL dual-pane chrome; a full-screen modal that prompts must repaint itself after"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**Gotcha (found build 212, 2026-07-31).** `input_line()` (the shared prompt line-editor, xfmgr.p8) ends
every accept/cancel with **`box_close()` -> `draw_frame()`**, which repaints the MAIN dual-pane chrome:
the vertical **divider at col ~36**, the `DIRECTORY`/`FILE:` pane headers, the title. That's correct in
the normal view (input_line's home), but WRONG inside a full-screen modal - it bleeds main-view chrome
over the modal.

Symptom (the bug it caused): content search in the GLOBAL browser ([[xfmgr-showall-revisit]],
[[xfmgr-file-text-search]]) called input_line; on ENTER, box_close redrew the divider + pane headers over
the browser, then the scan loop ran and left that chrome visible ONLY on the long deep-path rows (short
rows end before col 36, so they looked fine) - a transient corruption that self-heals after the modal's
next full repaint. Classic "only shows up while searching" signature.

**Rule:** any full-screen modal that calls `input_line` (or anything that ends in `box_close`) must
**repaint itself right after the prompt returns**, before doing more work over that frame. The fix here:
`content_search_prune` does `txt.clear_screen(); show_all_frame(); draw_sa_page(cursor)` after input_line,
before the scan loop. The draw code itself was innocent - proven by tracing (cm_src is 133 B, build_path
composes correctly), so don't chase draw_sa_row; the culprit is the shared prompt's cleanup. Related:
box_close -> draw_frame is deliberately kept in main ([[xfmgr-overlay-ram-strategy]]).

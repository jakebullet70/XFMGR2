---
name: xfmgr-ram-savings-menu
description: "Verified menu of main-RAM savings for XFMGR2 (held, not yet applied) + the 3 overflow bugs that were fixed"
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

**Verified RAM-savings review (2026-07-01).** Free main RAM was ~2.2 KB. A workflow
found + adversarially verified these savings; the user chose to **fix the overflow
bugs first and HOLD the RAM changes**. Byte figures are the corrected (post-verify)
estimates. This is the backlog to draw from when reclaiming RAM.

**UPDATE (later same session):** free RAM fell to ~1.0 KB (998 B) after adding dir-rename,
the 2-line copy/move+relog banners, dir-panel Prune/Quit-here, and the copy/move "create
missing dest?" prompt. (Note: `diskio.status_code()` is already linked via xscan;
`diskio.status()` is NOT — using status() costs ~186 B, so prefer status_code().)

**QUICK-WINS PACKAGE NOW APPLIED (same session):** recovered **+989 B → ~1.9 KB (1987 B)** free.
Applied: DIR_MAX 192→128 (-512 B BSS, caps logged dirs at 128), HIST_N 15→10 (-250 B slab,
10 recents), `clamp_file_cursor()` helper dedup of the ~8 file-index-rebuild clamps (-183 B
image), pr_leaf/pr_sub merge in xscan (-40 B), his_fname 20→16 (-4 B). All verified by build.
**Still on the shelf:** the **cold-bank move** (~1.6 KB: reserve one bank, push/pop_rambank
the modal-only `sa_*`/`cm_*`/`view_pages`/`pr_*`) and `hist_buf`→bank (525 B, high effort).

**Bugs already FIXED (this session):**
- `hist_store()` SRC/xfmgr.p8 — uncapped `strings.copy` of a ≤79-char prompt input
  into a 50-byte (`HIST_W`) slot → overflow. Now `str_copy_cap(sptr, hist_ptr(0), HIST_W-1)`.
- ShowAll `sa_line` (100 B) — unbounded `strings.append` of path+filename → now a
  capped append (`str_copy_cap(namebuf, &sa_line+sl, 99-sl)`).
- `new_node()` SRC/xtree.p8 — reserves the name FIRST; returns `NONE` if the 3072-byte
  name arena is full, instead of a node whose `name_ptr` derefs `dname_buf+$ffff`.

**Confirmed savings (safe), largest first:**
| Saving | Bytes | Mechanism | Risk |
|---|--:|---|---|
| ShowAll `sa_*` arrays → cold bank | 1021 | BSS→bank | low |
| `hist_buf` → cold bank | 525 | slab→bank | high (needs far-string helpers) |
| DIR_MAX 192→128 | 512 | cap (128 dirs) | low |
| `cm_*` copy/move scratch → cold bank | 390 | BSS→bank | med |
| prune `pr_*` scratch → cold bank | 254 | BSS→bank | low (str→raw refactor) |
| HIST_N 15→10 | 250 | cap | low |
| `view_pages` → cold bank | 200 | BSS→bank | low |
| `clamp_file_cursor()` helper | 170 | image | low |
| FILE_VIS_MAX 255→240 | 45 | cap (mild trunc) | low |
| consolidate `pr_leaf`/`pr_sub` | 41 | BSS | low |
| copy/move msg factor | ~12 | image | low |
| `his_fname` 20→16 | 4 | BSS | low |

**Suggested packages:**
- **Quick wins (~1.0 KB, no new bank):** DIR_MAX→128, HIST_N→10, clamp helper,
  pr_leaf/pr_sub merge, his_fname→16.
- **Cold-bank move (~1.6 KB more):** reserve ONE bank (same discipline as `DX_BANK`),
  move `sa_*` + `cm_*` + `view_pages` (all cold, modal-only) into it with
  push/pop_rambank. Add `pr_*` for +254. Uniform, proven mechanism.
- **hist_buf→bank (525):** high effort (write `far_copy_str`/`far_compare_str`), defer.

**Do NOT move:** `ft_*` file display index (xfiles.p8) stays in MAIN RAM — it's read
in the per-keystroke `draw_files` loop; banking it would hurt responsiveness.
**Rejected (unsafe):** shrinking `namebuf`/`exit_dir`/`cm_src`/`cm_dst`/`view_find`
(sized at real path/name maxima), and `memory()`-slab "moves" (slabs ARE main RAM,
zero saving — only a real RAM bank counts).

Related: [[xfmgr-architecture]], [[xfmgr-showall-revisit]], [[always-report-mem-stats]].

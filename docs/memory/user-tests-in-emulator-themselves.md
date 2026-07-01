---
name: user-tests-in-emulator-themselves
description: "The user runs/verifies XFMGR in the emulator themselves — build & launch, then report; don't drive the GUI to verify"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b8fa7cc6-ce21-49c0-9d7e-f50a35429b63
---

The user prefers to **test and visually verify in the emulator themselves**. After a change:
build + launch (`run.bat`) and report the result + memory-stats, then STOP.

**Why:** driving the x16emu GUI with SendKeys/AppActivate/screenshots to "verify" is flaky
(SDL letter-key input is unreliable; popups need navigation) and the user would rather just
look. They've said "i will test, just launch", "i will press the A key, just ask", and
interrupted a screenshot-verification step with "i will test".

**How to apply:**
- Do use PowerShell to compile + `run.bat` to LAUNCH the app for them (that's wanted).
- Do NOT SendKeys / AppActivate / screenshot-and-Read to confirm behaviour or colours.
- Compile-time verification is still fine (asm-byte probes, build output). If I truly need to
  know an on-screen value, ASK the user rather than automate the GUI.
- Always include the build memory-stats block (see [[always-report-mem-stats]]).

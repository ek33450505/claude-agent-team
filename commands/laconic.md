---
description: Toggle laconic terse-output mode. Usage: /laconic [lite|full|ultra|off]
---

Activate laconic mode for this session.

If the user typed `/laconic off` — deactivate laconic mode, return to normal verbosity.
If the user typed `/laconic lite` — activate lite compression level.
If the user typed `/laconic ultra` — activate ultra compression level.
Otherwise (`/laconic` or `/laconic full`) — activate full laconic mode (default).

Load the laconic skill and inform the user which level is now active. One sentence confirmation only.

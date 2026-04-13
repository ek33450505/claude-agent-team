---
description: Toggle caveman terse-output mode. Usage: /caveman [lite|full|ultra|off]
---

Activate caveman mode for this session.

If the user typed `/caveman off` — deactivate caveman mode, return to normal verbosity.
If the user typed `/caveman lite` — activate lite compression level.
If the user typed `/caveman ultra` — activate ultra compression level.
Otherwise (`/caveman` or `/caveman full`) — activate full caveman mode (default).

Load the caveman skill and inform the user which level is now active. One sentence confirmation only.

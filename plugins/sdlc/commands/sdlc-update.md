---
description: Check and update all installed Claude Code plugins
argument-hint: "[--auto-on | --auto-off | --snooze | --status | --check-only | --disable-checks | --enable-checks]"
allowed-tools: Bash
---

Run the sdlc-update script. Execute this single command and print its full output:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc-update.sh" "$ARGUMENTS"
```

Do not summarize or interpret the output. Print it verbatim.

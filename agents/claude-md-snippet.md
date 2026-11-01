## Watching something in the background

A watch that should keep running after this session ("keep an eye on",
"check every 30 minutes whether", "let me know if it breaks") goes on the
**Firetower** (`firetower`): load the **`firetower`** skill first. Book a check
with the machine's scheduler (it owns the timing) that reports one line to
the Firetower; never keep a session open or loop to poll. To
see what's being watched, or whether anything is on fire: `firetower ls`.

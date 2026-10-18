<!-- asqu:start -->
## Version history (Asqu)

This project uses Asqu to keep its history. Asqu saves files by itself, but it can't see
what the person asked you, so please tell it:

1. **Before changing files**, record the person's request in their own words:
   `asqu intent "<the person's request>"`
2. **When you've finished**, run `asqu save`.

If you can't run commands, write the request to `.asqu/intent` before editing instead.

- To undo or go back: preview with `asqu undo --dry-run` or `asqu back <their words> --dry-run`,
  show the person, then run it without `--dry-run`.
- For a big or risky change, use a Try: `asqu try start <name> -w "<request>"`, work in the
  folder it prints, then `asqu try keep <name>`.
- Never pass `--yes` or `--trust-check` yourself. Those are the person's decisions.
<!-- asqu:end -->

This should be the simplest app, offloading most of the work to dependencies. I
want a CLI that should allow for:

```bash
$ prer
[prompts for title]
[opens neovim for me to write the pull request in a temporary file that, once closed, will be used in the open pull request]
[lets me assign the reviewer from everyone available]
[copies into my clipboard a string following the syntax `[:open-pr: {title} @reviewer]({url})` and lets me know]
```

This should be written using Zig, and it can rely on Wayland native things like
`wl-clipboard` to copy to clipboard.

To determine the at of the reviewer in Slack, you can prepare a map file that I
can edit, but not commit. It can be whatever format is easier to parse,
preferably JSON.


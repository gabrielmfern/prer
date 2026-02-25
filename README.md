# prer

CLI to create GitHub pull requests and copy a Slack-formatted link to the clipboard.

## Requirements

These executables must be installed and available on your `PATH`:

| Dependency | Purpose |
|------------|--------|
| **gh** (GitHub CLI) | Repo info, collaborators, PR create/view/list. Must be [installed](https://cli.github.com/) and authenticated (`gh auth login`). |
| **git** | Preflight checks (remote, status, branch, commit range). |
| **nvim** (Neovim) | Editor for the PR body when creating a new PR. |
| **Clipboard** | Copy the Slack message to the clipboard: **wl-copy** on Linux (e.g. from `wl-clipboard`), **pbcopy** on macOS (built-in). |

## Optional configuration

- **`~/.config/prer/reviewers.json`** — Maps GitHub usernames to Slack handles for the `@reviewer` part of the message. If missing, it can be auto-generated from repo collaborators on first run; edit the values to set Slack handles.

## Build

```bash
zig build
```

Binary: `zig-out/bin/prer`.

## Usage

- **`prer`** — Interactive flow: prompt for title, edit body in nvim, choose reviewer, create PR, copy Slack message.
- **`prer <number>`** — Copy Slack message for existing PR by number (e.g. `prer 8`).
- **`prer <url>`** — Copy Slack message for existing PR by URL (e.g. `prer https://github.com/owner/repo/pull/8`).

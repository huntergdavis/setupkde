# setupkde


Rebuilds my KDE app environment on a fresh Kubuntu machine: installs the
programs and recreates the KDE menu icons.

```bash
./setup-kde.sh
```

Safe to re-run — every step is idempotent.

## What it does

**Menu icons** (`~/.local/share/applications/`): HEY, HEY Journal, Newsboat, ortop.

**Programs:**

| Program | Source |
|---|---|
| `hey` | built from `basecamp/hey-cli` → `/usr/local/bin/hey` |
| `ortop` | built from `huntergdavis/openrouter-tui` → `~/.local/bin/ortop` |
| `newsboat` | built from source → `/usr/local/bin/newsboat` |
| fresh-editor | snap (classic) — used by HEY Journal as `$EDITOR` |
| duckstation | snap `duckstation-gpl` |
| firefox, thunderbird, bottom | snaps |
| crystal-dock | apt (Ubuntu universe) |
| claude-desktop | apt repo `pkg.claude-desktop-debian.dev` |
| rustdesk | latest `.deb` from GitHub releases |

Wrapper scripts `~/.local/bin/hey-journal` and `~/.local/bin/ortop-gui` are
recreated too.

Override the build/clone location with `BUILD_DIR=/path ./setup-kde.sh`
(default `~/src`).

## What it deliberately does NOT do

No keys, logins, or config secrets. After running, set up yourself:

- `~/.config/ortop/env` — OpenRouter API keys (sourced by `ortop-gui`)
- HEY login — run `hey` and sign in
- `~/.config/newsboat/urls` — FreshRSS endpoint + credentials

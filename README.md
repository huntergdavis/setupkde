# setupkde


Rebuilds my KDE app environment on a fresh Kubuntu machine: installs the
programs and recreates the KDE menu icons.

```bash
./setup-kde.sh
```

Safe to re-run — every step is idempotent.

## What it does

**Menu icons** (`~/.local/share/applications/`): HEY, HEY Journal, Newsboat,
ortop, Media Editor.

**Programs:**

| Program | Source |
|---|---|
| `hey` | built from `basecamp/hey-cli` → `/usr/local/bin/hey` |
| `ortop` | built from `huntergdavis/openrouter-tui` → `~/.local/bin/ortop` |
| `newsboat` | built from source → `/usr/local/bin/newsboat` |
| Media Editor | cloned from `huntergdavis/media` (SSH) → `~/workspace/media` |
| fresh-editor | snap (classic) — also set as the system-wide default editor |
| duckstation | snap `duckstation-gpl` |
| firefox, thunderbird, bottom | snaps |
| crystal-dock | apt (Ubuntu universe) |
| claude-desktop | apt repo `pkg.claude-desktop-debian.dev` |
| rustdesk | latest `.deb` from GitHub releases |

**Default editor:** fresh-editor is made the system-wide editor (`EDITOR`,
`VISUAL`, and the `editor` alternative). Because fresh-editor is a snap that
dispatches on its invocation name, a wrapper at `/usr/local/bin/fresh` re-execs
it under the right name so `git`, `crontab`, etc. work. Effective next login.

Wrapper scripts `~/.local/bin/hey-journal` and `~/.local/bin/ortop-gui` are
recreated too.

Override locations with `BUILD_DIR=/path` (upstream builds, default `~/src`)
or `WORKSPACE_DIR=/path` (personal repos, default `~/workspace`).

## What it deliberately does NOT do

No keys, logins, or config secrets. After running, set up yourself:

- `~/.config/ortop/env` — OpenRouter API keys (sourced by `ortop-gui`)
- HEY login — run `hey` and sign in
- `~/.config/newsboat/urls` — FreshRSS endpoint + credentials
- GitHub SSH key — required to clone the private `huntergdavis/media` repo

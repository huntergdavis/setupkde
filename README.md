# setupkde


Rebuilds my KDE app environment on a fresh Kubuntu machine: installs the
programs and recreates the KDE menu icons.

```bash
./setup-kde.sh
```

Safe to re-run — every step is idempotent.

## What it does

**Menu icons** (`~/.local/share/applications/`): HEY, HEY Journal, Newsboat,
ortop, Media Editor, Dunking Bird, qBittorrent TUI, Motion Cues.

**Programs:** every binary lives in **`/usr/local/bin`** (the one binary
location). Built artifacts stay in their repo and are symlinked in, so a
rebuild needs no reinstall. Repos split by ownership: third-party builds go to
`~/src`, your own (huntergdavis) projects to `~/workspace`.

| Program | Source |
|---|---|
| `hey` | built from `basecamp/hey-cli` (`~/src`) → symlink `/usr/local/bin/hey` |
| `ortop` | built from `huntergdavis/openrouter-tui` (`~/workspace/ortop`) → symlink `/usr/local/bin/ortop` |
| `qbt-tui` | built from `nickvanw/qbittorrent-tui` (`~/src`) → symlink `/usr/local/bin/qbt-tui` |
| `newsboat` | built from source (`~/src`) → `make install` to `/usr/local/bin/newsboat` |
| Media Editor | cloned from `huntergdavis/media` (SSH) → `~/workspace/media` |
| Dunking Bird | cloned from `huntergdavis/dunkingbird` → `~/workspace/dunkingbird` |
| Motion Cues | cloned from `monperrus/motion-cues` (`~/src`) → venv install, symlink `/usr/local/bin/motion-cues` |
| fresh-editor | snap (classic) — also set as the system-wide default editor |
| duckstation | snap `duckstation-gpl` |
| firefox, thunderbird, bottom | snaps |
| claude-desktop | apt repo `pkg.claude-desktop-debian.dev` |
| rustdesk | latest `.deb` from GitHub releases |

**Default editor:** fresh-editor is made the system-wide editor (`EDITOR`,
`VISUAL`, and the `editor` alternative). Because fresh-editor is a snap that
dispatches on its invocation name, a wrapper at `/usr/local/bin/fresh` re-execs
it under the right name so `git`, `crontab`, etc. work. Effective next login.

**Dunking Bird** types into the active window via `ydotool`, so the installer
also pulls in `ydotool`/`xclip`/`xdotool`, adds you to the `input` group
(re-login required), and on KDE Wayland installs `kdotool` for window
targeting. Its menu icon runs the repo's own `run_dunking_bird.sh`, which
starts the ydotool daemon and the TUI.

**Motion Cues** is a PyQt6 system-tray GUI (a Linux port of Apple's Vehicle
Motion Cues) that drifts peripheral dots to reduce motion sickness. It installs
into its own venv under `~/src/motion-cues`. It drives X11 ShapeBounding/
ShapeInput directly, so its `motion-cues-gui` wrapper forces Qt's `xcb` platform
(real X11 client via XWayland on KDE Wayland; a no-op on a true X11 session).

Launcher wrappers `hey-journal`, `ortop-gui`, `qbt-tui-gui`, and `motion-cues-gui`
are written to `/usr/local/bin` too (the menu icons call these). Re-running the script also
cleans up the old layout: any leftover binaries in `~/.local/bin` and the old
`~/src/openrouter-tui` clone are removed.

Override locations with `BUILD_DIR=/path` (upstream builds, default `~/src`)
or `WORKSPACE_DIR=/path` (personal repos, default `~/workspace`).

## What it deliberately does NOT do

No keys, logins, or config secrets. After running, set up yourself:

- `~/.config/ortop/env` — OpenRouter API keys (sourced by `ortop-gui`)
- HEY login — run `hey` and sign in
- `~/.config/newsboat/urls` — FreshRSS endpoint + credentials
- GitHub SSH key — required to clone the private `huntergdavis/media` repo

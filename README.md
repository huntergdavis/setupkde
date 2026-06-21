# setupkde

Rebuilds my KDE app environment — the TUI apps and their KDE menu icons — on a
fresh machine. **One codebase, two platforms:**

- **Kubuntu laptop** (x86_64, root/sudo, snap, systemd)
- **Termux on Android** (aarch64, unprivileged, `$PREFIX/bin`, no snap/systemd)

## Quick start

**Kubuntu laptop:**

```bash
./setup-kde.sh
```

**Termux (full fresh-device bootstrap — Claude Code, KDE+GPU, then apps):**

```bash
git clone https://github.com/huntergdavis/setupkde.git
cd setupkde
bash bootstrap.sh        # runs the three phases below, unattended
```

On Termux you can also run just the apps phase on its own with
`bash setup-kde.sh` (it assumes KDE/konsole are already installed).

Everything is idempotent — safe to re-run.

## How the two platforms share one script

`setup-kde.sh` holds all the shared logic (source builds, launcher wrappers, the
KDE `.desktop` menu icons, legacy cleanup, orchestration). Everything that
genuinely differs between the two worlds lives in a **platform profile**:

```
setup-kde.sh              # universal orchestrator + shared steps
lib/
  platform-linux.sh       # Kubuntu: sudo, /usr/local/bin, apt+snap, rustup,
                          #   /etc/environment editor, systemd NFS automounts
  platform-termux.sh      # Termux: no sudo, $PREFIX/bin, pkg only, system rust,
                          #   ~/.bashrc editor, no snap/systemd
```

The profile is **auto-detected** (Termux is recognised by `$TERMUX_VERSION` /
`/data/data/com.termux`) and sourced before anything runs. Force one with
`PLATFORM=linux` or `PLATFORM=termux`. Each profile defines a small set of vars
(`BIN_DIR`, `SUDO`, `BASH_SHEBANG`, `FRESH_PATH`) and the `p_*` hook functions the
orchestrator calls where the platforms diverge (build deps, newsboat, fresh-editor,
default-editor mechanism, jellyterm install, dunkingbird input backend, extra apps,
VPN, mounts, closing notes).

## What it installs

Every binary lives in the one binary location — **`/usr/local/bin`** on Kubuntu,
**`$PREFIX/bin`** on Termux. Built artifacts stay in their repo and are symlinked
in, so a rebuild needs no reinstall. Repos split by ownership: third-party builds
to `~/src`, your own (huntergdavis) projects to `~/workspace`. Override with
`BUILD_DIR=/path` / `WORKSPACE_DIR=/path`.

**Menu icons** (`~/.local/share/applications/`): HEY, HEY Journal, Newsboat,
ortop, Media Editor, Dunking Bird, JellyTerm, qBittorrent TUI (+ Motion Cues on
Kubuntu). Each optional icon self-gates on whether its repo/binary actually
installed, so Linux-only entries simply don't appear on Termux.

| Program | Kubuntu | Termux |
|---|---|---|
| `hey` | built from `basecamp/hey-cli` | same (source build) |
| `ortop` | built from `huntergdavis/openrouter-tui` | same (source build) |
| `qbt-tui` | built from `nickvanw/qbittorrent-tui` | same (source build) |
| `newsboat` | built from source | Termux **package** (source build fails on Android) |
| Media Editor | `huntergdavis/media` (SSH) → venv | same |
| Dunking Bird | `huntergdavis/dunkingbird` → venv; `input` group for ydotool | same, but ydotool can't run without root → auto-type inert |
| JellyTerm | `huntergdavis/jellyterm`, installer unattended (`mpv-terminal`) | same, via `bash` + `--skip-system-packages` + shebang fixups |
| fresh-editor | snap (classic) + system-wide default editor | Termux **package** + default editor via `~/.bashrc` |
| bottom (`btm`) | snap | built from source (`--no-default-features`) |
| Motion Cues | `monperrus/motion-cues` → venv, xcb wrapper | — (no PyQt6 wheel) |
| duckstation, firefox, thunderbird | snaps | — |
| claude-desktop | apt repo `pkg.claude-desktop-debian.dev` | — (use the Termux Claude bootstrap) |
| rustdesk | latest `.deb` from GitHub releases | — |
| Tailscale | `tailscale.com/install.sh` | not packaged — use the official Android app |
| NFS mounts (monkeydluffy) | `/etc/fstab` + systemd automount | — (no systemd) |

Launcher wrappers `hey-journal`, `ortop-gui`, `qbt-tui-gui`, and `jellyterm` are
written into the binary dir too (the menu icons call these). Re-running also
cleans up the old layout: leftover binaries in `~/.local/bin` and the old
`~/src/openrouter-tui` clone are removed.

## Termux bootstrap (`bootstrap.sh`) phases

Skip a phase with `SKIP_CLAUDE=1` / `SKIP_KDE=1` / `SKIP_APPS=1`. Each phase is
tolerant (warn-and-continue) and re-runnable.

| Phase | Script | What it installs |
|---|---|---|
| 1. Claude Code | `stages/10-claude.sh` | Official linux-arm64 `claude` binary patched via **glibc-runner** to run on Android/bionic, with a self-updating wrapper. (from [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android)) |
| 2. KDE + GPU | `stages/20-kde.sh` | **KDE Plasma 6** + **Adreno Turnip/Zink** GPU acceleration on Termux-X11. Origin [techjarves/Linux-on-Samsung](https://github.com/techjarves/Linux-on-Samsung) (MIT). Ships `~/start-kde` / `~/stop-kde`. |
| 3. Apps + icons | `setup-kde.sh` | the table above (Termux column). |

**Termux prerequisites** (install yourself first): the **Termux**, **Termux:X11**,
and **Termux:API** Android apps, then `pkg install git`. The KDE stage needs a
Snapdragon/Adreno GPU (built/tested on a Galaxy Tab S8, Adreno 730).

## What it deliberately does NOT do

No keys, logins, or config secrets. After running, set up yourself:

- `~/.config/ortop/env` — OpenRouter API keys (sourced by `ortop-gui`)
- `~/.config/qbt-tui/env` — qBittorrent WebUI creds (a stub is created)
- HEY login — run `hey` and sign in
- Jellyfin login — run `jellyterm` and sign in
- `~/.config/newsboat/urls` — FreshRSS endpoint + credentials
- GitHub SSH key — required to clone the private `huntergdavis/media` repo
- **Termux only:** `claude` then `/login`; `termux-setup-storage`; open the
  Termux:X11 app then `~/start-kde`

# setupkde (termux branch)

Rebuilds my entire **Termux** environment on a fresh Android device — Claude Code,
a GPU-accelerated KDE Plasma 6 desktop, and all my TUI apps + menu icons — with one
command.

> This is the Termux/Android (aarch64) port. The original Kubuntu version lives on
> `main`. Several things are fundamentally different here: no root/sudo, no snap, no
> systemd, `$PREFIX/bin` instead of `/usr/local/bin`, bionic libc.

## Prerequisites (install these yourself first)

1. **Termux** (F-Droid / GitHub build).
2. **Termux:X11** app (for the KDE desktop display).
3. **Termux:API** app (device features).
4. `pkg install git` — to clone this repo.

## Bootstrap

```bash
git clone https://github.com/huntergdavis/setupkde.git
cd setupkde
bash bootstrap.sh
```

Runs **unattended** in three phases, each tolerant (warn-and-continue) and re-runnable.
Skip a phase with `SKIP_CLAUDE=1` / `SKIP_KDE=1` / `SKIP_APPS=1`.

| Phase | Script | What it installs |
|---|---|---|
| 1. Claude Code | `stages/10-claude.sh` | Official linux-arm64 `claude` binary patched via **glibc-runner** to run on Android/bionic, with a self-updating wrapper. (from [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android)) |
| 2. KDE + GPU | `stages/20-kde.sh` | **KDE Plasma 6** + **Adreno Turnip/Zink** GPU acceleration on Termux-X11. Authored from a hard-won working blueprint; origin [techjarves/Linux-on-Samsung](https://github.com/techjarves/Linux-on-Samsung) (MIT). Ships `~/start-kde` / `~/stop-kde`. |
| 3. Apps + icons | `setup-kde.sh` | HEY, HEY Journal, Newsboat, ortop, qBittorrent TUI, JellyTerm, Media Editor, Dunking Bird, fresh-editor, bottom + KDE menu entries. |

After it finishes, the bootstrap prints the short list of inherently-manual steps below.

## Phase 2 — why KDE needs a custom installer

Stock desktop installers leave you with a broken or software-rendered desktop on
unrooted Android. `stages/20-kde.sh` encodes the fixes that make it actually work:

- **Turnip Adreno** Vulkan ICD (`mesa-vulkan-icd-freedreno`) — real GPU, not swrast.
- **`plasma-desktop`** explicitly (plasma-workspace alone = empty desktop).
- **`libprocesscore.so.10` ABI shim** (version skew vs libksysguard `.so.11`).
- **Compositing OFF** in `kwinrc` — no DRI3 / no `/dev/dri` on unrooted Android, so
  kwin's compositor crash-loops; apps still render on the GPU as GLX clients.
- **kicker + icontasks** panel layout (Kickoff crash-loops this build).
- HiDPI scaling, GLX-not-EGL, app-menu prefix, kscreen autoload off.

GPU env + D-Bus/X11/PulseAudio bring-up live in `~/start-kde`. The stage runs a
verification pass (Turnip present, plasma shell present, shim present, binaries
present) and **fails loudly** rather than hiding a software-render fallback.

Targets Snapdragon/Adreno (built/tested on a Galaxy Tab S8, Adreno 730). Exynos/Mali
would need a swrast fallback.

## Phase 3 — apps (`setup-kde.sh`)

Binaries live in `$PREFIX/bin` (no sudo, no `/usr/local/bin`). Built artifacts stay in
their repo and are symlinked in. Termux specifics vs. the Kubuntu build:

- **Newsboat** and **fresh-editor** install from Termux **packages** (source builds
  fail on Android: newsboat's vendored gettext, fresh's android-hostile crates).
- **bottom** builds from source with `--no-default-features` (skips the Android-
  incompatible battery dep). CPU monitoring can't work (Android blocks `/proc/stat`).
- **fresh-editor** is the default `EDITOR`/`VISUAL` (set in `~/.bashrc`).
- **Dunking Bird** auto-type needs `ydotool` (unavailable without root) — installed but
  the auto-type feature is inert.
- Dropped: Motion Cues (no PyQt6 wheel), and the Kubuntu-only firefox/thunderbird/
  duckstation/claude-desktop/rustdesk snaps + systemd NFS mounts.
- **Tailscale** isn't packaged for Termux — use the official Android app.

`setup-kde.sh` can also be run on its own (it assumes phase 2 already installed KDE/konsole).

## Manual steps (printed at the end of bootstrap)

No keys, logins, or secrets are stored in the repo:

- **Claude:** `claude` then `/login`; `termux-setup-storage`
- **KDE:** open the Termux:X11 app, then `~/start-kde` (stop: `~/stop-kde`). Log: `~/kde.log`
- `~/.config/ortop/env` — OpenRouter API keys
- `~/.config/qbt-tui/env` — qBittorrent WebUI creds
- `~/.config/newsboat/urls` — FreshRSS endpoint + credentials
- `hey` / `jellyterm` — run and sign in
- **GitHub SSH key** — required to clone the private `huntergdavis/media` repo

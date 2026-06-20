#!/data/data/com.termux/files/usr/bin/bash
#
# setup-kde.sh — rebuild Hunter's KDE app environment (TERMUX edition).
#
# This is the Termux/Android port of the original Kubuntu script. Termux is an
# unprivileged Android app, so the environment is fundamentally different:
#   - NO root / NO sudo            -> everything installs into $PREFIX (user-owned)
#   - NO /usr/local/bin            -> the one binary dir is $PREFIX/bin
#   - NO snap / snapd              -> snap apps come from pkg, source, or dropped
#   - NO systemd                   -> the NFS automount step is gone
#   - aarch64 (bionic libc)        -> glibc/x86_64 .deb apps can't run here
#   - KDE Plasma 6 + konsole are already installed (and version-pinned), so we
#     never reinstall them — installing only named build deps avoids disturbing
#     the pinned kf6/qt6 libraries.
#
# Installs the programs and creates the KDE menu icons for:
#   HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
#   JellyTerm, qBittorrent TUI, plus fresh-editor + bottom.
#
# It also makes fresh-editor the default editor (EDITOR/VISUAL) via ~/.bashrc.
#
# Dropped vs. the Kubuntu version (no Termux/aarch64 path — see chat history):
#   firefox (already installed via pkg), thunderbird (not needed),
#   duckstation, claude-desktop, rustdesk, and the systemd NFS mounts.
#
# This script does NOT copy keys, tokens, logins, or config secrets.
# After running it you still need to provide, yourself:
#   - ~/.config/ortop/env        (OpenRouter API keys; sourced by ortop-gui)
#   - ~/.config/qbt-tui/env      (qBittorrent WebUI creds; sourced by qbt-tui-gui)
#   - HEY login / `hey` config
#   - JellyTerm / Jellyfin login
#   - newsboat ~/.config/newsboat/urls (FreshRSS aggregator + creds)
#
# The Media Editor repo is private; cloning it needs your SSH key set up
# with GitHub (the clone URL is git@github.com:huntergdavis/media.git).
#
# Safe to re-run: every step checks whether the work is already done.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # this repo (ships the qbt icon)
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"        # Termux prefix (user-owned)
# Two repo roots, split by ownership (not by build system):
#   BUILD_DIR     — third-party upstream repos (hey-cli, qbittorrent-tui, fresh)
#   WORKSPACE_DIR — your own (huntergdavis) projects (ortop, media, dunkingbird, jellyterm)
BUILD_DIR="${BUILD_DIR:-$HOME/src}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
# The one place binaries live. On Termux this is $PREFIX/bin (user-writable, no
# sudo). Built artifacts stay in their repo and are symlinked in here, so a
# rebuild is picked up with no stale copy.
BIN_DIR="$PREFIX/bin"
APPS_DIR="$HOME/.local/share/applications"   # XDG per-user menu entries (not binaries)
CARGO_ROOT="$BUILD_DIR/cargo"                # where `cargo install` lands (then symlinked)

HEY_REPO="https://github.com/basecamp/hey-cli.git"
ORTOP_REPO="https://github.com/huntergdavis/openrouter-tui.git"
ORTOP_DIR="$WORKSPACE_DIR/ortop"   # your project, lives alongside media/dunkingbird
QBT_TUI_REPO="https://github.com/nickvanw/qbittorrent-tui.git"   # public
MEDIA_REPO="git@github.com:huntergdavis/media.git"   # private; needs your GitHub SSH key
MEDIA_DIR="$WORKSPACE_DIR/media"
DUNKING_REPO="https://github.com/huntergdavis/dunkingbird.git"   # public
DUNKING_DIR="$WORKSPACE_DIR/dunkingbird"
JELLYTERM_REPO="https://github.com/huntergdavis/jellyterm.git"   # public
JELLYTERM_DIR="$WORKSPACE_DIR/jellyterm"

# Path of the fresh-editor binary (installed by the fresh-editor Termux package).
FRESH_BIN="$BIN_DIR/fresh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Symlink a built binary into BIN_DIR. -f replaces a prior copy/symlink; -n
# avoids descending into an existing symlinked dir. No sudo: $PREFIX/bin is ours.
link_bin() {
  local src="$1" name="${2:-$(basename "$1")}"
  ln -sfn "$src" "$BIN_DIR/$name"
}

# Clone if missing, otherwise pull latest. Echoes the repo dir.
clone_or_update() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    info "updating $(basename "$dir")"
    git -C "$dir" pull --ff-only --quiet || warn "could not fast-forward $dir; using current checkout"
  else
    info "cloning $(basename "$dir")"
    git clone --depth 1 "$url" "$dir"
  fi
}

mkdir -p "$BUILD_DIR" "$WORKSPACE_DIR" "$APPS_DIR"   # BIN_DIR ($PREFIX/bin) already exists

# ---------------------------------------------------------------------------
# 1. Build dependencies + toolchains (Termux pkg/apt, no sudo)
# ---------------------------------------------------------------------------
# We use `apt-get install` (NOT `pkg upgrade`) so we only pull the named build
# deps and never bump the version-pinned KDE (kf6/qt6) libraries. rust+cargo and
# clang are already installed; golang/go is not, so the toolchain list adds it.
install_build_deps() {
  say "Installing build toolchains and dependencies (Termux pkg/apt)"
  apt-get update -y 2>/dev/null || apt-get update || warn "apt-get update reported an error; continuing"

  # Package-name notes for Termux (differ from Ubuntu):
  #   golang            (was golang-go)   — provides `go`
  #   rust              already installed — provides cargo/rustc (no rustup on Termux)
  #   stfl              (was libstfl-dev) — newsboat TUI lib; headers bundled
  #   libsqlite/libcurl/ncurses/libxml2/json-c/dbus — dev headers ship in the
  #                     main package (Termux has no -dev split)
  #   xdotool/xclip     from the (already-enabled) x11-repo
  #   konsole/snapd     omitted: konsole is pre-installed & pinned; no snap on Termux
  #   ydotool           NOT packaged for Termux (see Dunking Bird note below)
  apt-get install -y \
    build-essential clang make binutils pkg-config git curl \
    golang rust gettext asciidoctor ruby \
    stfl libsqlite libcurl ncurses libxml2 dbus json-c \
    python python-pip mpv \
    xdotool xclip \
    || warn "some build deps failed to install; later source builds may fail"

  have go    || warn "go not on PATH after install — hey/ortop/qbt-tui builds will fail"
  have cargo || warn "cargo not on PATH — fresh-editor/bottom builds will fail"
}

# ---------------------------------------------------------------------------
# 2. Source builds: hey, ortop, qbt-tui (newsboat is a Termux package)
# ---------------------------------------------------------------------------
build_hey() {
  say "Building HEY (hey-cli) -> $BIN_DIR/hey"
  if have hey; then info "hey already on PATH; rebuilding to update"; fi
  local dir="$BUILD_DIR/hey-cli"
  clone_or_update "$HEY_REPO" "$dir"
  ( cd "$dir" && make build )           # outputs bin/hey
  link_bin "$dir/bin/hey" hey
  info "installed $("$BIN_DIR/hey" --version 2>/dev/null | head -1 || echo hey)"
}

build_ortop() {
  say "Building ortop (openrouter-tui) -> $BIN_DIR/ortop"
  local dir="$ORTOP_DIR"
  clone_or_update "$ORTOP_REPO" "$dir"
  ( cd "$dir" && go build -o ortop ./... )
  link_bin "$dir/ortop" ortop
}

# qBittorrent TUI: a Bubble Tea terminal client for the qBittorrent WebUI API.
# Connects to a remote instance, so no torrent daemon is installed here — just
# the client. The menu icon launches qbt-tui-gui, which bakes in the WebUI URL
# and sources credentials from ~/.config/qbt-tui/env (see install_wrappers).
build_qbt_tui() {
  say "Building qBittorrent TUI (qbt-tui) -> $BIN_DIR/qbt-tui"
  local dir="$BUILD_DIR/qbittorrent-tui"
  clone_or_update "$QBT_TUI_REPO" "$dir"
  ( cd "$dir" && go build -o qbt-tui ./cmd/qbt-tui )
  link_bin "$dir/qbt-tui" qbt-tui
}

build_newsboat() {
  say "Installing Newsboat -> $BIN_DIR/newsboat"
  # Unlike the Kubuntu build, we do NOT build newsboat from source on Termux: its
  # gettext-sys crate can't find a usable system libintl and falls back to an
  # autotools build of vendored gettext that is glacially slow and ultimately
  # fails on Android. Termux packages newsboat (2.43+) directly, so just install
  # that — it's the same upstream, already cross-compiled for aarch64.
  if have newsboat; then
    info "newsboat already installed ($(newsboat --version 2>/dev/null | head -1))"
  elif apt-get install -y newsboat; then
    info "newsboat installed from the Termux package"
  else
    warn "could not install the newsboat package; skipping"
  fi
}

# Media Editor: a personal Textual TUI for editing markdown collection tables.
# Cloned to ~/workspace (not ~/src) because the markdown files it edits live
# in the repo. Self-bootstraps a venv via run-tui.sh; we pre-warm it here.
install_media() {
  say "Installing Media Editor (media) -> $MEDIA_DIR"
  if [ -d "$MEDIA_DIR/.git" ]; then
    info "updating media"
    git -C "$MEDIA_DIR" pull --ff-only --quiet || warn "could not fast-forward $MEDIA_DIR; using current checkout"
  else
    info "cloning media (needs your GitHub SSH key)"
    # Pre-trust github.com's host key so the SSH clone doesn't prompt (or fail
    # non-interactively) on a fresh machine. Idempotent: only add if missing.
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/known_hosts"
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
      ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null \
        || warn "could not pre-fetch github.com host key (ssh-keyscan failed)"
    fi
    if ! git clone "$MEDIA_REPO" "$MEDIA_DIR"; then
      warn "could not clone $MEDIA_REPO — set up your GitHub SSH key, then re-run. Skipping Media Editor."
      return 0
    fi
  fi
  chmod 0755 "$MEDIA_DIR/run-tui.sh" 2>/dev/null || true

  # Pre-build the Textual venv so the first menu launch is instant.
  if [ ! -d "$MEDIA_DIR/media_editor_env" ]; then
    info "creating media_editor_env venv"
    if python3 -m venv "$MEDIA_DIR/media_editor_env"; then
      "$MEDIA_DIR/media_editor_env/bin/pip" install --quiet --upgrade pip
      "$MEDIA_DIR/media_editor_env/bin/pip" install --quiet -r "$MEDIA_DIR/requirements.txt"
    else
      rm -rf "$MEDIA_DIR/media_editor_env"
      warn "venv creation failed; run-tui.sh will retry on first launch"
    fi
  fi
}

# Dunking Bird: a personal Textual/curses TUI that types a prompt into the
# active window every X seconds (drives input via ydotool). Public repo.
#
# TERMUX NOTE: ydotool is NOT packaged for Termux, and its uinput backend needs
# root/kernel access an unprivileged Android app doesn't have — so the auto-type
# feature won't function natively here. We still install the TUI + xdotool/xclip
# (which the launcher's prereq checks look for) and warn about ydotool.
install_dunkingbird() {
  say "Installing Dunking Bird (dunkingbird) -> $DUNKING_DIR"
  clone_or_update "$DUNKING_REPO" "$DUNKING_DIR"
  chmod 0755 "$DUNKING_DIR/run_dunking_bird.sh" 2>/dev/null || true

  # Pre-build the venv the launcher activates if present (requirements.txt has
  # no hard pip deps, but this keeps the launcher's venv path working).
  if [ ! -d "$DUNKING_DIR/venv" ]; then
    info "creating venv"
    if python3 -m venv "$DUNKING_DIR/venv"; then
      "$DUNKING_DIR/venv/bin/pip" install --quiet --upgrade pip
      "$DUNKING_DIR/venv/bin/pip" install --quiet -r "$DUNKING_DIR/requirements.txt" || true
    else
      rm -rf "$DUNKING_DIR/venv"
      warn "venv creation failed; the launcher will run without it"
    fi
  fi

  have ydotool || warn "ydotool is unavailable on Termux (no uinput without root) — Dunking Bird's auto-type will not work"

  # kdotool: window capture/focus backend used on KDE Wayland (best-effort).
  # Build it into a cargo root under BUILD_DIR and symlink the binary into
  # BIN_DIR like everything else. Skipped unless this is a Wayland session.
  if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && ! have kdotool; then
    info "installing kdotool (KDE Wayland window backend)"
    if cargo install --git https://github.com/jinliu/kdotool --root "$CARGO_ROOT"; then
      link_bin "$CARGO_ROOT/bin/kdotool" kdotool
    else
      warn "could not install kdotool; window targeting may be limited on KDE Wayland"
    fi
  fi
}

# JellyTerm: a terminal Jellyfin browser/player. Its own installer manages the
# Python venv; mpv (the player) is already installed in the build-deps step.
#
# TERMUX NOTES:
#   - The repo's scripts use `#!/usr/bin/env bash`, but Termux has no /usr/bin/env
#     (it's $PREFIX/bin/env), so a direct `./scripts/install.sh` fails with
#     "bad interpreter". termux-fix-shebang rewrites them to the $PREFIX path;
#     we also invoke the installer through `bash` so it runs regardless.
#   - We pass --skip-system-packages: the installer's OS-package path uses sudo
#     (absent on Termux) and we already have mpv, so the venv is all we need.
install_jellyterm() {
  say "Installing JellyTerm (jellyterm) -> $JELLYTERM_DIR"
  clone_or_update "$JELLYTERM_REPO" "$JELLYTERM_DIR"
  chmod 0755 "$JELLYTERM_DIR/scripts/install.sh" "$JELLYTERM_DIR/scripts/run.sh" 2>/dev/null || true
  # Rewrite the upstream `#!/usr/bin/env bash` shebangs for Termux so run.sh
  # (invoked later by the PATH wrapper and the menu icon) execs directly.
  have termux-fix-shebang && termux-fix-shebang "$JELLYTERM_DIR/scripts/"*.sh 2>/dev/null || true

  if [ -f "$JELLYTERM_DIR/scripts/install.sh" ]; then
    ( cd "$JELLYTERM_DIR" && bash ./scripts/install.sh --yes --skip-system-packages --player mpv-terminal ) \
      || warn "JellyTerm installer reported an error; check it manually"
  else
    warn "skipping JellyTerm install (installer not present at $JELLYTERM_DIR/scripts/install.sh)"
  fi
}

# ---------------------------------------------------------------------------
# 3. Replacements for the old snaps: fresh-editor, bottom
# ---------------------------------------------------------------------------
# Snap doesn't exist on Termux (no systemd, no root, squashfs can't be mounted).
# fresh-editor is packaged for Termux, so we install that. bottom isn't, so it's
# built from source. firefox (already installed via pkg), thunderbird, and
# duckstation are intentionally not handled here.
#
# fresh-editor: do NOT build from source on Termux. The upstream (sinelaw/fresh)
# pulls several deps that exclude target_os="android" (trash, arboard) plus an
# embedded JS runtime (rquickjs-sys needs bindgen for aarch64), and the release
# profile's fat LTO OOMs rustc on a phone. Termux packages fresh-editor at the
# same version (0.4.1), already cross-compiled for aarch64 — just install it.
build_fresh_editor() {
  say "Installing fresh-editor -> $FRESH_BIN"
  if have fresh; then
    info "fresh already installed ($(fresh --version 2>/dev/null | head -1))"
  elif apt-get install -y fresh-editor; then
    info "fresh-editor installed from the Termux package"
  else
    warn "could not install the fresh-editor package; EDITOR will fall back to vim/nano"
  fi
}

build_bottom() {
  say "Building bottom (btm) -> $BIN_DIR/btm"
  # `bottom` is the crate; its binary is `btm`. Build into the shared cargo root
  # and symlink like everything else.
  #
  # --no-default-features is REQUIRED on Termux: bottom's default "deploy" feature
  # pulls in `battery` -> starship-battery, which has no Android target and fails
  # with `compile_error!("Support for this target OS is not implemented yet!")`.
  # Dropping it also drops the (irrelevant here) nvidia/zfs features. btm still
  # builds and runs fine; only the battery widget is gone.
  if cargo install bottom --no-default-features --root "$CARGO_ROOT"; then
    link_bin "$CARGO_ROOT/bin/btm" btm
    info "bottom -> $BIN_DIR/btm"
  else
    warn "cargo install bottom failed; skipping"
  fi
}

# ---------------------------------------------------------------------------
# 3b. Make fresh-editor the default editor
# ---------------------------------------------------------------------------
# On Termux there's no snap argv[0] dispatch problem (fresh is a real binary) and
# no /etc/environment / pam_env. We set EDITOR/VISUAL in ~/.bashrc (sourced by
# interactive shells, including the konsole sessions the menu icons spawn).
# Idempotent: a marked block is rewritten in place. Falls back to vim/nano if
# the fresh build didn't produce a binary.
set_default_editor() {
  say "Making fresh-editor the default editor (via ~/.bashrc)"

  local editor="$FRESH_BIN"
  if [ ! -x "$FRESH_BIN" ]; then
    editor="$(command -v vim || command -v nano || echo "$FRESH_BIN")"
    warn "fresh not built; defaulting EDITOR to $editor"
  fi

  local rc="$HOME/.bashrc"
  touch "$rc"
  # Strip any previous block we wrote, then append a fresh one.
  if grep -q '# >>> setup-kde editor >>>' "$rc"; then
    sed -i '/# >>> setup-kde editor >>>/,/# <<< setup-kde editor <<</d' "$rc"
  fi
  {
    echo '# >>> setup-kde editor >>>'
    printf 'export EDITOR="%s"\n' "$editor"
    printf 'export VISUAL="%s"\n' "$editor"
    echo '# <<< setup-kde editor <<<'
  } >> "$rc"
  info "EDITOR/VISUAL -> $editor (takes effect in new shells)"
}

# ---------------------------------------------------------------------------
# 4. Tailscale
# ---------------------------------------------------------------------------
# NOTE: Tailscale is NOT in the Termux repos (checked main, x11, glibc, TUR), and
# there's no systemd to run tailscaled as a service. We attempt the package in
# case a repo adds it later; otherwise we point at the official Android app.
install_tailscale() {
  say "Installing Tailscale"
  if have tailscale; then info "tailscale already installed"; return; fi
  if apt-get install -y tailscale 2>/dev/null; then
    info "tailscale installed — run it manually:  tailscaled &   then:  tailscale up"
  else
    warn "tailscale is not packaged for Termux. Use the official Tailscale Android app instead:"
    warn "  https://play.google.com/store/apps/details?id=com.tailscale.ipn"
  fi
}

# ---------------------------------------------------------------------------
# 5. Wrapper scripts (recreated verbatim, Termux paths)
# ---------------------------------------------------------------------------
install_wrappers() {
  say "Installing launcher wrapper scripts -> $BIN_DIR"

  tee "$BIN_DIR/hey-journal" >/dev/null <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Launcher wrapper for the "HEY Journal" KDE menu entry.
# \`hey journal write\` opens \$EDITOR; GUI launches don't always have it set,
# so guarantee fresh-editor is used (falls back to any EDITOR already set).
export EDITOR="\${EDITOR:-$FRESH_BIN}"
export VISUAL="\${VISUAL:-\$EDITOR}"
exec hey journal write "\$@"
EOF

  tee "$BIN_DIR/ortop-gui" >/dev/null <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Launcher wrapper for the ortop KDE menu entry.
# GUI launches don't source ~/.bashrc, so load the OpenRouter keys explicitly.
. "$HOME/.config/ortop/env" 2>/dev/null
exec ortop "$@"
EOF

  tee "$BIN_DIR/qbt-tui-gui" >/dev/null <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Launcher wrapper for the qbt-tui KDE menu entry.
# GUI launches don't source ~/.bashrc, so set the (non-secret) server URL here
# and load the qBittorrent WebUI credentials from a separate env file.
export QBT_SERVER_URL="${QBT_SERVER_URL:-http://192.168.0.238:9999/}"
. "$HOME/.config/qbt-tui/env" 2>/dev/null
exec qbt-tui "$@"
EOF

  if [ -f "$JELLYTERM_DIR/scripts/run.sh" ]; then
    tee "$BIN_DIR/jellyterm" >/dev/null <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Launcher wrapper for JellyTerm. Keep this as a wrapper, not a symlink to
# scripts/run.sh, so the project root stays stable when invoked from PATH.
exec "$JELLYTERM_DIR/scripts/run.sh" "\$@"
EOF
    chmod 0755 "$BIN_DIR/jellyterm"
  else
    warn "skipping JellyTerm PATH wrapper (runner not present at $JELLYTERM_DIR/scripts/run.sh)"
  fi

  chmod 0755 "$BIN_DIR/hey-journal" "$BIN_DIR/ortop-gui" "$BIN_DIR/qbt-tui-gui"
  if [ ! -f "$HOME/.config/ortop/env" ]; then
    warn "ortop needs ~/.config/ortop/env with your OpenRouter keys (not created by this script)"
  fi

  # Seed a credentials stub for qbt-tui (URL is in the wrapper; creds are yours).
  mkdir -p "$HOME/.config/qbt-tui"
  if [ ! -f "$HOME/.config/qbt-tui/env" ]; then
    cat > "$HOME/.config/qbt-tui/env" <<'EOF'
# qBittorrent WebUI credentials for qbt-tui (sourced by qbt-tui-gui).
# Server URL is set by the wrapper; fill in EITHER username+password
# OR an api_key (qBittorrent 5.2.0+) below — not both.
export QBT_SERVER_USERNAME="admin"
export QBT_SERVER_PASSWORD=""
# export QBT_SERVER_API_KEY="qbt_xxxxxxxxxxxxxxxxxxxxxxxx"
EOF
    chmod 0600 "$HOME/.config/qbt-tui/env"
    warn "qbt-tui needs WebUI creds in ~/.config/qbt-tui/env (stub created; fill it in)"
  fi
}

# ---------------------------------------------------------------------------
# 6. KDE menu icons (.desktop entries)
# ---------------------------------------------------------------------------
install_desktop_entries() {
  say "Creating KDE menu icons -> $APPS_DIR"

  cat > "$APPS_DIR/hey.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=HEY
GenericName=HEY Email
Comment=HEY email client (terminal TUI)
Exec=konsole -p tabtitle=HEY -e hey
Icon=mail-client
Terminal=false
Categories=Network;Email;
Keywords=hey;email;mail;inbox;
StartupNotify=true
EOF

  cat > "$APPS_DIR/hey-journal.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=HEY Journal
GenericName=Journal Entry
Comment=Write today's HEY journal entry
Exec=konsole --hold -p tabtitle=HEY\\sJournal -e $BIN_DIR/hey-journal
Icon=accessories-text-editor
Terminal=false
Categories=Utility;TextEditor;
Keywords=hey;journal;diary;write;entry;
StartupNotify=true
EOF

  cat > "$APPS_DIR/newsboat.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Newsboat
GenericName=RSS Feed Reader
Comment=Read RSS feeds from your FreshRSS aggregator
Exec=konsole --separate -p tabtitle=Newsboat -e newsboat
Icon=application-rss+xml
Terminal=false
Categories=Network;News;Feed;
Keywords=RSS;Feed;News;Reader;FreshRSS;
StartupNotify=true
StartupWMClass=konsole
EOF

  cat > "$APPS_DIR/ortop.desktop" <<EOF
[Desktop Entry]
Categories=System;Monitor;ConsoleOnly;
Comment=Read-only terminal dashboard for your OpenRouter spend
Exec=konsole --hold -p tabtitle=ortop -e $BIN_DIR/ortop-gui
GenericName=OpenRouter Monitor
Icon=utilities-system-monitor
Keywords=openrouter;llm;monitor;dashboard;spend;
Name=ortop
NoDisplay=false
Path=
PrefersNonDefaultGPU=false
StartupNotify=true
Terminal=false
TerminalOptions=
Type=Application
Version=1.0
X-KDE-SubstituteUID=false
X-KDE-Username=
EOF

  cat > "$APPS_DIR/qbt-tui.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=qBittorrent TUI
GenericName=Torrent Manager
Comment=Terminal UI for the qBittorrent WebUI at 192.168.0.238:9999
Exec=konsole -p tabtitle=qBittorrent -e $BIN_DIR/qbt-tui-gui
Icon=$SCRIPT_DIR/qbittorrent.svg
Terminal=false
Categories=Network;P2P;FileTransfer;
Keywords=qbittorrent;torrent;bittorrent;download;tui;qbt;
StartupNotify=true
EOF

  chmod 0644 "$APPS_DIR"/{hey,hey-journal,newsboat,ortop,qbt-tui}.desktop

  # JellyTerm — launches through the $PREFIX/bin wrapper so it is also on PATH.
  if [ -f "$JELLYTERM_DIR/scripts/run.sh" ]; then
    cat > "$APPS_DIR/jellyterm.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=JellyTerm
GenericName=Jellyfin Terminal Client
Comment=Browse Jellyfin and play media from the terminal
Exec=konsole -p tabtitle=JellyTerm -e $BIN_DIR/jellyterm
Icon=multimedia-player
Terminal=false
Categories=AudioVideo;Player;Video;
Keywords=jellyfin;jellyterm;media;movies;shows;music;tui;
StartupNotify=true
EOF
    chmod 0644 "$APPS_DIR/jellyterm.desktop"
  else
    warn "skipping JellyTerm menu icon (repo not present at $JELLYTERM_DIR)"
  fi

  # Media Editor — only wire it up if the repo actually cloned.
  if [ -f "$MEDIA_DIR/run-tui.sh" ]; then
    cat > "$APPS_DIR/media-tui.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Media Editor
GenericName=Physical Media Editor
Comment=TUI for editing your markdown media collection tables
Exec=konsole -p tabtitle=Media -e $MEDIA_DIR/run-tui.sh
Icon=text-x-markdown
Terminal=false
Categories=Office;Database;
Keywords=media;markdown;movies;cds;vinyl;games;collection;editor;
StartupNotify=true
EOF
    chmod 0644 "$APPS_DIR/media-tui.desktop"
  else
    warn "skipping Media Editor menu icon (media repo not present at $MEDIA_DIR)"
  fi

  # Dunking Bird — launches its own run_dunking_bird.sh (which checks prereqs);
  # uses the icon bundled in the repo. Only wire up if the repo cloned.
  if [ -f "$DUNKING_DIR/run_dunking_bird.sh" ]; then
    cat > "$APPS_DIR/dunkingbird.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Dunking Bird
GenericName=Auto Prompt Sender
Comment=Type a prompt into the active window every X interval
Exec=konsole --hold -p tabtitle=DunkingBird -e $DUNKING_DIR/run_dunking_bird.sh
Icon=$DUNKING_DIR/dunkingbird.png
Terminal=false
Categories=Utility;
Keywords=dunking;bird;prompt;automation;ydotool;agent;
StartupNotify=true
EOF
    chmod 0644 "$APPS_DIR/dunkingbird.desktop"
  else
    warn "skipping Dunking Bird menu icon (repo not present at $DUNKING_DIR)"
  fi


  if have update-desktop-database; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# 0. Migrate off the old split layout (~/.local/bin, ~/src/openrouter-tui)
# ---------------------------------------------------------------------------
# Earlier versions installed some binaries to ~/.local/bin and cloned ortop to
# ~/src/openrouter-tui. ~/.local/bin can sit *ahead* of $PREFIX/bin on PATH, so a
# leftover copy there would shadow the new symlink — remove them.
cleanup_legacy_layout() {
  say "Cleaning up legacy ~/.local/bin and old ortop clone"
  local b
  for b in ortop qbt-tui ortop-gui qbt-tui-gui hey-journal jellyterm kdotool; do
    if [ -e "$HOME/.local/bin/$b" ] || [ -L "$HOME/.local/bin/$b" ]; then
      info "removing stale ~/.local/bin/$b (now in $BIN_DIR)"
      rm -f "$HOME/.local/bin/$b"
    fi
  done
  if [ -d "$BUILD_DIR/openrouter-tui" ] && [ "$BUILD_DIR/openrouter-tui" != "$ORTOP_DIR" ]; then
    info "removing old ortop clone at $BUILD_DIR/openrouter-tui (now $ORTOP_DIR)"
    rm -rf "$BUILD_DIR/openrouter-tui"
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
main() {
  install_build_deps
  cleanup_legacy_layout

  build_hey
  build_ortop
  build_qbt_tui
  build_newsboat
  install_media
  install_dunkingbird
  install_jellyterm

  build_fresh_editor
  build_bottom
  set_default_editor
  install_tailscale

  install_wrappers
  install_desktop_entries

  say "Done."
  cat <<EOF

Menu icons created: HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
JellyTerm, qBittorrent TUI.
Binaries live in $BIN_DIR (Termux \$PREFIX/bin) — no sudo, no /usr/local/bin.
fresh-editor installed from the Termux package; bottom (btm) built from source.
fresh-editor is now the default editor (open a new shell, or: source ~/.bashrc).

Termux differences from the Kubuntu build:
  - Dropped (no Termux/aarch64 path): firefox (already installed), thunderbird,
    duckstation, claude-desktop, rustdesk, and the systemd NFS mounts.
  - Tailscale isn't packaged for Termux — use the official Android app.
  - Dunking Bird's auto-type needs ydotool, which can't run without root here.

Still up to you (secrets — intentionally not handled here):
  - ~/.config/ortop/env   OpenRouter API keys
  - ~/.config/qbt-tui/env qBittorrent WebUI username+password (or api_key)
  - HEY login             run: hey   (and sign in)
  - Jellyfin login        run: jellyterm   (and sign in)
  - ~/.config/newsboat/urls   your FreshRSS endpoint + credentials
  - GitHub SSH key        needed to clone the private media repo
EOF
}

main "$@"

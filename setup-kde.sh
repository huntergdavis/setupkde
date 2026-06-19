#!/usr/bin/env bash
#
# setup-kde.sh — rebuild Hunter's KDE app environment on a fresh machine.
#
# Installs the programs and creates the KDE menu icons for:
#   HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
#   qBittorrent TUI, fresh-editor
# plus the other apps installed by hand (duckstation, claude-desktop,
# rustdesk, torguard, firefox/thunderbird/bottom snaps).
#
# It also makes fresh-editor the system-wide default editor (EDITOR/VISUAL
# and the `editor` alternative) via a wrapper, so git/crontab/hey all use it.
#
# This script does NOT copy keys, tokens, logins, or config secrets.
# After running it you still need to provide, yourself:
#   - ~/.config/ortop/env        (OpenRouter API keys; sourced by ortop-gui)
#   - ~/.config/qbt-tui/env      (qBittorrent WebUI creds; sourced by qbt-tui-gui)
#   - HEY login / `hey` config
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
# Two repo roots, split by ownership (not by build system):
#   BUILD_DIR     — third-party upstream repos (hey-cli, qbittorrent-tui, newsboat)
#   WORKSPACE_DIR — your own (huntergdavis) projects (ortop, media, dunkingbird)
BUILD_DIR="${BUILD_DIR:-$HOME/src}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
# The one place binaries live. Built artifacts stay in their repo and are
# symlinked in here, so /usr/local/bin is the single PATH entry that matters
# and a rebuild is picked up with no stale copy. No ~/.local/bin anywhere.
BIN_DIR="/usr/local/bin"
APPS_DIR="$HOME/.local/share/applications"   # XDG per-user menu entries (not binaries)

HEY_REPO="https://github.com/basecamp/hey-cli.git"
ORTOP_REPO="https://github.com/huntergdavis/openrouter-tui.git"
ORTOP_DIR="$WORKSPACE_DIR/ortop"   # your project, lives alongside media/dunkingbird
NEWSBOAT_REPO="https://github.com/newsboat/newsboat.git"
QBT_TUI_REPO="https://github.com/nickvanw/qbittorrent-tui.git"   # public
MEDIA_REPO="git@github.com:huntergdavis/media.git"   # private; needs your GitHub SSH key
MEDIA_DIR="$WORKSPACE_DIR/media"
DUNKING_REPO="https://github.com/huntergdavis/dunkingbird.git"   # public
DUNKING_DIR="$WORKSPACE_DIR/dunkingbird"

# NFS shares exported by monkeydluffy (192.168.0.238). Mounted read-write for
# grsync. Each entry is "server_export|local_mountpoint".
NFS_SERVER="192.168.0.238"
NFS_MOUNTS=(
  "/media/hunter/EasyStore18gb|/mnt/monkeydluffy/treasure"
  "/media/hunter/Expansion28tb|/mnt/monkeydluffy/more_treasure"
)

# Path of the fresh-editor wrapper that fixes snap's argv[0] dispatch (see below).
FRESH_WRAPPER="/usr/local/bin/fresh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Symlink a built binary into BIN_DIR. -f replaces a prior copy/symlink (so an
# old `install`-ed file migrates to a symlink); -n avoids descending into an
# existing symlinked dir. Centralizes the "one binary location" rule.
link_bin() {
  local src="$1" name="${2:-$(basename "$1")}"
  sudo ln -sfn "$src" "$BIN_DIR/$name"
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

mkdir -p "$BUILD_DIR" "$WORKSPACE_DIR" "$APPS_DIR"   # BIN_DIR (/usr/local/bin) already exists

# ---------------------------------------------------------------------------
# 1. apt build dependencies + toolchains
# ---------------------------------------------------------------------------
install_build_deps() {
  say "Installing build toolchains and dependencies (apt)"
  sudo apt-get update -qq
  # cargo/rustc from apt are often too old for recent crates (e.g. newsboat
  # requires resolver = "3" which needs cargo 1.84+). We install via rustup
  # below and skip the apt rust packages.
  sudo apt-get install -y \
    build-essential pkg-config git curl ca-certificates gnupg \
    golang-go gettext asciidoctor \
    libstfl-dev libsqlite3-dev libcurl4-openssl-dev \
    libncurses-dev libxml2-dev libdbus-1-dev libjson-c-dev \
    python3 python3-venv python3-pip \
    ydotool xclip xdotool \
    konsole snapd

  # Install rustup (provides up-to-date cargo/rustc) if not already present.
  if ! command -v rustup >/dev/null 2>&1; then
    say "Installing rustup (stable Rust toolchain)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  fi
  # Ensure cargo is on PATH for the remainder of this script run.
  # shellcheck source=/dev/null
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
}

# ---------------------------------------------------------------------------
# 2. Source builds: hey, ortop, newsboat
# ---------------------------------------------------------------------------
build_hey() {
  say "Building HEY (hey-cli) -> /usr/local/bin/hey"
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
  say "Building Newsboat -> /usr/local/bin/newsboat"
  local dir="$BUILD_DIR/newsboat"
  clone_or_update "$NEWSBOAT_REPO" "$dir"
  ( cd "$dir" && make -j"$(nproc)" && sudo make install )   # installs under /usr/local
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
# The menu icon launches its own run_dunking_bird.sh, which starts the ydotool
# daemon and the TUI; the apt step above provides ydotool/xclip/xdotool so the
# launcher's prerequisite checks pass on a fresh machine.
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

  # ydotool needs the invoking user in the `input` group (re-login to apply).
  # The launcher starts ydotoold itself (via sudo) at run time.
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
    info "adding $USER to the input group (for ydotool; re-login to take effect)"
    sudo usermod -aG input "$USER" || warn "could not add $USER to the input group"
  fi

  # kdotool: window capture/focus backend used on KDE Wayland (best-effort).
  # cargo can't write to /usr/local/bin without sudo, so build it into a cargo
  # root under BUILD_DIR and symlink the binary into BIN_DIR like everything else.
  if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && ! have kdotool; then
    info "installing kdotool (KDE Wayland window backend)"
    if cargo install --git https://github.com/jinliu/kdotool --root "$BUILD_DIR/cargo"; then
      link_bin "$BUILD_DIR/cargo/bin/kdotool" kdotool
    else
      warn "could not install kdotool; window targeting may be limited on KDE Wayland"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 3. Snaps: fresh-editor, duckstation, and the rest
# ---------------------------------------------------------------------------
install_snaps() {
  say "Installing snaps"
  snap_install() {
    local name="$1"; shift
    if snap list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
      info "$name already installed"
    else
      info "installing $name"
      sudo snap install "$name" "$@"
    fi
  }
  snap_install fresh-editor --classic     # required by HEY Journal (EDITOR)
  snap_install duckstation-gpl
  snap_install firefox
  snap_install thunderbird
  snap_install bottom
}

# ---------------------------------------------------------------------------
# 3b. Make fresh-editor the system-wide default editor
# ---------------------------------------------------------------------------
# /snap/bin/fresh-editor symlinks to /usr/bin/snap, and snap chooses which app
# to run from the basename it's invoked as. Tools that call the editor as
# "editor" (git, crontab) would therefore run snap *as* "editor" and fail with
# `unknown command ...`. A tiny wrapper that always re-execs fresh-editor under
# its real name fixes this; we point EDITOR/VISUAL and the `editor` alternative
# at the wrapper.
set_default_editor() {
  say "Making fresh-editor the system-wide default editor"

  sudo tee "$FRESH_WRAPPER" >/dev/null <<'EOF'
#!/bin/sh
# Wrapper for the fresh-editor snap.
# Snap dispatches by argv[0] basename, so it must be invoked as "fresh-editor".
# Tools that call it as "editor" (git, crontab, etc.) break without this.
exec /snap/bin/fresh-editor "$@"
EOF
  sudo chmod 0755 "$FRESH_WRAPPER"

  # `editor` alternative (used by sensible-editor and as git's last-resort editor).
  sudo update-alternatives --install /usr/bin/editor editor "$FRESH_WRAPPER" 200
  sudo update-alternatives --set editor "$FRESH_WRAPPER"

  # EDITOR/VISUAL for all login + GUI sessions (pam_env reads /etc/environment).
  # Idempotent: strip any prior lines first. Takes effect on next login.
  sudo sed -i '/^EDITOR=/d;/^VISUAL=/d' /etc/environment
  printf 'EDITOR="%s"\nVISUAL="%s"\n' "$FRESH_WRAPPER" "$FRESH_WRAPPER" | sudo tee -a /etc/environment >/dev/null
  info "EDITOR/VISUAL -> $FRESH_WRAPPER (takes effect on next login)"
}

# ---------------------------------------------------------------------------
# 4. apt apps from extra repos / releases
# ---------------------------------------------------------------------------
install_claude_desktop() {
  say "Installing claude-desktop (pkg.claude-desktop-debian.dev)"
  if dpkg -s claude-desktop >/dev/null 2>&1; then
    info "claude-desktop already installed"; return
  fi
  local key=/usr/share/keyrings/claude-desktop.gpg
  local key_url=https://pkg.claude-desktop-debian.dev/KEY.gpg
  local list=/etc/apt/sources.list.d/claude-desktop.list
  if [ ! -s "$key" ] || ! gpg --quiet --show-keys "$key" >/dev/null 2>&1; then
    info "fetching signing key"
    sudo rm -f "$key"
    curl -fsSL "$key_url" \
      | sudo gpg --dearmor --yes -o "$key" \
      || { warn "could not fetch claude-desktop key; skipping. See https://github.com/aaddrick/claude-desktop-debian"; return; }
  fi
  echo "deb [signed-by=$key arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
    | sudo tee "$list" >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y claude-desktop
}

install_rustdesk() {
  say "Installing rustdesk (latest .deb from GitHub releases)"
  if dpkg -s rustdesk >/dev/null 2>&1; then
    info "rustdesk already installed"; return
  fi
  local url
  url=$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
        | grep -oE 'https://[^"]*x86_64\.deb' | head -1)
  if [ -z "$url" ]; then
    warn "could not find a rustdesk .deb asset; skipping. See https://github.com/rustdesk/rustdesk/releases"
    return
  fi
  local deb="$BUILD_DIR/$(basename "$url")"
  info "downloading $(basename "$url")"
  curl -fsSL -o "$deb" "$url"
  sudo apt-get install -y "$deb"
}

install_torguard() {
  say "Installing TorGuard VPN client (.deb from torguard.net)"
  if dpkg -s torguard >/dev/null 2>&1; then
    info "torguard already installed"; return
  fi
  local url="https://updates.torguard.biz/Software/Linux/torguard-latest-amd64.deb"
  local deb="$BUILD_DIR/torguard-latest-amd64.deb"
  info "downloading torguard-latest-amd64.deb"
  curl -fsSL -o "$deb" "$url" \
    || { warn "could not download TorGuard .deb; skipping. See https://torguard.net/downloads.php"; return; }
  sudo apt-get install -y "$deb"
}

# ---------------------------------------------------------------------------
# 5. Wrapper scripts (recreated verbatim)
# ---------------------------------------------------------------------------
install_wrappers() {
  say "Installing launcher wrapper scripts -> $BIN_DIR"

  sudo tee "$BIN_DIR/hey-journal" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for the "HEY Journal" KDE menu entry.
# `hey journal write` opens $EDITOR; GUI launches don't always have it set,
# so guarantee fresh-editor is used (falls back to any EDITOR already set).
export EDITOR="${EDITOR:-/usr/local/bin/fresh}"
export VISUAL="${VISUAL:-$EDITOR}"
exec hey journal write "$@"
EOF

  sudo tee "$BIN_DIR/ortop-gui" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for the ortop KDE menu entry.
# GUI launches don't source ~/.bashrc, so load the OpenRouter keys explicitly.
. "$HOME/.config/ortop/env" 2>/dev/null
exec ortop "$@"
EOF

  sudo tee "$BIN_DIR/qbt-tui-gui" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for the qbt-tui KDE menu entry.
# GUI launches don't source ~/.bashrc, so set the (non-secret) server URL here
# and load the qBittorrent WebUI credentials from a separate env file.
export QBT_SERVER_URL="${QBT_SERVER_URL:-http://192.168.0.238:9999/}"
. "$HOME/.config/qbt-tui/env" 2>/dev/null
exec qbt-tui "$@"
EOF

  sudo chmod 0755 "$BIN_DIR/hey-journal" "$BIN_DIR/ortop-gui" "$BIN_DIR/qbt-tui-gui"
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
# 7. NFS mounts from monkeydluffy (for grsync)
# ---------------------------------------------------------------------------
# The drives "treasure" and "more treasure" live on monkeydluffy and are
# exported over NFS (faster than SMB for Linux<->Linux). We mount them via
# /etc/fstab using systemd automount so they:
#   - survive reboot,
#   - mount on first access (don't block boot), and
#   - don't hang the machine if the server or a USB drive is offline (nofail).
# This is the client side only; the NFS server config lives on monkeydluffy.
install_nfs_mounts() {
  say "Mounting monkeydluffy NFS shares (for grsync)"
  sudo apt-get install -y nfs-common

  local changed=0 export_path mountpoint line
  for entry in "${NFS_MOUNTS[@]}"; do
    export_path="${entry%%|*}"
    mountpoint="${entry##*|}"
    sudo mkdir -p "$mountpoint"
    line="$NFS_SERVER:$export_path  $mountpoint  nfs  _netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600,noatime  0  0"
    if grep -qF " $mountpoint " /etc/fstab; then
      info "fstab entry for $mountpoint already present"
    else
      info "adding fstab entry for $mountpoint"
      echo "$line" | sudo tee -a /etc/fstab >/dev/null
      changed=1
    fi
  done

  if [ "$changed" = 1 ]; then
    sudo systemctl daemon-reload
    sudo mount -a || warn "mount -a reported an error; check 'showmount -e $NFS_SERVER'"
  fi
  info "shares will mount on first access under /mnt/monkeydluffy/"
}

# ---------------------------------------------------------------------------
# 0. Migrate off the old split layout (~/.local/bin, ~/src/openrouter-tui)
# ---------------------------------------------------------------------------
# Earlier versions installed some binaries to ~/.local/bin and cloned ortop to
# ~/src/openrouter-tui. Ubuntu puts ~/.local/bin *ahead* of /usr/local/bin on
# PATH, so a leftover copy there would shadow the new symlink — remove them.
cleanup_legacy_layout() {
  say "Cleaning up legacy ~/.local/bin and old ortop clone"
  local b
  for b in ortop qbt-tui ortop-gui qbt-tui-gui hey-journal kdotool; do
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

  install_snaps
  set_default_editor
  install_claude_desktop
  install_rustdesk
  install_torguard

  install_wrappers
  install_desktop_entries
  install_nfs_mounts

  say "Done."
  cat <<EOF

Menu icons created: HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
qBittorrent TUI.
TorGuard VPN installed (launch from the app menu or run: torguard).
NFS shares from monkeydluffy mounted at /mnt/monkeydluffy/{treasure,more_treasure}
(systemd automount; survives reboot, mounts on first access).
fresh-editor is now the system-wide default editor (effective next login).
Dunking Bird needs the 'input' group for ydotool — re-login if it was just added.
Still up to you (secrets — intentionally not handled here):
  - ~/.config/ortop/env   OpenRouter API keys
  - ~/.config/qbt-tui/env qBittorrent WebUI username+password (or api_key)
  - HEY login             run: hey   (and sign in)
  - ~/.config/newsboat/urls   your FreshRSS endpoint + credentials
  - GitHub SSH key        needed to clone the private media repo
EOF
}

main "$@"

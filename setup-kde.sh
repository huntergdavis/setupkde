#!/usr/bin/env bash
#
# setup-kde.sh — rebuild Hunter's KDE app environment on a fresh machine.
#
# ONE script, TWO platforms. The shared logic (source builds, launcher wrappers,
# KDE menu icons, legacy cleanup, orchestration) lives here; everything that
# genuinely differs between a Kubuntu laptop and Termux/Android is isolated in a
# platform profile under lib/:
#
#   lib/platform-linux.sh   — Kubuntu/Debian: sudo, /usr/local/bin, apt + snap,
#                             rustup, /etc/environment, systemd NFS automounts.
#   lib/platform-termux.sh  — Termux/Android (aarch64): no root/sudo, $PREFIX/bin,
#                             pkg/apt only, system rust, ~/.bashrc, no snap/systemd.
#
# The profile is auto-detected (override with PLATFORM=linux|termux) and sourced
# before anything runs. It must define the vars BIN_DIR / SUDO / BASH_SHEBANG /
# FRESH_PATH and the p_* hook functions called by main() below.
#
# Installs the programs and creates the KDE menu icons for:
#   HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
#   JellyTerm, qBittorrent TUI (+ Motion Cues / fresh-editor / bottom where the
#   platform supports them).
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
# NOTE: on Termux invoke as `bash setup-kde.sh` (bootstrap.sh does this) — the
# #!/usr/bin/env shebang has no /usr/bin/env to resolve there.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # this repo (ships the qbt icon)

# ---------------------------------------------------------------------------
# Platform profile (auto-detected; override with PLATFORM=linux|termux)
# ---------------------------------------------------------------------------
if [ -z "${PLATFORM:-}" ]; then
  if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then
    PLATFORM=termux
  else
    PLATFORM=linux
  fi
fi
PLATFORM_LIB="$SCRIPT_DIR/lib/platform-$PLATFORM.sh"
[ -r "$PLATFORM_LIB" ] || {
  echo "setup-kde.sh: no platform profile for '$PLATFORM' (expected $PLATFORM_LIB)" >&2
  exit 1
}
# shellcheck source=/dev/null
. "$PLATFORM_LIB"   # defines BIN_DIR, SUDO, BASH_SHEBANG, FRESH_PATH and the p_* hooks

# ---------------------------------------------------------------------------
# Shared config (the "what/where"; the profile decides the "how")
# ---------------------------------------------------------------------------
# Two repo roots, split by ownership (not by build system):
#   BUILD_DIR     — third-party upstream repos (hey-cli, qbittorrent-tui, newsboat)
#   WORKSPACE_DIR — your own (huntergdavis) projects (ortop, media, dunkingbird, jellyterm)
BUILD_DIR="${BUILD_DIR:-$HOME/src}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
APPS_DIR="$HOME/.local/share/applications"   # XDG per-user menu entries (not binaries)
CARGO_ROOT="$BUILD_DIR/cargo"                 # where `cargo install` lands (then symlinked)

HEY_REPO="https://github.com/basecamp/hey-cli.git"
ORTOP_REPO="https://github.com/huntergdavis/openrouter-tui.git"
ORTOP_DIR="$WORKSPACE_DIR/ortop"   # your project, lives alongside media/dunkingbird
NEWSBOAT_REPO="https://github.com/newsboat/newsboat.git"
QBT_TUI_REPO="https://github.com/nickvanw/qbittorrent-tui.git"   # public
MEDIA_REPO="git@github.com:huntergdavis/media.git"   # private; needs your GitHub SSH key
MEDIA_DIR="$WORKSPACE_DIR/media"
DUNKING_REPO="https://github.com/huntergdavis/dunkingbird.git"   # public
DUNKING_DIR="$WORKSPACE_DIR/dunkingbird"
MOTION_CUES_REPO="https://github.com/monperrus/motion-cues.git"   # public, third-party (Linux only)
MOTION_CUES_DIR="$BUILD_DIR/motion-cues"
JELLYTERM_REPO="https://github.com/huntergdavis/jellyterm.git"   # public
JELLYTERM_DIR="$WORKSPACE_DIR/jellyterm"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Symlink a built binary into BIN_DIR. -f replaces a prior copy/symlink (so an
# old `install`-ed file migrates to a symlink); -n avoids descending into an
# existing symlinked dir. $SUDO is empty on Termux ($PREFIX/bin is user-owned)
# and "sudo" on Linux (/usr/local/bin needs root).
link_bin() {
  local src="$1" name="${2:-$(basename "$1")}"
  $SUDO ln -sfn "$src" "$BIN_DIR/$name"
}

# Clone if missing, otherwise pull latest.
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

# Write an executable launcher to $1 with the platform's shebang, reading the
# script body from stdin (heredoc). Quoted heredocs keep the body literal;
# unquoted ones let $FRESH_PATH etc. expand at write time. $SUDO handles the
# Linux /usr/local/bin permissions; it's empty on Termux.
write_launcher() {
  local dest="$1"
  { printf '%s\n' "$BASH_SHEBANG"; cat; } | $SUDO tee "$dest" >/dev/null
  $SUDO chmod 0755 "$dest"
}

mkdir -p "$BUILD_DIR" "$WORKSPACE_DIR" "$APPS_DIR"   # BIN_DIR already exists on both platforms

# ---------------------------------------------------------------------------
# Source builds shared by both platforms: hey, ortop, qbt-tui
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
# The platform hook p_dunkingbird_input handles the input backend (the `input`
# group on Linux; a "no ydotool on Android" warning on Termux). kdotool (KDE
# Wayland window targeting) is built the same way on both platforms.
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

  p_dunkingbird_input   # input group (Linux) / ydotool-unavailable warning (Termux)

  # kdotool: window capture/focus backend used on KDE Wayland (best-effort).
  # cargo can't write to /usr/local/bin without sudo, so build it into a cargo
  # root under BUILD_DIR and symlink the binary into BIN_DIR like everything else.
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
# Python venv and OS player prerequisites. The platform hook p_jellyterm_install
# runs that installer the platform's way (Termux needs shebang fixups + bash +
# --skip-system-packages because the OS-package path uses sudo).
install_jellyterm() {
  say "Installing JellyTerm (jellyterm) -> $JELLYTERM_DIR"
  clone_or_update "$JELLYTERM_REPO" "$JELLYTERM_DIR"
  chmod 0755 "$JELLYTERM_DIR/scripts/install.sh" "$JELLYTERM_DIR/scripts/run.sh" 2>/dev/null || true
  p_jellyterm_install "$JELLYTERM_DIR"
}

# ---------------------------------------------------------------------------
# Launcher wrapper scripts (shared; platform shebang via write_launcher)
# ---------------------------------------------------------------------------
install_wrappers() {
  say "Installing launcher wrapper scripts -> $BIN_DIR"

  write_launcher "$BIN_DIR/hey-journal" <<EOF
# Launcher wrapper for the "HEY Journal" KDE menu entry.
# \`hey journal write\` opens \$EDITOR; GUI launches don't always have it set,
# so guarantee fresh-editor is used (falls back to any EDITOR already set).
export EDITOR="\${EDITOR:-$FRESH_PATH}"
export VISUAL="\${VISUAL:-\$EDITOR}"
exec hey journal write "\$@"
EOF

  write_launcher "$BIN_DIR/ortop-gui" <<'EOF'
# Launcher wrapper for the ortop KDE menu entry.
# GUI launches don't source ~/.bashrc, so load the OpenRouter keys explicitly.
. "$HOME/.config/ortop/env" 2>/dev/null
exec ortop "$@"
EOF

  write_launcher "$BIN_DIR/qbt-tui-gui" <<'EOF'
# Launcher wrapper for the qbt-tui KDE menu entry.
# GUI launches don't source ~/.bashrc, so set the (non-secret) server URL here
# and load the qBittorrent WebUI credentials from a separate env file.
export QBT_SERVER_URL="${QBT_SERVER_URL:-http://192.168.0.238:9999/}"
. "$HOME/.config/qbt-tui/env" 2>/dev/null
exec qbt-tui "$@"
EOF

  if [ -f "$JELLYTERM_DIR/scripts/run.sh" ]; then
    write_launcher "$BIN_DIR/jellyterm" <<EOF
# Launcher wrapper for JellyTerm. Keep this as a wrapper, not a symlink to
# scripts/run.sh, so the project root stays stable when invoked from PATH.
exec "$JELLYTERM_DIR/scripts/run.sh" "\$@"
EOF
  else
    warn "skipping JellyTerm PATH wrapper (runner not present at $JELLYTERM_DIR/scripts/run.sh)"
  fi

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
# KDE menu icons (.desktop entries) — shared; every optional app self-gates on
# whether its repo/binary actually installed, so the Motion Cues entry (Linux
# only) simply never appears on Termux.
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

  # JellyTerm — launches through the BIN_DIR wrapper so it is also on PATH.
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

  # Motion Cues — a PyQt6 system-tray GUI (Linux only; Termux has no PyQt6 wheel,
  # so the venv binary never exists there and this block is skipped). Launches
  # directly with no terminal.
  if [ -x "$MOTION_CUES_DIR/venv/bin/motion-cues" ]; then
    cat > "$APPS_DIR/motion-cues.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Motion Cues
GenericName=Vehicle Motion Cues
Comment=Peripheral dots that reduce motion sickness using a laptop in a vehicle
Exec=$BIN_DIR/motion-cues
Icon=preferences-desktop-display
Terminal=false
Categories=Utility;Accessibility;
Keywords=motion;cues;sickness;vehicle;car;dots;overlay;
StartupNotify=false
EOF
    chmod 0644 "$APPS_DIR/motion-cues.desktop"
  else
    warn "skipping Motion Cues menu icon (motion-cues not installed)"
  fi

  if have update-desktop-database; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Migrate off the old split layout (~/.local/bin, ~/src/openrouter-tui)
# ---------------------------------------------------------------------------
# Earlier versions installed some binaries to ~/.local/bin and cloned ortop to
# ~/src/openrouter-tui. ~/.local/bin can sit *ahead* of BIN_DIR on PATH, so a
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
  p_build_deps            # platform: apt+rustup (Linux) / pkg (Termux)
  cleanup_legacy_layout

  build_hey
  build_ortop
  build_qbt_tui
  p_newsboat              # platform: source build (Linux) / Termux package
  install_media
  install_dunkingbird
  install_jellyterm

  p_fresh_editor          # platform: snap (Linux) / Termux package
  p_extra_apps            # platform: snaps+duckstation+claude-desktop+rustdesk+motion-cues (Linux) / bottom (Termux)
  p_default_editor        # platform: /etc/environment + alternatives (Linux) / ~/.bashrc (Termux)
  p_vpn                   # platform: tailscale install (Linux) / package-or-Android-app note (Termux)

  install_wrappers
  install_desktop_entries
  p_mounts                # platform: systemd NFS automounts (Linux) / no-op (Termux)

  say "Done."
  p_final_notes
}

main "$@"

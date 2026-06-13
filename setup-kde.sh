#!/usr/bin/env bash
#
# setup-kde.sh — rebuild Hunter's KDE app environment on a fresh machine.
#
# Installs the programs and creates the KDE menu icons for:
#   HEY, HEY Journal, Newsboat, ortop, fresh-editor
# plus the other apps installed by hand (duckstation, claude-desktop,
# rustdesk, crystal-dock, firefox/thunderbird/bottom snaps).
#
# This script does NOT copy keys, tokens, logins, or config secrets.
# After running it you still need to provide, yourself:
#   - ~/.config/ortop/env        (OpenRouter API keys; sourced by ortop-gui)
#   - HEY login / `hey` config
#   - newsboat ~/.config/newsboat/urls (FreshRSS aggregator + creds)
#
# Safe to re-run: every step checks whether the work is already done.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BUILD_DIR="${BUILD_DIR:-$HOME/src}"          # where upstream repos are cloned/built
LOCAL_BIN="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"

HEY_REPO="https://github.com/basecamp/hey-cli.git"
ORTOP_REPO="https://github.com/huntergdavis/openrouter-tui.git"
NEWSBOAT_REPO="https://github.com/newsboat/newsboat.git"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

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

mkdir -p "$BUILD_DIR" "$LOCAL_BIN" "$APPS_DIR"

# ---------------------------------------------------------------------------
# 1. apt build dependencies + toolchains
# ---------------------------------------------------------------------------
install_build_deps() {
  say "Installing build toolchains and dependencies (apt)"
  sudo apt-get update -qq
  sudo apt-get install -y \
    build-essential pkg-config git curl ca-certificates gnupg \
    cargo rustc golang-go gettext asciidoctor \
    libstfl-dev libsqlite3-dev libcurl4-openssl-dev \
    libncurses-dev libxml2-dev \
    konsole snapd
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
  sudo install -m 0755 "$dir/bin/hey" /usr/local/bin/hey
  info "installed $(/usr/local/bin/hey --version 2>/dev/null | head -1 || echo hey)"
}

build_ortop() {
  say "Building ortop (openrouter-tui) -> $LOCAL_BIN/ortop"
  local dir="$BUILD_DIR/openrouter-tui"
  clone_or_update "$ORTOP_REPO" "$dir"
  ( cd "$dir" && go build -o ortop ./... )
  install -m 0755 "$dir/ortop" "$LOCAL_BIN/ortop"
}

build_newsboat() {
  say "Building Newsboat -> /usr/local/bin/newsboat"
  local dir="$BUILD_DIR/newsboat"
  clone_or_update "$NEWSBOAT_REPO" "$dir"
  ( cd "$dir" && make -j"$(nproc)" && sudo make install )   # installs under /usr/local
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
# 4. apt apps from extra repos / releases
# ---------------------------------------------------------------------------
install_crystal_dock() {
  say "Installing crystal-dock (Ubuntu universe)"
  if have crystal-dock || dpkg -s crystal-dock >/dev/null 2>&1; then
    info "crystal-dock already installed"
  else
    sudo apt-get install -y crystal-dock
  fi
}

install_claude_desktop() {
  say "Installing claude-desktop (pkg.claude-desktop-debian.dev)"
  if dpkg -s claude-desktop >/dev/null 2>&1; then
    info "claude-desktop already installed"; return
  fi
  local key=/usr/share/keyrings/claude-desktop.gpg
  local list=/etc/apt/sources.list.d/claude-desktop.list
  if [ ! -f "$key" ]; then
    info "fetching signing key"
    curl -fsSL https://pkg.claude-desktop-debian.dev/public.key \
      | sudo gpg --dearmor -o "$key" \
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

# ---------------------------------------------------------------------------
# 5. Wrapper scripts (recreated verbatim)
# ---------------------------------------------------------------------------
install_wrappers() {
  say "Installing launcher wrapper scripts -> $LOCAL_BIN"

  cat > "$LOCAL_BIN/hey-journal" <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for the "HEY Journal" KDE menu entry.
# `hey journal write` opens $EDITOR; GUI launches don't always have it set,
# so guarantee fresh-editor is used (falls back to any EDITOR already set).
export EDITOR="${EDITOR:-/snap/bin/fresh-editor}"
export VISUAL="${VISUAL:-$EDITOR}"
exec hey journal write "$@"
EOF

  cat > "$LOCAL_BIN/ortop-gui" <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for the ortop KDE menu entry.
# GUI launches don't source ~/.bashrc, so load the OpenRouter keys explicitly.
. "$HOME/.config/ortop/env" 2>/dev/null
exec ortop "$@"
EOF

  chmod 0755 "$LOCAL_BIN/hey-journal" "$LOCAL_BIN/ortop-gui"
  if [ ! -f "$HOME/.config/ortop/env" ]; then
    warn "ortop needs ~/.config/ortop/env with your OpenRouter keys (not created by this script)"
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
Exec=konsole --hold -p tabtitle=HEY\\sJournal -e $LOCAL_BIN/hey-journal
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
Exec=konsole --hold -p tabtitle=ortop -e $LOCAL_BIN/ortop-gui
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

  chmod 0644 "$APPS_DIR"/{hey,hey-journal,newsboat,ortop}.desktop
  if have update-desktop-database; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
main() {
  install_build_deps

  build_hey
  build_ortop
  build_newsboat

  install_snaps
  install_crystal_dock
  install_claude_desktop
  install_rustdesk

  install_wrappers
  install_desktop_entries

  say "Done."
  cat <<EOF

Menu icons created: HEY, HEY Journal, Newsboat, ortop.
Still up to you (secrets — intentionally not handled here):
  - ~/.config/ortop/env   OpenRouter API keys
  - HEY login             run: hey   (and sign in)
  - ~/.config/newsboat/urls   your FreshRSS endpoint + credentials
EOF
}

main "$@"

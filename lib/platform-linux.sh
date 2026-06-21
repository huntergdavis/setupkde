# lib/platform-linux.sh — Kubuntu/Debian profile for setup-kde.sh
#
# Sourced by setup-kde.sh. Privileged machine: sudo is available, binaries live
# in /usr/local/bin, packages come from apt + snap, Rust from rustup, the default
# editor is wired through /etc/environment + update-alternatives, and the NFS
# shares are mounted via systemd automount. Defines the vars + p_* hooks the
# shared orchestrator expects. Relies on helpers (say/info/warn/have, link_bin,
# clone_or_update) and config vars (BUILD_DIR, *_REPO/_DIR) defined by setup-kde.sh
# — they resolve at call time, not source time.

# --- Platform vars (consumed by the shared code) ---------------------------
BIN_DIR="/usr/local/bin"                # the one binary location (needs root)
SUDO="sudo"                             # privileged ops go through sudo
BASH_SHEBANG="#!/usr/bin/env bash"      # shebang baked into generated launchers
FRESH_PATH="/usr/local/bin/fresh"       # the editor command (a wrapper, created below)

# NFS shares exported by monkeydluffy (192.168.0.238). Mounted read-write for
# grsync. Each entry is "server_export|local_mountpoint".
NFS_SERVER="192.168.0.238"
NFS_MOUNTS=(
  "/media/hunter/EasyStore18gb|/mnt/monkeydluffy/treasure"
  "/media/hunter/Expansion28tb|/mnt/monkeydluffy/more_treasure"
)

# --- Build toolchains + dependencies (apt) ---------------------------------
p_build_deps() {
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
  # Ensure cargo is on PATH for the remainder of this script run. Use an
  # explicit if (not `&& .`) so a missing env file can't become this function's
  # non-zero exit status and trip `set -e`.
  # shellcheck source=/dev/null
  if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
}

# --- Newsboat (built from source) ------------------------------------------
p_newsboat() {
  say "Building Newsboat -> $BIN_DIR/newsboat"
  local dir="$BUILD_DIR/newsboat"
  clone_or_update "$NEWSBOAT_REPO" "$dir"
  ( cd "$dir" && make -j"$(nproc)" && sudo make install )   # installs under /usr/local
}

# --- fresh-editor (snap) ---------------------------------------------------
# Installed as a classic snap; p_default_editor then wires it in as the system
# editor. duckstation/firefox/thunderbird/bottom + the apt-repo / .deb apps are
# in p_extra_apps.
_snap_install() {
  local name="$1"; shift
  if snap list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    info "$name already installed"
  else
    info "installing $name"
    sudo snap install "$name" "$@"
  fi
}

p_fresh_editor() {
  say "Installing fresh-editor (snap, classic)"
  _snap_install fresh-editor --classic     # required by HEY Journal (EDITOR)
}

# --- Make fresh-editor the system-wide default editor ----------------------
# /snap/bin/fresh-editor symlinks to /usr/bin/snap, and snap chooses which app
# to run from the basename it's invoked as. Tools that call the editor as
# "editor" (git, crontab) would therefore run snap *as* "editor" and fail with
# `unknown command ...`. A tiny wrapper that always re-execs fresh-editor under
# its real name fixes this; we point EDITOR/VISUAL and the `editor` alternative
# at the wrapper ($FRESH_PATH).
p_default_editor() {
  say "Making fresh-editor the system-wide default editor"

  sudo tee "$FRESH_PATH" >/dev/null <<'EOF'
#!/bin/sh
# Wrapper for the fresh-editor snap.
# Snap dispatches by argv[0] basename, so it must be invoked as "fresh-editor".
# Tools that call it as "editor" (git, crontab, etc.) break without this.
exec /snap/bin/fresh-editor "$@"
EOF
  sudo chmod 0755 "$FRESH_PATH"

  # `editor` alternative (used by sensible-editor and as git's last-resort editor).
  sudo update-alternatives --install /usr/bin/editor editor "$FRESH_PATH" 200
  sudo update-alternatives --set editor "$FRESH_PATH"

  # EDITOR/VISUAL for all login + GUI sessions (pam_env reads /etc/environment).
  # Idempotent: strip any prior lines first. Takes effect on next login.
  sudo sed -i '/^EDITOR=/d;/^VISUAL=/d' /etc/environment
  printf 'EDITOR="%s"\nVISUAL="%s"\n' "$FRESH_PATH" "$FRESH_PATH" | sudo tee -a /etc/environment >/dev/null
  info "EDITOR/VISUAL -> $FRESH_PATH (takes effect on next login)"
}

# --- JellyTerm install (privileged installer path is fine here) ------------
p_jellyterm_install() {
  local dir="$1"
  if [ -x "$dir/scripts/install.sh" ]; then
    ( cd "$dir" && ./scripts/install.sh --yes --player mpv-terminal )
  else
    warn "skipping JellyTerm install (installer not present at $dir/scripts/install.sh)"
  fi
}

# --- Dunking Bird input backend (ydotool via the `input` group) ------------
p_dunkingbird_input() {
  # ydotool needs the invoking user in the `input` group (re-login to apply).
  # The launcher starts ydotoold itself (via sudo) at run time.
  local u="${USER:-$(id -un)}"
  if ! id -nG "$u" | tr ' ' '\n' | grep -qx input; then
    info "adding $u to the input group (for ydotool; re-login to take effect)"
    sudo usermod -aG input "$u" || warn "could not add $u to the input group"
  fi
}

# --- Extra apps: the remaining snaps, Motion Cues, claude-desktop, rustdesk -
p_extra_apps() {
  say "Installing snaps (duckstation, firefox, thunderbird, bottom)"
  _snap_install duckstation-gpl
  _snap_install firefox
  _snap_install thunderbird
  _snap_install bottom

  _install_motion_cues
  _install_claude_desktop
  _install_rustdesk
}

# Motion Cues: a Linux port of Apple's Vehicle Motion Cues. A PyQt6 GUI app that
# drifts peripheral dots matching vehicle motion to reduce motion sickness while
# using a laptop in a car. Third-party Python package installed into its own venv.
# The `motion-cues` command in BIN_DIR is a thin wrapper that forces Qt's xcb
# platform: the app drives X11 ShapeBounding/ShapeInput directly on its own window,
# which fails under a native Wayland Qt platform (winId() is a Wayland surface, not
# an X window). Forcing xcb makes it a real X11 client via XWayland on KDE Wayland;
# harmless on a true X11 session. (The matching menu icon is created by the shared
# install_desktop_entries, gated on the venv binary existing.)
_install_motion_cues() {
  say "Installing Motion Cues (motion-cues) -> venv + $BIN_DIR/motion-cues"
  # Runtime X11 libs the PyQt6 overlay needs (XWayland on Wayland sessions).
  sudo apt-get install -y libx11-6 libxext6
  clone_or_update "$MOTION_CUES_REPO" "$MOTION_CUES_DIR"

  if [ ! -d "$MOTION_CUES_DIR/venv" ]; then
    info "creating venv"
    if ! python3 -m venv "$MOTION_CUES_DIR/venv"; then
      rm -rf "$MOTION_CUES_DIR/venv"
      warn "venv creation failed; skipping Motion Cues"
      return 0
    fi
  fi
  "$MOTION_CUES_DIR/venv/bin/pip" install --quiet --upgrade pip
  # Install the cloned repo (pulls in PyQt6); editable so a `git pull` is live.
  if ! "$MOTION_CUES_DIR/venv/bin/pip" install --quiet -e "$MOTION_CUES_DIR"; then
    warn "pip install of motion-cues failed (PyQt6 may lack a wheel for this Python); skipping"
    return 0
  fi

  # rm first: earlier versions symlinked this to the venv binary, and `tee`
  # would otherwise follow that symlink and overwrite the venv entry point.
  sudo rm -f "$BIN_DIR/motion-cues"
  sudo tee "$BIN_DIR/motion-cues" >/dev/null <<EOF
#!/usr/bin/env bash
# Wrapper for the Motion Cues venv install.
# Motion Cues drives X11 ShapeBounding/ShapeInput directly on its own window.
# Under a native Wayland Qt platform, winId() is a Wayland surface (not an X
# window), so those Xlib SHAPE calls fail with BadWindow. Forcing Qt's xcb
# platform makes it a real X11 client via XWayland with a valid window id.
# Harmless on a true X11 session, where xcb is already the default.
export QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-xcb}"
exec "$MOTION_CUES_DIR/venv/bin/motion-cues" "\$@"
EOF
  sudo chmod 0755 "$BIN_DIR/motion-cues"
}

_install_claude_desktop() {
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

_install_rustdesk() {
  say "Installing rustdesk (latest .deb from GitHub releases)"
  if dpkg -s rustdesk >/dev/null 2>&1; then
    info "rustdesk already installed"; return
  fi
  local url
  # `|| true`: under set -e + pipefail an empty grep match would otherwise abort
  # here, making the graceful "asset not found" skip below unreachable.
  url=$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
        | grep -oE 'https://[^"]*x86_64\.deb' | head -1) || true
  if [ -z "$url" ]; then
    warn "could not find a rustdesk .deb asset; skipping. See https://github.com/rustdesk/rustdesk/releases"
    return
  fi
  local deb="$BUILD_DIR/$(basename "$url")"
  info "downloading $(basename "$url")"
  curl -fsSL -o "$deb" "$url"
  sudo apt-get install -y "$deb"
}

# --- Tailscale -------------------------------------------------------------
p_vpn() {
  say "Installing Tailscale"
  if have tailscale; then info "tailscale already installed"; return; fi
  curl -fsSL https://tailscale.com/install.sh | sh
}

# --- NFS mounts from monkeydluffy (for grsync) -----------------------------
# The drives "treasure" and "more treasure" live on monkeydluffy and are
# exported over NFS (faster than SMB for Linux<->Linux). We mount them via
# /etc/fstab using systemd automount so they:
#   - survive reboot,
#   - mount on first access (don't block boot), and
#   - don't hang the machine if the server or a USB drive is offline (nofail).
# This is the client side only; the NFS server config lives on monkeydluffy.
p_mounts() {
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

# --- Closing summary -------------------------------------------------------
p_final_notes() {
  cat <<EOF

Menu icons created: HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
JellyTerm, qBittorrent TUI, Motion Cues.
Tailscale installed (run: sudo tailscale up   to authenticate and connect).
NFS shares from monkeydluffy mounted at /mnt/monkeydluffy/{treasure,more_treasure}
(systemd automount; survives reboot, mounts on first access).
fresh-editor is now the system-wide default editor (effective next login).
Dunking Bird needs the 'input' group for ydotool — re-login if it was just added.
Still up to you (secrets — intentionally not handled here):
  - ~/.config/ortop/env   OpenRouter API keys
  - ~/.config/qbt-tui/env qBittorrent WebUI username+password (or api_key)
  - HEY login             run: hey   (and sign in)
  - Jellyfin login        run: jellyterm   (and sign in)
  - ~/.config/newsboat/urls   your FreshRSS endpoint + credentials
  - GitHub SSH key        needed to clone the private media repo
EOF
}

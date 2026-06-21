# lib/platform-termux.sh — Termux/Android (aarch64) profile for setup-kde.sh
#
# Sourced by setup-kde.sh. Termux is an unprivileged Android app, so the world is
# fundamentally different from the Kubuntu profile:
#   - NO root / NO sudo            -> everything installs into $PREFIX (user-owned)
#   - NO /usr/local/bin            -> the one binary dir is $PREFIX/bin
#   - NO snap / snapd              -> snap apps come from pkg, source, or dropped
#   - NO systemd                   -> the NFS automount step is a no-op
#   - aarch64 (bionic libc)        -> glibc/x86_64 .deb apps can't run here
#   - KDE Plasma 6 + konsole are already installed (version-pinned), so we install
#     only named build deps and never `pkg upgrade` (which would disturb kf6/qt6).
#
# Defines the vars + p_* hooks the shared orchestrator expects. Relies on helpers
# (say/info/warn/have, link_bin, clone_or_update) and config vars (BUILD_DIR,
# CARGO_ROOT, *_REPO/_DIR) defined by setup-kde.sh — they resolve at call time.

# --- Platform vars (consumed by the shared code) ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"      # Termux prefix (user-owned)
BIN_DIR="$PREFIX/bin"                                     # the one binary location (no sudo)
SUDO=""                                                   # no root on Termux; ops run as us
BASH_SHEBANG="#!$PREFIX/bin/bash"                         # shebang baked into generated launchers
FRESH_PATH="$BIN_DIR/fresh"                               # the editor binary (Termux package)

# --- Build toolchains + dependencies (pkg/apt, no sudo) --------------------
# We use `apt-get install` (NOT `pkg upgrade`) so we only pull the named build
# deps and never bump the version-pinned KDE (kf6/qt6) libraries. rust+cargo and
# clang are already installed; golang is not, so the toolchain list adds it.
p_build_deps() {
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
  have cargo || warn "cargo not on PATH — bottom build will fail"
}

# --- Newsboat (Termux package) ---------------------------------------------
# Unlike the Kubuntu build, we do NOT build newsboat from source on Termux: its
# gettext-sys crate can't find a usable system libintl and falls back to an
# autotools build of vendored gettext that is glacially slow and ultimately
# fails on Android. Termux packages newsboat (2.43+) directly, so just install
# that — it's the same upstream, already cross-compiled for aarch64.
p_newsboat() {
  say "Installing Newsboat -> $BIN_DIR/newsboat"
  if have newsboat; then
    info "newsboat already installed ($(newsboat --version 2>/dev/null | head -1))"
  elif apt-get install -y newsboat; then
    info "newsboat installed from the Termux package"
  else
    warn "could not install the newsboat package; skipping"
  fi
}

# --- fresh-editor (Termux package) -----------------------------------------
# Do NOT build from source on Termux. The upstream (sinelaw/fresh) pulls several
# deps that exclude target_os="android" (trash, arboard) plus an embedded JS
# runtime (rquickjs-sys needs bindgen for aarch64), and the release profile's fat
# LTO OOMs rustc on a phone. Termux packages fresh-editor at the same version
# (0.4.1), already cross-compiled for aarch64 — just install it.
p_fresh_editor() {
  say "Installing fresh-editor -> $FRESH_PATH"
  if have fresh; then
    info "fresh already installed ($(fresh --version 2>/dev/null | head -1))"
  elif apt-get install -y fresh-editor; then
    info "fresh-editor installed from the Termux package"
  else
    warn "could not install the fresh-editor package; EDITOR will fall back to vim/nano"
  fi
}

# --- Make fresh-editor the default editor (via ~/.bashrc) ------------------
# On Termux there's no snap argv[0] dispatch problem (fresh is a real binary) and
# no /etc/environment / pam_env. We set EDITOR/VISUAL in ~/.bashrc (sourced by
# interactive shells, including the konsole sessions the menu icons spawn).
# Idempotent: a marked block is rewritten in place. Falls back to vim/nano if the
# fresh package didn't install a binary.
p_default_editor() {
  say "Making fresh-editor the default editor (via ~/.bashrc)"

  local editor="$FRESH_PATH"
  if [ ! -x "$FRESH_PATH" ]; then
    editor="$(command -v vim || command -v nano || echo "$FRESH_PATH")"
    warn "fresh not installed; defaulting EDITOR to $editor"
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

# --- JellyTerm install (shebang fixups + bash + skip system packages) ------
# The repo's scripts use `#!/usr/bin/env bash`, but Termux has no /usr/bin/env
# (it's $PREFIX/bin/env), so a direct `./scripts/install.sh` fails with "bad
# interpreter". termux-fix-shebang rewrites them; we also invoke the installer
# through `bash` so it runs regardless. --skip-system-packages: the installer's
# OS-package path uses sudo (absent on Termux) and we already have mpv.
p_jellyterm_install() {
  local dir="$1"
  have termux-fix-shebang && termux-fix-shebang "$dir/scripts/"*.sh 2>/dev/null || true
  if [ -f "$dir/scripts/install.sh" ]; then
    ( cd "$dir" && bash ./scripts/install.sh --yes --skip-system-packages --player mpv-terminal ) \
      || warn "JellyTerm installer reported an error; check it manually"
  else
    warn "skipping JellyTerm install (installer not present at $dir/scripts/install.sh)"
  fi
}

# --- Dunking Bird input backend (ydotool unavailable on Android) -----------
# ydotool is NOT packaged for Termux, and its uinput backend needs root/kernel
# access an unprivileged Android app doesn't have — so the auto-type feature
# won't function natively here. The TUI + xdotool/xclip still install (the build
# deps step handles those); we just warn.
p_dunkingbird_input() {
  have ydotool || warn "ydotool is unavailable on Termux (no uinput without root) — Dunking Bird's auto-type will not work"
}

# --- Extra apps: bottom (the snaps/duckstation/claude/rustdesk are Linux-only)
# Snap doesn't exist on Termux. firefox is already installed via pkg; thunderbird
# and duckstation aren't ported. bottom isn't packaged, so it's built from source.
p_extra_apps() {
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

# --- Tailscale -------------------------------------------------------------
# NOT in the Termux repos (checked main, x11, glibc, TUR), and there's no systemd
# to run tailscaled as a service. We attempt the package in case a repo adds it
# later; otherwise point at the official Android app.
p_vpn() {
  say "Installing Tailscale"
  if have tailscale; then info "tailscale already installed"; return; fi
  if apt-get install -y tailscale 2>/dev/null; then
    info "tailscale installed — run it manually:  tailscaled &   then:  tailscale up"
  else
    warn "tailscale is not packaged for Termux. Use the official Tailscale Android app instead:"
    warn "  https://play.google.com/store/apps/details?id=com.tailscale.ipn"
  fi
}

# --- NFS mounts: no-op on Termux (no systemd, no root mount) ---------------
p_mounts() { :; }

# --- Closing summary -------------------------------------------------------
p_final_notes() {
  cat <<EOF

Menu icons created: HEY, HEY Journal, Newsboat, ortop, Media Editor, Dunking Bird,
JellyTerm, qBittorrent TUI.
Binaries live in $BIN_DIR (Termux \$PREFIX/bin) — no sudo, no /usr/local/bin.
fresh-editor installed from the Termux package; bottom (btm) built from source.
fresh-editor is now the default editor (open a new shell, or: source ~/.bashrc).

Termux differences from the Kubuntu build:
  - Dropped (no Termux/aarch64 path): firefox (already installed), thunderbird,
    duckstation, claude-desktop, rustdesk, Motion Cues, and the systemd NFS mounts.
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

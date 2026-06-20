#!/data/data/com.termux/files/usr/bin/bash
#
# 20-kde.sh — install KDE Plasma 6 + Adreno (Turnip/Zink) GPU acceleration on
# Termux + Termux-X11, on an unrooted Android device.
#
# This is authored from the hard-won working blueprint (every fix, config, and
# the start/stop launchers) rather than a generic desktop installer. It started
# from techjarves/Linux-on-Samsung (MIT) — https://github.com/techjarves/Linux-on-Samsung
# — but that script's GPU step silently fell back to software rendering (swrast)
# and the desktop needed ~16 additional fixes to actually work. Those fixes are
# encoded here:
#   - install the Adreno Vulkan ICD (mesa-vulkan-icd-freedreno = Turnip), not swrast
#   - install plasma-desktop explicitly (plasma-workspace alone = empty desktop)
#   - libprocesscore.so.10 ABI shim (version skew vs libksysguard .so.11)
#   - kwin compositing OFF (no DRI3 / no /dev/dri on unrooted Android — crash-loops)
#   - app menu prefix, kicker+icontasks panel layout, HiDPI, kscreen autoload off
# The GPU env + dbus/x11/pulse bring-up live in the start-kde launcher (shipped here).
#
# Targets Snapdragon/Adreno (Turnip). On Exynos/Mali the Turnip ICD won't bind and
# the verification below will fail loudly — that device would need a swrast fallback.
#
# Does NOT start X. After this finishes: open the Termux-X11 Android app, then run
# ~/start-kde.

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/20-kde-assets"

say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '\033[0;32m    ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. Packages — KDE + GPU + apps + warning-fixers (one apt transaction).
# ---------------------------------------------------------------------------
# apt-get install (NOT `pkg upgrade`) so we pull only what we name and don't bump
# unrelated version-sensitive KDE libraries. Tolerant: if the batch install trips
# on one renamed/missing package, fall back to installing them individually so a
# single bad name can't block the rest.
install_kde_packages() {
  say "Installing KDE Plasma + Adreno GPU stack (apt)"
  apt-get update -y 2>/dev/null || apt-get update || warn "apt-get update reported an error; continuing"

  # Core desktop + GPU (required). plasma-desktop is the shell package — without it
  # plasmashell logs 'invalid corona' and you get an empty desktop.
  local core=(
    mesa-zink mesa-vulkan-icd-freedreno vulkan-loader-android
    dbus plasma-workspace plasma-desktop kwin-x11 systemsettings
  )
  # Apps that ship with the working setup.
  local apps=(
    konsole dolphin kate ark gwenview okular kcalc spectacle filelight
    kinfocenter plasma-systemmonitor firefox plasma-nm kde-gtk-config breeze-gtk
    kdeplasma-addons plasma-browser-integration kdialog kwalletmanager kdeconnect
    kdegraphics-thumbnailers print-manager plasma-workspace-wallpapers kmenuedit
    kactivitymanagerd kscreen
  )
  # Quiet the recurring KF6 warnings + verification/diagnostic tools.
  local extras=(
    xdg-desktop-portal xdg-desktop-portal-kde xorg-setxkbmap
    gsettings-desktop-schemas mesa-demos vulkan-tools
  )
  # Runtime: audio + the Termux-X11 server package (the Android APK is separate).
  local runtime=( pulseaudio termux-x11-nightly )

  local all=( "${core[@]}" "${apps[@]}" "${extras[@]}" "${runtime[@]}" )
  if apt-get install -y "${all[@]}"; then
    ok "installed ${#all[@]} packages"
  else
    warn "batch install hit an error; retrying packages individually"
    local p
    for p in "${all[@]}"; do
      apt-get install -y "$p" >/dev/null 2>&1 && info "ok: $p" || warn "failed: $p"
    done
  fi
}

# ---------------------------------------------------------------------------
# 2. libprocesscore.so.10 ABI shim (task manager / device notifier applets)
# ---------------------------------------------------------------------------
# plasma-desktop links libprocesscore.so.10 but libksysguard ships .so.11 (repo
# version skew). The imported KSysGuard symbols are identical across the two, so
# the symlink is ABI-safe. start-kde re-creates it after apt upgrades.
install_libprocesscore_shim() {
  say "Creating libprocesscore.so.10 ABI shim"
  if [ -e "$PREFIX/lib/libprocesscore.so.11" ]; then
    ln -sf libprocesscore.so.11 "$PREFIX/lib/libprocesscore.so.10"
    ok "libprocesscore.so.10 -> libprocesscore.so.11"
  elif [ -e "$PREFIX/lib/libprocesscore.so.10" ]; then
    info "libprocesscore.so.10 already present"
  else
    warn "neither libprocesscore.so.10 nor .so.11 found (libksysguard not installed yet?)"
  fi
}

# ---------------------------------------------------------------------------
# 3. KDE config: disable compositing + kscreen autoload (non-destructive).
# ---------------------------------------------------------------------------
# kwriteconfig6 sets just these keys without clobbering any other config the user
# has. Compositing can never use the GPU here (no DRI3/no /dev/dri) so it must be
# off or kwin crash-loops. kscreen autoload causes a mode-mismatch "flash" every
# login on Termux-X11's EDID-less virtual output.
configure_kde() {
  say "Configuring KDE (compositing off, kscreen autoload off)"
  if have kwriteconfig6; then
    kwriteconfig6 --file kwinrc  --group Compositing     --key Enabled  false
    kwriteconfig6 --file kded6rc --group Module-kscreen  --key autoload false
    ok "kwinrc [Compositing] Enabled=false; kded6rc [Module-kscreen] autoload=false"
  else
    warn "kwriteconfig6 not found; writing minimal config files directly"
    mkdir -p "$HOME/.config"
    printf '[Compositing]\nEnabled=false\n'        > "$HOME/.config/kwinrc"
    printf '[Module-kscreen]\nautoload=false\n'    > "$HOME/.config/kded6rc"
  fi
  # KScreen accumulates unmatchable saved configs on Termux-X11 — clear them so a
  # single fixed display uses the native mode with no startup flash.
  rm -rf "$HOME/.local/share/kscreen/"* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 4. Default panel layout: kicker (classic menu) + icontasks (task manager).
# ---------------------------------------------------------------------------
# Kickoff's in-place drill-down crash-loops plasmashell in this build, and the
# stock panel has no task manager (minimized windows vanish). Ship a layout that
# uses kicker + icontasks. Only install when absent so a re-run doesn't clobber a
# panel the user has since customized.
install_panel_layout() {
  say "Installing default panel layout (kicker + icontasks)"
  local dst="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  if [ -f "$dst" ]; then
    info "panel layout already present; leaving it (delete it to reset)"
  elif [ -f "$ASSETS/plasma-appletsrc" ]; then
    mkdir -p "$HOME/.config"
    cp "$ASSETS/plasma-appletsrc" "$dst"
    ok "installed panel layout -> $dst"
  else
    warn "panel layout asset missing ($ASSETS/plasma-appletsrc)"
  fi
}

# ---------------------------------------------------------------------------
# 5. start-kde / stop-kde launchers (verbatim from the working blueprint).
# ---------------------------------------------------------------------------
install_launchers() {
  say "Installing ~/start-kde and ~/stop-kde launchers"
  local f
  for f in start-kde stop-kde; do
    if [ -f "$ASSETS/$f" ]; then
      cp "$ASSETS/$f" "$HOME/$f"
      chmod 0755 "$HOME/$f"
      ok "~/$f"
    else
      warn "launcher asset missing ($ASSETS/$f)"
    fi
  done
}

# ---------------------------------------------------------------------------
# 6. Verification — fail loudly (the blueprint's hardest-won lesson).
# ---------------------------------------------------------------------------
# The original installer printed "Turnip ✓" unconditionally and hid the swrast
# fallback. Here we actually check. GL (glxinfo) needs a running X server, which
# isn't up during install, so that check is deferred to after ~/start-kde; we
# verify everything that can be checked headless.
verify_kde() {
  say "Verifying KDE + GPU install"
  local fail=0

  # Turnip Adreno Vulkan ICD — works headless (Vulkan needs no X).
  if have vulkaninfo && vulkaninfo --summary 2>/dev/null | grep -qi 'Turnip Adreno'; then
    ok "Vulkan: Turnip Adreno present (hardware GPU)"
  elif [ -f "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]; then
    warn "freedreno ICD installed but vulkaninfo didn't report Turnip (check 'vulkaninfo --summary')"
  else
    warn "Turnip Adreno NOT detected — GL would fall back to software (swrast). On Snapdragon, ensure mesa-vulkan-icd-freedreno installed."
    fail=1
  fi

  # plasma-desktop shell package (else empty desktop).
  if [ -d "$PREFIX/share/plasma/shells/org.kde.plasma.desktop" ]; then
    ok "plasma-desktop shell present"
  else
    warn "org.kde.plasma.desktop shell MISSING — install plasma-desktop"
    fail=1
  fi

  # ABI shim.
  if [ -L "$PREFIX/lib/libprocesscore.so.10" ] || [ -e "$PREFIX/lib/libprocesscore.so.10" ]; then
    ok "libprocesscore.so.10 present"
  else
    warn "libprocesscore.so.10 missing (task manager applet will fail to load)"
  fi

  # Key binaries.
  local b miss=""
  for b in startplasma-x11 konsole firefox systemsettings setxkbmap; do
    have "$b" || miss="$miss $b"
  done
  [ -z "$miss" ] && ok "key binaries present (startplasma-x11, konsole, firefox, systemsettings, setxkbmap)" \
                 || warn "missing binaries:$miss"

  if [ "$fail" = 1 ]; then
    warn "KDE verification found a HARD problem above — the desktop may not work until it's resolved."
  else
    ok "headless checks passed. After launch, verify GL: DISPLAY=:0 GALLIUM_DRIVER=zink MESA_LOADER_DRIVER_OVERRIDE=zink glxinfo | grep 'OpenGL renderer'  ->  zink (Turnip ...)"
  fi
}

main() {
  install_kde_packages
  install_libprocesscore_shim
  configure_kde
  install_panel_layout
  install_launchers
  verify_kde

  say "KDE stage done."
  cat <<EOF

KDE Plasma 6 + Adreno (Turnip/Zink) GPU is installed and configured.
To launch the desktop:
  1. Open the Termux-X11 Android app.
  2. In Termux, run:  ~/start-kde
  3. Stop it with:    ~/stop-kde
Session log (best debugging tool): ~/kde.log
EOF
}

main "$@"

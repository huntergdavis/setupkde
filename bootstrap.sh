#!/data/data/com.termux/files/usr/bin/bash
#
# bootstrap.sh — rebuild Hunter's entire Termux environment on a fresh device,
# unattended, in three phases:
#
#   1. Claude Code   (stages/10-claude.sh — ferrumclaudepilgrim/claude-code-android:
#                     official linux-arm64 binary patched via glibc-runner to run on
#                     Android/bionic, with a self-updating wrapper)
#   2. KDE + GPU     (stages/20-kde.sh — KDE Plasma 6 + Adreno Turnip/Zink on Termux-X11,
#                     authored from the working blueprint; origin techjarves/Linux-on-Samsung)
#   3. Apps + icons  (setup-kde.sh — HEY, Newsboat, ortop, qbt-tui, JellyTerm, Media
#                     Editor, Dunking Bird, fresh-editor, bottom + KDE menu entries)
#
# PREREQUISITES (install these yourself first — they are Android apps / a base pkg):
#   - Termux            (from F-Droid / GitHub)
#   - Termux:X11 app    + `pkg install termux-x11-nightly` (the KDE stage installs the pkg)
#   - Termux:API app    (+ `pkg install termux-api` for the CLI bridge)
#   - `pkg install git` (to clone this repo)
#
# Then:  git clone <repo> && cd setupkde && bash bootstrap.sh
#
# Runs unattended. Each phase is tolerant (warn-and-continue) so one failure
# doesn't abort the rest. Skip phases with env toggles, e.g.:
#   SKIP_CLAUDE=1 bash bootstrap.sh        (also SKIP_KDE=1, SKIP_APPS=1)
#
# A short list of inherently-manual steps (logins, opening the X11 app, secrets)
# is printed at the end.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

c_say()  { printf '\n\033[1;35m######## %s ########\033[0m\n' "$*"; }
say()    { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info()   { printf '    %s\n' "$*"; }
ok()     { printf '\033[0;32m    ✓ %s\033[0m\n' "$*"; }
warn()   { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
have()   { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  say "Preflight checks"
  [ -n "${PREFIX:-}" ] && [ -d "/data/data/com.termux" ] \
    || { warn "This doesn't look like Termux (\$PREFIX/com.termux missing). Aborting."; exit 1; }
  [ "$(uname -m)" = "aarch64" ] \
    || { warn "aarch64 only; uname -m = $(uname -m). Aborting."; exit 1; }
  ok "Termux on aarch64"

  # git/curl are needed by the stages (and you needed git to clone this). Ensure them.
  if ! have git || ! have curl; then
    info "installing git/curl"
    apt-get install -y git curl >/dev/null 2>&1 || warn "could not install git/curl"
  fi
  have git && have curl && ok "git + curl present"

  # Companion apps are manual prerequisites — warn (non-fatal) if not detectable.
  have termux-x11 || warn "termux-x11 not found yet (the KDE stage installs termux-x11-nightly; the Termux:X11 *app* must be installed separately)"
  have termux-battery-status || warn "termux-api CLI not found (install the Termux:API app + 'pkg install termux-api' for device features)"
}

# Run a phase script, tolerant. $1=label, rest=command.
run_phase() {
  local label="$1"; shift
  c_say "PHASE: $label"
  if "$@"; then
    ok "phase '$label' finished"
  else
    warn "phase '$label' exited non-zero — continuing to the next phase"
  fi
}

phase_claude() {
  # The installer asks two y/n questions (both default Yes); `yes` keeps it unattended.
  yes | bash "$SCRIPT_DIR/stages/10-claude.sh"
}

phase_kde() {
  bash "$SCRIPT_DIR/stages/20-kde.sh"
}

phase_apps() {
  bash "$SCRIPT_DIR/setup-kde.sh"
}

final_summary() {
  c_say "BOOTSTRAP COMPLETE — manual steps remaining"
  cat <<'EOF'

Everything that can be automated is done. These steps are inherently manual:

  CLAUDE
    • Authenticate:        claude        (then run /login inside it)
    • Storage permission:  termux-setup-storage

  KDE DESKTOP (GPU-accelerated)
    • Open the Termux:X11 Android app.
    • Start the desktop:   ~/start-kde      (stop with ~/stop-kde)
    • After it's up, confirm hardware GL:
        DISPLAY=:0 GALLIUM_DRIVER=zink MESA_LOADER_DRIVER_OVERRIDE=zink glxinfo | grep "OpenGL renderer"
      -> should say  zink (Turnip Adreno (TM) 730).  Log: ~/kde.log

  APP SECRETS / LOGINS (not stored in the repo)
    • ~/.config/ortop/env       OpenRouter API keys (ortop)
    • ~/.config/qbt-tui/env     qBittorrent WebUI creds (stub created by setup-kde.sh)
    • ~/.config/newsboat/urls   your FreshRSS endpoint + credentials
    • hey                       run it and sign in
    • jellyterm                 run it and sign in
    • GitHub SSH key            needed to clone the private 'media' repo

EOF
}

main() {
  c_say "Termux full-environment bootstrap (Claude -> KDE+GPU -> apps)"
  preflight

  if [ "${SKIP_CLAUDE:-0}" = 1 ]; then say "Skipping Claude phase (SKIP_CLAUDE=1)"; else run_phase "Claude Code" phase_claude; fi
  if [ "${SKIP_KDE:-0}"    = 1 ]; then say "Skipping KDE phase (SKIP_KDE=1)";       else run_phase "KDE + GPU"   phase_kde;    fi
  if [ "${SKIP_APPS:-0}"   = 1 ]; then say "Skipping apps phase (SKIP_APPS=1)";     else run_phase "Apps + icons" phase_apps;   fi

  final_summary
}

main "$@"

#!/data/data/com.termux/files/usr/bin/bash
# claude-code-android installer (Termux on aarch64 Android).
#
# Installs Anthropic's official linux-arm64 claude binary, patched via
# glibc-runner so it runs under Android's bionic kernel. A wrapper at
# $PREFIX/bin/claude auto-checks for new versions once per day on launch
# (--update-now forces an immediate check) and re-patches if needed.
#
# Two yes/no questions up front, then unattended. Approx 5-10 minutes
# depending on connection. The first download is ~233 MB.
#
# Re-running this script is safe. On a device that already has the v2.9
# launcher it refreshes the launcher in place (no re-download); on a pinned
# npm install it routes you to migrate.sh; otherwise it installs while
# preserving any existing ~/.claude. Day-to-day updates happen automatically
# through the launcher.
#
# Tracking the upstream issue this works around:
#   https://github.com/anthropics/claude-code/issues/50270

set -euo pipefail

info(){ printf '\033[0;36m[info]\033[0m  %s\n' "$1"; }
ok(){   printf '\033[0;32m[ok]\033[0m    %s\n' "$1"; }
warn(){ printf '\033[0;33m[warn]\033[0m  %s\n' "$1" >&2; }
fail(){ printf '\033[0;31m[fail]\033[0m  %s\n' "$1" >&2; exit 1; }

# --- Preflight ---
[ -z "${PREFIX:-}" ] && fail "PREFIX unset. Run this inside Termux, not adb shell."
[ "$(uname -m)" = "aarch64" ] || fail "aarch64 only. uname -m reports: $(uname -m)"

# Android's low-memory killer can SIGKILL the whole process tree during the heavy
# glibc install if this runs inside a claude session under memory pressure. A
# plain Termux shell is safer.
if [ -n "${CLAUDE_CODE_EXECPATH:-}" ] || [ -n "${CLAUDECODE:-}" ]; then
  warn "You appear to be running inside a claude session; Android may kill the"
  warn "install under memory pressure. A plain Termux shell is safer."
  read -r -p "Continue anyway? [y/N] " LMK
  case "${LMK,,}" in y|yes) ;; *) fail "Stopped. Open a fresh Termux session and re-run." ;; esac
fi

# --- Classify any prior claude state, then route or pick an install mode ---
# One classifier covers every real prior state instead of a blunt
# "anything-exists, refuse" gate. Outcomes:
#   already_v29  complete v2.9.0 wrapper present        -> nothing to do
#   pinned       npm @anthropic-ai/claude-code present  -> migrate.sh (safe npm removal)
#   inplace      official native install, or leftover ~/.claude with no working
#                binary                                 -> install here, preserving data
#   fresh        no claude footprint at all             -> clean install
CC_NPM_PKG="$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
CC_BINLINK="$PREFIX/bin/claude"
CC_VERSIONS="$HOME/.local/share/claude/versions"

cc_has_versions(){ [ -d "$CC_VERSIONS" ] && ls "$CC_VERSIONS"/*.*.* >/dev/null 2>&1; }
cc_is_wrapper(){ [ -f "$CC_BINLINK" ] && [ ! -L "$CC_BINLINK" ]; }
cc_is_npm_link(){ [ -L "$CC_BINLINK" ] && readlink "$CC_BINLINK" | grep -q 'node_modules/@anthropic-ai/claude-code'; }

if cc_has_versions && cc_is_wrapper; then
  state="already_v29"
elif [ -d "$CC_NPM_PKG" ] || cc_is_npm_link; then
  state="pinned"
elif cc_has_versions || [ -e "$HOME/.local/bin/claude" ] || [ -d "$HOME/.local/share/claude" ] \
     || [ -e "$HOME/.claude" ] || [ -e "$HOME/.claude.json" ]; then
  state="inplace"
else
  state="fresh"
fi

if [ "$state" = already_v29 ]; then
  # An existing v2.9 launcher is present. The launcher only changes when this
  # script rewrites it (the daily auto-update refreshes the binary, not the
  # launcher), so re-running install.sh is how an existing install picks up
  # launcher improvements such as the self-healing rollback. Refresh in place:
  # skip the heavy first-time steps (packages, glibc, binary download) and go
  # straight to rewriting the launcher and settings.
  info "existing v2.9 install detected; refreshing the launcher to the current version"
  REFRESH=1
  PATCHELF="$PREFIX/glibc/bin/patchelf"
  GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  { [ -x "$PATCHELF" ] && [ -f "$GLIBC_LD" ]; } || fail "glibc-runner is missing; cannot refresh the launcher. Install it (pkg install glibc-runner patchelf-glibc) and re-run."
  VERSIONS_DIR="$HOME/.local/share/claude/versions"
  WRAPPER="$PREFIX/bin/claude"
  BINARY="(existing install retained)"
  LATEST="(existing)"
  FRESH=0
  RECOMMENDED=0
  mkdir -p "$HOME/.claude"
fi
if [ "$state" = pinned ]; then
  info "An older pinned v2.x install is present."
  info "To upgrade WITHOUT losing your sessions, login, or settings, use the"
  info "migration script instead of this installer:"
  printf '\n    curl -fsSL https://raw.githubusercontent.com/ferrumclaudepilgrim/claude-code-android/main/migrate.sh -o migrate.sh\n    bash migrate.sh\n\n'
  info "This installer does not remove npm installs; migrate.sh does that safely."
  exit 0
fi

# Everything from here to the settings step is the heavy first-time install
# (questions, packages, glibc, the ~233 MB binary download). On a refresh of an
# existing v2.9 launcher, skip all of it and go straight to rewriting the
# launcher and settings.
if [ "${REFRESH:-0}" != 1 ]; then

cat <<BANNER

  claude-code-android installer
  =============================
  Two yes/no questions up front, then unattended install (5-10 minutes).
  When it finishes, you'll type 'claude' to start.

BANNER

# --- Q1: Fresh Termux? ---
cat <<'Q1'
Q1. Is this a fresh Termux install?

  Brand new Termux installs need their package index brought up to date
  before installing anything else. The script refreshes the package index
  and upgrades base packages, taking the new defaults for any system config
  files that ship updates. Safe on a fresh Termux: nothing of yours to lose yet.

  If you have been using Termux a while and customized system configs
  under $PREFIX/etc/ (sshd_config, openssl.cnf, etc.), say no and the
  script will keep your changes during the upgrade.

  This choice applies only to THIS install run. It does NOT change how
  your future pkg upgrade commands behave.

Q1
read -r -p "Fresh Termux? [Y/n] " Q1
Q1="${Q1:-Y}"
case "${Q1,,}" in
  y|yes) FRESH=1 ;;
  n|no)  FRESH=0 ;;
  *) fail "Q1: answer 'y' or 'n'; got '$Q1'" ;;
esac
ok "Q1: $([ $FRESH = 1 ] && echo fresh || echo keep)"
echo

# --- Q2: Recommended packages? ---
cat <<'Q2'
Q2. Install recommended packages?

  Claude Code launches with just the patched binary, but many of its
  built-in tools assume common Linux utilities exist. Without these you
  will hit "command not found" errors when:

    - The Bash tool tries to run git, curl, jq, python, make
    - Claude tries to clone a repo, build with clang, or parse JSON
    - You want SSH from inside a Claude session (openssh client)

  These are the same utilities a typical PC running Claude Code already
  has. Without them on Termux, you spend the first hour hitting
  "pkg install <thing>" prompts.

  Packages: git, gh, wget, jq, python, openssh, tree, proot, termux-api,
  proot-distro, make, clang, file, xxd, htop, bat, fzf (17 packages,
  roughly 200 MB additional disk).

Q2
read -r -p "Install recommended packages? [Y/n] " Q2
Q2="${Q2:-Y}"
case "${Q2,,}" in
  y|yes) RECOMMENDED=1 ;;
  n|no)  RECOMMENDED=0 ;;
  *) fail "Q2: answer 'y' or 'n'; got '$Q2'" ;;
esac
ok "Q2: $([ $RECOMMENDED = 1 ] && echo yes || echo no)"
echo

# --- Pre-install: fresh asserts, or in-place preservation ---
if [ "$state" = inplace ]; then
  # A prior claude config is present (official native install, or a leftover
  # ~/.claude after a removed claude). Install in place and keep the user's
  # data: ~/.claude (sessions, login, agents, hooks) is never removed, and
  # settings.json is merged, not overwritten.
  RUNNING="$( { pgrep -x claude; pgrep -f '@anthropic-ai/claude-code'; } 2>/dev/null | sort -un | grep -vw "$$" | grep -vw "${PPID:-0}" | tr '\n' ' ' || true )"
  if [ -n "${RUNNING// /}" ]; then
    fail "claude appears to be running (PIDs: $RUNNING). Close all claude sessions, then re-run."
  fi
  if [ -e "$HOME/.claude/settings.json" ]; then
    cp -a "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.pre-v29.bak" 2>/dev/null \
      && ok "backed up existing settings.json -> settings.json.pre-v29.bak"
  fi
  ok "existing claude config will be preserved (installing in place)"
else
  # Fresh: the classifier already proved there is no claude footprint; these are
  # belt-and-suspenders guards against a race or a partial earlier run.
  [ -e "$PREFIX/bin/claude" ]        && fail "\$PREFIX/bin/claude already exists. Use migrate.sh, or 'termux-reset' for a clean install."
  [ -e "$HOME/.local/share/claude" ] && fail "\$HOME/.local/share/claude already exists. Use migrate.sh for an in-place upgrade."
  ok "clean state confirmed"
fi

# --- apt non-interactive options based on Q1 ---
export DEBIAN_FRONTEND=noninteractive
if [ "$FRESH" = 1 ]; then
  APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew"
else
  APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
fi

# --- Pin a Termux mirror if none is selected (avoids an interactive stall) ---
# On a brand-new Termux with no chosen mirror, the package tooling can stop on a
# mirror-selection prompt. Selecting the default first keeps the run unattended.
# Only acts when nothing is chosen yet, so it never overrides a working mirror.
if [ ! -e "$PREFIX/etc/termux/chosen_mirrors" ] && [ -e "$PREFIX/etc/termux/mirrors/default" ]; then
  ln -sf "$PREFIX/etc/termux/mirrors/default" "$PREFIX/etc/termux/chosen_mirrors" 2>/dev/null || true
fi

# --- Termux: bring base packages current ---
# apt-get (not pkg/apt) for the scripted steps: apt-get has a stable CLI and
# does not print apt's "does not have a stable CLI interface" script warning.
info "apt-get update"
apt-get update $APT_OPTS >/dev/null || fail "apt-get update failed"

info "apt-get full-upgrade (fixes any bootstrap/current library mismatches)"
apt-get full-upgrade $APT_OPTS >/dev/null || fail "apt-get full-upgrade failed"

info "apt-get install curl jq"
apt-get install $APT_OPTS curl jq >/dev/null || fail "apt-get install curl/jq failed"
ok "base tools installed"

# --- glibc-runner + patchelf-glibc ---
info "apt-get install glibc-repo (enables Termux glibc-packages source)"
apt-get install $APT_OPTS glibc-repo >/dev/null || fail "glibc-repo install failed"
apt-get update $APT_OPTS >/dev/null || fail "apt-get update after glibc-repo failed"

info "apt-get install glibc-runner patchelf-glibc (~50 MB download)"
apt-get install $APT_OPTS glibc-runner patchelf-glibc >/dev/null || fail "glibc-runner install failed"

PATCHELF="$PREFIX/glibc/bin/patchelf"
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
[ -x "$PATCHELF" ] || fail "patchelf not found at $PATCHELF after install"
[ -f "$GLIBC_LD" ] || fail "glibc ld.so not found at $GLIBC_LD after install"
ok "glibc-runner + patchelf installed"

# --- Resolve latest claude version, download, verify, patch ---
info "resolving latest claude version from npm registry"
LATEST="$(curl -fsSL --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | jq -r .version 2>/dev/null)"
if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
  fail "could not query npm registry for the latest claude version"
fi
if ! printf '%s' "$LATEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  fail "npm registry returned an unexpected version string: $LATEST"
fi
ok "latest claude version: $LATEST"

VERSIONS_DIR="$HOME/.local/share/claude/versions"
BINARY="$VERSIONS_DIR/$LATEST"
WRAPPER="$PREFIX/bin/claude"
mkdir -p "$VERSIONS_DIR" "$HOME/.claude"

DL_BASE="https://downloads.claude.ai/claude-code-releases/$LATEST"

info "downloading $LATEST linux-arm64 binary (~233 MB)"
curl -fsSL --max-time 300 "$DL_BASE/linux-arm64/claude" -o "$BINARY.tmp" \
  || fail "binary download failed"

info "verifying checksum against published manifest"
EXP="$(curl -fsSL --max-time 10 "$DL_BASE/manifest.json" 2>/dev/null | jq -er '.platforms["linux-arm64"].checksum' 2>/dev/null || true)"
ACT="$(sha256sum "$BINARY.tmp" | cut -d' ' -f1)"
if [ -z "$EXP" ]; then
  rm -f "$BINARY.tmp"
  fail "could not read checksum from manifest"
fi
if [ "$EXP" != "$ACT" ]; then
  rm -f "$BINARY.tmp"
  fail "checksum mismatch: expected $EXP, got $ACT"
fi
ok "checksum verified"

chmod +x "$BINARY.tmp"
LD_PRELOAD='' "$PATCHELF" --set-interpreter "$GLIBC_LD" "$BINARY.tmp" \
  || fail "patchelf failed to set ELF interpreter"
mv "$BINARY.tmp" "$BINARY"
ok "binary patched and installed at $BINARY"

# Smoke-test the freshly installed binary. Some upstream releases crash on full
# launch under Android's seccomp filter while still passing "--version" (Android
# 10 statx -> SIGSYS; Bun 1.4 epoll_pwait2 -> SIGSEGV). Probe with --init-only
# (it boots the full runtime and exits 0 on a healthy binary). On pass, record
# it as verified so the wrapper's first launch skips the re-test; on fail, warn
# with a working path forward instead of a cryptic crash on first launch.
info "smoke-testing the installed binary"
ST_ERR="$VERSIONS_DIR/.smoke-stderr"
ST_HOME="$VERSIONS_DIR/.smoke-home"
rm -rf "$ST_HOME"; mkdir -p "$ST_HOME/.claude"
HOME="$ST_HOME" LD_PRELOAD='' timeout -s KILL 25 "$BINARY" --init-only </dev/null >/dev/null 2>"$ST_ERR"
ST_RC=$?
rm -rf "$ST_HOME"
if { [ "$ST_RC" -gt 128 ] && [ "$ST_RC" -le 159 ]; } || [ "$ST_RC" -eq 124 ] \
   || [ "$ST_RC" -eq 126 ] || [ "$ST_RC" -eq 127 ] \
   || grep -qE 'Bad system call|oh no: Bun has crashed|panic\(|bun\.report' "$ST_ERR" 2>/dev/null; then
  rm -f "$ST_ERR"
  warn "Claude Code $LATEST crashes on this device. This is a known upstream"
  warn "regression in some releases under Android's seccomp filter, not an install"
  warn "problem. The install is complete, but this version will not launch here."
  warn "To get a working Claude Code now:"
  warn "  - run  ./install-pinned.sh   to pin a known-good build, or"
  warn "  - run Claude Code inside proot-distro Ubuntu (see the README)."
else
  rm -f "$ST_ERR"
  printf '%s\n' "$LATEST" > "$VERSIONS_DIR/.verified"
  ok "binary launches cleanly on this device"
fi

fi  # end heavy first-time install (skipped on a refresh)

# --- ~/.claude/settings.json ---
# autoUpdates:false disables claude's in-process updater; the wrapper handles
# updates instead. No env.LD_PRELOAD: a bionic preload set here leaks into the
# Bash tool's subprocesses and breaks claude's bundled grep/rg/ugrep, which
# re-exec the raw glibc binary and then mis-resolve libc. The wrapper already
# clears LD_PRELOAD before exec, so the binary itself is unaffected.
# Known trade-off: without the preload, claude's subprocesses also lose
# termux-exec, so a directly-run "#!/usr/bin/env ..." script cannot find its
# interpreter (Android has no /usr/bin/env). Grep correctness wins; the common
# cases (bash/python/node FILE, and tools called by name) still work.
SF="$HOME/.claude/settings.json"
if [ -e "$SF" ]; then
  TMP="$(mktemp "${TMPDIR:-$PREFIX/tmp}/cc-settings.XXXXXX")"
  if jq 'del(.env.LD_PRELOAD) | .autoUpdates=false | if (.env // {}) == {} then del(.env) else . end' "$SF" > "$TMP" 2>/dev/null; then
    cat "$TMP" > "$SF"     # write THROUGH a possible symlink rather than replacing it
    rm -f "$TMP"
    ok "settings.json updated (existing keys preserved; stale LD_PRELOAD removed)"
  else
    rm -f "$TMP"
    warn "settings.json is not valid JSON; leaving it untouched."
    warn "Set  \"autoUpdates\": false  by hand and remove any env.LD_PRELOAD."
  fi
else
  cat > "$SF" <<'EOF'
{
  "autoUpdates": false
}
EOF
  ok "settings.json written"
fi

# --- Wrapper at $PREFIX/bin/claude ---
# Once per 24h on launch, checks npm for a newer version. If found,
# downloads, verifies checksum, patchelfs, swaps. --update-now forces
# an immediate check, bypassing the rate limit. Any failure (network,
# checksum, patchelf) is reported to stderr and the cached binary is
# used. Self-heals the ELF interpreter every launch. Unsets LD_PRELOAD
# before exec so the glibc binary doesn't crash on libtermux-exec's
# unversioned libc.so dependency.
cat > "$WRAPPER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
VERSIONS_DIR="$VERSIONS_DIR"
GLIBC_LD="$GLIBC_LD"
PATCHELF="$PATCHELF"
STAMP="\$VERSIONS_DIR/.last-update-check"
BLOCKLIST="\$VERSIONS_DIR/.blocklist"
VERIFIED="\$VERSIONS_DIR/.verified"
RATE_LIMIT=86400

# Smoke test: returns 0 if the binary launches on this device, 1 if it crashes
# or hangs. Why this exists: upstream has shipped binaries that pass "--version"
# but die on full launch under Android's seccomp filter (Android 10 statx ->
# SIGSYS; Bun 1.4 epoll_pwait2 -> SIGSEGV). We probe the full runtime with
# --init-only (it boots the HTTP thread and worker pool and exits 0 offline on
# a healthy binary) and refuse to promote or run anything that dies. If a
# future release drops --init-only, the probe returns a benign non-zero (no
# signal, no crash banner), treated as inconclusive: not rejected, never a
# false fail.
smoke_test() {
  st_err="\$VERSIONS_DIR/.smoke-stderr"
  st_home="\$VERSIONS_DIR/.smoke-home"
  if [ ! -s "\$1" ]; then return 1; fi
  # Probe in an isolated HOME so we never load the user's hooks (--init-only
  # fires SessionStart/SessionEnd), never depend on login, and never write to
  # the real ~/.claude. The crash we detect is a syscall, independent of config.
  rm -rf "\$st_home"; mkdir -p "\$st_home/.claude"
  HOME="\$st_home" LD_PRELOAD= timeout -s KILL 25 "\$1" --init-only </dev/null >/dev/null 2>"\$st_err"
  st_rc=\$?
  rm -rf "\$st_home"
  if [ "\$st_rc" -gt 128 ] && [ "\$st_rc" -le 159 ]; then rm -f "\$st_err"; return 1; fi
  if [ "\$st_rc" -eq 124 ]; then rm -f "\$st_err"; return 1; fi
  if [ "\$st_rc" -eq 126 ] || [ "\$st_rc" -eq 127 ]; then rm -f "\$st_err"; return 1; fi
  if grep -qE 'Bad system call|oh no: Bun has crashed|panic\(|bun\.report' "\$st_err" 2>/dev/null; then
    rm -f "\$st_err"; return 1
  fi
  rm -f "\$st_err"
  return 0
}

force_update=0
args=()
for a in "\$@"; do
  if [ "\$a" = "--update-now" ]; then
    force_update=1
  else
    args+=("\$a")
  fi
done

should_check=0
if [ "\$force_update" = 1 ]; then
  should_check=1
elif [ ! -f "\$STAMP" ]; then
  should_check=1
else
  now=\$(date +%s)
  last=\$(stat -c%Y "\$STAMP" 2>/dev/null || echo 0)
  [ \$((now - last)) -ge \$RATE_LIMIT ] && should_check=1
fi

if [ "\$should_check" = 1 ]; then
  latest=\$(curl -fsSL --max-time 5 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | jq -r .version 2>/dev/null || echo "")
  if [ -n "\$latest" ] && printf '%s' "\$latest" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\$'; then
    new_bin="\$VERSIONS_DIR/\$latest"
    if [ ! -f "\$new_bin" ] && ! grep -qxF "\$latest" "\$BLOCKLIST" 2>/dev/null; then
      dl="https://downloads.claude.ai/claude-code-releases/\$latest"
      if curl -fsSL --max-time 300 "\$dl/linux-arm64/claude" -o "\$new_bin.tmp" 2>/dev/null; then
        exp=\$(curl -fsSL --max-time 5 "\$dl/manifest.json" 2>/dev/null | jq -er '.platforms["linux-arm64"].checksum' 2>/dev/null || echo "")
        act=\$(sha256sum "\$new_bin.tmp" | cut -d' ' -f1)
        if [ -n "\$exp" ] && [ "\$exp" = "\$act" ]; then
          chmod +x "\$new_bin.tmp"
          if LD_PRELOAD= "\$PATCHELF" --set-interpreter "\$GLIBC_LD" "\$new_bin.tmp" 2>/dev/null; then
            if smoke_test "\$new_bin.tmp"; then
              mv "\$new_bin.tmp" "\$new_bin"
              printf '%s\n' "\$latest" > "\$VERIFIED"
              # Retain N-1 (latest + previous) for rollback.
              prev=\$(ls -1 "\$VERSIONS_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\$' | sort -V | tail -2 | head -1)
              for old in "\$VERSIONS_DIR"/*; do
                base=\$(basename "\$old")
                [ -f "\$old" ] && [ "\$base" != "\$latest" ] && [ "\$base" != "\$prev" ] && rm -f "\$old"
              done
            else
              rm -f "\$new_bin.tmp"
              printf '%s\n' "\$latest" >> "\$BLOCKLIST"
              echo "[claude] update: \$latest crashes on launch (failed smoke test), keeping cached" >&2
            fi
          else
            rm -f "\$new_bin.tmp"
            echo "[claude] update: patchelf failed on \$latest, using cached" >&2
          fi
        else
          rm -f "\$new_bin.tmp"
          echo "[claude] update: checksum mismatch on \$latest, using cached" >&2
        fi
      else
        echo "[claude] update: download failed, using cached" >&2
      fi
    fi
  else
    echo "[claude] update: could not query npm registry, using cached" >&2
  fi
  touch "\$STAMP"
fi

# Pick the highest installed version that actually launches on this device.
# Self-healing rollback: skip blocklisted versions; the already-verified-good
# version runs with no re-test (zero startup cost); any other candidate is
# re-patched and smoke-tested, and if it crashes it is blocklisted and we fall
# back to the next-highest. This rescues a device that auto-updated to a binary
# that crashes here (e.g. a bad release that landed before this wrapper shipped)
# with no user action.
verified=\$(cat "\$VERIFIED" 2>/dev/null || echo "")
bin=""
for cand in \$(ls -1 "\$VERSIONS_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\$' | sort -Vr); do
  grep -qxF "\$cand" "\$BLOCKLIST" 2>/dev/null && continue
  cpath="\$VERSIONS_DIR/\$cand"
  [ -f "\$cpath" ] || continue
  if [ "\$cand" = "\$verified" ]; then bin="\$cpath"; break; fi
  interp=\$(LD_PRELOAD= "\$PATCHELF" --print-interpreter "\$cpath" 2>/dev/null || echo unknown)
  [ "\$interp" = "\$GLIBC_LD" ] || LD_PRELOAD= "\$PATCHELF" --set-interpreter "\$GLIBC_LD" "\$cpath" 2>/dev/null
  if smoke_test "\$cpath"; then
    printf '%s\n' "\$cand" > "\$VERIFIED"
    bin="\$cpath"
    break
  else
    echo "[claude] \$cand crashes on this device; rolling back to the previous version" >&2
    printf '%s\n' "\$cand" >> "\$BLOCKLIST"
  fi
done
if [ -z "\$bin" ]; then
  echo "[claude] no working claude binary found in \$VERSIONS_DIR. Re-run install.sh." >&2
  exit 1
fi

unset LD_PRELOAD
exec "\$bin" "\${args[@]}"
EOF
chmod +x "$WRAPPER"
ok "wrapper installed at $WRAPPER"

# --- Native-install launcher discovery ---
# Claude Code sees the binary under ~/.local/share/claude/versions, treats it as
# a native install, and expects a launcher at ~/.local/bin/claude with
# ~/.local/bin on PATH. Without them it prints "Native installation ... not in
# your PATH" notices at startup. Set both up the way claude's own message
# prescribes. The launcher points at this wrapper so every invocation still
# routes through it; ~/.local/bin is appended to PATH so $PREFIX/bin stays first.
mkdir -p "$HOME/.local/bin"
ln -sfn "$WRAPPER" "$HOME/.local/bin/claude"
if ! grep -Fq 'native-install launcher discovery' "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# claude-code-android: native-install launcher discovery\nexport PATH="$PATH:$HOME/.local/bin"\n' >> "$HOME/.bashrc"
  ok "added ~/.local/bin to PATH in ~/.bashrc"
else
  ok "PATH already includes ~/.local/bin in ~/.bashrc"
fi

# --- Recommended packages (Q2) ---
if [ "$RECOMMENDED" = 1 ]; then
  info "installing recommended packages (this is the longest step)"
  apt-get install $APT_OPTS git gh wget jq python openssh tree proot \
    termux-api proot-distro make clang file xxd htop bat fzf >/dev/null \
    || fail "recommended package install failed"
  ok "recommended packages installed"
fi

# --- Verify ---
hash -r 2>/dev/null || true
if VER="$(claude --version 2>&1)"; then
  ok "claude --version: $VER"
elif [ "${REFRESH:-0}" = 1 ]; then
  warn "the refreshed launcher could not find a working Claude Code version on this device."
  warn "run  ./install-pinned.sh  to pin a known-good build, or use proot-Ubuntu (see the README)."
else
  fail "claude --version failed: $VER"
fi

# --- Done ---
cat <<DONE

Install complete.

  Wrapper:   $WRAPPER
  Binary:    $BINARY
  Settings:  $HOME/.claude/settings.json

The wrapper auto-checks for a new claude release once per day on launch.
To force an immediate check at any time:  claude --update-now

Open a new Termux session (so the updated PATH is active and startup is
warning-free), then type:

  claude

DONE

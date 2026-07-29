#!/usr/bin/env bash
#
# TWG Security — NX Mediaserver one-line bootstrap
# ------------------------------------------------
# Provisions a fresh Ubuntu/Debian server with the Network Optix NX
# mediaserver (Witness or Meta), plus optional Webmin, GPU drivers, timezone,
# and NTP.
#
# The SCREEN shows a clean, branded status interface (one line per step, a
# spinner while it runs, a ✔/✖ when it finishes). The noisy apt/dpkg/curl
# output no longer scrolls past — it's tucked into a full plain-text LOG FILE
# for later debugging. Think of it like an airline departure board: the board
# shows "Boarding / Departed"; the full flight manifest lives in the back
# office (the log).
#
# Usage (as root):
#   curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
#
# Every knob is an environment variable and can be overridden inline, e.g.:
#   curl -fsSL <url> | sudo NX_EDITION=meta INSTALL_WEBMIN=true bash
#
# When run from a real terminal an interactive MENU appears so a tech can pick
# options; pass NONINTERACTIVE=true (or run with no TTY, e.g. plain curl|bash
# in automation) to skip the menu and use the env-var defaults.
#
# Honors NO_COLOR (https://no-color.org): set it to force plain output.
#
# This file is PUBLIC. No secrets, license keys, or internal hostnames live here.

set -euo pipefail

# ===========================================================================
# UI toolkit — colors, glyphs, banner, and the step/spinner engine
# ===========================================================================
# Defined first so even the earliest error (e.g. "not root") is presented in
# the same branded style as everything else.
#
# We only turn on colors/spinners when stdout is a real terminal (not a pipe
# or file), TERM isn't "dumb", and the operator hasn't set NO_COLOR. In every
# other case (CI, cron, redirected output) we fall back to plain text so logs
# stay readable and nothing emits stray escape codes.
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
  UI=true
else
  UI=false
fi

# Fancy box-drawing / braille glyphs need a UTF-8 terminal. If the locale isn't
# UTF-8 we keep the color but swap to plain ASCII glyphs so nothing renders as
# garbage question-marks.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*8* | *[Uu][Tt][Ff]8*) UTF8=true ;;
  *) UTF8=false ;;
esac

# TWG Security brand palette (24-bit truecolor):
#   primary red  #C0392B   dark charcoal #1A1A1A   white #FFFFFF
# Charcoal is near-black, so we use it only as a banner background; on-screen
# secondary text uses a dim grey that stays readable on any theme.
if $UI; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[38;2;192;57;43m'          # TWG red, foreground
  C_REDBG=$'\033[48;2;192;57;43m'        # TWG red, background
  C_CHARBG=$'\033[48;2;26;26;26m'        # TWG charcoal, background
  C_WHITE=$'\033[38;2;255;255;255m'
  C_GREY=$'\033[38;2;150;150;150m'
  C_GREEN=$'\033[38;2;46;160;67m'
  C_YELLOW=$'\033[38;2;214;153;33m'
  CR=$'\r'; CLR=$'\033[K'; HIDE=$'\033[?25l'; SHOW=$'\033[?25h'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_REDBG=''; C_CHARBG=''
  C_WHITE=''; C_GREY=''; C_GREEN=''; C_YELLOW=''
  CR=''; CLR=''; HIDE=''; SHOW=''
fi

# Glyphs (UTF-8 vs ASCII fallback).
if $UTF8; then
  G_OK='✔'; G_BAD='✖'; G_WARN='⚠'; G_BAR='▍'; G_ARROW='▶'; G_DOT='•'
  SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  G_OK='OK'; G_BAD='XX'; G_WARN='!!'; G_BAR='|'; G_ARROW='>'; G_DOT='-'
  SPIN=('|' '/' '-' '\')
fi

# LOG_FILE is finalized in the logging section below; declare it early so the
# helpers can reference it safely even before it exists.
LOG_FILE=""

# logline: append a timestamped plain-text line to the log file (no color).
# Safe to call before the log exists — it just no-ops until LOG_FILE is set.
logline() {
  [[ -n "${LOG_FILE}" ]] || return 0
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

# section: a titled divider. On screen it's a red tick + bold title; in the log
# it's a plain "=== Title ===" header.
section() {
  if $UI; then
    printf '\n  %s%s%s %s%s%s\n' "$C_RED" "$G_BAR" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  else
    printf '\n== %s ==\n' "$1"
  fi
  logline "=== $1 ==="
}

# kv: aligned key / value line, for the plan and summary cards.
kv() {
  if $UI; then
    printf '    %s%-15s%s %s\n' "$C_GREY" "$1" "$C_RESET" "$2"
  else
    printf '    %-15s %s\n' "$1" "$2"
  fi
  logline "    $1: $2"
}

# note: a dim, indented secondary line (context that isn't a pass/fail).
note() {
  if $UI; then
    printf '    %s%s %s%s\n' "$C_DIM" "$G_DOT" "$1" "$C_RESET"
  else
    printf '    %s %s\n' "$G_DOT" "$1"
  fi
  logline "    - $1"
}

# ok / warn: a green success line / a yellow non-fatal warning.
ok()   { if $UI; then printf '    %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$1"; else printf '    %s %s\n' "$G_OK" "$1"; fi; logline "    OK: $1"; }
warn() { if $UI; then printf '    %s%s %s%s\n' "$C_YELLOW" "$G_WARN" "$1" "$C_RESET"; else printf '    %s %s\n' "$G_WARN" "$1"; fi; logline "    WARN: $1"; }

# die: fatal error — restore the cursor, print a red banner, point at the log,
# and exit non-zero. Used for anything we cannot recover from.
die() {
  $UI && printf '%s' "$SHOW"
  if $UI; then
    printf '\n  %s%s ERROR %s %s%s\n' "$C_REDBG$C_WHITE$C_BOLD" '' "$C_RESET" "$C_RED" "$1"
    printf '%s' "$C_RESET"
  else
    printf '\nERROR: %s\n' "$1" >&2
  fi
  logline "FATAL: $1"
  [[ -n "${LOG_FILE}" ]] && printf '  %sSee the full log: %s%s\n' "$C_DIM" "${LOG_FILE}" "$C_RESET" >&2
  exit 1
}

# dump_tail: on a step failure, show the last few log lines so the operator
# isn't forced to open the file to see what broke.
dump_tail() {
  [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]] || return 0
  printf '    %s---- last log lines ----%s\n' "$C_DIM" "$C_RESET"
  tail -n 8 "${LOG_FILE}" 2>/dev/null | sed "s/^/    ${C_DIM}/;s/$/${C_RESET}/" || true
}

# step: run a command as one unit of work with a live status line.
#   step "Human description" my_command arg1 arg2
# All of the command's stdout+stderr is captured to the log file only, keeping
# the screen clean. In UI mode a spinner animates with an elapsed-seconds
# counter; on finish the line is rewritten to ✔ (green) or ✖ (red). In plain
# mode it prints a simple start/done/FAILED marker. Returns the command's exit
# code so the caller can decide whether a failure is fatal or best-effort.
step() {
  local desc="$1"; shift
  logline "STEP begin: ${desc}  (cmd: $*)"
  local t0=$SECONDS rc=0

  if ! $UI; then
    printf '  %s %s ... ' "$G_ARROW" "${desc}"
    if "$@" >> "${LOG_FILE}" 2>&1; then
      printf 'done\n'
    else
      rc=$?; printf 'FAILED (exit %d)\n' "$rc"; dump_tail
    fi
    logline "STEP end: ${desc}  (rc=${rc}, ${SECONDS}s elapsed)"
    return $rc
  fi

  # UI mode: run the work in the background and animate while it lives.
  "$@" >> "${LOG_FILE}" 2>&1 &
  local pid=$! i=0
  printf '%s' "$HIDE"
  while kill -0 "$pid" 2>/dev/null; do
    printf '%s  %s%s%s %s %s[%ds]%s%s' "$CR" \
      "$C_RED" "${SPIN[i]}" "$C_RESET" "${desc}" "$C_DIM" "$((SECONDS - t0))" "$C_RESET" "$CLR"
    i=$(((i + 1) % ${#SPIN[@]}))
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  printf '%s' "$SHOW"

  if [[ $rc -eq 0 ]]; then
    printf '%s  %s%s%s %s %s[%ds]%s%s\n' "$CR" \
      "$C_GREEN" "$G_OK" "$C_RESET" "${desc}" "$C_DIM" "$((SECONDS - t0))" "$C_RESET" "$CLR"
  else
    printf '%s  %s%s%s %s %s(exit %d)%s%s\n' "$CR" \
      "$C_RED" "$G_BAD" "$C_RESET" "${desc}" "$C_DIM" "$rc" "$C_RESET" "$CLR"
    dump_tail
  fi
  logline "STEP end: ${desc}  (rc=${rc}, $((SECONDS - t0))s elapsed)"
  return $rc
}

# banner: the branded header. Block "TWG" art in TWG red when the terminal can
# render it; a tidy plain header otherwise (and always in the log).
banner() {
  if $UI && $UTF8; then
    printf '\n'
    printf '  %s%s████████╗██╗    ██╗ ██████╗ %s\n'  "$C_BOLD" "$C_RED" "$C_RESET"
    printf '  %s%s╚══██╔══╝██║    ██║██╔════╝ %s   %s%sTWG SECURITY%s\n'      "$C_BOLD" "$C_RED" "$C_RESET" "$C_BOLD" "$C_WHITE" "$C_RESET"
    printf '  %s%s   ██║   ██║ █╗ ██║██║  ███╗%s   %s%sThe Wire Guys%s\n'     "$C_BOLD" "$C_RED" "$C_RESET" "$C_DIM" "$C_GREY" "$C_RESET"
    printf '  %s%s   ██║   ██║███╗██║██║   ██║%s\n'  "$C_BOLD" "$C_RED" "$C_RESET"
    printf '  %s%s   ██║   ╚███╔███╔╝╚██████╔╝%s   %sNX Mediaserver Deployment%s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$C_GREY" "$C_RESET"
    printf '  %s%s   ╚═╝    ╚══╝╚══╝  ╚═════╝ %s\n'  "$C_BOLD" "$C_RED" "$C_RESET"
    printf '\n'
  elif $UI; then
    printf '\n  %s%s TWG SECURITY %s  %sNX Mediaserver Deployment%s\n' \
      "$C_REDBG$C_WHITE$C_BOLD" '' "$C_RESET" "$C_GREY" "$C_RESET"
    printf '  %sThe Wire Guys%s\n\n' "$C_DIM" "$C_RESET"
  else
    printf '\n==========================================================\n'
    printf ' TWG Security - NX Mediaserver Deployment (The Wire Guys)\n'
    printf '==========================================================\n\n'
  fi
}

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
# The mediaserver .deb installs a systemd service and writes to /opt, and GPU
# driver install touches apt/system state, so we need real root.
if [[ "${EUID}" -ne 0 ]]; then
  banner
  die "This installer must run as root. Re-run with sudo, e.g.:
        curl -fsSL <url> | sudo bash"
fi

# ---------------------------------------------------------------------------
# 1. Configuration (all overridable at runtime via env vars)
# ---------------------------------------------------------------------------
# TWG defaults. Override any of these on the command line, or interactively via
# the menu below.
NX_EDITION="${NX_EDITION:-witness}"          # witness | meta
INSTALL_NX="${INSTALL_NX:-true}"             # install the mediaserver at all?
INSTALL_WEBMIN="${INSTALL_WEBMIN:-false}"    # install the Webmin admin panel?
INSTALL_GPU_DRIVERS="${INSTALL_GPU_DRIVERS:-auto}"  # auto | true | false
SET_TIMEZONE="${SET_TIMEZONE:-America/New_York}"    # empty string skips tz change
ENABLE_NTP="${ENABLE_NTP:-true}"             # enable network time sync?
NONINTERACTIVE="${NONINTERACTIVE:-false}"    # force-skip the interactive menu?

# Installer version — surfaced on screen so it's obvious at a glance which
# build of THIS script is running (helps tell a fresh deploy from a cached one).
INSTALLER_VERSION="2.1"

# Pinned NX release. Bump these when TWG pins a new build.
# See README.md -> "Updating the pinned version".
NX_VERSION="6.1.2"
NX_BUILD="42921"

# Proper product names for display — never show a bare lowercase "witness".
edition_label() {
  case "$1" in
    meta) printf 'NX Meta' ;;
    *)    printf 'NX Witness' ;;
  esac
}

# Run-state flags, filled in as we go, used to build the closing summary.
NX_DONE=false
WEBMIN_DONE=false
NVIDIA_INSTALLED=false
SECUREBOOT="unknown"
REBOOT_NEEDED=false

# ---------------------------------------------------------------------------
# 1a. Force every apt/dpkg step to be truly non-interactive
# ---------------------------------------------------------------------------
# `apt-get -y` answers apt's OWN prompts, but it does NOT stop a package's
# post-install script from popping a debconf/whiptail dialog (e.g. the NX
# mediaserver "Complete the setup process" note). On a headless or remote
# (tunneled) session that dialog blocks forever waiting for a keypress the
# pty never delivers — the install appears to hang on a magenta screen.
#
# In plain English: `-y` tells the cashier "yes" to their questions, but a
# package can still hand you a form to sign — this makes debconf skip the
# form entirely instead of waiting at the counter.
#
# Setting DEBIAN_FRONTEND=noninteractive switches debconf to a frontend that
# renders nothing and returns immediately (notes are logged, not displayed).
# DEBCONF_NONINTERACTIVE_SEEN=true additionally treats already-seen questions
# as answered so re-runs don't re-prompt. Exported so every apt/dpkg call in
# this script (NX, GPU drivers, Webmin) inherits it.
#
# NOTE: this does NOT affect our own menu below — that reads from /dev/tty,
# not debconf — so techs still get the interactive picker on a real terminal.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# needrestart (Ubuntu 22.04+) is the OTHER common headless blocker: after a
# library upgrade it throws up its own full-screen "which services to restart"
# dialog. Tell it to just restart services automatically and never prompt.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ---------------------------------------------------------------------------
# 2. Install logging — capture EVERYTHING to a file for later debugging
# ---------------------------------------------------------------------------
# Timestamped log under /var/log by default; override with LOG_FILE. Unlike the
# old build, we do NOT tee the whole world to the console — the pretty UI goes
# to the screen and every command's raw output goes here to the file, so the
# log is a complete, plain-text record of the run.
LOG_TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-/var/log/twg-nx-deploy-${LOG_TS}.log}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
# Create/append the log and write a header block into it.
{
  echo "=========================================================="
  echo " TWG Security — NX Mediaserver bootstrap"
  echo " $(date)"
  echo "=========================================================="
} >> "${LOG_FILE}" 2>/dev/null || die "Cannot write to log file: ${LOG_FILE}"

# Restore the cursor on ANY exit (success, error, Ctrl-C) so a killed spinner
# never leaves the terminal without a cursor. Temp-dir cleanup is added to this
# same trap once the workspace exists.
trap 'printf "%s" "${SHOW}"' EXIT

# ---------------------------------------------------------------------------
# 3. Show the banner and record system context
# ---------------------------------------------------------------------------
banner
note "Installer v${INSTALLER_VERSION} · logging to ${LOG_FILE}"

section "System"
. /etc/os-release 2>/dev/null || true
DISTRO_ID="${ID:-unknown}"            # ubuntu | debian | ...
DISTRO_LIKE="${ID_LIKE:-}"            # e.g. "debian"
kv "Distro" "${PRETTY_NAME:-unknown} (id=${DISTRO_ID})"
kv "Kernel" "$(uname -r)"
kv "Arch"   "$(uname -m)"
kv "Host"   "$(hostname 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# 4. Confirm this is a Debian/Ubuntu box (we need apt-get)
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get not found. This installer supports Debian/Ubuntu only."
fi

# ---------------------------------------------------------------------------
# 5. Interactive menu (only when a terminal is available)
# ---------------------------------------------------------------------------
# The one-liner pipes the script into bash, so stdin is the script — not the
# keyboard. To prompt anyway we read from the controlling terminal /dev/tty.
# If that can't be opened (no TTY: CI, cron, headless pipe) or NONINTERACTIVE
# is set, we skip the menu and use the env-var defaults untouched.
MENU_TTY=""
if [[ "${NONINTERACTIVE}" != "true" ]]; then
  if { true >/dev/tty; } 2>/dev/null; then
    MENU_TTY="/dev/tty"
  fi
fi

# Prompt helper: yes/no with a default. Echoes "true"/"false" on stdout; the
# human-facing prompt goes to stderr so it isn't captured by $(...).
ask_yn() {
  local prompt="$1" def="$2" ans hint
  if [[ "${def}" == "true" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '    %s%s%s %s%s%s ' "$C_WHITE" "${prompt}" "$C_RESET" "$C_DIM" "${hint}" "$C_RESET" >&2
  read -r ans < "${MENU_TTY}" || ans=""
  ans="${ans,,}"
  case "${ans}" in
    "")      echo "${def}" ;;
    y|yes)   echo "true" ;;
    n|no)    echo "false" ;;
    *)       echo "${def}" ;;
  esac
}

# Prompt helper: free-text value with a default (blank input keeps default).
ask_val() {
  local prompt="$1" def="$2" ans
  printf '    %s%s%s %s[%s]%s ' "$C_WHITE" "${prompt}" "$C_RESET" "$C_DIM" "${def:-<empty>}" "$C_RESET" >&2
  read -r ans < "${MENU_TTY}" || ans=""
  if [[ -z "${ans}" ]]; then echo "${def}"; else echo "${ans}"; fi
}

if [[ -n "${MENU_TTY}" ]]; then
  section "Setup"
  note "Press Enter to accept the [default] shown for each option."
  printf '\n'

  # NX edition — numbered pick so a tech types 1 or 2 instead of the word.
  # The edition words (witness/meta) still work too.
  case "${NX_EDITION}" in
    meta) ed_def="2" ;;
    *)    ed_def="1" ;;
  esac
  printf '    %sNX edition:%s  %s1%s) NX Witness   %s2%s) NX Meta\n' \
    "$C_WHITE" "$C_RESET" "$C_RED" "$C_RESET" "$C_RED" "$C_RESET" >&2
  edchoice="$(ask_val "Choose 1 or 2" "${ed_def}")"
  case "${edchoice,,}" in
    1|witness) NX_EDITION="witness" ;;
    2|meta)    NX_EDITION="meta" ;;
    *)         warn "Unrecognized '${edchoice}', keeping '${NX_EDITION}'." ;;
  esac

  # Toggles. We deliberately do NOT ask "install the mediaserver?" — that's the
  # whole reason someone runs this. Automation can still set INSTALL_NX=false.
  case "${INSTALL_GPU_DRIVERS}" in
    false) gpu_def="false" ;;
    *)     gpu_def="true"  ;;   # auto/true both present as "yes" in the menu
  esac
  if [[ "$(ask_yn "Detect GPU and install drivers?" "${gpu_def}")" == "true" ]]; then
    INSTALL_GPU_DRIVERS="auto"
  else
    INSTALL_GPU_DRIVERS="false"
  fi
  INSTALL_WEBMIN="$(ask_yn "Install Webmin admin panel?" "${INSTALL_WEBMIN}")"

  # Time.
  SET_TIMEZONE="$(ask_val "Timezone (blank = leave unchanged)" "${SET_TIMEZONE}")"
  ENABLE_NTP="$(ask_yn "Enable NTP time sync?" "${ENABLE_NTP}")"
else
  note "Non-interactive run — using env-var defaults (no menu)."
fi

# ---------------------------------------------------------------------------
# 6. Resolve the package URL from the edition (unless explicitly overridden)
# ---------------------------------------------------------------------------
# Done AFTER the menu so an edition change there is honored. Pinned download
# URLs for NX 6.1.2 build 42921. If NX_PKG_URL is set we honor it verbatim and
# ignore NX_EDITION for URL selection.
WITNESS_URL="https://updates.networkoptix.com/default/${NX_BUILD}/linux/nxwitness-server-${NX_VERSION}.${NX_BUILD}-linux_x64.deb"
META_URL="https://updates.networkoptix.com/metavms/${NX_BUILD}/linux/metavms-server-${NX_VERSION}.${NX_BUILD}-linux_x64.deb"

if [[ -n "${NX_PKG_URL:-}" ]]; then
  # Operator supplied an explicit URL — use it as-is.
  PKG_URL="${NX_PKG_URL}"
else
  case "${NX_EDITION}" in
    witness) PKG_URL="${WITNESS_URL}" ;;
    meta)    PKG_URL="${META_URL}" ;;
    *)       die "NX_EDITION must be 'witness' or 'meta' (got: '${NX_EDITION}')." ;;
  esac
fi

# The filename we download the package to.
PKG_FILE="$(basename "${PKG_URL}")"

# Pick the matching systemd service name for the chosen edition. Detected at
# the end from the actual installed units, but we keep a sensible default here.
case "${NX_EDITION}" in
  meta) SERVICE_HINT="networkoptix-metavms-mediaserver" ;;
  *)    SERVICE_HINT="networkoptix-mediaserver" ;;
esac

# ---------------------------------------------------------------------------
# 7. Show the effective plan (post-menu) so it's clear what's about to run
# ---------------------------------------------------------------------------
section "Deployment plan"
kv "Edition"    "$(edition_label "${NX_EDITION}")"
kv "Version"    "${NX_VERSION} build ${NX_BUILD}"
kv "Install NX" "${INSTALL_NX}"
kv "GPU drivers" "${INSTALL_GPU_DRIVERS}"
kv "Webmin"     "${INSTALL_WEBMIN}"
kv "Timezone"   "${SET_TIMEZONE:-<unchanged>}"
kv "NTP"        "${ENABLE_NTP}"
kv "Package"    "${PKG_FILE}"

# ---------------------------------------------------------------------------
# 8. Temp workspace with guaranteed cleanup
# ---------------------------------------------------------------------------
# Download into a private temp dir and remove it on any exit (success, error,
# or Ctrl-C). We fold the removal into the existing cursor-restore trap.
WORKDIR="$(mktemp -d)"
trap 'printf "%s" "${SHOW}"; rm -rf "${WORKDIR}"' EXIT

# ===========================================================================
# 9. NX mediaserver install
# ===========================================================================
if [[ "${INSTALL_NX}" == "true" ]]; then
  section "NX mediaserver"
  note "Edition: $(edition_label "${NX_EDITION}") ${NX_VERSION} (build ${NX_BUILD})"

  # --- 9a. Download the .deb -----------------------------------------------
  if ! step "Downloading ${PKG_FILE}" \
      curl -fSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${PKG_FILE}" "${PKG_URL}"; then
    die "Failed to download the NX package from:
        ${PKG_URL}"
  fi

  # --- 9b. Install ---------------------------------------------------------
  # apt-get resolves the .deb's dependencies for us. The leading path tells apt
  # this is a local file, not a repo package name. The Dpkg::Options keep the
  # install unattended even if a config-file conflict comes up: keep the
  # existing conffile (confold) and fall back to the package default when
  # there's no old version (confdef), instead of stopping to ask. Combined
  # with DEBIAN_FRONTEND=noninteractive (set at the top) this guarantees the
  # mediaserver postinst never blocks on that whiptail "Complete the setup"
  # note that hangs headless/remote runs.
  step "Refreshing apt package index" apt-get update -y || true
  if ! step "Installing ${PKG_FILE}" \
      apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${WORKDIR}/${PKG_FILE}"; then
    die "NX mediaserver install failed. See the log for apt's output."
  fi

  NX_DONE=true
  ok "NX mediaserver installed."
  note "The server is installed but NOT yet set up. Finish setup in the Nx"
  note "client via the 'New Site' tile, or open http://<server-ip>:7001."
else
  section "NX mediaserver"
  note "Skipped (INSTALL_NX=${INSTALL_NX})."
fi

# ===========================================================================
# 10. GPU detection + driver install
# ===========================================================================
# Detects an installed GPU and installs the vendor-appropriate drivers so NX
# can use hardware-accelerated decoding. INSTALL_GPU_DRIVERS:
#   false -> skip entirely
#   auto  -> detect; install only for a detected vendor (default)
#   true  -> same as auto (kept as an explicit "yes")
# GPU setup is an enhancement, not core provisioning, so failures here WARN
# and continue rather than aborting the whole run.

# detect_secureboot: echo "enabled" | "disabled" | "unknown".
# Secure Boot is the firmware "bouncer" that only admits kernel modules signed
# by a key it trusts. A freshly built NVIDIA module is unsigned, so on a
# Secure-Boot box it won't load until its key is enrolled — worth knowing.
# Prefer mokutil; fall back to reading the SecureBoot EFI variable directly
# (its last byte is 1 = on, 0 = off). No EFI var => legacy BIOS / not present.
detect_secureboot() {
  if command -v mokutil >/dev/null 2>&1; then
    case "$(mokutil --sb-state 2>/dev/null)" in
      *[Ee]nabled*)  echo enabled;  return ;;
      *[Dd]isabled*) echo disabled; return ;;
    esac
  fi
  local var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  if [[ -r "${var}" ]]; then
    local last
    last="$(od -An -t u1 "${var}" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | tail -n1)"
    case "${last}" in
      1) echo enabled;  return ;;
      0) echo disabled; return ;;
    esac
  fi
  echo unknown
}

section "GPU drivers"
if [[ "${INSTALL_GPU_DRIVERS}" != "false" ]]; then

  # lspci (pciutils) is how we enumerate hardware; install it if missing.
  if ! command -v lspci >/dev/null 2>&1; then
    step "Installing pciutils (for lspci)" apt-get install -y pciutils \
      || warn "Could not install pciutils; GPU detection may be limited."
  fi

  # Grab display-class devices (VGA / 3D / Display controllers).
  GPU_LINES="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)"

  if [[ -z "${GPU_LINES}" ]]; then
    note "No GPU detected — skipping driver install."
  else
    note "Detected:"
    while IFS= read -r line; do [[ -n "$line" ]] && note "  ${line}"; done <<<"${GPU_LINES}"

    # Classify by vendor (case-insensitive match on the lspci text).
    HAS_NVIDIA=false; HAS_AMD=false; HAS_INTEL=false
    # Note: match AMD by vendor string, NOT a bare "ati" — that would match
    # the "ati" inside "VGA comp-ati-ble controller" on every line.
    grep -qiE 'nvidia'                                   <<<"${GPU_LINES}" && HAS_NVIDIA=true
    grep -qiE 'advanced micro devices|amd/ati|radeon|\bamd\b' <<<"${GPU_LINES}" && HAS_AMD=true
    grep -qiE 'intel'                                    <<<"${GPU_LINES}" && HAS_INTEL=true

    # Is this an Ubuntu-family distro? ubuntu-drivers only exists there.
    IS_UBUNTU=false
    if [[ "${DISTRO_ID}" == "ubuntu" ]] || grep -qi 'ubuntu' <<<"${DISTRO_LIKE}"; then
      IS_UBUNTU=true
    fi

    step "Refreshing apt package index" apt-get update -y || true

    # --- NVIDIA ------------------------------------------------------------
    if [[ "${HAS_NVIDIA}" == "true" ]]; then
      note "NVIDIA GPU detected."

      # DKMS builds the NVIDIA kernel module against THIS kernel, so it needs
      # the matching headers plus a compiler. The driver metapackage usually
      # pulls these in, but installing them explicitly makes the build reliable
      # on minimal or HWE-kernel images where the deps don't line up — the most
      # common reason the module silently fails to build.
      step "Installing kernel headers + DKMS build tools" \
        apt-get install -y "linux-headers-$(uname -r)" build-essential dkms \
        || warn "Kernel headers / DKMS tools failed to install; the module build may fail."

      # Warn about Secure Boot BEFORE the install so it's not a mystery later.
      SECUREBOOT="$(detect_secureboot)"
      if [[ "${SECUREBOOT}" == "enabled" ]]; then
        warn "Secure Boot is ENABLED. The NVIDIA module is unsigned, so the kernel"
        warn "will refuse to load it until you enroll its key (the 'MOK Manager'"
        warn "screen at next boot) or disable Secure Boot in BIOS/UEFI. Until then"
        warn "'nvidia-smi' will keep failing even after a reboot."
      fi

      if [[ "${IS_UBUNTU}" == "true" ]]; then
        # ubuntu-drivers picks the recommended (latest stable) driver for the
        # exact card — the vendor-blessed path on Ubuntu.
        if step "Installing ubuntu-drivers-common" apt-get install -y ubuntu-drivers-common; then
          step "Installing recommended NVIDIA driver" ubuntu-drivers install \
            || step "Retry: ubuntu-drivers autoinstall" ubuntu-drivers autoinstall \
            || warn "NVIDIA driver install failed — install manually."
        else
          warn "Could not install ubuntu-drivers-common — skipping NVIDIA."
        fi
      else
        # Debian: the NVIDIA driver lives in contrib/non-free, which may not be
        # enabled. Attempt it, and if it fails point the tech at the manual fix
        # rather than silently mangling their apt sources.
        step "Installing nvidia-driver (Debian contrib/non-free)" apt-get install -y nvidia-driver \
          || { warn "nvidia-driver unavailable. Enable 'contrib non-free"
               warn "non-free-firmware' in /etc/apt/sources.list, run 'apt-get"
               warn "update', then 'apt-get install nvidia-driver'."; }
      fi

      # Verify the driver files actually landed. DKMS installs the built module
      # into the running kernel's tree, so 'modinfo nvidia' succeeds right after
      # install even though the module can't LOAD until a reboot. This cleanly
      # separates "install failed" from "installed, just needs a reboot" — the
      # exact confusion behind an "nvidia-smi couldn't communicate" report.
      if modinfo nvidia >/dev/null 2>&1; then
        NVIDIA_INSTALLED=true
        ok "NVIDIA driver installed (version $(modinfo -F version nvidia 2>/dev/null || echo '?'))."
        note "It just needs a reboot to load — nvidia-smi will work once the system comes back up."
      else
        warn "NVIDIA driver files not found after install ('modinfo nvidia' failed)."
        warn "The DKMS build likely failed — check 'dkms status' and the log."
      fi
    fi

    # --- AMD ---------------------------------------------------------------
    if [[ "${HAS_AMD}" == "true" ]]; then
      # The amdgpu kernel driver ships in-kernel; add Mesa's VAAPI stack for
      # hardware video decode plus vainfo to check it.
      step "Installing AMD Mesa VAAPI drivers" apt-get install -y mesa-va-drivers vainfo \
        || warn "AMD VAAPI packages failed to install."
    fi

    # --- Intel -------------------------------------------------------------
    if [[ "${HAS_INTEL}" == "true" ]]; then
      # i965 (older) + intel-media (Gen8+) VAAPI drivers cover the common range.
      step "Installing Intel VAAPI drivers" apt-get install -y intel-media-va-driver i965-va-driver vainfo \
        || warn "Intel VAAPI packages failed to install."
    fi

    ok "GPU driver step complete."
  fi
else
  note "Skipped (INSTALL_GPU_DRIVERS=false)."
fi

# ===========================================================================
# 11. Webmin (optional)
# ===========================================================================
# Only runs when explicitly enabled. Adds Webmin's signed apt repo and installs
# it. Re-running is safe: the key/repo files are simply overwritten.
section "Webmin"
if [[ "${INSTALL_WEBMIN}" == "true" ]]; then

  # Composite step: everything Webmin's repo setup + install needs, as one unit
  # of work. Wrapped in a function so the spinner treats it atomically.
  install_webmin() {
    apt-get install -y software-properties-common apt-transport-https curl
    curl -fsSL https://download.webmin.com/developers-key.asc \
      | gpg --dearmor -o /usr/share/keyrings/webmin.gpg
    echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/newkey/repository stable contrib" \
      > /etc/apt/sources.list.d/webmin.list
    apt-get update -y
    apt-get install -y webmin
  }

  if step "Adding Webmin repo and installing" install_webmin; then
    WEBMIN_DONE=true
    ok "Webmin installed."
  else
    warn "Webmin install failed — see the log."
  fi
else
  note "Skipped (INSTALL_WEBMIN=${INSTALL_WEBMIN})."
fi

# ===========================================================================
# 12. Time: timezone, NTP, hardware clock
# ===========================================================================
section "Time"

# Set the timezone only when a non-empty value is provided.
if [[ -n "${SET_TIMEZONE}" ]]; then
  step "Setting timezone to ${SET_TIMEZONE}" timedatectl set-timezone "${SET_TIMEZONE}" \
    || warn "Failed to set timezone."
else
  note "SET_TIMEZONE empty — leaving timezone unchanged."
fi

# Enable network time synchronization when requested.
if [[ "${ENABLE_NTP}" == "true" ]]; then
  step "Enabling NTP (network time sync)" timedatectl set-ntp true \
    || warn "Failed to enable NTP."
else
  note "ENABLE_NTP=${ENABLE_NTP} — leaving NTP state unchanged."
fi

# Always sync the hardware (RTC) clock from the now-correct system clock.
step "Syncing hardware clock (hwclock --systohc)" hwclock --systohc \
  || warn "hwclock --systohc failed (common on VMs/containers without an RTC)."

# Show the key settings concisely; the full timedatectl dump goes to the log.
timedatectl >> "${LOG_FILE}" 2>&1 || true
TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
NTP_NOW="$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"
note "Timezone: ${TZ_NOW}   NTP: ${NTP_NOW}"

# ===========================================================================
# 13. Report the mediaserver service status
# ===========================================================================
# Detect the actual installed *mediaserver* unit rather than hardcoding it, so
# this stays correct across editions and future naming tweaks.
SERVICE_NAME=""
SERVICE_STATE=""
if [[ "${INSTALL_NX}" == "true" ]]; then
  section "Service status"

  # List loaded units and grab the first one whose name contains 'mediaserver'.
  SERVICE_NAME="$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -m1 'mediaserver' || true)"
  # Fall back to the edition-based hint if enumeration found nothing.
  SERVICE_NAME="${SERVICE_NAME:-${SERVICE_HINT}.service}"

  # Full status to the log; a one-word state to the screen.
  systemctl status "${SERVICE_NAME}" --no-pager >> "${LOG_FILE}" 2>&1 || true
  SERVICE_STATE="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
  SERVICE_STATE="${SERVICE_STATE:-unknown}"

  kv "Service" "${SERVICE_NAME}"
  case "${SERVICE_STATE}" in
    active)   ok "Service is active (running)." ;;
    inactive) note "Service is installed but not running yet (finish setup to start it)." ;;
    failed)   warn "Service reports 'failed' — check the log." ;;
    *)        note "Service state: ${SERVICE_STATE}." ;;
  esac
fi

# ===========================================================================
# 14. Closing summary
# ===========================================================================
# Best-effort local IP for the access hints (falls back to a placeholder).
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-<server-ip>}"

section "Done"
$NX_DONE     && kv "NX server"  "http://${SERVER_IP}:7001  ($(edition_label "${NX_EDITION}") ${NX_VERSION})"
$WEBMIN_DONE && kv "Webmin"     "https://${SERVER_IP}:10000"
kv "Log file" "${LOG_FILE}"

if $NVIDIA_INSTALLED; then
  if [[ "${SECUREBOOT}" == "enabled" ]]; then
    # Secure Boot means a plain reboot won't be enough, so don't offer one —
    # just explain the extra step, kindly.
    note "The NVIDIA driver is installed. Because Secure Boot is on, it needs one"
    note "extra step to load: enroll the driver's key at the 'MOK Manager' screen"
    note "on the next boot, or turn off Secure Boot in BIOS/UEFI. After that,"
    note "nvidia-smi will work."
  else
    note "The NVIDIA driver is installed and ready — it just needs a reboot to load."
    REBOOT_NEEDED=true
  fi
fi
if $NX_DONE && [[ "${SERVICE_STATE}" != "active" ]]; then
  note "When you're ready, finish NX setup from the Nx client's 'New Site' tile,"
  note "or open http://${SERVER_IP}:7001 in a browser."
fi

if $UI; then
  printf '\n  %s%s All done %s\n\n' "$C_REDBG$C_WHITE$C_BOLD" '' "$C_RESET"
else
  printf '\nAll done.\n\n'
fi
logline "Bootstrap complete."

# ---------------------------------------------------------------------------
# 15. Offer to reboot (only when something we installed needs it)
# ---------------------------------------------------------------------------
# The GPU driver loads at boot, so a reboot is the last step. Rather than just
# telling the tech to do it, offer to do it for them — but only when we're on a
# real terminal that can answer. In automation we just leave a friendly note.
if $REBOOT_NEEDED; then
  if [[ -n "${MENU_TTY}" ]]; then
    if [[ "$(ask_yn "This system needs a reboot to finish setting up the GPU driver. Reboot now?" "false")" == "true" ]]; then
      note "Rebooting now — the server will be back in a moment."
      logline "User approved reboot; rebooting."
      reboot
    else
      note "No problem. Reboot whenever you're ready with:  sudo reboot"
    fi
  else
    note "Reboot when you're ready to finish the GPU driver setup:  sudo reboot"
  fi
fi

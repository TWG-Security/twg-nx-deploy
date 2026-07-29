#!/usr/bin/env bash
#
# TWG Security — NX Mediaserver one-line bootstrap
# ------------------------------------------------
# Provisions a fresh Ubuntu/Debian server with the Network Optix NX
# mediaserver (NX Witness or NX Meta), plus optional Webmin, GPU drivers,
# timezone, and NTP.
#
# THE INTERFACE. On a capable terminal the installer takes over the screen with
# a full-screen dashboard: a fixed TWG banner, the run plan, and a live
# checklist of phases that tick from pending → running (spinner) → ✔/✖ in
# place — like a proper installer app, not a wall of scrolling logs. The noisy
# apt/dpkg/curl output goes to a LOG FILE instead. When the run finishes the
# screen is restored and a clean summary is printed. Think of it as mission
# control: the board up front shows each stage lighting up green; the detailed
# telemetry is recorded in the log for later.
#
# It falls back gracefully: a smaller/older terminal gets tidy line-by-line
# status; a pipe with no terminal (CI/cron) or NO_COLOR gets plain text. Set
# NO_TUI=1 to force the line-by-line mode on a full terminal.
#
# Usage (as root):
#   curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
#
# Every knob is an environment variable and can be overridden inline, e.g.:
#   curl -fsSL <url> | sudo NX_EDITION=meta INSTALL_WEBMIN=true bash
#
# When run from a real terminal an interactive MENU appears so a tech can pick
# options; pass NONINTERACTIVE=true (or run with no TTY) to use env-var defaults.
#
# Honors NO_COLOR (https://no-color.org) and NO_TUI.
#
# This file is PUBLIC. No secrets, license keys, or internal hostnames live here.

set -euo pipefail

# Installer version — surfaced on screen so it's obvious at a glance which build
# of THIS script is running (helps tell a fresh deploy from a cached one).
INSTALLER_VERSION="2.3"

# ===========================================================================
# UI toolkit — capability detection, palette, banner, dashboard, phase engine
# ===========================================================================
# Colors/animation turn on only when stdout is a real terminal, TERM isn't
# "dumb", and NO_COLOR is unset. Otherwise everything degrades to plain text.
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
  UI=true
else
  UI=false
fi

# Box-drawing / braille glyphs need a UTF-8 terminal. If the locale isn't UTF-8
# we keep color but swap to ASCII glyphs so nothing renders as garbage.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*8* | *[Uu][Tt][Ff]8*) UTF8=true ;;
  *) UTF8=false ;;
esac

# TWG Security brand palette: primary red #C0392B, white, dim grey.
#
# Color depth matters here. If we blindly emit 24-bit truecolor (#C0392B) to a
# terminal that only does 256 colors, it gets approximated to the NEAREST cube
# index — which for #C0392B is 166, an ORANGE (#d75f00). That's why the logo
# looked orange. So we pick the red to match what the terminal actually
# supports: truecolor gets exact #C0392B; 256-color gets index 160 (a clean
# red); anything else gets basic ANSI red. We also NEVER wrap the red art in
# bold — many terminals render bold as "brighter", which also skews red→orange.
if $UI; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
    C_RED=$'\033[38;2;192;57;43m'          # exact TWG red #C0392B
    C_REDBG=$'\033[48;2;192;57;43m'
    C_WHITE=$'\033[38;2;255;255;255m'
    C_GREY=$'\033[38;2;150;150;150m'
    C_GREEN=$'\033[38;2;46;160;67m'
    C_YELLOW=$'\033[38;2;214;153;33m'
  elif [[ "${TERM:-}" == *256color* ]]; then
    C_RED=$'\033[38;5;160m'                # clean red, NOT the orange 166
    C_REDBG=$'\033[48;5;160m'
    C_WHITE=$'\033[38;5;231m'
    C_GREY=$'\033[38;5;245m'
    C_GREEN=$'\033[38;5;35m'
    C_YELLOW=$'\033[38;5;178m'
  else
    C_RED=$'\033[31m'; C_REDBG=$'\033[41m'  # basic ANSI red
    C_WHITE=$'\033[97m'; C_GREY=$'\033[90m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  fi
  CLR=$'\033[K'; HIDE=$'\033[?25l'; SHOW=$'\033[?25h'
  HOME_=$'\033[H'; CLRSCR=$'\033[2J'; CLREOS=$'\033[J'
  ALT_H=$'\033[?1049h'; ALT_L=$'\033[?1049l'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_REDBG=''
  C_WHITE=''; C_GREY=''; C_GREEN=''; C_YELLOW=''
  CLR=''; HIDE=''; SHOW=''
  HOME_=''; CLRSCR=''; CLREOS=''; ALT_H=''; ALT_L=''
fi

# Glyphs (UTF-8 vs ASCII fallback).
if $UTF8; then
  G_OK='✔'; G_BAD='✖'; G_WARN='⚠'; G_BAR='▍'; G_DOT='•'; G_PEND='·'; G_SKIP='–'; G_SUB='›'; ELL='…'
  SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  G_OK='OK'; G_BAD='XX'; G_WARN='!!'; G_BAR='|'; G_DOT='-'; G_PEND='.'; G_SKIP='-'; G_SUB='>'; ELL='..'
  SPIN=('|' '/' '-' '\')
fi

# --- Full-screen (TUI) capability ------------------------------------------
# The dashboard needs color + UTF-8 + tput + a terminal at least 15x50 (it
# shrinks the banner on short windows). Anything less falls back to
# line-by-line status. NO_TUI forces the fallback.
TUI=false; ALT_ON=false
if $UI && $UTF8 && [[ -z "${NO_TUI:-}" ]] && command -v tput >/dev/null 2>&1; then
  _rows="$(tput lines 2>/dev/null || echo 0)"; _cols="$(tput cols 2>/dev/null || echo 0)"
  if [[ "${_rows}" =~ ^[0-9]+$ && "${_cols}" =~ ^[0-9]+$ ]] && (( _rows >= 15 && _cols >= 50 )); then
    TUI=true
  fi
fi

# LOG_FILE is finalized in the logging section; declare early so helpers are
# safe to call before it exists (they no-op until it's set).
LOG_FILE=""

# Dashboard state.
PHASE_NAMES=(); PHASE_STATUS=(); WARNINGS=()
CUR_PHASE=-1; PHASE_T0=0; SPIN_I=0; WMARK=0; LAST_PHASE=-1
DETAIL=""; PLAN_SUMMARY=""

# logline: append a timestamped plain-text line to the log (no color).
logline() {
  [[ -n "${LOG_FILE}" ]] || return 0
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

# --- Normal-screen helpers (used before/after the dashboard) ----------------
# section: a titled divider (red tick + bold title).
section() {
  if $UI; then printf '\n  %s%s%s %s%s%s\n' "$C_RED" "$G_BAR" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  else printf '\n== %s ==\n' "$1"; fi
  logline "=== $1 ==="
}
# kv: aligned key / value line for the plan and summary cards.
kv() {
  if $UI; then printf '    %s%-15s%s %s\n' "$C_GREY" "$1" "$C_RESET" "$2"
  else printf '    %-15s %s\n' "$1" "$2"; fi
  logline "    $1: $2"
}
# note / ok / warn: dim context / green success / yellow non-fatal warning.
note() { if $UI; then printf '    %s%s %s%s\n' "$C_DIM" "$G_DOT" "$1" "$C_RESET"; else printf '    %s %s\n' "$G_DOT" "$1"; fi; logline "    - $1"; }
ok()   { if $UI; then printf '    %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$1"; else printf '    %s %s\n' "$G_OK" "$1"; fi; logline "    OK: $1"; }
warn() { if $UI; then printf '    %s%s %s%s\n' "$C_YELLOW" "$G_WARN" "$1" "$C_RESET"; else printf '    %s %s\n' "$G_WARN" "$1"; fi; logline "    WARN: $1"; }

# dump_tail: show the last few log lines after a fatal error.
dump_tail() {
  [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]] || return 0
  printf '    %s---- last log lines ----%s\n' "$C_DIM" "$C_RESET"
  tail -n 8 "${LOG_FILE}" 2>/dev/null | sed "s/^/    ${C_DIM}/;s/\$/${C_RESET}/" || true
}

# _trunc: clamp a plain (no-color) string to N columns with an ellipsis, so a
# long path/detail can never wrap and shove the layout off the screen.
_trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then printf '%s%s' "${s:0:max-1}" "$ELL"; else printf '%s' "$s"; fi
}

# _append_banner ARRAYNAME COMPACT: push the header lines onto the named array.
# COMPACT=true (short windows) uses a one-line badge; otherwise the block art.
# The red art is NEVER bold — bold skews the red toward orange on many terminals.
_append_banner() {
  local -n _a="$1"; local compact="$2"
  if [[ "$compact" == "true" ]] || ! $UTF8; then
    if $UI; then _a+=("  ${C_REDBG}${C_WHITE}${C_BOLD} TWG SECURITY ${C_RESET}  ${C_GREY}NX Mediaserver Deployment · v${INSTALLER_VERSION}${C_RESET}")
    else _a+=(" TWG Security - NX Mediaserver Deployment v${INSTALLER_VERSION} (The Wire Guys)"); fi
  else
    _a+=("  ${C_RED}████████╗██╗    ██╗ ██████╗ ${C_RESET}")
    _a+=("  ${C_RED}╚══██╔══╝██║    ██║██╔════╝ ${C_RESET}   ${C_BOLD}${C_WHITE}TWG SECURITY${C_RESET}")
    _a+=("  ${C_RED}   ██║   ██║ █╗ ██║██║  ███╗${C_RESET}   ${C_GREY}The Wire Guys${C_RESET}")
    _a+=("  ${C_RED}   ██║   ██║███╗██║██║   ██║${C_RESET}")
    _a+=("  ${C_RED}   ██║   ╚███╔███╔╝╚██████╔╝${C_RESET}   ${C_GREY}NX Mediaserver Deployment · v${INSTALLER_VERSION}${C_RESET}")
    _a+=("  ${C_RED}   ╚═╝    ╚══╝╚══╝  ╚═════╝ ${C_RESET}")
  fi
}

# banner: the header on the normal screen (with breathing room).
banner() {
  local -a B=(); _append_banner B false
  printf '\n'; local ln; for ln in "${B[@]}"; do printf '%s\n' "$ln"; done; printf '\n'
}

# render: repaint the dashboard so it FILLS the terminal — banner and plan at
# the top, the phase checklist below, blank fill, and the log footer pinned to
# the bottom row. It measures the terminal every frame (so it adapts to the
# window and to resizes) and builds exactly $rows lines, so it can never scroll
# or get cut off at the bottom. No-op unless TUI is active.
render() {
  $TUI || return 0
  local rows cols w
  rows="$(tput lines 2>/dev/null || echo 24)"; cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24; [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  w=$(( cols < 82 ? cols - 4 : 78 )); (( w < 20 )) && w=20
  local div="" m; for ((m = 0; m < w; m++)); do div+="─"; done

  local compact=false; (( rows < 22 )) && compact=true
  local -a L=()
  [[ "$compact" == "true" ]] || L+=("")            # top margin only when tall
  _append_banner L "$compact"
  L+=("  ${C_DIM}${div}${C_RESET}")
  L+=("  ${C_GREY}Plan${C_RESET}  $(_trunc "${PLAN_SUMMARY}" $((w - 6)))")
  L+=("  ${C_DIM}${div}${C_RESET}")
  L+=("")

  local i st icon nc name
  for i in "${!PHASE_NAMES[@]}"; do
    st="${PHASE_STATUS[$i]}"; name="$(_trunc "${PHASE_NAMES[$i]}" $((w - 12)))"
    case "$st" in
      ok)   icon="${C_GREEN}${G_OK}${C_RESET}";     nc="" ;;
      warn) icon="${C_YELLOW}${G_WARN}${C_RESET}";  nc="" ;;
      fail) icon="${C_RED}${G_BAD}${C_RESET}";      nc="" ;;
      run)  icon="${C_RED}${SPIN[$SPIN_I]}${C_RESET}"; nc="$C_BOLD" ;;
      skip) icon="${C_DIM}${G_SKIP}${C_RESET}";     nc="$C_DIM" ;;
      *)    icon="${C_DIM}${G_PEND}${C_RESET}";     nc="$C_DIM" ;;
    esac
    if [[ "$st" == run ]]; then
      L+=("   ${icon}  ${nc}${name}${C_RESET}  ${C_DIM}[$((SECONDS - PHASE_T0))s]${C_RESET}")
      L+=("        ${C_DIM}${G_SUB} $(_trunc "${DETAIL}" $((w - 6)))${C_RESET}")
    else
      L+=("   ${icon}  ${nc}${name}${C_RESET}")
    fi
  done

  # Fit the body to (rows - 2): pad with blanks to push the footer down, or trim
  # if the window is too short. Then the two footer lines land on the last rows.
  local avail=$(( rows - 2 )) body=${#L[@]}
  if (( body < avail )); then local p; for ((p = 0; p < avail - body; p++)); do L+=(""); done
  elif (( body > avail )); then L=( "${L[@]:0:avail}" ); fi
  L+=("  ${C_DIM}${div}${C_RESET}")
  L+=("  ${C_GREY}log${C_RESET}  ${C_DIM}$(_trunc "${LOG_FILE}" $((w - 6)))${C_RESET}")

  # Emit exactly $rows lines: home, each line cleared to EOL, no trailing
  # newline on the last line (a newline on the bottom row would scroll).
  printf '%s' "$HOME_"
  local n=${#L[@]} j
  for ((j = 0; j < n; j++)); do
    printf '%s%s' "${L[$j]}" "$CLR"
    (( j < n - 1 )) && printf '\n'
  done
  # Always succeed: the final (( ... )) above yields 1 on the last line, and
  # callers (enter_tui, phase_begin, …) end on render — a non-zero return would
  # trip `set -e` and abort the whole run.
  return 0
}

# enter_tui / exit_tui: swap to the alternate screen buffer and back. The alt
# buffer is why the dashboard can "take over" and then vanish cleanly, leaving
# the user's scrollback untouched (same trick less/vim/htop use).
enter_tui() { $TUI || return 0; printf '%s%s%s%s' "$ALT_H" "$CLRSCR" "$HOME_" "$HIDE"; ALT_ON=true; render; }
exit_tui()  { $ALT_ON || return 0; printf '%s%s' "$SHOW" "$ALT_L"; ALT_ON=false; }

# --- Phase engine -----------------------------------------------------------
# push_phase adds a checklist entry (records its index in LAST_PHASE).
push_phase() { PHASE_NAMES+=("$1"); PHASE_STATUS+=("pending"); LAST_PHASE=$(( ${#PHASE_NAMES[@]} - 1 )); }

# add_warn records a non-fatal problem: surfaced in the active phase's detail
# line, collected for the summary, and logged.
add_warn() {
  WARNINGS+=("$1"); logline "WARN: $1"
  if $TUI; then DETAIL="$1"; render
  elif $UI; then printf '        %s%s %s%s\n' "$C_YELLOW" "$G_WARN" "$1" "$C_RESET"
  else printf '        %s %s\n' "$G_WARN" "$1"; fi
}

# phase_begin marks a phase running and remembers the warning count so
# phase_end can auto-decide ✔ vs ⚠.
phase_begin() {
  CUR_PHASE=$1; PHASE_STATUS[$1]="run"; PHASE_T0=$SECONDS; WMARK=${#WARNINGS[@]}; DETAIL="starting…"
  logline "PHASE begin: ${PHASE_NAMES[$1]}"
  if $TUI; then render
  elif $UI; then printf '\n  %s%s%s %s%s%s\n' "$C_RED" "$G_BAR" "$C_RESET" "$C_BOLD" "${PHASE_NAMES[$1]}" "$C_RESET"
  else printf '\n== %s ==\n' "${PHASE_NAMES[$1]}"; fi
}

# phase_detail updates the active phase's sub-line (informational).
phase_detail() {
  DETAIL="$1"; logline "  · $1"
  if $TUI; then render
  elif $UI; then printf '        %s%s %s%s\n' "$C_DIM" "$G_SUB" "$1" "$C_RESET"
  else printf '        %s %s\n' "$G_SUB" "$1"; fi
}

# phase_end sets the final status. Pass an explicit status (ok|warn|fail|skip)
# or omit it to auto-pick ok/warn from whether any warnings were added.
phase_end() {
  local idx=$1 forced="${2:-}" st
  if [[ -n "$forced" ]]; then st="$forced"
  elif (( ${#WARNINGS[@]} > WMARK )); then st="warn"
  else st="ok"; fi
  PHASE_STATUS[$idx]="$st"; logline "PHASE end: ${PHASE_NAMES[$idx]} -> $st"
  if $TUI; then render; return 0; fi
  if $UI; then
    case "$st" in
      ok)   printf '    %s%s%s done\n' "$C_GREEN" "$G_OK" "$C_RESET" ;;
      warn) printf '    %s%s%s done (with notes)\n' "$C_YELLOW" "$G_WARN" "$C_RESET" ;;
      fail) printf '    %s%s%s failed\n' "$C_RED" "$G_BAD" "$C_RESET" ;;
      skip) printf '    %s%s%s skipped\n' "$C_DIM" "$G_SKIP" "$C_RESET" ;;
    esac
  else
    case "$st" in ok) echo "    done" ;; warn) echo "    done (notes)" ;; fail) echo "    FAILED" ;; skip) echo "    skipped" ;; esac
  fi
}

# phase_run runs one command as the active phase's work. Its output is captured
# to the log only. In TUI mode a spinner animates the phase line; otherwise a
# sub-line prints. Returns the command's exit code.
phase_run() {
  local detail="$1"; shift
  DETAIL="$detail"; logline "  run: ${detail}  (cmd: $*)"
  if ! $TUI; then
    if $UI; then printf '        %s%s %s%s\n' "$C_DIM" "$G_SUB" "$detail" "$C_RESET"; else printf '        %s %s\n' "$G_SUB" "$detail"; fi
    if "$@" >> "${LOG_FILE}" 2>&1; then return 0; else return $?; fi
  fi
  "$@" >> "${LOG_FILE}" 2>&1 &
  local pid=$! rc=0
  render
  while kill -0 "$pid" 2>/dev/null; do
    SPIN_I=$(((SPIN_I + 1) % ${#SPIN[@]})); render; sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  render
  return $rc
}

# detect_secureboot: echo "enabled" | "disabled" | "unknown".
# Secure Boot is the firmware "bouncer" that only admits kernel modules signed
# by a key it trusts; a freshly built NVIDIA module is unsigned. Prefer mokutil;
# fall back to reading the SecureBoot EFI variable directly (last byte 1=on).
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
    case "${last}" in 1) echo enabled; return ;; 0) echo disabled; return ;; esac
  fi
  echo unknown
}

# die: fatal error. Leave the dashboard, print a red banner on the normal
# screen with the last log lines, and exit non-zero.
die() {
  exit_tui
  $UI && printf '%s' "$SHOW"
  if $UI; then printf '\n  %s ERROR %s %s%s%s\n' "$C_REDBG$C_WHITE$C_BOLD" "$C_RESET" "$C_RED" "$1" "$C_RESET"
  else printf '\nERROR: %s\n' "$1" >&2; fi
  logline "FATAL: $1"
  dump_tail
  [[ -n "${LOG_FILE}" ]] && printf '  %sSee the full log: %s%s\n' "$C_DIM" "${LOG_FILE}" "$C_RESET" >&2
  exit 1
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
NX_EDITION="${NX_EDITION:-witness}"          # witness | meta
INSTALL_NX="${INSTALL_NX:-true}"             # install the mediaserver at all?
INSTALL_WEBMIN="${INSTALL_WEBMIN:-false}"    # install the Webmin admin panel?
INSTALL_GPU_DRIVERS="${INSTALL_GPU_DRIVERS:-auto}"  # auto | true | false
SET_TIMEZONE="${SET_TIMEZONE:-America/New_York}"    # empty string skips tz change
ENABLE_NTP="${ENABLE_NTP:-true}"             # enable network time sync?
NONINTERACTIVE="${NONINTERACTIVE:-false}"    # force-skip the interactive menu?

# Pinned NX release. Bump these when TWG pins a new build.
# See README.md -> "Updating the pinned version".
NX_VERSION="6.1.2"
NX_BUILD="42921"

# Proper product names for display — never show a bare lowercase "witness".
edition_label() {
  case "$1" in meta) printf 'NX Meta' ;; *) printf 'NX Witness' ;; esac
}

# Run-state flags / values, filled in as we go and used to build the summary.
NX_DONE=false
WEBMIN_DONE=false
NVIDIA_INSTALLED=false
SECUREBOOT="unknown"
REBOOT_NEEDED=false
SERVICE_NAME=""
SERVICE_STATE=""

# ---------------------------------------------------------------------------
# 1a. Force every apt/dpkg step to be truly non-interactive
# ---------------------------------------------------------------------------
# `apt-get -y` answers apt's OWN prompts, but does NOT stop a package's
# post-install script from popping a debconf/whiptail dialog (e.g. the NX
# "Complete the setup process" note). On a headless/remote session that dialog
# blocks forever. In plain English: `-y` tells the cashier "yes", but a package
# can still hand you a form to sign — this makes debconf skip the form entirely.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
# needrestart (Ubuntu 22.04+) is the OTHER common headless blocker; tell it to
# just restart services automatically and never prompt.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ---------------------------------------------------------------------------
# 2. Install logging — capture EVERYTHING to a file for later debugging
# ---------------------------------------------------------------------------
# The dashboard shows the summary; every command's raw output goes here, so the
# log is a complete, timestamped, plain-text record of the run.
LOG_TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-/var/log/twg-nx-deploy-${LOG_TS}.log}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
{
  echo "=========================================================="
  echo " TWG Security — NX Mediaserver bootstrap (installer v${INSTALLER_VERSION})"
  echo " $(date)"
  echo "=========================================================="
} >> "${LOG_FILE}" 2>/dev/null || die "Cannot write to log file: ${LOG_FILE}"

# Restore the cursor, leave the alt-screen, and remove the temp dir on ANY exit
# (success, error, Ctrl-C) so a killed run never leaves a mangled terminal.
cleanup() {
  printf '%s' "${SHOW}"
  $ALT_ON && printf '%s' "${ALT_L}"
  [[ -n "${WORKDIR:-}" ]] && rm -rf "${WORKDIR}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Banner + system context (normal screen, before the dashboard)
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
MENU_TTY=""
if [[ "${NONINTERACTIVE}" != "true" ]]; then
  if { true >/dev/tty; } 2>/dev/null; then MENU_TTY="/dev/tty"; fi
fi

# ask_yn: yes/no with a default. Echoes true/false; prompt goes to stderr.
ask_yn() {
  local prompt="$1" def="$2" ans hint
  if [[ "${def}" == "true" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '    %s%s%s %s%s%s ' "$C_WHITE" "${prompt}" "$C_RESET" "$C_DIM" "${hint}" "$C_RESET" >&2
  read -r ans < "${MENU_TTY}" || ans=""
  ans="${ans,,}"
  case "${ans}" in "") echo "${def}" ;; y|yes) echo "true" ;; n|no) echo "false" ;; *) echo "${def}" ;; esac
}
# ask_val: free-text value with a default (blank input keeps default).
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

  case "${NX_EDITION}" in meta) ed_def="2" ;; *) ed_def="1" ;; esac
  printf '    %sNX edition:%s  %s1%s) NX Witness   %s2%s) NX Meta\n' \
    "$C_WHITE" "$C_RESET" "$C_RED" "$C_RESET" "$C_RED" "$C_RESET" >&2
  edchoice="$(ask_val "Choose 1 or 2" "${ed_def}")"
  case "${edchoice,,}" in
    1|witness) NX_EDITION="witness" ;;
    2|meta)    NX_EDITION="meta" ;;
    *)         warn "Unrecognized '${edchoice}', keeping '$(edition_label "${NX_EDITION}")'." ;;
  esac

  # We deliberately do NOT ask "install the mediaserver?" — that's the whole
  # reason someone runs this. Automation can still set INSTALL_NX=false.
  case "${INSTALL_GPU_DRIVERS}" in false) gpu_def="false" ;; *) gpu_def="true" ;; esac
  if [[ "$(ask_yn "Detect GPU and install drivers?" "${gpu_def}")" == "true" ]]; then
    INSTALL_GPU_DRIVERS="auto"
  else
    INSTALL_GPU_DRIVERS="false"
  fi
  INSTALL_WEBMIN="$(ask_yn "Install Webmin admin panel?" "${INSTALL_WEBMIN}")"
  SET_TIMEZONE="$(ask_val "Timezone (blank = leave unchanged)" "${SET_TIMEZONE}")"
  ENABLE_NTP="$(ask_yn "Enable NTP time sync?" "${ENABLE_NTP}")"
else
  note "Non-interactive run — using env-var defaults (no menu)."
fi

# ---------------------------------------------------------------------------
# 6. Resolve the package URL from the edition (unless explicitly overridden)
# ---------------------------------------------------------------------------
WITNESS_URL="https://updates.networkoptix.com/default/${NX_BUILD}/linux/nxwitness-server-${NX_VERSION}.${NX_BUILD}-linux_x64.deb"
META_URL="https://updates.networkoptix.com/metavms/${NX_BUILD}/linux/metavms-server-${NX_VERSION}.${NX_BUILD}-linux_x64.deb"

if [[ -n "${NX_PKG_URL:-}" ]]; then
  PKG_URL="${NX_PKG_URL}"
else
  case "${NX_EDITION}" in
    witness) PKG_URL="${WITNESS_URL}" ;;
    meta)    PKG_URL="${META_URL}" ;;
    *)       die "NX_EDITION must be 'witness' or 'meta' (got: '${NX_EDITION}')." ;;
  esac
fi
PKG_FILE="$(basename "${PKG_URL}")"
case "${NX_EDITION}" in
  meta) SERVICE_HINT="networkoptix-metavms-mediaserver" ;;
  *)    SERVICE_HINT="networkoptix-mediaserver" ;;
esac

# ---------------------------------------------------------------------------
# 7. Show the plan (normal screen), then build the dashboard checklist
# ---------------------------------------------------------------------------
section "Deployment plan"
kv "Edition"     "$(edition_label "${NX_EDITION}")"
kv "Version"     "${NX_VERSION} build ${NX_BUILD}"
kv "Install NX"  "${INSTALL_NX}"
kv "GPU drivers" "${INSTALL_GPU_DRIVERS}"
kv "Webmin"      "${INSTALL_WEBMIN}"
kv "Timezone"    "${SET_TIMEZONE:-<unchanged>}"
kv "NTP"         "${ENABLE_NTP}"
kv "Package"     "${PKG_FILE}"

# One-line plan for the dashboard header.
PLAN_SUMMARY="$(edition_label "${NX_EDITION}") ${NX_VERSION} · GPU ${INSTALL_GPU_DRIVERS} · Webmin ${INSTALL_WEBMIN} · TZ ${SET_TIMEZONE:-unchanged}"

# Build the phase checklist from the chosen options (order = run order).
P_DL=-1; P_NX=-1; P_GPU=-1; P_WEB=-1; P_TIME=-1; P_SVC=-1
ED_LABEL="$(edition_label "${NX_EDITION}")"
if [[ "${INSTALL_NX}" == "true" ]]; then
  push_phase "Download ${ED_LABEL} package";    P_DL=$LAST_PHASE
  push_phase "Install ${ED_LABEL} mediaserver"; P_NX=$LAST_PHASE
fi
[[ "${INSTALL_GPU_DRIVERS}" != "false" ]] && { push_phase "GPU drivers"; P_GPU=$LAST_PHASE; }
[[ "${INSTALL_WEBMIN}" == "true" ]]       && { push_phase "Webmin admin panel"; P_WEB=$LAST_PHASE; }
push_phase "Time & clock"; P_TIME=$LAST_PHASE
[[ "${INSTALL_NX}" == "true" ]] && { push_phase "Service status"; P_SVC=$LAST_PHASE; }

# ---------------------------------------------------------------------------
# 8. Temp workspace (removed on exit by the cleanup trap)
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"

# ===========================================================================
# 9. Take over the screen and run the phases
# ===========================================================================
enter_tui

# --- NX mediaserver: download + install ------------------------------------
if [[ "${INSTALL_NX}" == "true" ]]; then
  phase_begin "$P_DL"
  if ! phase_run "Fetching ${PKG_FILE}" \
      curl -fSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${PKG_FILE}" "${PKG_URL}"; then
    phase_end "$P_DL" fail
    die "Failed to download the NX package from:
        ${PKG_URL}"
  fi
  phase_end "$P_DL"

  phase_begin "$P_NX"
  phase_run "Refreshing package index" apt-get update -y || true
  # apt resolves the .deb's dependencies; the Dpkg::Options keep it unattended
  # on a conffile conflict (keep existing / fall back to default) so the
  # mediaserver postinst never blocks headless.
  if ! phase_run "Installing package (apt resolves dependencies)" \
      apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${WORKDIR}/${PKG_FILE}"; then
    phase_end "$P_NX" fail
    die "NX mediaserver install failed. See the log for apt's output."
  fi
  NX_DONE=true
  phase_end "$P_NX"
fi

# --- GPU detection + driver install ----------------------------------------
# Best-effort: problems here add a warning and continue, they don't abort.
if [[ "${INSTALL_GPU_DRIVERS}" != "false" ]]; then
  phase_begin "$P_GPU"

  if ! command -v lspci >/dev/null 2>&1; then
    phase_run "Installing pciutils (for hardware detection)" apt-get install -y pciutils \
      || add_warn "Could not install pciutils; GPU detection may be limited."
  fi

  GPU_LINES="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)"
  printf '%s\n' "${GPU_LINES}" >> "${LOG_FILE}" 2>/dev/null || true

  if [[ -z "${GPU_LINES}" ]]; then
    phase_detail "No GPU detected — nothing to install."
    phase_end "$P_GPU" skip
  else
    HAS_NVIDIA=false; HAS_AMD=false; HAS_INTEL=false
    grep -qiE 'nvidia' <<<"${GPU_LINES}" && HAS_NVIDIA=true
    # Match AMD by vendor string, NOT a bare "ati" (that hits "VGA comp-ati-ble").
    grep -qiE 'advanced micro devices|amd/ati|radeon|\bamd\b' <<<"${GPU_LINES}" && HAS_AMD=true
    grep -qiE 'intel' <<<"${GPU_LINES}" && HAS_INTEL=true

    _vend=""; $HAS_NVIDIA && _vend+="NVIDIA "; $HAS_AMD && _vend+="AMD "; $HAS_INTEL && _vend+="Intel "
    phase_detail "Detected: ${_vend:-unrecognized GPU}"

    IS_UBUNTU=false
    if [[ "${DISTRO_ID}" == "ubuntu" ]] || grep -qi 'ubuntu' <<<"${DISTRO_LIKE}"; then IS_UBUNTU=true; fi

    phase_run "Refreshing package index" apt-get update -y || true

    if [[ "${HAS_NVIDIA}" == "true" ]]; then
      # DKMS builds the module against THIS kernel; install headers + compiler
      # explicitly so the build is reliable on minimal/HWE images.
      phase_run "Installing kernel headers + DKMS build tools" \
        apt-get install -y "linux-headers-$(uname -r)" build-essential dkms \
        || add_warn "Kernel headers / DKMS tools failed to install; the module build may fail."

      SECUREBOOT="$(detect_secureboot)"
      [[ "${SECUREBOOT}" == "enabled" ]] && \
        add_warn "Secure Boot is ON — the NVIDIA module needs its key enrolled (MOK Manager) or Secure Boot disabled before it can load."

      if [[ "${IS_UBUNTU}" == "true" ]]; then
        if phase_run "Installing ubuntu-drivers-common" apt-get install -y ubuntu-drivers-common; then
          phase_run "Installing recommended NVIDIA driver" ubuntu-drivers install \
            || phase_run "Retrying with ubuntu-drivers autoinstall" ubuntu-drivers autoinstall \
            || add_warn "NVIDIA driver install failed — install it manually."
        else
          add_warn "Could not install ubuntu-drivers-common — skipping NVIDIA."
        fi
      else
        phase_run "Installing nvidia-driver (Debian contrib/non-free)" apt-get install -y nvidia-driver \
          || add_warn "nvidia-driver unavailable. Enable contrib/non-free/non-free-firmware, apt-get update, then install nvidia-driver."
      fi

      # Verify the module built. DKMS installs it into the running kernel's
      # tree, so 'modinfo nvidia' succeeds right away even though it can't LOAD
      # until reboot — separating "install failed" from "just needs a reboot".
      if modinfo nvidia >/dev/null 2>&1; then
        NVIDIA_INSTALLED=true
        phase_detail "NVIDIA driver verified (version $(modinfo -F version nvidia 2>/dev/null || echo '?')) — loads on reboot."
      else
        add_warn "NVIDIA driver files not found after install ('modinfo nvidia' failed) — the DKMS build likely failed; check 'dkms status'."
      fi
    fi

    if [[ "${HAS_AMD}" == "true" ]]; then
      phase_run "Installing AMD Mesa VAAPI drivers" apt-get install -y mesa-va-drivers vainfo \
        || add_warn "AMD VAAPI packages failed to install."
    fi

    if [[ "${HAS_INTEL}" == "true" ]]; then
      phase_run "Installing Intel VAAPI drivers" apt-get install -y intel-media-va-driver i965-va-driver vainfo \
        || add_warn "Intel VAAPI packages failed to install."
    fi

    phase_end "$P_GPU"
  fi
fi

# --- Webmin (optional) ------------------------------------------------------
if [[ "${INSTALL_WEBMIN}" == "true" ]]; then
  phase_begin "$P_WEB"
  # Composite: repo setup + install as one unit (a function so it's atomic).
  install_webmin() {
    apt-get install -y software-properties-common apt-transport-https curl
    curl -fsSL https://download.webmin.com/developers-key.asc | gpg --dearmor -o /usr/share/keyrings/webmin.gpg
    echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/newkey/repository stable contrib" \
      > /etc/apt/sources.list.d/webmin.list
    apt-get update -y
    apt-get install -y webmin
  }
  if phase_run "Adding repo and installing Webmin" install_webmin; then
    WEBMIN_DONE=true; phase_end "$P_WEB"
  else
    add_warn "Webmin install failed — see the log."; phase_end "$P_WEB" warn
  fi
fi

# --- Time: timezone, NTP, hardware clock -----------------------------------
phase_begin "$P_TIME"
if [[ -n "${SET_TIMEZONE}" ]]; then
  phase_run "Setting timezone to ${SET_TIMEZONE}" timedatectl set-timezone "${SET_TIMEZONE}" \
    || add_warn "Failed to set timezone."
else
  phase_detail "Leaving timezone unchanged."
fi
if [[ "${ENABLE_NTP}" == "true" ]]; then
  phase_run "Enabling network time sync (NTP)" timedatectl set-ntp true \
    || add_warn "Failed to enable NTP."
else
  phase_detail "Leaving NTP state unchanged."
fi
phase_run "Syncing hardware clock" hwclock --systohc \
  || add_warn "hwclock --systohc failed (normal on VMs/containers without an RTC)."
timedatectl >> "${LOG_FILE}" 2>&1 || true
TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
NTP_NOW="$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"
phase_detail "Timezone ${TZ_NOW} · NTP ${NTP_NOW}"
phase_end "$P_TIME"

# --- Mediaserver service status --------------------------------------------
if [[ "${INSTALL_NX}" == "true" ]]; then
  phase_begin "$P_SVC"
  SERVICE_NAME="$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -m1 'mediaserver' || true)"
  SERVICE_NAME="${SERVICE_NAME:-${SERVICE_HINT}.service}"
  systemctl status "${SERVICE_NAME}" --no-pager >> "${LOG_FILE}" 2>&1 || true
  SERVICE_STATE="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
  SERVICE_STATE="${SERVICE_STATE:-unknown}"
  case "${SERVICE_STATE}" in
    active)   phase_detail "${SERVICE_NAME} is active (running)."; phase_end "$P_SVC" ;;
    inactive) phase_detail "${SERVICE_NAME} installed, not started yet (finish setup to start it)."; phase_end "$P_SVC" ;;
    failed)   add_warn "${SERVICE_NAME} reports 'failed' — check the log."; phase_end "$P_SVC" warn ;;
    *)        phase_detail "${SERVICE_NAME}: ${SERVICE_STATE}."; phase_end "$P_SVC" ;;
  esac
fi

# ===========================================================================
# 10. Restore the screen and print the summary
# ===========================================================================
exit_tui

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-<server-ip>}"

section "Summary"
$NX_DONE     && kv "NX server"  "http://${SERVER_IP}:7001  ($(edition_label "${NX_EDITION}") ${NX_VERSION})"
$WEBMIN_DONE && kv "Webmin"     "https://${SERVER_IP}:10000"
kv "Log file" "${LOG_FILE}"

if (( ${#WARNINGS[@]} )); then
  printf '\n'
  for w in "${WARNINGS[@]}"; do warn "$w"; done
fi

if $NVIDIA_INSTALLED; then
  if [[ "${SECUREBOOT}" == "enabled" ]]; then
    note "The NVIDIA driver is installed. Because Secure Boot is on, it needs one"
    note "extra step to load: enroll the driver's key at the 'MOK Manager' screen"
    note "on the next boot, or turn off Secure Boot in BIOS/UEFI."
  else
    note "The NVIDIA driver is installed and ready — it just needs a reboot to load."
    REBOOT_NEEDED=true
  fi
fi
if $NX_DONE && [[ "${SERVICE_STATE}" != "active" ]]; then
  note "When you're ready, finish NX setup from the Nx client's 'New Site' tile,"
  note "or open http://${SERVER_IP}:7001 in a browser."
fi

if $UI; then printf '\n  %s All done %s\n\n' "$C_REDBG$C_WHITE$C_BOLD" "$C_RESET"
else printf '\nAll done.\n\n'; fi
logline "Bootstrap complete."

# ---------------------------------------------------------------------------
# 11. Offer to reboot (only when something we installed needs it)
# ---------------------------------------------------------------------------
# The GPU driver loads at boot, so a reboot is the last step. Rather than just
# telling the tech to do it, offer to do it for them — but only on a real
# terminal that can answer. In automation we just leave a friendly note.
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

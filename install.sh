#!/usr/bin/env bash
#
# TWG Security — NX Mediaserver one-line bootstrap
# ------------------------------------------------
# Provisions a fresh Ubuntu/Debian server with the Network Optix NX
# mediaserver (Witness or Meta), plus optional Webmin, GPU drivers, timezone,
# and NTP. Everything is logged to a file for later debugging.
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
# This file is PUBLIC. No secrets, license keys, or internal hostnames live here.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Must run as root
# ---------------------------------------------------------------------------
# The mediaserver .deb installs a systemd service and writes to /opt, and GPU
# driver install touches apt/system state, so we need real root. Bail
# immediately with a readable message if we don't have it.
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: this installer must run as root. Re-run with sudo, e.g.:" >&2
  echo "  curl -fsSL <url> | sudo bash" >&2
  exit 1
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

# Pinned NX release. Bump these when TWG pins a new build.
# See README.md -> "Updating the pinned version".
NX_VERSION="6.1.2"
NX_BUILD="42921"

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
# Timestamped log under /var/log by default; override with LOG_FILE. We route
# all stdout+stderr through `tee` so output shows live on the console AND is
# persisted. This is set up first so the menu and every step below are logged.
LOG_TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-/var/log/twg-nx-deploy-${LOG_TS}.log}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
# tee -a keeps appending if the file already exists (safe to re-run).
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=========================================================="
echo " TWG Security — NX Mediaserver bootstrap"
echo " $(date)"
echo " Logging to: ${LOG_FILE}"
echo "=========================================================="

# Record system context up front so a debugger has it without asking.
echo ">>> System info"
. /etc/os-release 2>/dev/null || true
DISTRO_ID="${ID:-unknown}"            # ubuntu | debian | ...
DISTRO_LIKE="${ID_LIKE:-}"            # e.g. "debian"
echo "    distro : ${PRETTY_NAME:-unknown} (id=${DISTRO_ID})"
echo "    kernel : $(uname -r)"
echo "    arch   : $(uname -m)"
echo "    host   : $(hostname 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# 3. Confirm this is a Debian/Ubuntu box (we need apt-get)
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: apt-get not found. This installer supports Debian/Ubuntu only." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Interactive menu (only when a terminal is available)
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
  read -rp "${prompt} ${hint} " ans < "${MENU_TTY}" >&2 || ans=""
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
  read -rp "${prompt} [${def:-<empty>}] " ans < "${MENU_TTY}" >&2 || ans=""
  if [[ -z "${ans}" ]]; then echo "${def}"; else echo "${ans}"; fi
}

if [[ -n "${MENU_TTY}" ]]; then
  echo ""
  echo "----------------------------------------------------------"
  echo " Interactive setup — press Enter to accept the [default]."
  echo "----------------------------------------------------------"

  # NX edition — numbered pick so a tech types 1 or 2 instead of the word.
  # The edition words (witness/meta) still work too. The default is shown as
  # its number in [brackets].
  case "${NX_EDITION}" in
    meta) ed_def="2" ;;
    *)    ed_def="1" ;;
  esac
  echo "NX edition:  1) witness   2) meta" >&2
  edchoice="$(ask_val "Choose 1 or 2" "${ed_def}")"
  case "${edchoice,,}" in
    1|witness) NX_EDITION="witness" ;;
    2|meta)    NX_EDITION="meta" ;;
    *)         echo "    unrecognized '${edchoice}', keeping '${NX_EDITION}'" ;;
  esac

  # Toggles.
  INSTALL_NX="$(ask_yn "Install the NX mediaserver?" "${INSTALL_NX}")"
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
  echo "----------------------------------------------------------"
else
  echo ">>> Non-interactive run — using env-var defaults (no menu)."
fi

# ---------------------------------------------------------------------------
# 5. Resolve the package URL from the edition (unless explicitly overridden)
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
    *)
      echo "ERROR: NX_EDITION must be 'witness' or 'meta' (got: '${NX_EDITION}')." >&2
      exit 1
      ;;
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

# Echo the effective plan (post-menu) so the log records exactly what ran.
echo ">>> Effective configuration"
echo "    Edition        : ${NX_EDITION}"
echo "    NX version     : ${NX_VERSION} build ${NX_BUILD}"
echo "    Install NX     : ${INSTALL_NX}"
echo "    GPU drivers    : ${INSTALL_GPU_DRIVERS}"
echo "    Install Webmin : ${INSTALL_WEBMIN}"
echo "    Timezone       : ${SET_TIMEZONE:-<unchanged>}"
echo "    Enable NTP     : ${ENABLE_NTP}"
echo "    Package        : ${PKG_FILE}"

# ---------------------------------------------------------------------------
# 6. Temp workspace with guaranteed cleanup
# ---------------------------------------------------------------------------
# Download into a private temp dir and remove it on any exit (success, error,
# or Ctrl-C) via a trap so we never leave stray .deb files behind.
WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# ===========================================================================
# 7. NX mediaserver install
# ===========================================================================
if [[ "${INSTALL_NX}" == "true" ]]; then

  # --- 7a. Download the .deb -----------------------------------------------
  echo ">>> Downloading ${PKG_FILE}"
  echo "    from ${PKG_URL}"
  curl -fSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${PKG_FILE}" "${PKG_URL}"

  # --- 7b. Install ---------------------------------------------------------
  # apt-get resolves the .deb's dependencies for us. The leading ./ tells apt
  # this is a local file, not a repo package name. The Dpkg::Options keep the
  # install unattended even if a config-file conflict comes up: keep the
  # existing conffile (confold) and fall back to the package default when
  # there's no old version (confdef), instead of stopping to ask. Combined
  # with DEBIAN_FRONTEND=noninteractive (set at the top) this guarantees the
  # mediaserver postinst never blocks on that whiptail "Complete the setup"
  # note that hangs headless/remote runs.
  echo ">>> Installing ${PKG_FILE}"
  apt-get update -y
  apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${WORKDIR}/${PKG_FILE}"
  echo "    NX mediaserver installed."
  echo "    NOTE: the server is installed but NOT yet set up. Finish setup in"
  echo "          the Nx client via the 'New Site' tile, or open the server's"
  echo "          web page at http://<server-ip>:7001 in a browser."

else
  echo ">>> Skipping NX install (INSTALL_NX=${INSTALL_NX})."
fi

# ===========================================================================
# 8. GPU detection + driver install
# ===========================================================================
# Detects an installed GPU and installs the vendor-appropriate drivers so NX
# can use hardware-accelerated decoding. INSTALL_GPU_DRIVERS:
#   false -> skip entirely
#   auto  -> detect; install only for a detected vendor (default)
#   true  -> same as auto (kept as an explicit "yes")
# GPU setup is an enhancement, not core provisioning, so failures here WARN
# and continue rather than aborting the whole run.
if [[ "${INSTALL_GPU_DRIVERS}" != "false" ]]; then
  echo ">>> GPU detection"

  # lspci (pciutils) is how we enumerate hardware; install it if missing.
  if ! command -v lspci >/dev/null 2>&1; then
    echo "    installing pciutils (for lspci)"
    apt-get install -y pciutils || echo "    WARNING: could not install pciutils; GPU detection may be limited."
  fi

  # Grab display-class devices (VGA / 3D / Display controllers).
  GPU_LINES="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)"

  if [[ -z "${GPU_LINES}" ]]; then
    echo "    no GPU detected — skipping driver install."
  else
    echo "    detected:"
    echo "${GPU_LINES}" | sed 's/^/      /'

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

    apt-get update -y || true

    # --- NVIDIA ------------------------------------------------------------
    if [[ "${HAS_NVIDIA}" == "true" ]]; then
      echo ">>> NVIDIA GPU — installing drivers"
      if [[ "${IS_UBUNTU}" == "true" ]]; then
        # ubuntu-drivers picks the recommended (latest stable) driver for the
        # exact card — the vendor-blessed path on Ubuntu.
        if apt-get install -y ubuntu-drivers-common; then
          echo "    recommended drivers per ubuntu-drivers:"
          ubuntu-drivers devices 2>/dev/null | sed 's/^/      /' || true
          if ubuntu-drivers install; then
            echo "    NVIDIA driver installed (ubuntu-drivers)."
          else
            echo "    WARNING: 'ubuntu-drivers install' failed; trying autoinstall."
            ubuntu-drivers autoinstall || echo "    WARNING: NVIDIA driver install failed — install manually."
          fi
        else
          echo "    WARNING: could not install ubuntu-drivers-common — skipping NVIDIA."
        fi
      else
        # Debian: the NVIDIA driver lives in contrib/non-free, which may not be
        # enabled. Attempt it, and if it fails point the tech at the manual fix
        # rather than silently mangling their apt sources.
        echo "    Debian detected — attempting nvidia-driver from contrib/non-free."
        if apt-get install -y nvidia-driver; then
          echo "    NVIDIA driver installed."
        else
          echo "    WARNING: nvidia-driver unavailable. Enable 'contrib non-free"
          echo "             non-free-firmware' in /etc/apt/sources.list, run"
          echo "             'apt-get update', then 'apt-get install nvidia-driver'."
        fi
      fi
      # Report GPU state if the tool is present now.
      command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || true
      echo "    NOTE: a reboot is recommended so the NVIDIA kernel module loads."
    fi

    # --- AMD ---------------------------------------------------------------
    if [[ "${HAS_AMD}" == "true" ]]; then
      echo ">>> AMD GPU — installing Mesa VAAPI drivers"
      # The amdgpu kernel driver ships in-kernel; add Mesa's VAAPI stack for
      # hardware video decode plus vainfo to check it.
      apt-get install -y mesa-va-drivers vainfo \
        || echo "    WARNING: AMD VAAPI packages failed to install."
    fi

    # --- Intel -------------------------------------------------------------
    if [[ "${HAS_INTEL}" == "true" ]]; then
      echo ">>> Intel GPU — installing VAAPI drivers"
      # i965 (older) + intel-media (Gen8+) VAAPI drivers cover the common range.
      apt-get install -y intel-media-va-driver i965-va-driver vainfo \
        || echo "    WARNING: Intel VAAPI packages failed to install."
    fi

    echo "    GPU driver step complete."
  fi
else
  echo ">>> Skipping GPU driver install (INSTALL_GPU_DRIVERS=false)."
fi

# ===========================================================================
# 9. Webmin (optional)
# ===========================================================================
# Only runs when explicitly enabled. Adds Webmin's signed apt repo and installs
# it. Re-running is safe: the key/repo files are simply overwritten.
if [[ "${INSTALL_WEBMIN}" == "true" ]]; then
  echo ">>> Installing Webmin"

  # Tooling Webmin's repo setup needs.
  apt install -y software-properties-common apt-transport-https curl

  # Import Webmin's signing key into a dedicated keyring.
  curl -fsSL https://download.webmin.com/developers-key.asc | gpg --dearmor -o /usr/share/keyrings/webmin.gpg

  # Register the signed repository.
  echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/newkey/repository stable contrib" > /etc/apt/sources.list.d/webmin.list

  # Install Webmin from the freshly-added repo.
  apt update && apt install -y webmin

  # Best-effort local IP for the access hint (falls back to a placeholder).
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SERVER_IP="${SERVER_IP:-<server-ip>}"
  echo "    Webmin installed. Access it at: https://${SERVER_IP}:10000"
else
  echo ">>> Skipping Webmin install (INSTALL_WEBMIN=${INSTALL_WEBMIN})."
fi

# ===========================================================================
# 10. Time: timezone, NTP, hardware clock
# ===========================================================================
echo ">>> Configuring time"

# Set the timezone only when a non-empty value is provided.
if [[ -n "${SET_TIMEZONE}" ]]; then
  echo "    setting timezone to ${SET_TIMEZONE}"
  timedatectl set-timezone "${SET_TIMEZONE}"
else
  echo "    SET_TIMEZONE empty — leaving timezone unchanged."
fi

# Enable network time synchronization when requested.
if [[ "${ENABLE_NTP}" == "true" ]]; then
  echo "    enabling NTP (network time sync)"
  timedatectl set-ntp true
else
  echo "    ENABLE_NTP=${ENABLE_NTP} — leaving NTP state unchanged."
fi

# Always sync the hardware (RTC) clock from the now-correct system clock.
echo "    syncing hardware clock (hwclock --systohc)"
hwclock --systohc || echo "    WARNING: hwclock --systohc failed (common on VMs/containers without an RTC)."

echo ">>> Current time settings:"
timedatectl

# ===========================================================================
# 11. Report the mediaserver service status
# ===========================================================================
# Detect the actual installed *mediaserver* unit rather than hardcoding it, so
# this stays correct across editions and future naming tweaks.
if [[ "${INSTALL_NX}" == "true" ]]; then
  echo ">>> NX mediaserver service status"

  # List loaded units and grab the first one whose name contains 'mediaserver'.
  SERVICE_NAME="$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -m1 'mediaserver' || true)"

  # Fall back to the edition-based hint if enumeration found nothing.
  SERVICE_NAME="${SERVICE_NAME:-${SERVICE_HINT}.service}"

  echo "    service: ${SERVICE_NAME}"
  # --no-pager keeps output flowing when piped; don't let a non-zero status
  # (e.g. service not yet started) abort the script.
  systemctl status "${SERVICE_NAME}" --no-pager || true
fi

echo "=========================================================="
echo " TWG Security — bootstrap complete."
echo " Full install log saved to: ${LOG_FILE}"
echo "=========================================================="

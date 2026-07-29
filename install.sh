#!/usr/bin/env bash
#
# TWG Security — NX Mediaserver one-line bootstrap
# ------------------------------------------------
# Provisions a fresh Ubuntu/Debian server with the Network Optix NX
# mediaserver (Witness or Meta), plus optional Webmin, timezone, and NTP.
#
# Usage (as root):
#   curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
#
# Every knob is an environment variable and can be overridden inline, e.g.:
#   curl -fsSL <url> | sudo NX_EDITION=meta INSTALL_WEBMIN=true bash
#
# This file is PUBLIC. No secrets, license keys, or internal hostnames live here.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Must run as root
# ---------------------------------------------------------------------------
# The mediaserver .deb installs a systemd service and writes to /opt, so we
# need real root. Bail immediately with a readable message if we don't have it.
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: this installer must run as root. Re-run with sudo, e.g.:" >&2
  echo "  curl -fsSL <url> | sudo bash" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Configuration (all overridable at runtime via env vars)
# ---------------------------------------------------------------------------
# TWG defaults. Override any of these on the command line.
NX_EDITION="${NX_EDITION:-witness}"          # witness | meta
INSTALL_NX="${INSTALL_NX:-true}"             # install the mediaserver at all?
INSTALL_WEBMIN="${INSTALL_WEBMIN:-false}"    # install the Webmin admin panel?
SET_TIMEZONE="${SET_TIMEZONE:-America/New_York}"  # empty string skips tz change
ENABLE_NTP="${ENABLE_NTP:-true}"             # enable network time sync?
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-true}"   # verify the .deb SHA256 before install?

# Pinned NX release. Bump these (and regenerate checksums.txt) when TWG pins a
# new build. See README.md -> "Updating the pinned version".
NX_VERSION="6.1.2"
NX_BUILD="42921"

# Where to find checksums.txt. When piped from GitHub Pages we can't read a
# local copy, so we fetch it from the same origin the installer came from.
# Override with CHECKSUMS_URL, or provide the hash directly via NX_PKG_SHA256.
CHECKSUMS_URL="${CHECKSUMS_URL:-https://twg-security.github.io/twg-nx-deploy/checksums.txt}"

# ---------------------------------------------------------------------------
# 2. Resolve the package URL from the edition (unless explicitly overridden)
# ---------------------------------------------------------------------------
# Pinned download URLs for NX 6.1.2 build 42921. If NX_PKG_URL is set we honor
# it verbatim and ignore NX_EDITION for URL selection.
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

# The filename we download to and the name we look up in checksums.txt.
PKG_FILE="$(basename "${PKG_URL}")"

# Pick the matching systemd service name for the chosen edition. Detected at
# the end from the actual installed units, but we keep a sensible default here.
case "${NX_EDITION}" in
  meta) SERVICE_HINT="networkoptix-metavms-mediaserver" ;;
  *)    SERVICE_HINT="networkoptix-mediaserver" ;;
esac

echo "=========================================================="
echo " TWG Security — NX Mediaserver bootstrap"
echo "=========================================================="
echo " Edition        : ${NX_EDITION}"
echo " NX version     : ${NX_VERSION} build ${NX_BUILD}"
echo " Install NX     : ${INSTALL_NX}"
echo " Install Webmin : ${INSTALL_WEBMIN}"
echo " Timezone       : ${SET_TIMEZONE:-<unchanged>}"
echo " Enable NTP     : ${ENABLE_NTP}"
echo " Verify hash    : ${VERIFY_CHECKSUM}"
echo " Package        : ${PKG_FILE}"
echo "=========================================================="

# ---------------------------------------------------------------------------
# 3. Confirm this is a Debian/Ubuntu box (we need apt-get)
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: apt-get not found. This installer supports Debian/Ubuntu only." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Temp workspace with guaranteed cleanup
# ---------------------------------------------------------------------------
# Download into a private temp dir and remove it on any exit (success, error,
# or Ctrl-C) via a trap so we never leave stray .deb files behind.
WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# ===========================================================================
# 5. NX mediaserver install
# ===========================================================================
if [[ "${INSTALL_NX}" == "true" ]]; then

  # --- 5a. Download the .deb -----------------------------------------------
  echo ">>> Downloading ${PKG_FILE}"
  echo "    from ${PKG_URL}"
  curl -fSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${PKG_FILE}" "${PKG_URL}"

  # --- 5b. Verify the checksum ---------------------------------------------
  # Preference order for the expected hash:
  #   1. NX_PKG_SHA256 env var (explicit, wins)
  #   2. the line for PKG_FILE inside checksums.txt (fetched from CHECKSUMS_URL)
  if [[ "${VERIFY_CHECKSUM}" == "true" ]]; then
    echo ">>> Verifying SHA256 checksum"

    EXPECTED_SHA=""
    if [[ -n "${NX_PKG_SHA256:-}" ]]; then
      # Operator handed us the hash directly.
      EXPECTED_SHA="${NX_PKG_SHA256}"
      echo "    using SHA256 from NX_PKG_SHA256 env var"
    else
      # Try to pull checksums.txt and find the row for our exact filename.
      echo "    looking up ${PKG_FILE} in ${CHECKSUMS_URL}"
      if curl -fsSL -o "${WORKDIR}/checksums.txt" "${CHECKSUMS_URL}" 2>/dev/null; then
        # A valid row is "<64-hex-hash>  <filename>". Reject placeholders.
        EXPECTED_SHA="$(awk -v f="${PKG_FILE}" \
          '$2 == f && $1 ~ /^[0-9a-fA-F]{64}$/ { print $1; exit }' \
          "${WORKDIR}/checksums.txt" || true)"
      else
        echo "    WARNING: could not fetch checksums.txt from ${CHECKSUMS_URL}"
      fi
    fi

    if [[ -n "${EXPECTED_SHA}" ]]; then
      # Build a checkfile and let sha256sum -c do the compare. Fail loudly.
      echo "${EXPECTED_SHA}  ${WORKDIR}/${PKG_FILE}" > "${WORKDIR}/verify.sha256"
      if sha256sum -c "${WORKDIR}/verify.sha256"; then
        echo "    checksum OK"
      else
        echo "ERROR: SHA256 mismatch for ${PKG_FILE}. Refusing to install." >&2
        echo "       expected: ${EXPECTED_SHA}" >&2
        echo "       actual  : $(sha256sum "${WORKDIR}/${PKG_FILE}" | awk '{print $1}')" >&2
        exit 1
      fi
    else
      # No usable hash found. VERIFY_CHECKSUM was requested, so this is fatal:
      # the operator explicitly asked us to verify and we can't. To proceed
      # anyway, re-run with VERIFY_CHECKSUM=false (knowingly) or supply
      # NX_PKG_SHA256.
      echo "ERROR: VERIFY_CHECKSUM=true but no SHA256 was found for ${PKG_FILE}." >&2
      echo "       Provide NX_PKG_SHA256=<hash>, populate checksums.txt via" >&2
      echo "       make-checksums.sh, or set VERIFY_CHECKSUM=false to skip." >&2
      exit 1
    fi
  else
    # Verification disabled by the operator — warn but continue.
    echo ">>> WARNING: checksum verification is DISABLED (VERIFY_CHECKSUM=false)."
    echo "    Installing without verifying the download integrity."
  fi

  # --- 5c. Install ---------------------------------------------------------
  # apt-get resolves the .deb's dependencies for us. The leading ./ tells apt
  # this is a local file, not a repo package name.
  echo ">>> Installing ${PKG_FILE}"
  apt-get update -y
  apt-get install -y "${WORKDIR}/${PKG_FILE}"
  echo "    NX mediaserver installed."

else
  echo ">>> Skipping NX install (INSTALL_NX=${INSTALL_NX})."
fi

# ===========================================================================
# 6. Webmin (optional)
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
# 7. Time: timezone, NTP, hardware clock
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
# 8. Report the mediaserver service status
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
echo "=========================================================="

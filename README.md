# twg-nx-deploy

One-line bootstrap that provisions a fresh **Ubuntu/Debian** server with the
[Network Optix NX](https://www.networkoptix.com/) mediaserver (**NX Witness** or
**NX Meta**), plus optional Webmin, timezone, and NTP setup. A tech runs a single
command and the server is ready.

> **TWG Security** — The Wire Guys. This repo is **public**: assume anyone can
> read every file. No secrets, license keys, or internal hostnames are committed
> here, and none should ever be added.

---

## Quick start (NX Witness — default)

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
```

That installs **NX Witness 6.1.2 build 42921**, sets the timezone to
`America/New_York`, enables NTP, and syncs the hardware clock.

---

## Examples

All behavior is controlled by environment variables passed inline. Because the
script runs under `sudo`, put the variables **after** `sudo` (or use
`sudo -E` with exported vars) so they reach the script:

**NX Meta instead of Witness**
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo NX_EDITION=meta bash
```

**Enable Webmin**
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo INSTALL_WEBMIN=true bash
```
Webmin is then reachable at `https://<server-ip>:10000`.

**Override the timezone (or skip changing it)**
```bash
# set a different zone
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo SET_TIMEZONE=America/Chicago bash

# leave the timezone untouched (empty string skips it)
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo SET_TIMEZONE= bash
```

**Pin a different build via URL + hash**
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo \
  NX_PKG_URL="https://updates.networkoptix.com/default/43000/linux/nxwitness-server-6.1.3.43000-linux_x64.deb" \
  NX_PKG_SHA256="<64-hex-sha256-of-that-file>" \
  bash
```
When `NX_PKG_URL` is set it wins and `NX_EDITION` is ignored for URL selection.
Supplying `NX_PKG_SHA256` lets you verify a one-off build without editing
`checksums.txt`.

---

## Configuration reference

| Variable          | Default            | Meaning                                                        |
|-------------------|--------------------|----------------------------------------------------------------|
| `NX_EDITION`      | `witness`          | `witness` or `meta` — selects the package URL.                 |
| `INSTALL_NX`      | `true`             | Install the mediaserver at all.                                |
| `INSTALL_WEBMIN`  | `false`            | Install the Webmin admin panel.                                |
| `SET_TIMEZONE`    | `America/New_York` | Timezone to set. **Empty string skips** the timezone change.   |
| `ENABLE_NTP`      | `true`             | Enable network time sync (`timedatectl set-ntp true`).         |
| `VERIFY_CHECKSUM` | `true`             | Verify the `.deb` SHA256 before installing.                    |
| `NX_PKG_URL`      | *(derived)*        | Override the download URL. Wins over `NX_EDITION`.             |
| `NX_PKG_SHA256`   | *(unset)*          | Expected SHA256 for the download. Wins over `checksums.txt`.   |
| `CHECKSUMS_URL`   | Pages `checksums.txt` | Where to fetch `checksums.txt` when verifying.              |

---

## Supported distros

Debian and Ubuntu (anything with `apt-get`). The installer aborts with a clear
message if `apt-get` is missing, and must be run as **root**.

---

## Review before you run (recommended)

Piping a script straight into `sudo bash` executes it **as root**. You are
trusting whatever is at that URL. Review it first:

```bash
# 1. Download it
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh -o install.sh

# 2. Read it top to bottom (every block is commented)
less install.sh

# 3. Run it once you're satisfied
sudo bash install.sh
# ...with overrides, e.g.:
sudo NX_EDITION=meta INSTALL_WEBMIN=true bash install.sh
```

This repository is public — there are no secrets in it, so the only thing you're
verifying is that the steps are what you expect.

---

## GitHub Pages

The site is served **from the repository root** on the default branch. The
`.nojekyll` file is present so GitHub Pages serves files verbatim (no Jekyll
processing), which keeps `install.sh`, `checksums.txt`, and dotfiles reachable
at their raw paths:

- `https://twg-security.github.io/twg-nx-deploy/install.sh`
- `https://twg-security.github.io/twg-nx-deploy/checksums.txt`

Enable it under **Settings → Pages → Deploy from a branch**, root folder.

---

## Updating the pinned version + regenerating checksums

When Network Optix ships a new build TWG wants to standardize on:

1. **Update the pin** in **both** `install.sh` and `make-checksums.sh`:
   change `NX_VERSION` and `NX_BUILD` (and confirm the URL pattern still
   matches Network Optix's layout).
2. **Regenerate checksums** — run on any Linux box with internet access:
   ```bash
   ./make-checksums.sh
   ```
   This downloads both `.deb` packages and overwrites `checksums.txt` with real
   `sha256sum`-format rows.
3. **Commit** the updated `install.sh`, `make-checksums.sh`, and `checksums.txt`
   together.

Until real hashes are generated, `checksums.txt` ships **placeholder** rows.
`install.sh` only trusts a row whose hash is 64 hex characters, so with the
placeholders in place a run with `VERIFY_CHECKSUM=true` (the default) will
**fail loudly** rather than install an unverified package. Generate real hashes
with `make-checksums.sh` before relying on the default install command in
production.

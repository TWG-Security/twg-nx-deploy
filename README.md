# twg-nx-deploy

One command sets up a fresh **Ubuntu/Debian** server with the Network Optix NX
mediaserver (**NX Witness** or **NX Meta**). It can also detect the GPU and
install drivers, install Webmin, set the timezone/NTP, and it saves a full log
of everything it did.

> **TWG Security — The Wire Guys.** This repo is **public**. Never commit
> secrets, license keys, or internal hostnames here.

---

## 1. Install it (the one-liner)

Copy, paste, run on the server:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
```

**What that does by default:**

- Installs **NX Witness 6.1.2 (build 42921)**
- Detects the GPU and installs the right drivers (`auto`)
- Sets timezone to **America/New_York** and turns on NTP
- Saves a log to **`/var/log/twg-nx-deploy-<date>.log`**

If you run it from a real terminal, a short **menu** appears first so you can
change any option before it starts. (See section 3.)

---

## 2. Common variations

Change behavior by putting `NAME=value` **after `sudo`**. A few examples:

**Install NX Meta instead of Witness**
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo NX_EDITION=meta bash
```

**Also install Webmin** (web admin panel at `https://<server-ip>:10000`)
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo INSTALL_WEBMIN=true bash
```

**Use a different timezone**
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo SET_TIMEZONE=America/Chicago bash
```

**Skip GPU drivers** (e.g. a plain VM with no GPU)
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo INSTALL_GPU_DRIVERS=false bash
```

**Combine options** — just list them
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo NX_EDITION=meta INSTALL_WEBMIN=true SET_TIMEZONE=America/Denver bash
```

**Install a different NX build** (paste the vendor URL + its SHA256)
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo \
  NX_PKG_URL="https://updates.networkoptix.com/default/43000/linux/nxwitness-server-6.1.3.43000-linux_x64.deb" \
  NX_PKG_SHA256="<the-64-character-sha256-of-that-file>" \
  bash
```

---

## 3. The setup menu

When you run the installer **from a terminal**, you'll see prompts like this
before anything is installed:

```
----------------------------------------------------------
 Interactive setup — press Enter to accept the [default].
----------------------------------------------------------
NX edition (witness/meta) [witness]:
Install the NX mediaserver? [Y/n]
Detect GPU and install drivers? [Y/n]
Install Webmin admin panel? [y/N]
Timezone (blank = leave unchanged) [America/New_York]:
Enable NTP time sync? [Y/n]
Verify package SHA256 before install? [Y/n]
```

- **Press Enter** to accept the default shown in `[brackets]`.
- Type a value (like `meta`, `y`, or `n`) to change it.

**To skip the menu** and just use the defaults / your env vars, add
`NONINTERACTIVE=true`:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo NONINTERACTIVE=true bash
```

The menu is skipped automatically when there's no terminal (automation, cron,
CI), so unattended runs never hang waiting for input.

---

## 4. The install log

Every run writes a complete log — everything printed to the screen — to:

```
/var/log/twg-nx-deploy-<date>-<time>.log
```

The exact path is printed at the start and end of the run. If something goes
wrong, grab that file to debug. To put it somewhere else:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo LOG_FILE=/root/nx-install.log bash
```

---

## 5. GPU drivers

With `INSTALL_GPU_DRIVERS=auto` (the default) the installer detects the card
and installs the matching drivers:

| GPU found | What it installs |
|-----------|------------------|
| **NVIDIA** | Recommended driver via `ubuntu-drivers` (Ubuntu). *A reboot is recommended afterward so the driver loads.* |
| **AMD**    | Mesa VAAPI drivers (`mesa-va-drivers`, `vainfo`) |
| **Intel**  | Intel VAAPI drivers (`intel-media-va-driver`, `i965-va-driver`, `vainfo`) |
| **None**   | Nothing — it just moves on |

Set `INSTALL_GPU_DRIVERS=false` to skip this step entirely.

> **NVIDIA on Debian:** the driver lives in the `contrib`/`non-free` repos. The
> installer attempts it and, if it can't, prints the exact commands to enable
> those repos and install manually.

---

## 6. All options

| Variable              | Default            | What it does                                             |
|-----------------------|--------------------|----------------------------------------------------------|
| `NX_EDITION`          | `witness`          | `witness` or `meta`                                      |
| `INSTALL_NX`          | `true`             | Install the mediaserver                                  |
| `INSTALL_GPU_DRIVERS` | `auto`             | `auto`/`true` = detect & install, `false` = skip         |
| `INSTALL_WEBMIN`      | `false`            | Install the Webmin admin panel                           |
| `SET_TIMEZONE`        | `America/New_York` | Timezone to set (**blank = leave unchanged**)            |
| `ENABLE_NTP`          | `true`             | Turn on network time sync                                |
| `VERIFY_CHECKSUM`     | `true`             | Verify the package SHA256 before installing              |
| `NONINTERACTIVE`      | `false`            | `true` = skip the menu                                   |
| `LOG_FILE`            | `/var/log/twg-nx-deploy-<date>.log` | Where to save the install log           |
| `NX_PKG_URL`          | *(auto)*           | Override the download URL (wins over `NX_EDITION`)       |
| `NX_PKG_SHA256`       | *(unset)*          | Expected SHA256 for the download (wins over `checksums.txt`) |
| `CHECKSUMS_URL`       | Pages `checksums.txt` | Where to fetch `checksums.txt` for verification       |

---

## 7. Supported systems

Debian and Ubuntu (anything with `apt-get`). The installer **must run as root**
(use `sudo`) and stops with a clear message on anything else.

---

## 8. Review before you run (recommended)

Piping into `sudo bash` runs the script **as root**. If you'd rather read it
first:

```bash
# 1. Download it
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh -o install.sh

# 2. Read it (every section is commented)
less install.sh

# 3. Run it when you're happy
sudo bash install.sh
```

This repo is public and contains no secrets — you're only confirming the steps
are what you expect.

---

## 9. For maintainers

### How the files fit together
- **`install.sh`** — the installer (served via GitHub Pages).
- **`make-checksums.sh`** — regenerates `checksums.txt` for the pinned build.
- **`checksums.txt`** — SHA256 sums the installer checks the download against.
- **`.nojekyll`** — tells GitHub Pages to serve files as-is from the repo root.

### GitHub Pages
Served **from the repository root** on the default branch. Because `.nojekyll`
is present, `install.sh` and `checksums.txt` are reachable directly:

- `https://twg-security.github.io/twg-nx-deploy/install.sh`
- `https://twg-security.github.io/twg-nx-deploy/checksums.txt`

Enable under **Settings → Pages → Deploy from a branch**, root folder.

### Updating the pinned NX version
1. Update `NX_VERSION` and `NX_BUILD` in **both** `install.sh` and
   `make-checksums.sh`.
2. Regenerate the checksums on any Linux box with internet access:
   ```bash
   ./make-checksums.sh
   ```
3. Commit `install.sh`, `make-checksums.sh`, and `checksums.txt` together.

> **Important:** `checksums.txt` currently ships **placeholder** hashes. Until
> you run `make-checksums.sh`, a default install (with `VERIFY_CHECKSUM=true`)
> will **stop with an error** instead of installing an unverified package —
> this is intentional. Generate the real hashes before production use.

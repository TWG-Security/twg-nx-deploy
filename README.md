# twg-nx-deploy

One command sets up a fresh **Ubuntu/Debian** server with the Network Optix NX
mediaserver (**NX Witness** or **NX Meta**). It can also detect the GPU and
install drivers, install Webmin, install **CVEDIA-RT**, set the timezone/NTP,
and it saves a full log of everything it did.

On a capable terminal the installer **takes over the screen** with a
full-screen dashboard — a fixed TWG banner, the run plan, and a live checklist
of phases that tick from pending → running (spinner + timer) → ✔ / ✖ in place,
like a proper installer app instead of a wall of scrolling logs. When it
finishes, your screen is restored and a clean summary is printed. The noisy
apt/dpkg/curl output goes to the log file (see [section 4](#4-the-install-log)).

It degrades gracefully: a smaller or older terminal gets tidy line-by-line
status; a plain pipe / CI / cron (no terminal) or `NO_COLOR` gets plain text.
Set `NO_TUI=1` to force line-by-line mode on a full terminal.

> **TWG Security — The Wire Guys.** This repo is **public**. Never commit
> secrets, license keys, or internal hostnames here.

---

## 1. Install it (the one-liner)

Copy, paste, run on the server:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo bash
```

> **First time using this repo? One quick one-time setup step must be done
> before the command above works — see [section 0](#0-one-time-setup-do-this-first).**
> After that's done once, the one-liner above is all any tech ever runs.

---

## 0. One-time setup (do this first)

This step only needs doing **once, by a maintainer**. After that the
one-liner in section 1 works for everyone, forever.

**Turn on the website that serves the installer.**
Without this you get a **404** at the install URL.
- Go to the repo on GitHub → **Settings → Pages**.
- Under **Source**, choose **GitHub Actions**. Save.
- That's it — a deploy runs automatically and the install URL goes live in a
  minute or two. (Check **Actions → Deploy to GitHub Pages** for a green run.)

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

**Install a different NX build** (paste the vendor URL)
```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo \
  NX_PKG_URL="https://updates.networkoptix.com/default/43000/linux/nxwitness-server-6.1.3.43000-linux_x64.deb" \
  bash
```

---

## 3. The setup menu

When you run the installer **from a terminal**, a short **Setup** section
appears (styled with the TWG banner above it) with prompts like these before
anything is installed:

```
  ▍ Setup
    • Press Enter to accept the [default] shown for each option.

    NX edition:  1) witness   2) meta
    Choose 1 or 2 [1]:
    Detect GPU and install drivers? [Y/n]
    Install Webmin admin panel? [y/N]
    Install CVEDIA-RT? (runs its own setup you'll step through) [y/N]
    Timezone (blank = leave unchanged) [America/New_York]:
    Enable NTP time sync? [Y/n]
```

- **Press Enter** to accept the default shown in `[brackets]`.
- For the edition, type `1` (witness) or `2` (meta) — the words `witness`/`meta`
  still work too. For yes/no prompts, type `y` or `n`.

**To skip the menu** and just use the defaults / your env vars, add
`NONINTERACTIVE=true`:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo NONINTERACTIVE=true bash
```

The menu is skipped automatically when there's no terminal (automation, cron,
CI), so unattended runs never hang waiting for input.

---

## 4. The install log

The screen shows a tidy status view; the **complete, plain-text log** — every
step plus all the raw apt/dpkg/curl output — is written to:

```
/var/log/twg-nx-deploy-<date>-<time>.log
```

The exact path is shown at the start and in the closing summary. If a step
fails, the installer also prints the last few log lines right on screen so you
usually don't have to open the file. To put the log somewhere else:

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo LOG_FILE=/root/nx-install.log bash
```

---

## 5. GPU drivers

With `INSTALL_GPU_DRIVERS=auto` (the default) the installer detects the card
and installs the matching drivers:

| GPU found | What it installs |
|-----------|------------------|
| **NVIDIA** | Kernel headers + DKMS build tools, then the recommended driver via `ubuntu-drivers` (Ubuntu). It then verifies the module built. **You must reboot before `nvidia-smi` works.** |
| **AMD**    | Mesa VAAPI drivers (`mesa-va-drivers`, `vainfo`) |
| **Intel**  | Intel VAAPI drivers (`intel-media-va-driver`, `i965-va-driver`, `vainfo`) |
| **None**   | Nothing — it just moves on |

Set `INSTALL_GPU_DRIVERS=false` to skip this step entirely.

> **NVIDIA on Debian:** the driver lives in the `contrib`/`non-free` repos. The
> installer attempts it and, if it can't, prints the exact commands to enable
> those repos and install manually.

### `nvidia-smi` fails right after install? — that's expected

The driver files are installed, but the *running* kernel loads the `nvidia`
module only at boot. Until you reboot, `nvidia-smi` reports **"couldn't
communicate with the NVIDIA driver"** — the install worked, it's just not
loaded yet.

```bash
sudo reboot        # then, once it's back:
nvidia-smi
```

The installer confirms the driver built (`modinfo nvidia`) and says this in
the closing summary, so a green ✔ on the driver step plus a `nvidia-smi`
failure before reboot is normal.

> **Secure Boot** is the one thing a reboot alone won't fix. When it's enabled,
> the firmware refuses to load the freshly built (unsigned) NVIDIA module until
> you either enroll its key at the **MOK Manager** screen on next boot or
> disable Secure Boot in BIOS/UEFI. The installer detects Secure Boot and warns
> you when this applies. If `nvidia-smi` still fails *after* a reboot, this is
> almost always why — check with `mokutil --sb-state`.

---

## 5a. CVEDIA-RT (optional)

Answer **yes** to the CVEDIA-RT prompt (or pass `INSTALL_CVEDIA=true`) and the
installer will set up [CVEDIA-RT](https://get.cvedia.com), running the vendor's
own commands:

```bash
curl -fsSLo - http://get.cvedia.com | sudo bash   # vendor bootstrap (interactive)
sudo apt install cvedia-rt -y                      # the package
```

**CVEDIA's bootstrap has its own menu you must step through.** Because that's
interactive, it can't run inside the full-screen dashboard (the prompts would
be hidden). So the installer runs everything else first, **restores your
screen, and then runs CVEDIA's setup on the visible terminal** so you can
answer its menu — exactly like the vendor's one-liner. After you finish, it
installs the `cvedia-rt` package and reports the result in the summary.

```bash
curl -fsSL https://twg-security.github.io/twg-nx-deploy/install.sh | sudo INSTALL_CVEDIA=true bash
```

> In a fully unattended run (no terminal), the bootstrap can't be stepped
> through; the installer runs it non-interactively and warns if it needs input.

---

## 6. All options

| Variable              | Default            | What it does                                             |
|-----------------------|--------------------|----------------------------------------------------------|
| `NX_EDITION`          | `witness`          | `witness` or `meta`                                      |
| `INSTALL_NX`          | `true`             | Install the mediaserver                                  |
| `INSTALL_GPU_DRIVERS` | `auto`             | `auto`/`true` = detect & install, `false` = skip         |
| `INSTALL_WEBMIN`      | `false`            | Install the Webmin admin panel                           |
| `INSTALL_CVEDIA`      | `false`            | Install CVEDIA-RT (runs the vendor's interactive setup)  |
| `SET_TIMEZONE`        | `America/New_York` | Timezone to set (**blank = leave unchanged**)            |
| `ENABLE_NTP`          | `true`             | Turn on network time sync                                |
| `NONINTERACTIVE`      | `false`            | `true` = skip the menu                                   |
| `LOG_FILE`            | `/var/log/twg-nx-deploy-<date>.log` | Where to save the install log           |
| `NX_PKG_URL`          | *(auto)*           | Override the download URL (wins over `NX_EDITION`)       |
| `NO_COLOR`            | *(unset)*          | Set to any value to force plain, uncolored output        |
| `NO_TUI`              | *(unset)*          | Set to any value to disable the full-screen dashboard (line-by-line) |

---

## 6a. Troubleshooting: install hangs on a magenta setup screen

If a run stalls on a pink/magenta full-screen box titled **"Configuring
networkoptix-mediaserver"** that says *"Installation is not yet complete… run
Nx Witness Client and click New Site"* with an `<Ok>` button — and especially
if you see stray `^[[A^[[B` characters when you press arrow keys — that's a
`debconf`/`whiptail` dialog the package puts up during install. On a headless
or remote/tunneled session it can block forever because keystrokes don't reach
it cleanly.

- **To get past it right now:** the `<Ok>` button is already selected — press
  **Enter** (or **Tab** then **Enter**). The server is installed; it just isn't
  set up yet. Finish setup from the Nx client's **New Site** tile or by opening
  `http://<server-ip>:7001` in a browser.
- **Permanent fix:** the installer now forces every apt/dpkg step to be truly
  non-interactive (`DEBIAN_FRONTEND=noninteractive`, plus `needrestart` set to
  auto-restart), so this dialog no longer appears. Re-pull the latest
  `install.sh` and it won't happen again.

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
- **`.nojekyll`** — tells GitHub Pages to serve files as-is from the repo root.

### GitHub Pages
Deployed by the **`.github/workflows/pages.yml`** GitHub Action, which uploads
the repository root and publishes it. Because `.nojekyll` is present,
`install.sh` is served verbatim:

- `https://twg-security.github.io/twg-nx-deploy/install.sh`

Enable once under **Settings → Pages → Source → GitHub Actions** (see
[section 0](#0-one-time-setup-do-this-first)). After that, every push to the
default branch that changes a served file redeploys automatically; you can also
trigger a redeploy from **Actions → Deploy to GitHub Pages → Run workflow**.

> Don't also set "Deploy from a branch" — the two sources are mutually
> exclusive. This repo uses **GitHub Actions**.

### Updating the pinned NX version
1. Update `NX_VERSION` and `NX_BUILD` in `install.sh`.
2. Commit `install.sh`. The next push to the default branch redeploys Pages
   automatically.

# Contributing

Thanks for helping out. This project is two bash scripts that run on real phones,
so the most valuable contributions are usually reports from hardware I don't have.

## Reporting a bug

Open an issue using the **Bug report** template and attach `~/termux-setup.log`.
The log records the result of every package install, so the last few lines almost
always name the exact step that failed.

Include your GPU line — `getprop ro.hardware.egl` and `getprop ro.hardware`. GPU
detection drives which driver stack gets installed, and it's where most
device-specific breakage lives.

## Making a change

There is no build system and no test suite. Before opening a PR:

1. `bash -n termux-linux-setup.sh && bash -n setup-homeassistant.sh` — a syntax
   error here strands someone half-way through a 30-minute install.
2. `shellcheck --severity=warning --shell=bash *.sh` — same check CI runs.
   CI also runs `--help` and a few bad flags through both scripts, so keep
   `parse_args` free of anything Termux-specific.
3. Run the changed script end to end on a real device, and say which device and
   Android version you tested on in the PR description.

## Conventions

- **Every package install goes through `safe_install_pkg`** (or `proot_install_pkg`
  for things inside the Ubuntu container). Never call `apt-get install` directly —
  the wrapper is what keeps a package conflict from silently killing the run.
- **No `set -e` or `set -u`.** This is deliberate and documented at the top of
  `termux-linux-setup.sh`: `set -e` kills the whole script on a single failed
  optional package, and `set -u` trips over Termux variables that are legitimately
  empty. `set -o pipefail` is kept.
- **Use `$PREFIX` / `$HOME`**, via the `TERMUX_PREFIX` and `TERMUX_HOME` variables,
  rather than hardcoding `/data/data/com.termux/...`. People do run Termux on
  secondary Android user profiles.
- **Desktop-specific logic branches on `$DE_CHOICE`** (1=XFCE4, 2=LXQt, 3=MATE,
  4=KDE). If you add a desktop, update every `case` that switches on it —
  packages, kill command, start command, terminal shortcut.
- **Never `read` from stdin directly.** Use the `ask` helper. With
  `curl ... | bash` stdin *is* the script, so a bare `read` eats the rest of it.
  Every new choice also needs a flag, so `-y` installs stay fully unattended.
- **Redirect `< /dev/null` on anything that might prompt** (apt, pkg) for the
  same reason.
- **Colors:** GREEN success, RED error, YELLOW warning, CYAN info, GRAY skipped.

## Adding or changing a package

Termux package metadata changes often, and a package that resolves today can
conflict tomorrow. When you change a package name, check its real metadata first:

```bash
apt-cache show <package> | grep -E "Version|Depends|Conflicts|Replaces|Provides"
```

Watch for two traps that have already caused bugs here:

- **Versioned conflicts.** `Conflicts: ndk-sysroot (<< 23b-6)` only applies to
  versions below `23b-6`. Treating it as an unconditional conflict skips packages
  that would have installed fine.
- **File overlaps between repos.** Two packages can both ship
  `libvulkan_freedreno.so` without declaring a conflict, and dpkg only finds out
  at unpack time. If two packages come from different repos and serve the same
  purpose, assume they collide until you've checked.

#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Home Assistant Core — Smart Home Server Setup
#
#  Installs Home Assistant Core inside a proot-distro
#  Ubuntu container on Termux. No root required.
#
#  What you get:
#  - Home Assistant Core running on your phone
#  - Web dashboard accessible from any device on your network
#  - Control WiFi smart lights/plugs (TP-Link Kasa, Tuya, etc.)
#  - Start/stop scripts for easy management
#
#  Requires: Termux on arm64 Android, ~3 GB free storage
#######################################################

set -o pipefail

# ============== DYNAMIC PATH DETECTION ==============
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

# ============== CONFIGURATION ==============
CURRENT_STEP=0
TOTAL_STEPS=7
INSTALL_HACS="no"

HACS_FROM_FLAG=""
ASSUME_YES="no"

LOG_FILE="$TERMUX_HOME/termux-setup.log"

# Same apt options as termux-linux-setup.sh: never prompt about config files,
# retry/time out on a stalled mirror instead of hanging, wait for the dpkg lock.
APT_OPTS=(
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
    -o DPkg::Lock::Timeout=300
)
# The same, as a string for apt inside the Ubuntu container.
APT_OPTS_STR="${APT_OPTS[*]}"

# ============== COMMAND-LINE FLAGS ==============
usage() {
    cat << 'USAGE'
Usage: bash setup-homeassistant.sh [options]

Install Home Assistant Core on Android (Termux + proot-distro Ubuntu).
Run with no options for the interactive installer.

Options:
  --hacs        Also install HACS, the community store (default)
  --no-hacs     Skip HACS
  -y, --yes     Don't ask anything; use the flags above or the defaults
  -h, --help    Show this help

One-line install:
  curl -fsSL https://raw.githubusercontent.com/mayukh4/linux-android/main/setup-homeassistant.sh | bash

Re-running is safe: finished steps are skipped. Install log: ~/termux-setup.log
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --hacs)    HACS_FROM_FLAG="yes" ;;
            --no-hacs) HACS_FROM_FLAG="no" ;;
            -y|--yes)  ASSUME_YES="yes" ;;
            -h|--help) usage; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

# Where to read answers from. With `curl ... | bash` stdin is the script
# itself, so a plain `read` would swallow the rest of it; read from the
# terminal instead. No terminal at all (CI, nohup) means use the defaults.
TTY_IN=""
if [ -t 0 ]; then
    TTY_IN=/dev/stdin
elif { : < /dev/tty; } 2>/dev/null; then
    TTY_IN=/dev/tty
fi

# ask <var> <prompt> — read one answer, or leave it empty (= default) when
# running unattended.
ask() {
    local __reply=""
    if [ "$ASSUME_YES" != "yes" ] && [ -n "$TTY_IN" ]; then
        read -rp "$2" __reply < "$TTY_IN" || __reply=""
    fi
    printf -v "$1" '%s' "$__reply"
}


# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# ============== LOGGING ==============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ============== PROGRESS BAR ==============
update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local FILLED=$((PERCENT / 5))
    local EMPTY=$((20 - FILLED))

    local BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    BAR+="${NC}"

    echo ""
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  PROGRESS: ${WHITE}Step ${CURRENT_STEP}/${TOTAL_STEPS}${NC}  ${BAR}  ${WHITE}${PERCENT}%${NC}"
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ============== SPINNER ==============
#
# Big packages (KDE, Firefox, Wine) can take many minutes on a slow phone or
# connection, and a bare spinner looks exactly like a hang (issue #7). So the
# spinner shows the elapsed time and, after a few seconds, the latest line apt
# wrote to the log ("Get:12 ... firefox [74.1 MB]", "Unpacking ...").
# If the log stops moving for several minutes it says so, once.

# Latest non-empty log line, stripped of control characters.
last_log_line() {
    tail -n 3 "$LOG_FILE" 2>/dev/null \
        | tr -d '\r' \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1
}

_spin() {
    local pid=$1
    local message=$2
    local optional=$3
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇')
    local i=0 tick=0
    local start=$SECONDS elapsed
    local cols detail="" line
    local size last_size=-1 last_change=$SECONDS warned=0

    cols=$(tput cols 2>/dev/null || echo 80)
    [ "$cols" -gt 20 ] 2>/dev/null || cols=80

    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))

        # Once a second: refresh the detail line and check for a stall.
        if [ $((tick % 10)) -eq 0 ]; then
            size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$size" != "$last_size" ]; then
                last_size=$size
                last_change=$SECONDS
            fi
            if [ "$elapsed" -ge 4 ]; then
                detail=$(last_log_line)
            fi
            if [ "$warned" -eq 0 ] && [ $((SECONDS - last_change)) -ge 300 ]; then
                warned=1
                printf "\r\033[K  ${YELLOW}⚠${NC}  No progress for 5 minutes. Check your connection and keep\n"
                printf "     Termux in the foreground. If it never moves, press Ctrl+C and\n"
                printf "     re-run the script — installed packages are skipped.\n"
                log "STALL: no log output for 300s during: $message"
            fi
        fi

        line=$(printf "%s [%d:%02d]" "$message" $((elapsed / 60)) $((elapsed % 60)))
        if [ -n "$detail" ]; then
            line="$line · $detail"
        fi
        # Keep it on one line so \r can redraw it.
        line=${line:0:$((cols - 6))}
        printf "\r\033[K  ${CYAN}%s${NC}  %s" "${spin[$i]}" "$line"

        i=$(( (i + 1) % 6 ))
        tick=$((tick + 1))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?
    elapsed=$((SECONDS - start))
    local took=""
    [ "$elapsed" -ge 10 ] && took=$(printf " (%d:%02d)" $((elapsed / 60)) $((elapsed % 60)))

    if [ "$exit_code" -eq 0 ]; then
        printf "\r\033[K  ${GREEN}✔${NC}  %-55s${GRAY}%s${NC}\n" "$message" "$took"
        log "OK: $message"
    elif [ "$optional" = "optional" ]; then
        printf "\r\033[K  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(optional — skipped)${NC}\n" "$message"
        log "OPTIONAL FAILED: $message"
        return 0
    else
        printf "\r\033[K  ${RED}✘${NC}  %-55s ${RED}(failed — see $LOG_FILE)${NC}\n" "$message"
        log "FAILED: $message"
    fi

    return "$exit_code"
}

spinner() { _spin "$1" "$2" ""; }

# Same as spinner, but a failure is reported as a warning rather than an error.
# For packages the desktop still works without.
spinner_optional() { _spin "$1" "$2" "optional"; }

# ============== TERMUX PACKAGE INSTALLER ==============
safe_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    # dpkg -s also succeeds for removed-but-not-purged packages.
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" = "installed" ]; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed): $pkg"
        return 0
    fi

    local conflicts
    conflicts=$(apt-cache show "$pkg" 2>/dev/null \
        | grep -i "^Conflicts:" \
        | sed 's/^Conflicts://i' \
        | tr ',' '\n' \
        | awk '{print $1}')

    for conflict in $conflicts; do
        [ -z "$conflict" ] && continue
        if [ "$(dpkg-query -W -f='${db:Status-Status}' "$conflict" 2>/dev/null)" = "installed" ]; then
            printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(skipped — conflicts with: %s)${NC}\n" \
                "$name" "$conflict"
            log "SKIP (conflict with $conflict): $pkg"
            return 0
        fi
    done

    (DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_OPTS[@]}" \
        "$pkg" < /dev/null >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name}..."
}

# ============== PROOT UBUNTU PACKAGE INSTALLER ==============
proot_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    # Check if already installed inside the proot
    if proot-distro login ubuntu -- dpkg -s "$pkg" &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed in Ubuntu): $pkg"
        return 0
    fi

    (proot-distro login ubuntu -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y ${APT_OPTS_STR} '$pkg'" \
        < /dev/null >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name} (Ubuntu)..."
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║        Home Assistant — Smart Home Server Setup      ║
  ║        Turn your phone into a smart home hub         ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "${GRAY}  Detailed logs → $LOG_FILE${NC}"
    echo ""
}

# ============== PRE-FLIGHT CHECKS ==============
preflight_checks() {
    log "=== Home Assistant setup started ==="

    echo -e "${PURPLE}[*] Checking prerequisites...${NC}"
    echo ""

    # Check architecture
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        echo -e "  ${RED}✘ Unsupported architecture: ${arch}${NC}"
        echo -e "    ${WHITE}Home Assistant requires a 64-bit ARM device.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔${NC}  Architecture: ${WHITE}${arch}${NC}"

    # Check available storage (need ~3 GB)
    local free_mb
    free_mb=$(df -m "$TERMUX_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 2500 ]; then
        echo -e "  ${YELLOW}⚠${NC}  Free storage: ${YELLOW}${free_mb} MB${NC} (3000 MB+ recommended)"
        echo ""
        echo -e "  ${WHITE}You might run out of space during installation.${NC}"
        echo -e "  ${WHITE}Continue anyway? (y/n)${NC}"
        ask CONTINUE_INPUT "  [default: y]: "
        if [[ ! "${CONTINUE_INPUT:-y}" =~ ^[Yy] ]]; then
            echo -e "  ${RED}Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "  ${GREEN}✔${NC}  Free storage: ${WHITE}${free_mb:-unknown} MB${NC}"
    fi

    # Check network connectivity
    # Don't rely on pinging google.com: ICMP is filtered on many networks and
    # Google is unreachable in some countries. Try the hosts the install
    # actually needs, over HTTPS, and only warn if none answer.
    local net_ok="no" host
    for host in https://packages-cf.termux.dev https://pypi.org https://github.com; do
        if curl -fsS -o /dev/null --max-time 8 "$host" 2>/dev/null; then
            net_ok="yes"; break
        fi
    done
    if [ "$net_ok" = "no" ] && ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        net_ok="yes"
    fi
    if [ "$net_ok" = "yes" ]; then
        echo -e "  ${GREEN}✔${NC}  Network: ${WHITE}Connected${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC}  Could not confirm an internet connection."
        echo -e "    ${WHITE}The install downloads ~1 GB. It will fail without a connection.${NC}"
        log "WARNING: network check failed"
    fi

    # Detect phone IP for later
    PHONE_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$PHONE_IP" ]; then
        PHONE_IP="<your-phone-ip>"
    fi

    echo ""

    # Ask now rather than after a 30-minute install.
    echo -e "${CYAN}Optional: install HACS (Home Assistant Community Store)?${NC}"
    echo -e "  ${GRAY}HACS is the add-on store for community integrations and themes.${NC}"
    echo -e "  ${GRAY}It must be installed BEFORE any other custom integration.${NC}"
    echo ""
    if [ -n "$HACS_FROM_FLAG" ]; then
        INSTALL_HACS="$HACS_FROM_FLAG"
    else
        while true; do
            ask HACS_INPUT "  Install HACS? (y/n) [default: y]: "
            HACS_INPUT=${HACS_INPUT:-y}
            case "$HACS_INPUT" in
                [Yy]*) INSTALL_HACS="yes"; break;;
                [Nn]*) INSTALL_HACS="no";  break;;
                *) echo -e "  ${RED}Please enter y or n.${NC}";;
            esac
        done
    fi
    if [ "$INSTALL_HACS" == "yes" ]; then
        echo -e "  ${GREEN}✔ HACS will be installed.${NC}"
    else
        echo -e "  ${GRAY}  HACS skipped.${NC}"
    fi
    [ "$INSTALL_HACS" == "yes" ] && TOTAL_STEPS=8

    echo ""
    log "Preflight OK: arch=$arch, free=${free_mb}MB, ip=$PHONE_IP, hacs=$INSTALL_HACS"
}

# ============== STEP 1: INSTALL PROOT-DISTRO ==============
step_proot() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing proot-distro...${NC}"
    echo ""

    safe_install_pkg "proot-distro" "proot-distro (Linux container manager)"
    safe_install_pkg "proot"        "proot (user-space chroot)"
}

# ============== STEP 2: INSTALL UBUNTU ==============
step_ubuntu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up Ubuntu container...${NC}"
    echo ""

    # Check if Ubuntu is already installed
    if proot-distro list 2>/dev/null | grep -q "ubuntu.*Installed"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "Ubuntu container"
        log "SKIP (already installed): Ubuntu proot"
    else
        (proot-distro install ubuntu >> "$LOG_FILE" 2>&1) &
        spinner $! "Downloading and installing Ubuntu..."
    fi

    # Update package lists inside Ubuntu
    (proot-distro login ubuntu -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get update -y ${APT_OPTS_STR}" \
        < /dev/null >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating Ubuntu package lists..."
}

# ============== STEP 3: INSTALL UBUNTU DEPENDENCIES ==============
step_ubuntu_deps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing build dependencies in Ubuntu...${NC}"
    echo ""

    proot_install_pkg "python3"        "Python 3"
    proot_install_pkg "python3-pip"    "pip"
    proot_install_pkg "python3-venv"   "Python venv"
    proot_install_pkg "python3-dev"    "Python dev headers"
    proot_install_pkg "build-essential" "Build tools (gcc, make, etc.)"
    proot_install_pkg "libffi-dev"     "libffi (foreign function interface)"
    proot_install_pkg "libssl-dev"     "OpenSSL development headers"
    proot_install_pkg "libjpeg-dev"    "JPEG library"
    proot_install_pkg "zlib1g-dev"     "zlib compression library"
    proot_install_pkg "autoconf"       "Autoconf"
    proot_install_pkg "cargo"          "Rust/Cargo (for cryptography)"
    proot_install_pkg "pkg-config"     "pkg-config"
}

# ============== STEP 4: INSTALL HOME ASSISTANT ==============
step_homeassistant() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Home Assistant Core...${NC}"
    echo ""
    echo -e "  ${YELLOW}This step compiles native extensions and may take 15–30 minutes.${NC}"
    echo -e "  ${YELLOW}Keep your screen on or use termux-wake-lock.${NC}"
    echo ""

    # Create venv if it doesn't exist
    if proot-distro login ubuntu -- test -d "${TERMUX_HOME}/hass-venv"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already exists)${NC}\n" "Python virtual environment"
    else
        (proot-distro login ubuntu -- python3 -m venv "${TERMUX_HOME}/hass-venv" \
            >> "$LOG_FILE" 2>&1) &
        spinner $! "Creating Python virtual environment..."
    fi

    # Upgrade pip inside the venv
    # NOTE: Call venv binaries directly — "source activate" fails inside proot
    (proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/pip install --upgrade pip wheel setuptools \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Upgrading pip and setuptools..."

    # Install Home Assistant Core.
    # HA lazy-loads many components whose deps aren't pulled in by pip.
    # We explicitly install the ones needed for the core UI to function.
    (proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/pip install \
        homeassistant \
        hassil home-assistant-intents pyspeex-noise \
        numpy av mutagen pymicro-vad ha-ffmpeg PyTurboJPEG PyNaCl \
        cached-ipaddress file-read-backwards go2rtc-client async-upnp-client \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing Home Assistant Core (this takes a while)..."

    # Patch ifaddr: Android 10+ blocks getifaddrs() inside proot, causing
    # PermissionError in HA's network detection. We patch the library to
    # return an empty adapter list instead of crashing. HA still works fine
    # because we explicitly set server_host in configuration.yaml.
    local IFADDR_POSIX="${TERMUX_HOME}/hass-venv/lib/python3.*/site-packages/ifaddr/_posix.py"
    proot-distro login ubuntu -- bash -c \
        "sed -i 's/        raise OSError(eno, os.strerror(eno))/        return []/g' ${IFADDR_POSIX}" \
        >> "$LOG_FILE" 2>&1
    echo -e "  ${GREEN}✔${NC}  Patched ifaddr for Android network compatibility."
}

# ============== STEP 5: INITIALIZE HA CONFIG ==============
step_ha_config() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Initializing Home Assistant config...${NC}"
    echo ""

    # Create config dir and write configuration.yaml directly.
    # We skip the "run HA once to generate config" approach — it's fragile
    # inside proot. Instead we create a minimal valid config ourselves.
    local HASS_CONFIG="${TERMUX_HOME}/hass-config"

    if proot-distro login ubuntu -- test -f "${HASS_CONFIG}/configuration.yaml"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already exists)${NC}\n" "HA config directory"
    else
        proot-distro login ubuntu -- mkdir -p "${HASS_CONFIG}"
        echo -e "  ${GREEN}✔${NC}  Created config directory."
    fi

    # Ensure HA is accessible from the local network (not just localhost).
    # NOTE: must use double quotes so ${HASS_CONFIG} expands from Termux.
    if proot-distro login ubuntu -- grep -q "server_host" "${HASS_CONFIG}/configuration.yaml" 2>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already configured)${NC}\n" "Network binding (0.0.0.0)"
    else
        proot-distro login ubuntu -- sh -c "printf 'homeassistant:\n\nhttp:\n  server_host: 0.0.0.0\n\nmobile_app:\n\ndefault_config:\n' > ${HASS_CONFIG}/configuration.yaml"
        echo -e "  ${GREEN}✔${NC}  Configured HA to accept connections from your network."
    fi
}

# ============== STEP 6: CREATE LAUNCHER SCRIPTS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating start/stop scripts...${NC}"
    echo ""

    # start-homeassistant.sh
    # NOTE: proot-distro shares the Termux filesystem. The venv and config live
    # at the Termux home path, NOT at /root/. We bake the absolute path into
    # the script so ~ expansion can't break it.
    local HASS_BIN="${TERMUX_HOME}/hass-venv/bin/hass"
    local HASS_CFG="${TERMUX_HOME}/hass-config"

    cat > "$TERMUX_HOME/start-homeassistant.sh" << STARTEOF
#!${TERMUX_PREFIX}/bin/bash
echo ""
echo "[*] Starting Home Assistant Core..."
echo ""

if command -v termux-wake-lock &>/dev/null; then
    termux-wake-lock
    echo "[*] Wake lock acquired."
fi

PHONE_IP=\$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)

echo "-----------------------------------------------------"
echo "  Home Assistant is starting up."
echo ""
echo "  First launch takes 5-10 minutes to initialize."
echo "  When ready, open in your browser:"
echo ""
echo "    http://\${PHONE_IP:-localhost}:8123"
echo ""
echo "  Press Ctrl+C to stop."
echo "-----------------------------------------------------"
echo ""

proot-distro login ubuntu -- "${HASS_BIN}" -c "${HASS_CFG}"
STARTEOF
    chmod +x "$TERMUX_HOME/start-homeassistant.sh"
    echo -e "  ${GREEN}✔ Created ~/start-homeassistant.sh${NC}"

    # stop-homeassistant.sh
    cat > "$TERMUX_HOME/stop-homeassistant.sh" << STOPEOF
#!${TERMUX_PREFIX}/bin/bash
echo "[*] Stopping Home Assistant..."

# Match the hass process itself, not anything with "hass" in its command line
# (an editor open on ~/hass-config, a log tail, ...).
pkill -f "hass-venv/bin/hass" 2>/dev/null || pkill -f "hass -c" 2>/dev/null || true

if command -v termux-wake-unlock &>/dev/null; then
    termux-wake-unlock
    echo "[*] Wake lock released."
fi

echo "[*] Home Assistant stopped."
STOPEOF
    chmod +x "$TERMUX_HOME/stop-homeassistant.sh"
    echo -e "  ${GREEN}✔ Created ~/stop-homeassistant.sh${NC}"

    # upgrade-homeassistant.sh
    # pip will only ever resolve to the newest release whose requires-python
    # your container's interpreter satisfies, so this upgrades you as far as
    # that Python allows and then says so. See README ("Upgrading Home
    # Assistant") for the version/Python mapping.
    cat > "$TERMUX_HOME/upgrade-homeassistant.sh" << UPGRADEEOF
#!${TERMUX_PREFIX}/bin/bash
echo ""
echo "[*] Upgrading Home Assistant Core..."
echo ""

echo "[*] Stopping any running instance..."
pkill -f "hass-venv/bin/hass" 2>/dev/null || pkill -f "hass -c" 2>/dev/null || true
sleep 2

BEFORE=\$(proot-distro login ubuntu -- ${HASS_BIN} --version 2>/dev/null)
PYVER=\$(proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/python --version 2>/dev/null)

echo "[*] Container Python : \${PYVER:-unknown}"
echo "[*] Current HA       : \${BEFORE:-unknown}"
echo ""
echo "[*] This can take 10-20 minutes. Keep the screen on."
echo ""

if command -v termux-wake-lock &>/dev/null; then termux-wake-lock; fi

proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/pip install --upgrade homeassistant

AFTER=\$(proot-distro login ubuntu -- ${HASS_BIN} --version 2>/dev/null)

if command -v termux-wake-unlock &>/dev/null; then termux-wake-unlock; fi

echo ""
echo "-----------------------------------------------------"
echo "  Before : \${BEFORE:-unknown}"
echo "  After  : \${AFTER:-unknown}"
echo "-----------------------------------------------------"
if [ "\$BEFORE" = "\$AFTER" ]; then
    echo ""
    echo "  No change. You are already on the newest release that"
    echo "  \${PYVER:-your Python} can run. Home Assistant 2026.3 and later"
    echo "  need Python 3.14.2+; 2026.2.x is the last release for 3.13."
    echo "  See the README section \"Upgrading Home Assistant\"."
fi
echo ""
echo "[*] Start again with: bash ~/start-homeassistant.sh"
echo ""
UPGRADEEOF
    chmod +x "$TERMUX_HOME/upgrade-homeassistant.sh"
    echo -e "  ${GREEN}✔ Created ~/upgrade-homeassistant.sh${NC}"
}

# ============== STEP 7 (OPTIONAL): HACS ==============
#
# HACS is the community add-on store. Two things matter, both learned the hard
# way in issue #2:
#   1. It must be installed before any other custom integration. If
#      custom_components already has hand-installed integrations in it, the
#      HACS installer can leave you with a broken setup.
#   2. The official installer writes into the HA *config* directory, so it has
#      to run with that directory as the working directory.
step_hacs() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing HACS...${NC}"
    echo ""

    local HASS_CONFIG="${TERMUX_HOME}/hass-config"

    if proot-distro login ubuntu -- test -d "${HASS_CONFIG}/custom_components/hacs"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "HACS"
        log "SKIP (already installed): HACS"
        return 0
    fi

    # Warn about pre-existing custom integrations rather than silently
    # stepping on them.
    local existing
    existing=$(proot-distro login ubuntu -- sh -c \
        "ls -1 ${HASS_CONFIG}/custom_components 2>/dev/null | grep -v '^hacs$' | head -5")
    if [ -n "$existing" ]; then
        echo -e "  ${YELLOW}⚠${NC}  custom_components already contains:"
        echo "$existing" | sed 's/^/       /'
        echo -e "  ${YELLOW}   HACS expects to be installed first. If HACS misbehaves, remove${NC}"
        echo -e "  ${YELLOW}   those directories and re-run this script.${NC}"
        log "WARNING: pre-existing custom_components: $existing"
    fi

    proot_install_pkg "wget" "wget (Ubuntu)"

    (proot-distro login ubuntu -- sh -c \
        "cd ${HASS_CONFIG} && wget -q -O - https://get.hacs.xyz | bash -" \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Downloading and installing HACS..."

    if proot-distro login ubuntu -- test -d "${HASS_CONFIG}/custom_components/hacs"; then
        echo -e "  ${GREEN}✔${NC}  HACS installed."
        echo -e "    ${GRAY}Finish setup in the dashboard: Settings -> Devices & Services${NC}"
        echo -e "    ${GRAY}-> Add Integration -> HACS (restart HA first).${NC}"
        log "HACS installed OK"
    else
        echo -e "  ${YELLOW}⚠${NC}  HACS install did not complete — see $LOG_FILE."
        echo -e "    ${GRAY}You can retry manually:${NC}"
        echo -e "    ${GRAY}proot-distro login ubuntu -- sh -c \"cd ${HASS_CONFIG} && wget -O - https://get.hacs.xyz | bash -\"${NC}"
        log "WARNING: HACS install incomplete"
    fi
}

# ============== FINAL STEP: VERIFY INSTALLATION ==============
step_verify() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Verifying installation...${NC}"
    echo ""

    # Check that hass binary exists in the venv
    # NOTE: Call venv binaries directly — "source activate" fails inside proot
    if proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/hass --version &>/dev/null; then
        echo -e "  ${GREEN}✔${NC}  Home Assistant binary found."
        log "Verification OK: hass binary found"

        local HA_VERSION PY_VERSION
        HA_VERSION=$(proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/hass --version 2>/dev/null)
        PY_VERSION=$(proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/python --version 2>/dev/null | awk '{print $2}')

        if [ -n "$HA_VERSION" ]; then
            echo -e "  ${GREEN}✔${NC}  Home Assistant: ${WHITE}${HA_VERSION}${NC}"
            log "HA version: $HA_VERSION"
        fi
        if [ -n "$PY_VERSION" ]; then
            echo -e "  ${GREEN}✔${NC}  Container Python: ${WHITE}${PY_VERSION}${NC}"
            log "Container Python: $PY_VERSION"
        fi

        # pip installs the newest release whose requires-python your
        # interpreter satisfies, and stops there. That is why a fresh install
        # can land on an older HA than the one on the website — it is not a
        # broken install. (issue #2)
        case "$PY_VERSION" in
            3.13.*)
                echo ""
                echo -e "  ${YELLOW}⚠${NC}  Python 3.13 caps you at Home Assistant 2026.2.x."
                echo -e "     ${GRAY}2026.3 and later need Python 3.14.2+. This is expected,${NC}"
                echo -e "     ${GRAY}not a failed install. See the README section${NC}"
                echo -e "     ${GRAY}\"Upgrading Home Assistant\" for the Python 3.14 route.${NC}"
                ;;
            3.1[0-2].*)
                echo ""
                echo -e "  ${YELLOW}⚠${NC}  Python ${PY_VERSION} caps you at Home Assistant 2025.1.x."
                echo -e "     ${GRAY}HA 2025.2+ requires 3.13, 2025.6+ requires 3.13.2,${NC}"
                echo -e "     ${GRAY}2026.3+ requires 3.14.2. See the README.${NC}"
                ;;
        esac
    else
        echo -e "  ${RED}✘${NC}  Home Assistant binary not found."
        echo -e "    ${WHITE}Check $LOG_FILE for pip install errors.${NC}"
        log "FAILED: hass binary not found after install"
    fi

    # Check launcher scripts exist
    if [ -x "$TERMUX_HOME/start-homeassistant.sh" ]; then
        echo -e "  ${GREEN}✔${NC}  ~/start-homeassistant.sh is ready."
    fi
    if [ -x "$TERMUX_HOME/stop-homeassistant.sh" ]; then
        echo -e "  ${GREEN}✔${NC}  ~/stop-homeassistant.sh is ready."
    fi
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    echo -e "${GREEN}"
    cat << 'COMPLETE'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          ✔  HOME ASSISTANT INSTALLED!                ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
COMPLETE
    echo -e "${NC}"

    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}▶  START:${NC}    ${GREEN}bash ~/start-homeassistant.sh${NC}"
    echo -e "  ${WHITE}■  STOP: ${NC}    ${GREEN}bash ~/stop-homeassistant.sh${NC}"
    echo -e "  ${WHITE}▲  UPGRADE:${NC}  ${GREEN}bash ~/upgrade-homeassistant.sh${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}Access the dashboard from any device on your network:${NC}"
    echo -e "    ${WHITE}http://${PHONE_IP}:8123${NC}"
    echo ""
    echo -e "  ${CYAN}First launch takes 5–10 minutes to initialize.${NC}"
    echo -e "  ${CYAN}You'll create your admin account in the browser.${NC}"
    echo ""
    if [ "$INSTALL_HACS" == "yes" ]; then
        echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
        echo -e "  ${WHITE}FINISHING HACS SETUP${NC}"
        echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "    1. Restart Home Assistant (stop, then start)"
        echo -e "    2. Dashboard → Settings → Devices & Services"
        echo -e "    3. \"+ Add Integration\" → search \"HACS\""
        echo -e "    4. Tick all the acknowledgements, then authorize with GitHub"
        echo ""
        echo -e "    ${GRAY}Docs: https://www.hacs.xyz/docs/use/configuration/basic/${NC}"
        echo ""
    fi
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}ADDING YOUR SMART DEVICES${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}TP-Link Kasa (smart lights/plugs):${NC}"
    echo -e "    1. Open HA dashboard → Settings → Devices & Services"
    echo -e "    2. Click \"+ Add Integration\" → search \"TP-Link Kasa\""
    echo -e "    3. Enter the device's IP address (find it in the Kasa app"
    echo -e "       under Device Settings → Device Info)"
    echo -e "    ${GRAY}mDNS auto-discovery is disabled on Android — you must add by IP.${NC}"
    echo ""
    echo -e "  ${CYAN}Tuya / Smart Life (smart lights/plugs):${NC}"
    echo -e "    1. Create a Tuya IoT developer account at:"
    echo -e "       ${WHITE}https://iot.tuya.com${NC}"
    echo -e "    2. Create a Cloud Project and link your Smart Life app"
    echo -e "    3. In HA: Settings → Devices → Add Integration → \"Tuya\""
    echo -e "    4. Enter your Access ID, Access Secret, and country code"
    echo -e "    ${GRAY}Tuya uses cloud API — works even without local network access.${NC}"
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}KEEPING HA RUNNING IN THE BACKGROUND${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  To keep Home Assistant running when you close Termux:"
    echo ""
    echo -e "    ${GREEN}termux-wake-lock${NC}"
    echo -e "    ${GREEN}nohup bash ~/start-homeassistant.sh > ~/hass.log 2>&1 &${NC}"
    echo ""
    echo -e "  ${GRAY}The start script already acquires a wake lock, but running it"
    echo -e "  with nohup ensures it survives Termux being backgrounded.${NC}"
    echo ""
    echo -e "  ${GRAY}Full install log: $LOG_FILE${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    log "setup-homeassistant.sh started (args: $*)"

    if [ ! -d "$TERMUX_PREFIX" ] || ! command -v pkg >/dev/null 2>&1; then
        echo -e "${RED}This script must be run inside Termux on Android.${NC}"
        echo -e "Get Termux from F-Droid: https://f-droid.org/en/packages/com.termux/"
        exit 1
    fi

    # Acquire wake lock
    if command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
        log "Wake lock acquired."
        # Release it however we exit: success, an early `exit 1`, or Ctrl+C.
        trap 'termux-wake-unlock 2>/dev/null' EXIT
        trap 'echo; echo "Interrupted. Re-run the script to continue — finished steps are skipped."; exit 130' INT TERM
    else
        echo -e "${YELLOW}  [!] termux-wake-lock unavailable — keep your screen on during install.${NC}"
        echo ""
    fi

    show_banner
    preflight_checks

    step_proot
    step_ubuntu
    step_ubuntu_deps
    step_homeassistant
    step_ha_config
    step_launchers
    [ "$INSTALL_HACS" == "yes" ] && step_hacs
    step_verify
    show_completion

    if command -v termux-wake-unlock &>/dev/null; then
        termux-wake-unlock
        log "Wake lock released."
    fi
}

parse_args "$@"
main "$@"

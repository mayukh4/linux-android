#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Linux Desktop Setup Script
#
#  Features:
#  - Choice of Desktop Environment (XFCE4, LXQt, MATE, KDE)
#  - Smart GPU acceleration detection (Turnip/Zink)
#  - Conflict-safe package installer (no more silent exits)
#  - SSH server pre-installed and configured
#  - Productivity & Media tools (VLC, Firefox)
#  - Python 3 + pip
#  - Optional: Windows App Support (Wine/Hangover + Box64)
#
#  Tested on: LineageOS (Android 9+), arm64 devices
#######################################################

# Intentionally avoiding set -e (exit on error) and set -u (nounset):
# - set -e silently kills the script on any failed package install
# - set -u crashes on variables that are legitimately empty in Termux
# pipefail is kept so piped commands still report failures.
set -o pipefail

# ============== DYNAMIC PATH DETECTION ==============
# Supports standard and custom Termux installs (e.g. secondary user profiles)
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

# ============== CONFIGURATION ==============
INSTALL_WINE="no"
DE_CHOICE="1"
GPU_STACK="stock"
DE_NAME="XFCE4"
CURRENT_STEP=0
# TOTAL_STEPS is set after user choices are made

LOG_FILE="$TERMUX_HOME/termux-setup.log"

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

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
spinner() {
    local pid=$1
    local message=$2
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇')
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin[$i]}${NC}  %s  " "$message"
        i=$(( (i + 1) % 6 ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC}  %-55s\n" "$message"
        log "OK: $message"
    else
        printf "\r  ${RED}✘${NC}  %-55s ${RED}(failed — see $LOG_FILE)${NC}\n" "$message"
        log "FAILED: $message"
    fi

    return "$exit_code"
}

# Same as spinner, but a failure is reported as a warning rather than an error.
# For packages the desktop still works without.
spinner_optional() {
    local pid=$1
    local message=$2
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇')
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin[$i]}${NC}  %s  " "$message"
        i=$(( (i + 1) % 6 ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC}  %-55s\n" "$message"
        log "OK: $message"
    else
        printf "\r  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(optional — skipped)${NC}\n" "$message"
        log "OPTIONAL FAILED: $message"
    fi

    return 0
}

# ============== DPKG / APT HELPERS ==============

# dpkg -s also succeeds for packages that were removed but left their config
# behind, so ask for the real status instead.
pkg_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# apt-cache show prints one stanza per available version, highest first.
# We only care about the candidate, so cut at the first blank line.
apt_field() {
    apt-cache show "$1" 2>/dev/null \
        | sed -n '1,/^$/p' \
        | grep -i "^$2:" \
        | head -1 \
        | sed "s/^[^:]*:[[:space:]]*//"
}

# Strip version constraints and whitespace from a dependency list, one per line.
# "libmesa, ndk-sysroot (<< 23b-6), mesa" → "libmesa\nndk-sysroot\nmesa"
dep_names() {
    echo "$1" | tr ',' '\n' | sed 's/(.*//' | tr -d ' \t' | grep -v '^$'
}

# Is a single Conflicts entry actually violated right now?
#
# This is the bit the old version got wrong. Termux's mesa-zink declares
#   Conflicts: libmesa, ndk-sysroot (<< 23b-6), mesa
# Treating "ndk-sysroot (<< 23b-6)" as a plain name means any modern
# ndk-sysroot looks like a conflict and mesa-zink gets skipped, even though the
# constraint only covers versions older than 23b-6. (issue #4)
conflict_is_real() {
    local item="$1"
    local cname cop cver iver

    cname=$(echo "$item" | sed 's/(.*//' | tr -d ' \t')
    [ -z "$cname" ] && return 1
    pkg_installed "$cname" || return 1

    # No version constraint → any installed version conflicts.
    case "$item" in
        *"("*")"*) ;;
        *) return 0 ;;
    esac

    cop=$(echo "$item"  | sed -n 's/.*(\([<>=]\{1,2\}\)[[:space:]]*[^)]*).*/\1/p')
    cver=$(echo "$item" | sed -n 's/.*([<>=]\{1,2\}[[:space:]]*\([^)]*\)).*/\1/p')
    iver=$(pkg_version "$cname")
    if [ -z "$cop" ] || [ -z "$cver" ] || [ -z "$iver" ]; then
        return 0
    fi

    case "$cop" in
        "<<") cop="lt" ;;
        "<="|"<") cop="le" ;;
        "=")      cop="eq" ;;
        ">="|">") cop="ge" ;;
        ">>")     cop="gt" ;;
        *) return 0 ;;
    esac

    dpkg --compare-versions "$iver" "$cop" "$cver"
}

# Name of an installed package that already Provides "$1", if any.
provider_of() {
    dpkg-query -W -f='${db:Status-Status}|${Package}|${Provides}\n' 2>/dev/null \
        | awk -F'|' -v want="$1" '
            $1 == "installed" {
                n = split($3, a, ",")
                for (i = 1; i <= n; i++) {
                    p = a[i]; sub(/\(.*/, "", p); gsub(/[ \t]/, "", p)
                    if (p == want) { print $2; exit }
                }
            }'
}

# ============== CONFLICT-SAFE PACKAGE INSTALLER ==============
#
# Why this exists:
#   Termux has packages that hard-conflict with each other
#   (e.g. vulkan-loader-android vs vulkan-loader-generic).
#   Raw apt-get errors out on conflicts and — combined with set -e — would
#   silently kill the entire script.
#
# What this does:
#   1. Skips if the package is already installed, or already provided by
#      something installed (vulkan-loader-generic Provides vulkan-loader-android).
#   2. Reads the package's declared Conflicts and evaluates each one properly,
#      version constraints included.
#   3. Ignores a conflict the package also Replaces/Provides — that is a
#      supported swap (mesa → mesa-zink), not a breakage, and apt handles it.
#   4. Only then skips, with a warning, on a conflict that is genuinely unsafe.
#
# Usage: safe_install_pkg <pkg> [display name] [optional]
#   Passing "optional" as the third argument downgrades a failed install from a
#   red error to a yellow warning, for packages the desktop can live without.
#
safe_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    local optional=${3:-}

    if pkg_installed "$pkg"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed): $pkg"
        return 0
    fi

    # Already satisfied by a virtual provider?
    local provider
    provider=$(provider_of "$pkg")
    if [ -n "$provider" ]; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(provided by %s)${NC}\n" "$name" "$provider"
        log "SKIP (provided by $provider): $pkg"
        return 0
    fi

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(not in any enabled repo)${NC}\n" "$name"
        log "SKIP (unavailable): $pkg"
        return 1
    fi

    # Conflicts the package can legitimately take over are not blockers.
    local swappable
    swappable=$(dep_names "$(apt_field "$pkg" Replaces)
$(apt_field "$pkg" Provides)")

    local item cname
    while IFS= read -r item; do
        [ -z "$(echo "$item" | tr -d ' \t')" ] && continue

        if conflict_is_real "$item"; then
            cname=$(echo "$item" | sed 's/(.*//' | tr -d ' \t')
            if echo "$swappable" | grep -qx "$cname"; then
                log "CONFLICT OK (${pkg} replaces ${cname}): apt will swap them"
            else
                printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(skipped — conflicts with: %s)${NC}\n" \
                    "$name" "$cname"
                log "SKIP (conflict with $cname): $pkg"
                return 1
            fi
        fi
    done <<< "$(apt_field "$pkg" Conflicts | tr ',' '\n')"

    (DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        "$pkg" >> "$LOG_FILE" 2>&1) &

    if [ "$optional" = "optional" ]; then
        spinner_optional $! "Installing ${name}..."
    else
        spinner $! "Installing ${name}..."
    fi
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          Termux Linux Desktop Setup Script           ║
  ║             Run full Linux on your Android           ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "${GRAY}  Detailed logs → $LOG_FILE${NC}"
    echo ""
}

# ============== ENVIRONMENT & USER SELECTION ==============
setup_environment() {
    log "=== Setup started ==="

    echo -e "${PURPLE}[*] Detecting your device...${NC}"
    echo ""

    # `getprop X || echo default` does not do what it looks like: `||` only runs
    # when the command *fails* (non-zero exit), but a getprop that succeeds and
    # prints nothing still yields an empty string. The defaults were therefore
    # never applied when the property was empty, and the banner printed
    # `Device :`, `Android: Android` and `CPU ABI:` with blank values.
    # Apply the default to the captured value instead.
    DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null)
    DEVICE_MODEL=${DEVICE_MODEL:-Unknown}
    DEVICE_BRAND=$(getprop ro.product.brand 2>/dev/null)
    DEVICE_BRAND=${DEVICE_BRAND:-Unknown}
    ANDROID_VERSION=$(getprop ro.build.version.release 2>/dev/null)
    ANDROID_VERSION=${ANDROID_VERSION:-Unknown}
    CPU_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
    CPU_ABI=${CPU_ABI:-arm64-v8a}

    # Use actual EGL/hardware properties — NOT brand name.
    # Brand-based detection is wrong: Samsung ships both Adreno (Snapdragon)
    # and Mali (Exynos) phones, so checking "samsung" tells you nothing.
    GPU_RENDERER=$(getprop ro.hardware.egl 2>/dev/null || echo "")
    GPU_VENDOR_PROP=$(getprop ro.hardware 2>/dev/null || echo "")

    echo -e "  ${CYAN}Device :${NC}  ${WHITE}${DEVICE_BRAND} ${DEVICE_MODEL}${NC}"
    echo -e "  ${CYAN}Android:${NC}  ${WHITE}Android ${ANDROID_VERSION}${NC}"
    echo -e "  ${CYAN}CPU ABI:${NC}  ${WHITE}${CPU_ABI}${NC}"

    if [[ "$GPU_RENDERER" == *"adreno"* ]] || \
       [[ "$GPU_RENDERER" == *"Adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"msm"* ]]   || \
       [[ "$GPU_VENDOR_PROP" == *"qcom"* ]]; then
        GPU_DRIVER="freedreno"
        echo -e "  ${CYAN}GPU    :${NC}  ${WHITE}Adreno / Qualcomm — Turnip hardware acceleration ✔${NC}"
    else
        GPU_DRIVER="zink_native"
        echo -e "  ${CYAN}GPU    :${NC}  ${YELLOW}Non-Adreno (Mali / PowerVR / other)${NC}"
        echo -e "             ${YELLOW}Falling back to Zink/Vulkan. Use XFCE4 or LXQt for best results.${NC}"
    fi
    echo ""

    # ---- Desktop Environment ----
    echo -e "${CYAN}Choose your Desktop Environment:${NC}"
    echo ""
    echo -e "  ${WHITE}1) XFCE4${NC}       — Fast, customizable, macOS-style dock. ${GREEN}(Recommended)${NC}"
    echo -e "  ${WHITE}2) LXQt${NC}        — Ultra-lightweight. Best for low-RAM phones."
    echo -e "  ${WHITE}3) MATE${NC}        — Classic look. Moderate resource use."
    echo -e "  ${WHITE}4) KDE Plasma${NC}  — Modern Windows-style UI. Requires 4 GB+ RAM."
    echo ""

    while true; do
        read -rp "  Enter number (1-4) [default: 1]: " DE_INPUT
        DE_INPUT=${DE_INPUT:-1}
        if [[ "$DE_INPUT" =~ ^[1-4]$ ]]; then
            DE_CHOICE="$DE_INPUT"; break
        else
            echo -e "  ${RED}Invalid — enter 1, 2, 3, or 4.${NC}"
        fi
    done

    case $DE_CHOICE in
        1) DE_NAME="XFCE4";;
        2) DE_NAME="LXQt";;
        3) DE_NAME="MATE";;
        4) DE_NAME="KDE Plasma";;
    esac
    echo -e "\n  ${GREEN}✔ Selected: ${BOLD}${DE_NAME}${NC}"

    # ---- Optional: Wine ----
    echo ""
    echo -e "${CYAN}Optional: Install Windows app support (Wine + Box64/Hangover)?${NC}"
    echo -e "  ${GRAY}Adds ~500 MB. Runs some Windows x86 apps on ARM.${NC}"
    echo ""
    while true; do
        read -rp "  Install Wine? (y/n) [default: n]: " WINE_INPUT
        WINE_INPUT=${WINE_INPUT:-n}
        case "$WINE_INPUT" in
            [Yy]*) INSTALL_WINE="yes"; echo -e "  ${GREEN}✔ Wine will be installed.${NC}"; break;;
            [Nn]*) INSTALL_WINE="no";  echo -e "  ${GRAY}  Wine skipped.${NC}"; break;;
            *) echo -e "  ${RED}Please enter y or n.${NC}";;
        esac
    done

    TOTAL_STEPS=10
    [ "$INSTALL_WINE" == "yes" ] && TOTAL_STEPS=11

    log "DE=$DE_NAME, GPU=$GPU_DRIVER, Wine=$INSTALL_WINE"
    sleep 1
}

# ============== STEP 1: UPDATE SYSTEM ==============
step_update() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Updating system packages...${NC}"
    echo ""

    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating package lists..."

    # Run pkg upgrade in FOREGROUND (not backgrounded via &) so we can catch
    # the libpcre/libandroid-selinux crash that kills binaries like 'sleep'
    # mid-session when core libraries are replaced. If it fails, we tell the
    # user exactly what to do rather than dying silently.
    echo -e "  ${CYAN}⠿${NC}  Upgrading packages (may take a few minutes)..."
    if ! DEBIAN_FRONTEND=noninteractive pkg upgrade -y \
            -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1; then
        echo ""
        echo -e "  ${YELLOW}⚠  Upgrade hit a library conflict — this is common on first run.${NC}"
        echo ""
        echo -e "  ${WHITE}To fix:${NC}"
        echo -e "    1. Close Termux completely (swipe away from recents)"
        echo -e "    2. Reopen Termux and run:  ${GREEN}pkg upgrade -y${NC}"
        echo -e "    3. Then re-run this script"
        echo ""
        echo -e "  ${GRAY}Full error: $LOG_FILE${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔${NC}  Packages upgraded."
}

# ============== STEP 2: REPOSITORIES ==============
step_repos() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Adding package repositories...${NC}"
    echo ""
    safe_install_pkg "x11-repo" "X11 Repository"
    safe_install_pkg "tur-repo" "TUR Repository (Firefox, extra apps)"

    # MUST refresh after adding repos — otherwise packages from x11-repo
    # and tur-repo (termux-x11-nightly, firefox, etc.) won't be found.
    echo ""
    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1) &
    spinner $! "Refreshing package lists (post-repo)..."
}

# ============== STEP 3: TERMUX-X11 ==============
step_x11() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Termux-X11 display server...${NC}"
    echo ""
    safe_install_pkg "termux-x11-nightly" "Termux-X11 Display Server"
    safe_install_pkg "xorg-xrandr"        "XRandR (Display Settings)"
}

# ============== STEP 4: DESKTOP ENVIRONMENT ==============
step_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing ${DE_NAME} Desktop...${NC}"
    echo ""

    # None of the Termux DE metapackages depend on dbus, but every one of them
    # needs a session bus to reach its settings daemon. Without it XFCE greets
    # you with "Unable to contact settings server". (issue #5)
    safe_install_pkg "dbus" "D-Bus (session message bus)"

    case $DE_CHOICE in
        1)
            safe_install_pkg "xfce4"                    "XFCE4 Desktop"
            safe_install_pkg "xfce4-terminal"           "XFCE4 Terminal"
            safe_install_pkg "xfce4-whiskermenu-plugin" "Whisker Menu Plugin"
            safe_install_pkg "plank-reloaded"           "Plank Dock"
            safe_install_pkg "thunar"                   "Thunar File Manager"
            safe_install_pkg "mousepad"                 "Mousepad Text Editor"
            ;;
        2)
            safe_install_pkg "lxqt"       "LXQt Desktop"
            safe_install_pkg "qterminal"  "QTerminal"
            safe_install_pkg "pcmanfm-qt" "PCManFM-Qt File Manager"
            safe_install_pkg "featherpad" "FeatherPad Text Editor"
            ;;
        3)
            safe_install_pkg "mate"            "MATE Desktop"
            safe_install_pkg "mate-tweak"      "MATE Tweak"
            safe_install_pkg "plank-reloaded"  "Plank Dock"
            safe_install_pkg "mate-terminal"   "MATE Terminal"
            ;;
        4)
            safe_install_pkg "plasma-desktop" "KDE Plasma Desktop"
            safe_install_pkg "konsole"        "Konsole Terminal"
            safe_install_pkg "dolphin"        "Dolphin File Manager"
            ;;
    esac
}

# ============== STEP 5: GPU DRIVERS ==============
#
# Termux's own "mesa" package has shipped the Zink Gallium driver
# (lib/dri/zink_dri.so) since Mesa 23, so GALLIUM_DRIVER=zink works against the
# stock, current Mesa. The TUR "mesa-zink" package is Mesa 22.0.5 from 2022:
# installing it REMOVES mesa and drops you back four years, and its companion
# mesa-zink-vulkan-icd-freedreno ships the same libvulkan_freedreno.so as the
# main-repo Turnip driver, so dpkg aborts with a file-overwrite error if both
# land on the device. That was issue #4.
#
# So: prefer the stock stack, and only use the TUR one on installs whose Mesa
# genuinely has no Zink, or that already have mesa-zink from an earlier run.
step_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU acceleration...${NC}"
    echo ""

    GPU_STACK="stock"

    if pkg_installed "mesa-zink"; then
        # Don't rip out a working legacy setup on re-run — the two stacks
        # overwrite each other's files.
        GPU_STACK="tur"
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(keeping TUR stack)${NC}\n" "Existing mesa-zink install detected"
        log "GPU stack: tur (mesa-zink already installed)"
    else
        safe_install_pkg "mesa" "Mesa (OpenGL + Zink)"
        if [ ! -f "${TERMUX_PREFIX}/lib/dri/zink_dri.so" ]; then
            GPU_STACK="tur"
            echo -e "  ${YELLOW}⚠${NC}  This Mesa build has no Zink — falling back to TUR mesa-zink."
            log "GPU stack: tur (no zink_dri.so in stock mesa)"
        else
            log "GPU stack: stock (zink_dri.so present)"
        fi
    fi

    # vulkan-loader-generic is the modern loader and is what every
    # mesa-vulkan-icd-* depends on. Do NOT ask for vulkan-loader-android:
    # vulkan-loader-generic both Provides AND Conflicts with it, so requesting
    # it on a normal install aborts the apt transaction for zero benefit.
    safe_install_pkg "vulkan-loader-generic" "Vulkan Loader"

    if [ "$GPU_STACK" == "tur" ]; then
        safe_install_pkg "mesa-zink" "Mesa Zink (OpenGL on Vulkan)"
        if [ "$GPU_DRIVER" == "freedreno" ]; then
            safe_install_pkg "mesa-zink-vulkan-icd-freedreno" "Freedreno Vulkan ICD (Turnip)"
        else
            safe_install_pkg "mesa-zink-vulkan-icd-swrast"    "SwRast Vulkan ICD (software)"
        fi
    else
        if [ "$GPU_DRIVER" == "freedreno" ]; then
            safe_install_pkg "mesa-vulkan-icd-freedreno" "Freedreno Vulkan ICD (Turnip)"
        else
            safe_install_pkg "mesa-vulkan-icd-swrast"    "SwRast Vulkan ICD (software)"
        fi
    fi

    # Verify here rather than letting a missing ICD show up as a black screen
    # ten minutes from now.
    echo ""
    if [ "$GPU_DRIVER" == "freedreno" ]; then
        if [ -f "${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]; then
            echo -e "  ${GREEN}✔${NC}  Turnip (Adreno) Vulkan driver in place."
        else
            echo -e "  ${YELLOW}⚠${NC}  Turnip ICD missing — the desktop will fall back to software rendering."
            log "WARNING: freedreno ICD json not found"
        fi
    fi
    log "GPU stack final: $GPU_STACK"
}

# ============== STEP 6: AUDIO ==============
step_audio() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing audio server...${NC}"
    echo ""
    safe_install_pkg "pulseaudio" "PulseAudio"
}

# ============== STEP 7: APPS ==============
step_apps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing applications...${NC}"
    echo ""
    safe_install_pkg "firefox"  "Firefox Browser"
    safe_install_pkg "vlc"      "VLC Media Player"
    safe_install_pkg "git"      "Git Version Control"
    safe_install_pkg "wget"     "Wget"
    safe_install_pkg "curl"     "cURL"
    safe_install_pkg "openssh"  "OpenSSH (SSH server + client)"
}

# ============== STEP 8: PYTHON ==============
step_python() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Python...${NC}"
    echo ""
    safe_install_pkg "python"     "Python 3"
    safe_install_pkg "python-pip" "pip (Python Package Manager)"
}

# ============== STEP 9 (OPTIONAL): WINE ==============
step_wine() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Windows support (Wine + Box64)...${NC}"
    echo ""

    (pkg remove wine-stable -y >> "$LOG_FILE" 2>&1 || true) &
    spinner $! "Removing old Wine versions (if any)..."

    safe_install_pkg "hangover-wine"     "Hangover Wine"
    safe_install_pkg "hangover-wowbox64" "Box64 Wrapper"

    local WINE_BIN="${TERMUX_PREFIX}/opt/hangover-wine/bin"
    if [ -f "${WINE_BIN}/wine" ]; then
        ln -sf "${WINE_BIN}/wine"    "${TERMUX_PREFIX}/bin/wine"
        ln -sf "${WINE_BIN}/winecfg" "${TERMUX_PREFIX}/bin/winecfg"
        echo -e "  ${GREEN}✔ Wine binaries linked to PATH.${NC}"
        log "Wine symlinks created."
    else
        echo -e "  ${YELLOW}  Wine binary not found at expected path — symlinks skipped.${NC}"
        log "WARNING: Wine binary not found at $WINE_BIN"
    fi
}

# ============== STEP 10: LAUNCHER SCRIPTS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating startup scripts...${NC}"
    echo ""

    mkdir -p ~/.config

    XDG_INJECT="export XDG_DATA_DIRS=${TERMUX_PREFIX}/share:\${XDG_DATA_DIRS:-}\nexport XDG_CONFIG_DIRS=${TERMUX_PREFIX}/etc/xdg:\${XDG_CONFIG_DIRS:-}\nexport XDG_RUNTIME_DIR=\${TMPDIR:-${TERMUX_PREFIX}/tmp}"

    if [ "$DE_CHOICE" == "4" ]; then
        mkdir -p ~/.config/plasma-workspace/env
        {
            echo "#!${TERMUX_PREFIX}/bin/bash"
            echo -e "$XDG_INJECT"
        } > ~/.config/plasma-workspace/env/xdg_fix.sh
        chmod +x ~/.config/plasma-workspace/env/xdg_fix.sh
    fi

    cat > ~/.config/linux-gpu.sh << EOF
#!${TERMUX_PREFIX}/bin/bash
# GPU & Mesa environment — sourced by start-linux.sh
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
EOF

    if [ "$DE_CHOICE" == "4" ]; then
        echo "export KWIN_COMPOSE=O2ES" >> ~/.config/linux-gpu.sh
    else
        echo -e "$XDG_INJECT" >> ~/.config/linux-gpu.sh
    fi

    if [ "$GPU_DRIVER" == "freedreno" ]; then
        echo "export VK_ICD_FILENAMES=${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json" \
            >> ~/.config/linux-gpu.sh
    fi

    if [ "$DE_CHOICE" == "1" ] || [ "$DE_CHOICE" == "3" ]; then
        mkdir -p ~/.config/autostart
        cat > ~/.config/autostart/plank.desktop << 'PLANKEOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
PLANKEOF
    else
        rm -f ~/.config/autostart/plank.desktop 2>/dev/null || true
    fi

    case $DE_CHOICE in
        1)
            EXEC_CMD="exec startxfce4"
            KILL_CMD="pkill -9 xfce4-session 2>/dev/null; pkill -9 plank 2>/dev/null"
            ;;
        2)
            EXEC_CMD="exec startlxqt"
            KILL_CMD="pkill -9 lxqt-session 2>/dev/null"
            ;;
        3)
            EXEC_CMD="exec mate-session"
            KILL_CMD="pkill -9 mate-session 2>/dev/null; pkill -9 plank 2>/dev/null"
            ;;
        4)
            EXEC_CMD="(sleep 5 && pkill -9 plasmashell && plasmashell) >/dev/null 2>&1 &\nexec startplasma-x11"
            KILL_CMD="pkill -9 startplasma-x11 2>/dev/null; pkill -9 kwin_x11 2>/dev/null"
            ;;
    esac

    cat > ~/start-linux.sh << LAUNCHEREOF
#!${TERMUX_PREFIX}/bin/bash
echo ""
echo "[*] Starting ${DE_NAME} on Termux-X11..."
echo ""

source ~/.config/linux-gpu.sh 2>/dev/null

echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null || true
${KILL_CMD} || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
sleep 0.5

# ---- D-Bus session bus ----
# XFCE, MATE and KDE all reach their settings daemon over the session bus.
# If no bus is running -- or if a previous run was SIGKILLed and left a dead
# socket plus a stale address in ~/.dbus behind -- the desktop comes up with
# "Unable to contact settings server" and
# "Failed to connect to socket .../dbus-XXXX: Connection refused".
# Clearing the stale state and starting the bus at a fixed, predictable
# address fixes both. (issue #5)
echo "[*] Starting D-Bus session bus..."
export XDG_RUNTIME_DIR="\${TMPDIR:-${TERMUX_PREFIX}/tmp}"
mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "\$XDG_RUNTIME_DIR" 2>/dev/null || true

DBUS_DIR="${TERMUX_PREFIX}/var/run/dbus"
rm -rf "\$HOME/.dbus" 2>/dev/null || true
rm -f "\${XDG_RUNTIME_DIR}/dbus-"* 2>/dev/null || true
mkdir -p "\$DBUS_DIR" "${TERMUX_PREFIX}/var/lib/dbus"
rm -f "\$DBUS_DIR/session_bus_socket"
dbus-uuidgen --ensure >/dev/null 2>&1 || true

export DBUS_SESSION_BUS_ADDRESS="unix:path=\$DBUS_DIR/session_bus_socket"
if command -v dbus-daemon >/dev/null 2>&1; then
    dbus-daemon --session --address="\$DBUS_SESSION_BUS_ADDRESS" --nopidfile --fork
else
    echo "[!] dbus-daemon not found. Run: pkg install dbus"
    unset DBUS_SESSION_BUS_ADDRESS
fi

echo "[*] Starting PulseAudio..."
unset PULSE_SERVER
pulseaudio --kill 2>/dev/null || true
sleep 0.3
# Both calls are time-bounded on purpose. `pulseaudio --start` and `pactl` can
# block indefinitely when the audio HAL is wedged, and the "|| true" below only
# rescues a command that *fails* -- not one that never returns. Unbounded, a
# stuck PulseAudio stalls the launcher here and `termux-x11` is never started,
# so the desktop silently never appears (Termux-X11 just says "Not connected")
# with no error to act on. Audio is optional; it must never hold up the display.
if command -v timeout >/dev/null 2>&1; then
    timeout 10 pulseaudio --start --exit-idle-time=-1 \
        || echo "[!] PulseAudio did not start - continuing without audio."
    sleep 1
    timeout 5 pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
else
    pulseaudio --start --exit-idle-time=-1 || true
    sleep 1
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
fi
export PULSE_SERVER=127.0.0.1

echo "[*] Starting Termux-X11 display server..."
termux-x11 :0 -ac &
sleep 3
export DISPLAY=:0

# Daemons the bus starts on demand (xfconfd, xfsettingsd, ...) inherit the
# bus's environment, not this shell's -- so push DISPLAY across explicitly.
dbus-update-activation-environment DISPLAY XAUTHORITY PULSE_SERVER XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_RUNTIME_DIR >/dev/null 2>&1 || true

echo ""
echo "─────────────────────────────────────────────────"
echo "  ✔ Desktop launching! Open the Termux-X11 app."
echo "─────────────────────────────────────────────────"
echo ""

${EXEC_CMD}
LAUNCHEREOF
    chmod +x ~/start-linux.sh
    echo -e "  ${GREEN}✔ Created ~/start-linux.sh${NC}"

    cat > ~/stop-linux.sh << STOPEOF
#!${TERMUX_PREFIX}/bin/bash
echo "[*] Stopping ${DE_NAME}..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "pulseaudio"  2>/dev/null || true
${KILL_CMD} || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
# Leave no dead socket for the next start to trip over.
rm -f "${TERMUX_PREFIX}/var/run/dbus/session_bus_socket" 2>/dev/null || true
rm -rf "\$HOME/.dbus" 2>/dev/null || true
echo "[✔] Desktop stopped."
STOPEOF
    chmod +x ~/stop-linux.sh
    echo -e "  ${GREEN}✔ Created ~/stop-linux.sh${NC}"
}

# ============== STEP 11: DESKTOP SHORTCUTS ==============
step_shortcuts() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating desktop shortcuts...${NC}"
    echo ""

    mkdir -p ~/Desktop

    cat > ~/Desktop/Firefox.desktop << 'EOF'
[Desktop Entry]
Name=Firefox
Exec=firefox
Icon=firefox
Type=Application
Categories=Network;WebBrowser;
EOF

    cat > ~/Desktop/VLC.desktop << 'EOF'
[Desktop Entry]
Name=VLC Media Player
Exec=vlc
Icon=vlc
Type=Application
Categories=Video;AudioVideo;Player;
EOF

    local term_cmd term_icon
    case $DE_CHOICE in
        1) term_cmd="xfce4-terminal"; term_icon="xfce4-terminal";;
        2) term_cmd="qterminal";      term_icon="qterminal";;
        3) term_cmd="mate-terminal";  term_icon="mate-terminal";;
        4) term_cmd="konsole";        term_icon="utilities-terminal";;
    esac

    cat > ~/Desktop/Terminal.desktop << EOF
[Desktop Entry]
Name=Terminal
Exec=${term_cmd}
Icon=${term_icon}
Type=Application
Categories=System;TerminalEmulator;
EOF

    if [ "$INSTALL_WINE" == "yes" ]; then
        cat > ~/Desktop/Wine_Config.desktop << 'EOF'
[Desktop Entry]
Name=Wine Config
Exec=wine winecfg
Icon=wine
Type=Application
Categories=Utility;
EOF
    fi

    chmod +x ~/Desktop/*.desktop 2>/dev/null || true
    echo -e "  ${GREEN}✔ Desktop shortcuts created.${NC}"
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    echo -e "${GREEN}"
    cat << 'COMPLETE'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║              ✔  INSTALLATION COMPLETE!               ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
COMPLETE
    echo -e "${NC}"
    echo -e "  ${WHITE}Desktop  : ${GREEN}${DE_NAME}${NC}"
    echo -e "  ${WHITE}GPU      : ${GREEN}${GPU_DRIVER}${NC}"
    echo -e "  ${WHITE}Wine     : ${GREEN}${INSTALL_WINE}${NC}"
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}▶  START DESKTOP:${NC}  ${GREEN}bash ~/start-linux.sh${NC}"
    echo -e "  ${WHITE}■  STOP DESKTOP: ${NC}  ${GREEN}bash ~/stop-linux.sh${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}SSH into this device from another machine:${NC}"
    echo -e "    1. Start SSH server:  ${GREEN}sshd${NC}"
    echo -e "    2. Set a password:    ${GREEN}passwd${NC}"
    echo -e "    3. Find your IP:      ${GREEN}ip addr show wlan0 | grep 'inet '${NC}"
    echo -e "    4. Connect from PC:   ${GREEN}ssh \$(whoami)@<your-ip> -p 8022${NC}"
    echo ""
    echo -e "  ${GRAY}Full install log: $LOG_FILE${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    echo "" > "$LOG_FILE"
    log "termux-linux-setup.sh started"

    # Prevent Android from suspending Termux mid-install when screen turns off.
    # A suspended Termux kills background apt processes, causing random failures.
    if command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
        log "Wake lock acquired."
    else
        echo -e "${YELLOW}  [!] termux-wake-lock unavailable — keep your screen on during install.${NC}"
        echo ""
    fi

    show_banner
    setup_environment

    step_update
    step_repos
    step_x11
    step_desktop
    step_gpu
    step_audio
    step_apps
    step_python

    [ "$INSTALL_WINE" == "yes" ] && step_wine

    step_launchers
    step_shortcuts
    show_completion

    if command -v termux-wake-unlock &>/dev/null; then
        termux-wake-unlock
        log "Wake lock released."
    fi
}

main

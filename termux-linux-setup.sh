#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Linux Desktop Setup Script
#
#  Features:
#  - Choice of Desktop Environment (XFCE4, LXQt, MATE, KDE)
#  - Smart GPU acceleration detection (Turnip/Zink)
#  - Productivity & Media tools (VLC, Firefox)
#  - Python environment pre-installed
#  - Optional: Windows App Support (Wine/Hangover + Box64)
#
#  Tested on: LineageOS (Android 9+), arm64 devices
#######################################################

set -euo pipefail

# ============== DYNAMIC PATH DETECTION ==============
# Supports both standard and custom Termux installs
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

# ============== CONFIGURATION ==============
INSTALL_WINE="no"       # Set by user prompt
DE_CHOICE="1"
DE_NAME="XFCE4"

# TOTAL_STEPS is set after user choices are made
CURRENT_STEP=0

# Log file for debugging
LOG_FILE="$TERMUX_HOME/termux-setup.log"

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# ============== PROGRESS ==============
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
        printf "\r  ${GREEN}✔${NC}  %-50s\n" "$message"
        log "OK: $message"
    else
        printf "\r  ${RED}✘${NC}  %-50s ${RED}(FAILED — check $LOG_FILE)${NC}\n" "$message"
        log "FAILED: $message"
        # Non-fatal: log and continue so other packages still install
    fi

    return "$exit_code"
}

# ============== PACKAGE INSTALLER ==============
install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    (DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        "$pkg" >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name}..."
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

    DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
    DEVICE_BRAND=$(getprop ro.product.brand 2>/dev/null || echo "Unknown")
    ANDROID_VERSION=$(getprop ro.build.version.release 2>/dev/null || echo "Unknown")
    CPU_ABI=$(getprop ro.product.cpu.abi 2>/dev/null || echo "arm64-v8a")

    # Detect GPU vendor via actual EGL/Vulkan property, not brand name
    GPU_RENDERER=$(getprop ro.hardware.egl 2>/dev/null || echo "")
    GPU_VENDOR_PROP=$(getprop ro.hardware 2>/dev/null || echo "")

    echo -e "  ${CYAN}Device :${NC}  ${WHITE}${DEVICE_BRAND} ${DEVICE_MODEL}${NC}"
    echo -e "  ${CYAN}Android:${NC}  ${WHITE}Android ${ANDROID_VERSION}${NC}"
    echo -e "  ${CYAN}CPU ABI:${NC}  ${WHITE}${CPU_ABI}${NC}"

    # Detect if GPU is actually Adreno (Qualcomm) — do not rely on brand name
    if [[ "$GPU_RENDERER" == *"adreno"* ]] || \
       [[ "$GPU_RENDERER" == *"Adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"msm"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"qcom"* ]]; then
        GPU_DRIVER="freedreno"
        echo -e "  ${CYAN}GPU    :${NC}  ${WHITE}Adreno (Qualcomm) — Turnip Hardware Acceleration ✔${NC}"
    else
        GPU_DRIVER="zink_native"
        echo -e "  ${CYAN}GPU    :${NC}  ${YELLOW}Non-Adreno detected (Mali, PowerVR, etc.)${NC}"
        echo -e "  ${YELLOW}         Falling back to Zink/Vulkan software path.${NC}"
        echo -e "  ${YELLOW}         RECOMMENDATION: Choose XFCE4 or LXQt for best performance.${NC}"
    fi
    echo ""

    # ---- Desktop Environment Selection ----
    echo -e "${CYAN}Choose your Desktop Environment:${NC}"
    echo ""
    echo -e "  ${WHITE}1) XFCE4${NC}       — Fast, customizable, macOS-style dock. ${GREEN}(Recommended)${NC}"
    echo -e "  ${WHITE}2) LXQt${NC}        — Ultra-lightweight. Best for older/low-RAM phones."
    echo -e "  ${WHITE}3) MATE${NC}        — Classic look. Moderate resource usage."
    echo -e "  ${WHITE}4) KDE Plasma${NC}  — Modern Windows-style UI. Needs strong GPU & 4 GB+ RAM."
    echo ""

    while true; do
        read -rp "  Enter number (1-4) [default: 1]: " DE_INPUT
        DE_INPUT=${DE_INPUT:-1}
        if [[ "$DE_INPUT" =~ ^[1-4]$ ]]; then
            DE_CHOICE="$DE_INPUT"
            break
        else
            echo -e "  ${RED}Invalid input. Please enter 1, 2, 3, or 4.${NC}"
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
    echo -e "  ${GRAY}Adds ~500 MB. Lets you run some Windows x86 applications.${NC}"
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

    # Set total steps dynamically
    if [ "$INSTALL_WINE" == "yes" ]; then
        TOTAL_STEPS=11
    else
        TOTAL_STEPS=10
    fi

    log "DE=$DE_NAME, GPU=$GPU_DRIVER, Wine=$INSTALL_WINE"
    sleep 1
}

# ============== STEP 1: UPDATE SYSTEM ==============
step_update() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Updating system packages...${NC}"
    echo ""

    # Update package lists
    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating package lists..."

    # Use pkg (Termux's wrapper) instead of raw apt-get upgrade.
    # Raw apt-get upgrade can break mid-session when libpcre or libc gets replaced
    # while binaries like 'sleep' are still loaded from the old library in memory.
    # pkg upgrade handles Termux-specific bootstrap edge cases more safely.
    # Run in foreground (not background) so we can catch a crash and advise the user.
    echo -e "  ${CYAN}⠿${NC}  Upgrading installed packages (this may take a while)..."
    if ! DEBIAN_FRONTEND=noninteractive pkg upgrade -y \
            -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1; then

        echo ""
        echo -e "  ${YELLOW}⚠  Upgrade hit a library conflict (common on first run).${NC}"
        echo -e "  ${WHITE}Fix:${NC}"
        echo -e "    1. Close Termux completely and reopen it"
        echo -e "    2. Run:  ${GREEN}pkg upgrade -y${NC}"
        echo -e "    3. Then re-run this script"
        echo ""
        echo -e "  ${GRAY}Full error in: $LOG_FILE${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔${NC}  Packages upgraded."
}

# ============== STEP 2: INSTALL REPOSITORIES ==============
step_repos() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Adding package repositories...${NC}"
    echo ""
    install_pkg "x11-repo" "X11 Repository"
    install_pkg "tur-repo" "TUR Repository (Firefox, extra apps)"

    # IMPORTANT: Must refresh package lists after adding new repos
    echo ""
    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1) &
    spinner $! "Refreshing package lists (post-repo)..."
}

# ============== STEP 3: INSTALL TERMUX-X11 ==============
step_x11() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Termux-X11 display server...${NC}"
    echo ""
    install_pkg "termux-x11-nightly" "Termux-X11 Display Server"
    install_pkg "xorg-xrandr" "XRandR (Display Settings)"
}

# ============== STEP 4: INSTALL DESKTOP ENVIRONMENT ==============
step_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing ${DE_NAME} Desktop...${NC}"
    echo ""

    case $DE_CHOICE in
        1)
            install_pkg "xfce4"                    "XFCE4 Desktop"
            install_pkg "xfce4-terminal"           "XFCE4 Terminal"
            install_pkg "xfce4-whiskermenu-plugin" "Whisker Menu Plugin"
            install_pkg "plank-reloaded"           "Plank Dock"
            install_pkg "thunar"                   "Thunar File Manager"
            install_pkg "mousepad"                 "Mousepad Text Editor"
            ;;
        2)
            install_pkg "lxqt"       "LXQt Desktop"
            install_pkg "qterminal"  "QTerminal"
            install_pkg "pcmanfm-qt" "PCManFM-Qt File Manager"
            install_pkg "featherpad" "FeatherPad Text Editor"
            ;;
        3)
            install_pkg "mate"          "MATE Desktop"
            install_pkg "mate-tweak"   "MATE Tweak"
            install_pkg "plank-reloaded" "Plank Dock"
            install_pkg "mate-terminal" "MATE Terminal"
            ;;
        4)
            install_pkg "plasma-desktop" "KDE Plasma Desktop"
            install_pkg "konsole"        "Konsole Terminal"
            install_pkg "dolphin"        "Dolphin File Manager"
            ;;
    esac
}

# ============== STEP 5: INSTALL GPU DRIVERS ==============
step_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU acceleration...${NC}"
    echo ""

    install_pkg "mesa-zink"            "Mesa Zink (OpenGL on Vulkan)"
    install_pkg "vulkan-loader-android" "Vulkan Loader"

    if [ "$GPU_DRIVER" == "freedreno" ]; then
        install_pkg "mesa-vulkan-icd-freedreno" "Turnip Adreno Vulkan Driver"
    fi
}

# ============== STEP 6: INSTALL AUDIO ==============
step_audio() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing audio server...${NC}"
    echo ""
    install_pkg "pulseaudio" "PulseAudio"
}

# ============== STEP 7: INSTALL APPS ==============
step_apps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing applications...${NC}"
    echo ""
    install_pkg "firefox" "Firefox Browser"
    install_pkg "vlc"     "VLC Media Player"
    install_pkg "git"     "Git Version Control"
    install_pkg "wget"    "Wget"
    install_pkg "curl"    "cURL"
}

# ============== STEP 8: PYTHON ==============
step_python() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Python...${NC}"
    echo ""
    install_pkg "python" "Python 3"
    install_pkg "python-pip" "pip (Python Package Manager)"
    echo -e "  ${GRAY}  Python installed. Run 'python3' in your terminal to start.${NC}"
}

# ============== STEP 9 (OPTIONAL): WINE ==============
step_wine() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Windows support (Wine + Box64)...${NC}"
    echo ""

    # Remove any conflicting old Wine packages first
    (pkg remove wine-stable -y >> "$LOG_FILE" 2>&1 || true) &
    spinner $! "Removing old Wine versions (if any)..."

    install_pkg "hangover-wine"    "Hangover Wine"
    install_pkg "hangover-wowbox64" "Box64 Wrapper"

    # Symlink wine binaries into PATH only if they exist
    local WINE_BIN="${TERMUX_PREFIX}/opt/hangover-wine/bin"
    if [ -f "${WINE_BIN}/wine" ]; then
        ln -sf "${WINE_BIN}/wine"    "${TERMUX_PREFIX}/bin/wine"
        ln -sf "${WINE_BIN}/winecfg" "${TERMUX_PREFIX}/bin/winecfg"
        echo -e "  ${GREEN}✔ Wine binaries linked to PATH.${NC}"
        log "Wine symlinks created."
    else
        echo -e "  ${YELLOW}  Wine binary not found at expected path — symlinks skipped.${NC}"
        log "WARNING: Wine binary not found, symlinks skipped."
    fi
}

# ============== STEP 10: CREATE LAUNCHER SCRIPTS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating startup scripts...${NC}"
    echo ""

    mkdir -p ~/.config

    # XDG path fix for Termux
    XDG_INJECT="export XDG_DATA_DIRS=${TERMUX_PREFIX}/share:\${XDG_DATA_DIRS:-}\nexport XDG_CONFIG_DIRS=${TERMUX_PREFIX}/etc/xdg:\${XDG_CONFIG_DIRS:-}"

    # KDE needs startup environment injection
    if [ "$DE_CHOICE" == "4" ]; then
        mkdir -p ~/.config/plasma-workspace/env
        {
            echo "#!/${TERMUX_PREFIX}/bin/bash"
            echo -e "$XDG_INJECT"
        } > ~/.config/plasma-workspace/env/xdg_fix.sh
        chmod +x ~/.config/plasma-workspace/env/xdg_fix.sh
    fi

    # GPU & Mesa environment config
    cat > ~/.config/linux-gpu.sh << EOF
#!/${TERMUX_PREFIX}/bin/bash
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

    # Turnip driver if Adreno detected
    if [ "$GPU_DRIVER" == "freedreno" ]; then
        echo "export VK_ICD_FILENAMES=${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json" >> ~/.config/linux-gpu.sh
    fi

    # Plank autostart (XFCE4 and MATE only)
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

    # Determine DE-specific start/stop commands
    case $DE_CHOICE in
        1)
            EXEC_CMD="exec startxfce4"
            KILL_CMD="pkill -9 xfce4-session; pkill -9 plank"
            ;;
        2)
            EXEC_CMD="exec startlxqt"
            KILL_CMD="pkill -9 lxqt-session"
            ;;
        3)
            EXEC_CMD="exec mate-session"
            KILL_CMD="pkill -9 mate-session; pkill -9 plank"
            ;;
        4)
            # KDE: restart plasmashell after a short delay (common workaround for first launch)
            EXEC_CMD="(sleep 5 && pkill -9 plasmashell && plasmashell) >/dev/null 2>&1 &\nexec startplasma-x11"
            KILL_CMD="pkill -9 startplasma-x11; pkill -9 kwin_x11"
            ;;
    esac

    # ---- start-linux.sh ----
    cat > ~/start-linux.sh << LAUNCHEREOF
#!/${TERMUX_PREFIX}/bin/bash
echo ""
echo "[*] Starting ${DE_NAME} on Termux-X11..."
echo ""

# Load GPU environment
source ~/.config/linux-gpu.sh 2>/dev/null

# Clean up any leftover sessions
echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null || true
${KILL_CMD} 2>/dev/null || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
sleep 0.5

# Start audio
echo "[*] Starting PulseAudio..."
unset PULSE_SERVER
pulseaudio --kill 2>/dev/null || true
sleep 0.3
pulseaudio --start --exit-idle-time=-1
sleep 1
pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
export PULSE_SERVER=127.0.0.1

# Start X11 server
echo "[*] Starting Termux-X11 display server..."
termux-x11 :0 -ac &
sleep 3
export DISPLAY=:0

echo ""
echo "─────────────────────────────────────────────────"
echo "  ✔ Desktop launching! Open the Termux-X11 app."
echo "─────────────────────────────────────────────────"
echo ""

${EXEC_CMD}
LAUNCHEREOF
    chmod +x ~/start-linux.sh
    echo -e "  ${GREEN}✔ Created ~/start-linux.sh${NC}"

    # ---- stop-linux.sh ----
    cat > ~/stop-linux.sh << STOPEOF
#!/${TERMUX_PREFIX}/bin/bash
echo "[*] Stopping ${DE_NAME}..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "pulseaudio"  2>/dev/null || true
${KILL_CMD} 2>/dev/null || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
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

    # Terminal shortcut — icon and command match the installed DE
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

    # Wine shortcut only if installed
    if [ "$INSTALL_WINE" == "yes" ]; then
        cat > ~/Desktop/Wine_Config.desktop << 'EOF'
[Desktop Entry]
Name=Wine Config
Exec=wine winecfg
Icon=wine
Type=Application
Categories=Utility;
EOF
        echo -e "  ${GREEN}✔ Added Wine Config shortcut.${NC}"
    fi

    chmod +x ~/Desktop/*.desktop 2>/dev/null || true
    echo -e "  ${GREEN}✔ Desktop shortcuts created.${NC}"
}

# ============== COMPLETION SUMMARY ==============
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
    echo -e "  ${WHITE}Desktop installed: ${GREEN}${DE_NAME}${NC}"
    echo -e "  ${WHITE}GPU acceleration:  ${GREEN}${GPU_DRIVER}${NC}"
    echo -e "  ${WHITE}Wine support:      ${GREEN}${INSTALL_WINE}${NC}"
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}▶  TO START:${NC}  ${GREEN}bash ~/start-linux.sh${NC}"
    echo -e "  ${WHITE}■  TO STOP: ${NC}  ${GREEN}bash ~/stop-linux.sh${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${GRAY}Full install log: $LOG_FILE${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    # Initialize log
    echo "" > "$LOG_FILE"
    log "termux-linux-setup.sh started"

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

    if [ "$INSTALL_WINE" == "yes" ]; then
        step_wine
    fi

    step_launchers
    step_shortcuts

    show_completion
}

main

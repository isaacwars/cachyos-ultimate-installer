#!/bin/bash
# ==============================================================================
# CACHYOS ULTIMATE INSTALLER (ENTERPRISE TRANSACTIONAL EDITION)
# Arch Linux Post-Install Script
# Architecture: Intel Core Ultra (Arrow Lake) + NVIDIA Blackwell (RTX 50-series)
# Features: Traps (Anti-Corruption), Self-Healing, Early KMS, Secure Boot
# ==============================================================================

# Abort on unhandled errors, undefined variables, or pipeline failures
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Helpers ---
print_info() { echo -e "${CYAN}[ℹ] $1${NC}"; }
print_success() { echo -e "${GREEN}[✔] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[⚠] $1${NC}"; }
print_error() { echo -e "${RED}[✖] $1${NC}"; }
die() { print_error "$1"; exit 1; }

# ==============================================================================
# TRANSACTIONAL PROTOCOL (ANTI-CORRUPTION SHIELD)
# ==============================================================================
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${RED}========================================================================${NC}"
        echo -e "${YELLOW}INSTALLATION INTERRUPTED OR FAILED (Exit code: $exit_code)${NC}"
        echo -e "${CYAN}Running emergency cleanup protocol to prevent corruption...${NC}"
        
        if [ -f /var/lib/pacman/db.lck ]; then
            rm -f /var/lib/pacman/db.lck
            echo -e "${GREEN}[✔] Pacman database lock released.${NC}"
        fi
        
        if ls /tmp/cachyos-repo* >/dev/null 2>&1; then
            rm -rf /tmp/cachyos-repo*
            echo -e "${GREEN}[✔] Temporary download files purged.${NC}"
        fi
        
        echo -e "${YELLOW}System state neutralized. No orphaned or corrupted packages.${NC}"
        echo -e "${YELLOW}You can safely re-run the script.${NC}"
        echo -e "${RED}========================================================================${NC}"
    fi
    exit "$exit_code"
}

# Capture any interruption signal (Ctrl+C, process kill, command error)
trap cleanup EXIT INT TERM ERR

# ==============================================================================
# INITIAL VALIDATIONS
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    die "This script must be run as root (with sudo)."
fi

REAL_USER=${SUDO_USER:-$(whoami)}
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then
    die "Critical Failure: Run this script as a normal user using 'sudo'. paru requires it."
fi
if [[ ! "$REAL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    die "Critical Failure: Invalid username detected (possible injection vector)."
fi

if [ ! -d "/sys/firmware/efi" ]; then
    die "Critical Failure: This script requires a UEFI-installed system."
fi

# Auto-repair network at startup (DNS fallback)
if ! ping -c 1 -W 5 archlinux.org >/dev/null 2>&1; then
    print_warn "DNS resolution issues detected. Applying auto-repair (Fallback to Cloudflare 1.1.1.1)..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    if ! ping -c 1 -W 5 archlinux.org >/dev/null 2>&1; then
        die "Critical Failure: No physical internet connection."
    fi
    print_success "DNS temporarily repaired."
fi

print_success "Initial validations passed."

# ==============================================================================
# SELF-HEALING ALGORITHMS (AUTO-REPAIR)
# ==============================================================================
run_pacman() {
    local attempt=1
    local max_retries=3

    while [ $attempt -le $max_retries ]; do
        if pacman "$@" --noconfirm; then
            return 0
        fi

        print_warn "Pacman failed (Attempt $attempt/$max_retries). Starting auto-repair protocol..."

        if [ -f /var/lib/pacman/db.lck ]; then
            print_info "Healing [1/3]: Destroying /var/lib/pacman/db.lck..."
            rm -f /var/lib/pacman/db.lck
        fi

        if [ $attempt -eq 2 ]; then
            print_info "Healing [2/3]: Regenerating Arch/CachyOS cryptographic keys..."
            pacman-key --init >/dev/null 2>&1 || true
            pacman-key --populate archlinux cachyos >/dev/null 2>&1 || pacman-key --populate archlinux >/dev/null 2>&1 || true
            pacman -Sy archlinux-keyring cachyos-keyring --noconfirm || true
        fi

        if [ $attempt -eq 3 ]; then
            print_info "Healing [3/3]: Updating mirror list..."
            if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
                cachyos-rate-mirrors >/dev/null 2>&1 || true
            elif command -v reflector >/dev/null 2>&1; then
                reflector --latest 5 --sort rate --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 || true
            fi
            pacman -Syy --noconfirm || true
        fi

        ((attempt++))
        sleep 2
    done

    die "Critical Failure: Pacman could not recover after 3 auto-repair attempts. Command: pacman $*"
}

run_paru() {
    if sudo -u "$REAL_USER" paru "$@" --noconfirm; then
        return 0
    fi
    
    print_warn "AUR/Paru failed. Starting dependency & cache auto-repair..."
    run_pacman -S --needed base-devel git
    sudo -u "$REAL_USER" bash -c "paru -Sc --noconfirm" || true
    
    print_info "Retrying build..."
    if ! sudo -u "$REAL_USER" paru "$@" --noconfirm; then
        die "Critical Failure: AUR irreversibly failed after auto-repair. Command: paru $*"
    fi
}

# ==============================================================================
# PHASE 1: Foundations and Cachyfication
# ==============================================================================
print_info "Phase 1: Proactive preparation and CachyOS Repositories..."

# Compiler audit (Amputation Prevention)
run_pacman -S --needed base-devel git curl wget

cd /tmp
rm -rf /tmp/cachyos-repo* 2>/dev/null || true

# Repository download auto-repair
if ! curl --connect-timeout 10 --max-time 120 -sOf https://mirror.cachyos.org/cachyos-repo.tar.xz; then
    print_warn "Primary download failed. Retrying from GitHub RAW (Fallback)..."
    if ! curl --connect-timeout 10 --max-time 120 -sOfL https://raw.githubusercontent.com/CachyOS/CachyOS-Repo/master/cachyos-repo.tar.xz; then
        die "Critical Failure: Could not download repository from any source."
    fi
fi

if ! tar xvf cachyos-repo.tar.xz >/dev/null 2>&1; then
    die "Critical Failure: Corrupted cachyos-repo.tar.xz archive."
fi

cd cachyos-repo
chmod +x ./cachyos-repo.sh || true
./cachyos-repo.sh || die "Critical Failure: The official CachyOS script failed."
print_success "Repositories injected."

print_info "Synchronizing global pacman database (Self-Healing active)..."
run_pacman -Syu

# ==============================================================================
# PHASE 1.5: Early Cryptographic Architecture (Secure Boot)
# ==============================================================================
print_info "Phase 1.5: Setting up Secure Boot infrastructure..."

echo -e "\n${CYAN}========================================================================${NC}"
echo -e "${YELLOW}SECURE BOOT CONFIGURATION (INTERACTIVE)${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo -e "To enroll keys on the motherboard, your BIOS MUST be in 'Setup Mode'."
echo -e "If you enable this, NVIDIA drivers will be auto-signed upon compilation."
echo -e ""
if [ -t 0 ]; then
    read -p "Is your BIOS currently in Setup Mode? (y/n): " setup_mode_ans
else
    print_warn "Non-interactive (headless) environment detected. Secure Boot postponed (desktop script)."
    setup_mode_ans="n"
fi

DO_SECURE_BOOT=false
if [[ "$setup_mode_ans" =~ ^[Yy]$ ]]; then
    DO_SECURE_BOOT=true
    run_pacman -S --needed sbctl
    
    print_info "Generating Secure Boot master keys..."
    sbctl create-keys || die "Critical Failure: sbctl could not generate keys."
    
    print_info "Setting up auto-signing link for DKMS (NVIDIA)..."
    mkdir -p /etc/dkms/framework.conf.d/
    cat > /etc/dkms/framework.conf.d/sbctl-signing.conf <<EOF
mok_signing_key="/var/lib/sbctl/keys/db/db.key"
mok_certificate="/var/lib/sbctl/keys/db/db.pem"
EOF
    print_success "Cryptographic infrastructure injected. NVIDIA will auto-sign."
else
    print_warn "Key generation skipped. A desktop script will be left for later setup."
fi

# ==============================================================================
# PHASE 2: Hard Core and Base Hardware (Intel Arrow Lake)
# ==============================================================================
print_info "Phase 2: Installing Kernel, Microcode and Full Intel Core Ultra Support..."
run_pacman -S --needed \
    linux-cachyos linux-cachyos-headers cachyos-settings \
    intel-ucode thermald mesa vulkan-intel intel-media-driver level-zero-loader \
    scx-scheds

print_info "Enabling thermal service (thermald)..."
systemctl enable thermald || die "Critical Failure: Could not enable thermald."

print_info "Configuring Sched-Ext (SCX_LAVD)..."
mkdir -p /etc/default
if grep -q "^SCX_SCHEDULER=" /etc/default/scx 2>/dev/null; then
    sed -i 's/^SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx
else
    echo "SCX_SCHEDULER=scx_lavd" >> /etc/default/scx
fi

if [ ! -x "/usr/bin/scx_lavd" ]; then
    die "Critical Failure: scx_lavd binary does not exist. Pacman skipped its installation."
fi
systemctl enable scx.service || die "Critical Failure: Could not enable scx.service."
print_success "Intel base hardware configured and hardened."

# ==============================================================================
# PHASE 3: NVIDIA Blackwell and Bootloader
# ==============================================================================
print_info "Phase 3: Installing NVIDIA Open DKMS drivers (Blackwell)..."
run_pacman -S --needed \
    nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils

print_info "Injecting nvidia-drm.modeset=1 into the bootloader..."

inject_bootloader() {
    local injected=false
    
    if ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
        for conf in /boot/loader/entries/*.conf; do
            if ! grep -q "nvidia-drm.modeset=1" "$conf"; then
                sed -i 's/^options .*/& nvidia-drm.modeset=1/' "$conf"
            fi
        done
        print_success "Parameters injected into systemd-boot entries."
        injected=true
    fi

    if [ -f "/etc/default/grub" ]; then
        if ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak.$(date +%s) || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || die "Critical Failure: Could not rebuild GRUB."
            print_success "Parameters injected into GRUB."
        fi
        injected=true
    fi

    if [ -d "/etc/kernel" ]; then
        if [ -f "/etc/kernel/cmdline" ]; then
            if ! grep -q "nvidia-drm.modeset=1" /etc/kernel/cmdline; then
                sed -i 's/$/ nvidia-drm.modeset=1/' /etc/kernel/cmdline
            fi
        else
            echo "nvidia-drm.modeset=1" > /etc/kernel/cmdline
        fi
        print_success "Parameters added to global /etc/kernel/cmdline."
        injected=true
    fi

    if [ "$injected" = true ]; then
        return 0
    fi
    return 1
}

if ! inject_bootloader; then
    print_warn "No boot entries detected. Starting Auto-Repair..."
    run_pacman -S linux-cachyos
    if ! inject_bootloader; then
        die "Irreversible Critical Failure: Ghost bootloader. NVIDIA Blackwell will fail on Wayland."
    fi
fi

# ==============================================================================
# PHASE 3.5: Early Boot & Initramfs Synchronization
# ==============================================================================
print_info "Phase 3.5: Setting up Early KMS and Microcode (Low-Level Boot)..."

configure_mkinitcpio() {
    local mk_conf="/etc/mkinitcpio.conf"
    if [ ! -f "$mk_conf" ]; then
        print_warn "File $mk_conf not found. Skipping Early KMS configuration."
        return 0
    fi

    if ! grep -q "nvidia_drm" "$mk_conf"; then
        cp "$mk_conf" "${mk_conf}.bak.$(date +%s)" || true
        sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' "$mk_conf" || true
        sed -i 's/^MODULES="/MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm /' "$mk_conf" || true
        print_success "NVIDIA modules (Early KMS) injected into $mk_conf."
    fi

    if ! grep -E -q "HOOKS=.*microcode" "$mk_conf"; then
        cp "$mk_conf" "${mk_conf}.bak.$(date +%s)" || true
        sed -i 's/\(HOOKS=(.*autodetect\)/\1 microcode/' "$mk_conf" || true
        sed -i 's/\(HOOKS=".*autodetect\)/\1 microcode/' "$mk_conf" || true
        print_success "Microcode hook injected into $mk_conf."
    fi

    print_info "Synchronizing and rebuilding initial Ramdisk..."
    if ! mkinitcpio -P >/dev/null 2>&1; then
        die "Critical Failure: mkinitcpio could not regenerate boot images. System may not boot."
    fi
    print_success "Initramfs rebuilt and synchronized successfully."
}

configure_mkinitcpio

# ==============================================================================
# PHASE 4: AUR and Intel NPU
# ==============================================================================
print_info "Phase 4: Setting up AUR and compiling Neural Processing Unit (NPU)..."
run_pacman -S --needed paru rebuild-detector fwupd

print_info "Downloading and installing NPU firmware from AUR..."
run_paru -S --needed intel-npu-driver-bin
print_success "Intel NPU successfully installed."

# ==============================================================================
# PHASE 5: Custom Maintenance Routines
# ==============================================================================
print_info "Phase 5: Injecting robust update() and cleanpc() routines..."

read -r -d '' ROUTINES_CODE << 'ROUTINES_EOF' || true

# ==========================================
# CACHYOS MAINTENANCE ROUTINES
# ==========================================
cleanpc() {
    local red='\033[0;31m' green='\033[0;32m' yellow='\033[1;33m' cyan='\033[0;36m' nc='\033[0m'
    local orphans inconsistencies

    echo -e "${cyan}╔══════════════════════════════╗"
    echo -e "║       🧹  CleanPc  🧹       ║"
    echo -e "╚══════════════════════════════╝${nc}"

    echo -e "\n${yellow}[>] Removing orphaned packages...${nc}"
    orphans=$(pacman -Qdtq 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        echo "$orphans"
        echo "$orphans" | xargs -r sudo pacman -Rns --noconfirm 2>/dev/null && echo -e "${green}Done.${nc}" || echo -e "${red}Some failed.${nc}"
    else
        echo -e "${green}No orphans found.${nc}"
    fi

    echo -e "\n${yellow}[>] Cleaning pacman cache...${nc}"
    if command -v paccache &>/dev/null; then
        sudo paccache -rk2
        sudo paccache -ruk0
    else
        sudo pacman -Sc --noconfirm 2>/dev/null && echo -e "${green}Done.${nc}"
    fi

    if command -v yay &>/dev/null; then
        echo -e "\n${yellow}[>] Cleaning yay cache (AUR build artifacts)...${nc}"
        yay -Sc --aur --noconfirm
    elif command -v paru &>/dev/null; then
        echo -e "\n${yellow}[>] Cleaning paru cache...${nc}"
        paru -Sc --noconfirm
    fi

    echo -e "\n${yellow}[>] Cleaning journal logs (7 days)...${nc}"
    sudo journalctl --vacuum-time=7d 2>/dev/null && echo -e "${green}Done.${nc}"

    echo -e "\n${yellow}[>] Cleaning /tmp safely...${nc}"
    if command -v systemd-tmpfiles &>/dev/null; then
        sudo systemd-tmpfiles --clean 2>/dev/null && echo -e "${green}Done.${nc}"
    fi

    echo -e "\n${yellow}[>] Cleaning user cache...${nc}"
    find ~/.cache -not -path '*/.git*' -not -path '*/yay*' -not -path '*/paru*' -type f -atime +30 -delete 2>/dev/null || true
    find ~/.cache -not -path '*/.git*' -not -path '*/yay*' -not -path '*/paru*' -type d -empty -delete 2>/dev/null || true
    echo -e "${green}Done.${nc}"

    echo -e "\n${yellow}[>] Cleaning core dumps...${nc}"
    sudo find /var/lib/systemd/coredump -type f -delete 2>/dev/null || true
    echo -e "${green}Done.${nc}"

    if command -v flatpak &>/dev/null; then
        echo -e "\n${yellow}[>] Cleaning flatpak...${nc}"
        flatpak uninstall --unused -y 2>/dev/null
    fi

    echo -e "\n${yellow}[>] Checking for system package inconsistencies...${nc}"
    inconsistencies=$(LC_ALL=C pacman -Qk 2>/dev/null | grep -v '0 missing files')
    if [ -n "$inconsistencies" ]; then
        echo -e "${red}Inconsistencies detected in installed packages:${nc}"
        echo "$inconsistencies"
    else
        echo -e "${green}No package inconsistencies found (all files present).${nc}"
    fi

    echo -e "\n${yellow}[>] Running fstrim...${nc}"
    sudo fstrim -av 2>/dev/null || echo -e "${yellow}Not supported.${nc}"

    echo -e "\n${cyan}─────────────────────────────────${nc}"
    echo -e "${green}✅  System cleaned!${nc}\n"
}

update() {
    local red='\033[0;31m' green='\033[0;32m' yellow='\033[1;33m' cyan='\033[0;36m' nc='\033[0m'
    local has_warnings=0

    # 1. Prevent running as root directly (breaks AUR helpers)
    if [ "$EUID" -eq 0 ]; then
        echo -e "${red}❌ Error: Do not run this function as root/sudo. Run it as a normal user.${nc}"
        return 1
    fi

    echo -e "${cyan}╔══════════════════════════════╗"
    echo -e "║    🔄  System Update  🔄     ║"
    echo -e "╚══════════════════════════════╝${nc}"

    # 2. Check network connectivity (with multi-IP fallback)
    echo -e "\n${yellow}[>] Checking network connectivity...${nc}"
    if ! ping -c 2 -W 2 1.1.1.1 &>/dev/null && ! ping -c 2 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "${red}❌ No internet connection detected. Aborting.${nc}"
        return 1
    fi

    # 3. Check and remove stale pacman lock safely (sudo fuser to inspect root processes)
    if [ -f /var/lib/pacman/db.lck ]; then
        echo -e "\n${yellow}[>] Checking pacman database lock...${nc}"
        if command -v fuser &>/dev/null; then
            if sudo fuser /var/lib/pacman/db.lck &>/dev/null; then
                echo -e "${red}❌ Error: Pacman database is actively locked by another process. Aborting.${nc}"
                return 1
            else
                echo -e "${yellow}Removing stale pacman database lock...${nc}"
                sudo rm -f /var/lib/pacman/db.lck
            fi
        elif pgrep -x pacman &>/dev/null || pgrep -x yay &>/dev/null || pgrep -x paru &>/dev/null; then
            echo -e "${red}❌ Error: Pacman/AUR process is currently running. Aborting.${nc}"
            return 1
        else
            echo -e "${yellow}Removing stale pacman database lock...${nc}"
            sudo rm -f /var/lib/pacman/db.lck
        fi
    fi

    # 4. Rank/rate CachyOS and Arch mirrors FIRST if cachyos-rate-mirrors is available
    if command -v cachyos-rate-mirrors &>/dev/null; then
        echo -e "\n${yellow}[>] Ranking CachyOS mirrors...${nc}"
        sudo cachyos-rate-mirrors
    fi

    # 5. Core system update (Keyrings + Packages)
    echo -e "\n${yellow}[>] Updating system packages...${nc}"
    sudo pacman -Syu --noconfirm || {
        echo -e "${red}❌ Pacman update failed.${nc}"
        return 1
    }

    # 6. Update AUR packages via helper (yay or paru) with failure tracking
    if command -v yay &>/dev/null; then
        echo -e "\n${yellow}[>] Updating AUR (yay)...${nc}"
        if ! yay -Sua --noconfirm; then
            echo -e "${yellow}⚠ Warning: Some AUR packages failed to update.${nc}"
            has_warnings=1
        fi
    elif command -v paru &>/dev/null; then
        echo -e "\n${yellow}[>] Updating AUR (paru)...${nc}"
        if ! paru -Sua --noconfirm; then
            echo -e "${yellow}⚠ Warning: Some AUR packages failed to update.${nc}"
            has_warnings=1
        fi
    fi

    # 7. Check for packages that need rebuilding (rebuild-detector)
    if command -v checkrebuild &>/dev/null; then
        echo -e "\n${yellow}[>] Checking for AUR packages that need rebuilding...${nc}"
        local rebuilds
        rebuilds=$(checkrebuild 2>/dev/null || true)
        if [ -n "$rebuilds" ]; then
            echo -e "${yellow}⚠ Warning: Packages needing rebuild:${nc}"
            echo "$rebuilds"
            has_warnings=1
        else
            echo -e "${green}No packages need rebuilding.${nc}"
        fi
    fi

    # 8. Update bootloader and sign EFI binaries with sbctl (without silencing errors)
    if command -v bootctl &>/dev/null && bootctl status 2>/dev/null | grep -q "Product:.*systemd-boot"; then
        echo -e "\n${yellow}[>] Updating systemd-boot bootloader...${nc}"
        if sudo bootctl --graceful update; then
            if command -v sbctl &>/dev/null; then
                echo -e "${yellow}[>] Verifying and signing EFI binaries with sbctl...${nc}"
                if ! sudo sbctl sign-all; then
                    echo -e "${red}❌ CRITICAL: Secure Boot signing failed! System may not boot with Secure Boot enabled.${nc}"
                    has_warnings=1
                fi
            fi
        else
            echo -e "${yellow}⚠ Warning: bootctl update had issues.${nc}"
            has_warnings=1
        fi
    fi

    # 9. Firmware updates via fwupd
    if command -v fwupdmgr &>/dev/null; then
        echo -e "\n${yellow}[>] Checking for hardware firmware updates...${nc}"
        fwupdmgr refresh && fwupdmgr get-updates || true
    fi

    # 10. Update flatpak packages
    if command -v flatpak &>/dev/null; then
        echo -e "\n${yellow}[>] Updating flatpak...${nc}"
        flatpak update -y || has_warnings=1
    fi

    # 11. Update global npm packages (check write access)
    if command -v npm &>/dev/null; then
        local npm_prefix
        npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr')"
        if [ -w "$npm_prefix" ] || [ -w "$npm_prefix/lib/node_modules" 2>/dev/null ]; then
            echo -e "\n${yellow}[>] Checking for global npm package updates...${nc}"
            npm update -g || has_warnings=1
        else
            echo -e "\n${yellow}[i] Skipping npm update -g: user lacks write access to $npm_prefix.${nc}"
        fi
    fi

    # 12. Checking for unmerged .pacnew/.pacsave files (using pacdiff -o when available)
    echo -e "\n${yellow}[>] Checking for unmerged .pacnew/.pacsave files...${nc}"
    local pacnews=""
    if command -v pacdiff &>/dev/null; then
        pacnews=$(pacdiff -o 2>/dev/null)
    else
        pacnews=$(sudo find /etc -regextype posix-extended -regex ".+\.pac(new|save)" 2>/dev/null)
    fi

    if [ -n "$pacnews" ]; then
        echo -e "${yellow}⚠ Warning: Unmerged configuration files found:${nc}"
        echo "$pacnews"
        echo -e "${yellow}ℹ Tip: Run 'pacdiff' or 'meld' to merge them.${nc}"
        has_warnings=1
    else
        echo -e "${green}No .pacnew/.pacsave files found.${nc}"
    fi

    # 13. Check for failed systemd services
    echo -e "\n${yellow}[>] Checking for failed systemd services...${nc}"
    local failed_units
    failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null)
    if [ -n "$failed_units" ]; then
        echo "$failed_units"
        has_warnings=1
    else
        echo -e "${green}No failed systemd services.${nc}"
    fi

    # 14. Check if reboot is recommended (kernel upgrade check)
    echo -e "\n${yellow}[>] Checking kernel status...${nc}"
    local running
    running=$(uname -r)
    if [ ! -d "/lib/modules/$running" ] || [ ! -f "/lib/modules/$running/modules.dep" ]; then
        local installed
        installed=$(ls /lib/modules/ 2>/dev/null | sort -V | tail -1)
        echo -e "${yellow}⚠ Kernel updated (Running: $running | Installed: $installed)${nc}"
        echo -e "${yellow}⚠ REBOOT RECOMMENDED: sudo reboot${nc}"
    else
        echo -e "${green}Kernel is up to date (Running: $running).${nc}"
    fi

    echo -e "\n${cyan}─────────────────────────────────${nc}"
    if [ "$has_warnings" -eq 0 ]; then
        echo -e "${green}✅  System updated!${nc}\n"
    else
        echo -e "${yellow}⚠  System update completed with warnings. Check output above.${nc}\n"
    fi
}
ROUTINES_EOF

inject_routines() {
    local target="$1"
    if [ -d "$(dirname "$target")" ]; then
        touch "$target"
        if ! grep -q "CACHYOS MAINTENANCE ROUTINES" "$target" && ! grep -q "^cleanpc()" "$target"; then
            printf '\n%s\n' "$ROUTINES_CODE" >> "$target"
        fi
    fi
}

inject_routines "/etc/skel/.bashrc"
inject_routines "/etc/skel/.zshrc"
inject_routines "/home/$REAL_USER/.bashrc"
inject_routines "/home/$REAL_USER/.zshrc"

print_success "Routines injected."

# ==============================================================================
# PHASE 6: Final Enrollment (Secure Boot)
# ==============================================================================
print_info "Phase 6: Final Enrollment and Sealing..."

if [ "$DO_SECURE_BOOT" = true ]; then
    KERNEL_EFI=$(find /boot -maxdepth 3 -name "vmlinuz-linux-cachyos" | head -n 1)
    if [ -z "$KERNEL_EFI" ]; then
        die "Critical Failure: Kernel vmlinuz-linux-cachyos not found in /boot. Aborting signing."
    fi

    SYSTEMD_EFI=$(find /boot/EFI -maxdepth 3 -name "systemd-bootx64.efi" 2>/dev/null | head -n 1 || echo "")
    GRUB_EFI=$(find /boot/EFI -maxdepth 3 -iname "grubx64.efi" 2>/dev/null | head -n 1 || echo "")
    BOOT_EFI=$(find /boot/EFI -maxdepth 3 -name "BOOTX64.EFI" 2>/dev/null | head -n 1 || echo "")

    print_info "Signing boot binaries..."
    sbctl sign -s "$KERNEL_EFI" || die "Critical Failure: Failed to sign Kernel."
    [ -n "$SYSTEMD_EFI" ] && { sbctl sign -s "$SYSTEMD_EFI" || die "Failed to sign systemd-boot."; }
    [ -n "$GRUB_EFI" ] && { sbctl sign -s "$GRUB_EFI" || die "Failed to sign GRUB."; }
    [ -n "$BOOT_EFI" ] && { sbctl sign -s "$BOOT_EFI" || die "Failed to sign BOOTX64.EFI."; }
    
    print_info "Enrolling keys on motherboard (ASUS)..."
    sbctl enroll-keys --microsoft || die "Critical Failure: Motherboard rejected the keys. Are you sure you were in Setup Mode?"
    
    print_success "Secure Boot successfully configured and enrolled!"
else
    mkdir -p "/home/$REAL_USER/Desktop"
    cat > "/home/$REAL_USER/Desktop/terminar-secureboot.sh" <<'HEREDOC'
#!/bin/bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then echo "Run with sudo."; exit 1; fi
echo "Finishing Secure Boot setup..."
pacman -S --needed sbctl --noconfirm
sbctl create-keys || { echo "Failed to create keys."; exit 1; }

mkdir -p /etc/dkms/framework.conf.d/
cat > /etc/dkms/framework.conf.d/sbctl-signing.conf <<'INNEREOF'
mok_signing_key="/var/lib/sbctl/keys/db/db.key"
mok_certificate="/var/lib/sbctl/keys/db/db.pem"
INNEREOF

KERNEL_EFI=$(find /boot -maxdepth 3 -name "vmlinuz-linux-cachyos" | head -n 1)
SYSTEMD_EFI=$(find /boot/EFI -maxdepth 3 -name "systemd-bootx64.efi" 2>/dev/null | head -n 1 || echo "")
GRUB_EFI=$(find /boot/EFI -maxdepth 3 -iname "grubx64.efi" 2>/dev/null | head -n 1 || echo "")
BOOT_EFI=$(find /boot/EFI -maxdepth 3 -name "BOOTX64.EFI" 2>/dev/null | head -n 1 || echo "")

sbctl sign -s "$KERNEL_EFI" || { echo "Failed to sign Kernel."; exit 1; }
[ -n "$SYSTEMD_EFI" ] && sbctl sign -s "$SYSTEMD_EFI"
[ -n "$GRUB_EFI" ] && sbctl sign -s "$GRUB_EFI"
[ -n "$BOOT_EFI" ] && sbctl sign -s "$BOOT_EFI"

sbctl enroll-keys --microsoft || { echo "Enrollment failed. Restart BIOS in Setup Mode."; exit 1; }

echo "Forcing NVIDIA recompilation to inject new signatures..."
dkms remove -m nvidia --all >/dev/null 2>&1 || true
dkms remove -m nvidia-open --all >/dev/null 2>&1 || true
dkms autoinstall || { echo "DKMS recompilation failed."; exit 1; }

echo "Secure Boot configured and hardened!"
HEREDOC
    chmod +x "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    chown "$REAL_USER:$REAL_USER" "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    
    echo -e "1. Restart your PC and enter the BIOS."
    echo -e "2. Clear Secure Boot keys (Set BIOS to Setup Mode)."
    echo -e "3. Log into Arch and run the ${YELLOW}'terminar-secureboot.sh'${NC} script on your Desktop."
fi

# Disable the error trap if everything went well
trap - EXIT INT TERM ERR

print_success "MASTER INSTALLATION COMPLETED. Reboot your PC."

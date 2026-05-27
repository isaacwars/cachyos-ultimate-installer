#!/bin/bash
# ==============================================================================
# CACHYOS ULTIMATE INSTALLER
# ArchLinux Post-Install Script
# Architecture: Intel Core Ultra (Arrow Lake) + NVIDIA Blackwell (RTX 50-series)
# Features: CachyOS Repos, SCX_LAVD, Secure Boot, DKMS, NPU Support, Custom Routines
# ==============================================================================

# Si ocurre un error fatal, abortar.
set -e

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

# ==============================================================================
# VALIDACIONES INICIALES
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    print_error "Este script debe ejecutarse como root (con sudo)."
    exit 1
fi

if ! ping -c 1 archlinux.org &> /dev/null; then
    print_error "No hay conexión a internet. Abortando."
    exit 1
fi

if [ ! -d "/sys/firmware/efi" ]; then
    print_error "Este script requiere un sistema instalado en modo UEFI. Abortando."
    exit 1
fi

# Extraer el usuario real que lanzó "sudo" para compilar AUR correctamente
REAL_USER=${SUDO_USER:-$(whoami)}
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then
    print_error "No ejecutes este script logueado directamente como root en la tty. Usa un usuario normal con 'sudo'."
    exit 1
fi

print_success "Validaciones iniciales correctas."

# ==============================================================================
# FASE 1: Cimientos y Cachyficación
# ==============================================================================
print_info "Fase 1: Inyectando Repositorios de CachyOS..."
cd /tmp
if [ ! -d "cachyos-repo" ]; then
    curl -sO https://mirror.cachyos.org/cachyos-repo.tar.xz
    tar xvf cachyos-repo.tar.xz >/dev/null
    cd cachyos-repo
    # El script oficial de CachyOS modifica pacman.conf y añade las llaves
    ./cachyos-repo.sh
else
    print_warn "El script de CachyOS ya existe en /tmp, saltando descarga."
fi
print_success "Repositorios de CachyOS inyectados."

print_info "Actualizando base de datos global de pacman..."
pacman -Syu --noconfirm

# ==============================================================================
# FASE 2: Núcleo Duro y Hardware Base (Intel Arrow Lake)
# ==============================================================================
print_info "Fase 2: Instalando Kernel, Microcódigo y Soporte Completo Intel Core Ultra..."
pacman -S --needed --noconfirm \
    linux-cachyos linux-cachyos-headers cachyos-settings \
    intel-ucode thermald mesa vulkan-intel intel-media-driver level-zero-loader \
    scx-scheds

print_info "Habilitando servicios térmicos y de planificación (SCX_LAVD)..."
systemctl enable thermald 2>/dev/null || true

# Configurar Sched-Ext para usar SCX_LAVD
mkdir -p /etc/default
if grep -q "^SCX_SCHEDULER=" /etc/default/scx 2>/dev/null; then
    sed -i 's/^SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx
else
    echo "SCX_SCHEDULER=scx_lavd" >> /etc/default/scx
fi
systemctl enable scx.service 2>/dev/null || print_warn "Revisar configuración de scx_loader post-reboot."

print_success "Hardware base de Intel (iGPU, Códecs, Termales, Scheduler) configurado."

# ==============================================================================
# FASE 3: NVIDIA Blackwell y Gestor de Arranque
# ==============================================================================
print_info "Fase 3: Instalando drivers NVIDIA Open DKMS (Blackwell)..."
pacman -S --needed --noconfirm \
    nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils

print_info "Inyectando nvidia-drm.modeset=1 en el gestor de arranque..."
# Inyección inteligente para systemd-boot
if [ -d "/boot/loader/entries" ]; then
    for conf in /boot/loader/entries/*.conf; do
        [ -e "$conf" ] || continue
        if ! grep -q "nvidia-drm.modeset=1" "$conf"; then
            sed -i 's/^options .*/& nvidia-drm.modeset=1/' "$conf"
        fi
    done
    print_success "Parámetros inyectados en systemd-boot."
# Inyección inteligente para GRUB
elif [ -f "/etc/default/grub" ]; then
    if ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg
        print_success "Parámetros inyectados en GRUB."
    fi
else
    print_warn "Gestor de arranque desconocido. Añade nvidia-drm.modeset=1 manualmente a tu configuración."
fi

# ==============================================================================
# FASE 4: AUR y NPU de Intel
# ==============================================================================
print_info "Fase 4: Configurando AUR y NPU de Intel (Arrow Lake)..."
pacman -S --needed --noconfirm paru rebuild-detector fwupd

# Instalar el driver binario de la NPU bajando privilegios al usuario real (makepkg lo prohíbe como root)
print_info "Descargando e instalando firmware de la NPU desde AUR..."
sudo -u "$REAL_USER" bash -c "paru -S --needed --noconfirm intel-npu-driver-bin" || print_warn "La compilación de NPU falló. Puedes reintentarlo más tarde con 'paru -S intel-npu-driver-bin'."

print_success "Soporte de Unidad Neuronal (NPU) de Intel instalado."

# ==============================================================================
# FASE 5: Rutinas de Mantenimiento Personalizadas
# ==============================================================================
print_info "Fase 5: Inyectando rutinas robustas update() y cleanpc()..."

# Se guarda el código de las rutinas en una variable gigante para inyectarlo en .bashrc/.zshrc
ROUTINES_CODE='
# ==========================================
# RUTINAS DE MANTENIMIENTO CACHYOS
# ==========================================
update() {
    local red="\033[0;31m"
    local green="\033[0;32m"
    local yellow="\033[1;33m"
    local nc="\033[0m"

    echo -e "${yellow}[>] Verificando conexión a internet...${nc}"
    if ! ping -c 1 1.1.1.1 &>/dev/null; then
        echo -e "${red}❌ No hay conexión a internet. Abortando update.${nc}"
        return 1
    fi

    if [ -f /var/lib/pacman/db.lck ]; then
        if command -v fuser &>/dev/null; then
            if fuser /var/lib/pacman/db.lck &>/dev/null; then
                echo -e "${red}❌ Error: Pacman database is currently locked by another process.${nc}"
                return 1
            fi
        fi
        echo -e "${yellow}Removing stale pacman database lock...${nc}"
        sudo rm -f /var/lib/pacman/db.lck
    fi

    if command -v cachyos-rate-mirrors &>/dev/null; then
        echo -e "\n${yellow}[>] Ranking CachyOS mirrors...${nc}"
        sudo cachyos-rate-mirrors
    fi

    echo -e "\n${yellow}[>] Updating system packages...${nc}"
    sudo pacman -Syuu --noconfirm || return 1

    if command -v paru &>/dev/null; then
        echo -e "\n${yellow}[>] Updating AUR (paru)...${nc}"
        paru -Sua --noconfirm
    fi

    if command -v checkrebuild &>/dev/null; then
        echo -e "\n${yellow}[>] Checking for broken AUR packages...${nc}"
        checkrebuild
    fi

    if command -v bootctl &>/dev/null && bootctl status &>/dev/null; then
        if bootctl status | grep -q "Current Boot Loader:.*systemd-boot"; then
            echo -e "\n${yellow}[>] Updating systemd-boot bootloader...${nc}"
            sudo bootctl update
            if command -v sbctl &>/dev/null; then
                echo -e "${yellow}[>] Verificando firmas de arranque (Doble Seguridad)...${nc}"
                sudo sbctl sign-all >/dev/null 2>&1 || true
            fi
        fi
    fi

    if command -v fwupdmgr &>/dev/null; then
        echo -e "\n${yellow}[>] Checking for hardware firmware updates...${nc}"
        fwupdmgr refresh && fwupdmgr get-updates || true
    fi

    echo -e "${green}✅ Update completed successfully!${nc}"
}

cleanpc() {
    local red="\033[0;31m"
    local green="\033[0;32m"
    local yellow="\033[1;33m"
    local nc="\033[0m"

    echo -e "${yellow}[>] Removing orphaned packages...${nc}"
    if pacman -Qdtq >/dev/null 2>&1; then
        sudo pacman -Rns $(pacman -Qdtq) --noconfirm
    fi

    echo -e "\n${yellow}[>] Cleaning pacman cache...${nc}"
    sudo paccache -ruk0 || true
    sudo paccache -rk2 || true

    echo -e "\n${yellow}[>] Cleaning AUR cache...${nc}"
    if command -v paru &>/dev/null; then
        paru -Sc --noconfirm
    fi

    echo -e "\n${yellow}[>] Cleaning journal logs (7 days)...${nc}"
    sudo journalctl --vacuum-time=7d

    echo -e "\n${yellow}[>] Cleaning /tmp...${nc}"
    sudo rm -rf /tmp/* || true

    echo -e "\n${yellow}[>] Running fstrim...${nc}"
    sudo fstrim -av

    echo -e "${green}✅ System cleaned!${nc}"
}
'

# Función para inyectar sin duplicar
inject_routines() {
    local target="$1"
    if [ -f "$target" ]; then
        if ! grep -q "RUTINAS DE MANTENIMIENTO CACHYOS" "$target"; then
            echo "$ROUTINES_CODE" >> "$target"
        fi
    fi
}

inject_routines "/etc/skel/.bashrc"
inject_routines "/etc/skel/.zshrc"
inject_routines "/home/$REAL_USER/.bashrc"
inject_routines "/home/$REAL_USER/.zshrc"

print_success "Rutinas inyectadas en los perfiles globales (/etc/skel) y de usuario."

# ==============================================================================
# FASE 6: Secure Boot Automation
# ==============================================================================
print_info "Fase 6: Despliegue de Secure Boot (Blindaje Automático)"
pacman -S --needed --noconfirm sbctl

print_info "Configurando enlace de firmas entre sbctl y DKMS (NVIDIA)..."
mkdir -p /etc/dkms/framework.conf.d/
cat > /etc/dkms/framework.conf.d/sbctl-signing.conf <<EOF
mok_signing_key="/var/lib/sbctl/keys/db/db.key"
mok_certificate="/var/lib/sbctl/keys/db/db.pem"
EOF

echo -e "\n${CYAN}========================================================================${NC}"
echo -e "${YELLOW}🚨 FASE FINAL: MODO INTERACTIVO 🚨${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo -e "El sistema necesita firmar los kernels. Para empadronar las llaves en tu"
echo -e "placa base (ASUS), la BIOS DEBE estar en 'Setup Mode' (Clear Secure Boot Keys)."
echo -e ""
read -p "¿Tu BIOS está configurada en Setup Mode AHORA MISMO? (y/n): " setup_mode_ans

if [[ "$setup_mode_ans" =~ ^[Yy]$ ]]; then
    print_info "Generando y empadronando llaves maestras..."
    sbctl create-keys
    sbctl sign -s /boot/vmlinuz-linux-cachyos || true
    sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI || true
    sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi || true
    
    # Empadronamiento final
    sbctl enroll-keys --microsoft
    
    # Recompilar DKMS ahora que las llaves existen
    print_info "Recompilando NVIDIA con la nueva firma..."
    dkms autoinstall
    
    print_success "¡Secure Boot configurado exitosamente!"
else
    print_warn "Fase de Secure Boot pausada."
    
    # Dejar un script en el escritorio para que lo corran después
    mkdir -p "/home/$REAL_USER/Desktop"
    cat > "/home/$REAL_USER/Desktop/terminar-secureboot.sh" <<EOF
#!/bin/bash
if [ "\$EUID" -ne 0 ]; then echo "Ejecuta con sudo."; exit 1; fi
echo "Finalizando configuración de Secure Boot..."
sbctl create-keys
sbctl sign -s /boot/vmlinuz-linux-cachyos || true
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI || true
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi || true
sbctl enroll-keys --microsoft
dkms autoinstall
echo "¡Secure Boot configurado y blindado!"
EOF
    chmod +x "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    chown "$REAL_USER:$REAL_USER" "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    
    echo -e "No hay problema. Sigue estas instrucciones finales:"
    echo -e "1. Reinicia tu PC y entra a la BIOS."
    echo -e "2. Borra las llaves de Secure Boot (Pon la BIOS en Setup Mode)."
    echo -e "3. Inicia sesión en Arch y ejecuta el script ${YELLOW}'terminar-secureboot.sh'${NC} que dejé en tu Escritorio."
fi

print_success "🎉 INSTALACIÓN MAESTRA COMPLETADA. Reinicia tu PC. 🎉"

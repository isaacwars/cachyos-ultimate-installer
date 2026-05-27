#!/bin/bash
# ==============================================================================
# CACHYOS ULTIMATE INSTALLER (HARDENED EDITION)
# ArchLinux Post-Install Script
# Architecture: Intel Core Ultra (Arrow Lake) + NVIDIA Blackwell (RTX 50-series)
# Features: CachyOS Repos, SCX_LAVD, Secure Boot, DKMS, NPU Support, Custom Routines
# ==============================================================================

# Abort on any unhandled error or undefined variable
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
# VALIDACIONES INICIALES
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    die "Este script debe ejecutarse como root (con sudo)."
fi

if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    die "Fallo Crítico: No hay conexión a internet."
fi

if [ ! -d "/sys/firmware/efi" ]; then
    die "Fallo Crítico: Este script requiere un sistema instalado en modo UEFI."
fi

REAL_USER=${SUDO_USER:-$(whoami)}
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then
    die "Fallo Crítico: No ejecutes este script logueado directamente como root. Usa un usuario normal con 'sudo'."
fi

print_success "Validaciones iniciales superadas."

# ==============================================================================
# FASE 1: Cimientos y Cachyficación
# ==============================================================================
print_info "Fase 1: Descargando e inyectando Repositorios de CachyOS..."
cd /tmp
rm -rf /tmp/cachyos-repo* 2>/dev/null || true

# Uso de -f para forzar fallo si el archivo no existe (404)
if ! curl -sOf https://mirror.cachyos.org/cachyos-repo.tar.xz; then
    die "Fallo Crítico: No se pudo descargar el repositorio de CachyOS."
fi

if ! tar xvf cachyos-repo.tar.xz >/dev/null 2>&1; then
    die "Fallo Crítico: Archivo cachyos-repo.tar.xz corrupto."
fi

cd cachyos-repo
if [ ! -x "./cachyos-repo.sh" ]; then
    chmod +x ./cachyos-repo.sh || die "Fallo Crítico: Permisos insuficientes para ejecutar cachyos-repo.sh"
fi

./cachyos-repo.sh || die "Fallo Crítico: El script oficial de CachyOS falló."
print_success "Repositorios inyectados correctamente."

print_info "Actualizando base de datos global de pacman..."
pacman -Syu --noconfirm || die "Fallo Crítico: Pacman no pudo actualizar la base de datos."

# ==============================================================================
# FASE 2: Núcleo Duro y Hardware Base (Intel Arrow Lake)
# ==============================================================================
print_info "Fase 2: Instalando Kernel, Microcódigo y Soporte Completo Intel Core Ultra..."
pacman -S --needed --noconfirm \
    linux-cachyos linux-cachyos-headers cachyos-settings \
    intel-ucode thermald mesa vulkan-intel intel-media-driver level-zero-loader \
    scx-scheds || die "Fallo Crítico: Instalación de paquetes base fallida."

print_info "Habilitando servicio térmico (thermald)..."
systemctl enable thermald || die "Fallo Crítico: No se pudo habilitar thermald. Peligro térmico para el CPU."

print_info "Configurando Sched-Ext (SCX_LAVD)..."
mkdir -p /etc/default
if grep -q "^SCX_SCHEDULER=" /etc/default/scx 2>/dev/null; then
    sed -i 's/^SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx
else
    echo "SCX_SCHEDULER=scx_lavd" >> /etc/default/scx
fi

if [ ! -x "/usr/bin/scx_lavd" ]; then
    die "Fallo Crítico: El binario scx_lavd no existe tras la instalación."
fi
systemctl enable scx.service || die "Fallo Crítico: No se pudo habilitar scx.service."

print_success "Hardware base de Intel configurado y blindado."

# ==============================================================================
# FASE 3: NVIDIA Blackwell y Gestor de Arranque
# ==============================================================================
print_info "Fase 3: Instalando drivers NVIDIA Open DKMS (Blackwell)..."
pacman -S --needed --noconfirm \
    nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils || die "Fallo Crítico: Instalación de drivers NVIDIA fallida."

print_info "Inyectando nvidia-drm.modeset=1 en el gestor de arranque..."
INJECTED=false

# 1. Intentar inyectar en systemd-boot
if ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
    for conf in /boot/loader/entries/*.conf; do
        if ! grep -q "nvidia-drm.modeset=1" "$conf"; then
            sed -i 's/^options .*/& nvidia-drm.modeset=1/' "$conf"
        fi
    done
    print_success "Parámetros inyectados en las entradas de systemd-boot."
    INJECTED=true
fi

# 2. Intentar inyectar en GRUB
if [ -f "/etc/default/grub" ]; then
    if ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || die "Fallo Crítico: grub-mkconfig falló."
        print_success "Parámetros inyectados en GRUB."
    fi
    INJECTED=true
fi

# 3. Inyectar en configuración global (kernel-install)
if [ -d "/etc/kernel" ]; then
    if [ -f "/etc/kernel/cmdline" ]; then
        if ! grep -q "nvidia-drm.modeset=1" /etc/kernel/cmdline; then
            sed -i 's/$/ nvidia-drm.modeset=1/' /etc/kernel/cmdline
            print_success "Parámetros añadidos a /etc/kernel/cmdline."
        fi
    else
        echo "nvidia-drm.modeset=1" > /etc/kernel/cmdline
        print_success "Archivo /etc/kernel/cmdline generado."
    fi
    INJECTED=true
fi

if [ "$INJECTED" = false ]; then
    die "Fallo Crítico: Gestor de arranque no encontrado. NVIDIA Blackwell fallará en Wayland."
fi

# ==============================================================================
# FASE 4: AUR y NPU de Intel
# ==============================================================================
print_info "Fase 4: Configurando AUR y Compilando Unidad Neuronal (NPU)..."
pacman -S --needed --noconfirm paru rebuild-detector fwupd || die "Fallo Crítico: Fallo al instalar utilidades base (paru)."

print_info "Descargando e instalando firmware de la NPU desde AUR..."
# Si la compilación falla, paramos en seco.
if ! sudo -u "$REAL_USER" bash -c "paru -S --needed --noconfirm intel-npu-driver-bin"; then
    die "Fallo Crítico: Fallo al compilar intel-npu-driver-bin. Tu Unidad Neuronal está inoperativa."
fi
print_success "NPU de Intel correctamente instalada."

# ==============================================================================
# FASE 5: Rutinas de Mantenimiento Personalizadas
# ==============================================================================
print_info "Fase 5: Inyectando rutinas robustas update() y cleanpc()..."

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
    if ! ping -c 1 1.1.1.1 >/dev/null 2>&1; then
        echo -e "${red}❌ No hay conexión a internet. Abortando update.${nc}"
        return 1
    fi

    if [ -f /var/lib/pacman/db.lck ]; then
        if command -v fuser >/dev/null 2>&1; then
            if fuser /var/lib/pacman/db.lck >/dev/null 2>&1; then
                echo -e "${red}❌ Error: Pacman database is currently locked by another process.${nc}"
                return 1
            fi
        fi
        echo -e "${yellow}Removing stale pacman database lock...${nc}"
        sudo rm -f /var/lib/pacman/db.lck
    fi

    if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
        echo -e "\n${yellow}[>] Ranking CachyOS mirrors...${nc}"
        sudo cachyos-rate-mirrors || return 1
    fi

    echo -e "\n${yellow}[>] Updating system packages...${nc}"
    sudo pacman -Syuu --noconfirm || return 1

    if command -v paru >/dev/null 2>&1; then
        echo -e "\n${yellow}[>] Updating AUR (paru)...${nc}"
        paru -Sua --noconfirm || return 1
    fi

    if command -v checkrebuild >/dev/null 2>&1; then
        echo -e "\n${yellow}[>] Checking for broken AUR packages...${nc}"
        checkrebuild || true
    fi

    if command -v bootctl >/dev/null 2>&1 && bootctl status >/dev/null 2>&1; then
        if bootctl status | grep -q "Current Boot Loader:.*systemd-boot"; then
            echo -e "\n${yellow}[>] Updating systemd-boot bootloader...${nc}"
            sudo bootctl update || return 1
            if command -v sbctl >/dev/null 2>&1; then
                echo -e "${yellow}[>] Verificando firmas de arranque (Doble Seguridad)...${nc}"
                sudo sbctl sign-all >/dev/null 2>&1 || echo -e "${red}⚠ Fallo al re-firmar el gestor de arranque.${nc}"
            fi
        fi
    fi

    if command -v fwupdmgr >/dev/null 2>&1; then
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
        sudo pacman -Rns $(pacman -Qdtq) --noconfirm || true
    fi

    echo -e "\n${yellow}[>] Cleaning pacman cache...${nc}"
    sudo paccache -ruk0 >/dev/null 2>&1 || true
    sudo paccache -rk2 >/dev/null 2>&1 || true

    echo -e "\n${yellow}[>] Cleaning AUR cache...${nc}"
    if command -v paru >/dev/null 2>&1; then
        paru -Sc --noconfirm || true
    fi

    echo -e "\n${yellow}[>] Cleaning journal logs (7 days)...${nc}"
    sudo journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    echo -e "\n${yellow}[>] Cleaning /tmp...${nc}"
    sudo rm -rf /tmp/* >/dev/null 2>&1 || true

    echo -e "\n${yellow}[>] Running fstrim...${nc}"
    sudo fstrim -av >/dev/null 2>&1 || true

    echo -e "${green}✅ System cleaned!${nc}"
}
'

inject_routines() {
    local target="$1"
    if [ -d "$(dirname "$target")" ]; then
        touch "$target"
        if ! grep -q "RUTINAS DE MANTENIMIENTO CACHYOS" "$target"; then
            echo "$ROUTINES_CODE" >> "$target"
        fi
    fi
}

inject_routines "/etc/skel/.bashrc"
inject_routines "/etc/skel/.zshrc"
inject_routines "/home/$REAL_USER/.bashrc"
inject_routines "/home/$REAL_USER/.zshrc"

print_success "Rutinas inyectadas a prueba de fallos."

# ==============================================================================
# FASE 6: Secure Boot Automation
# ==============================================================================
print_info "Fase 6: Despliegue de Secure Boot (Blindaje Automático)"
pacman -S --needed --noconfirm sbctl || die "Fallo Crítico: sbctl no pudo instalarse."

print_info "Configurando enlace de firmas entre sbctl y DKMS (NVIDIA)..."
mkdir -p /etc/dkms/framework.conf.d/
cat > /etc/dkms/framework.conf.d/sbctl-signing.conf <<EOF
mok_signing_key="/var/lib/sbctl/keys/db/db.key"
mok_certificate="/var/lib/sbctl/keys/db/db.pem"
EOF

# Buscar binarios de arranque críticamente
KERNEL_EFI=$(find /boot -name "vmlinuz-linux-cachyos" | head -n 1)
if [ -z "$KERNEL_EFI" ]; then
    die "Fallo Crítico: Kernel vmlinuz-linux-cachyos no encontrado en /boot. Abortando fase de firma."
fi

SYSTEMD_EFI=$(find /boot/EFI -name "systemd-bootx64.efi" 2>/dev/null | head -n 1 || echo "")
BOOT_EFI=$(find /boot/EFI -name "BOOTX64.EFI" 2>/dev/null | head -n 1 || echo "")

echo -e "\n${CYAN}========================================================================${NC}"
echo -e "${YELLOW}🚨 FASE FINAL: MODO INTERACTIVO (SECURE BOOT) 🚨${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo -e "El sistema necesita firmar los binarios EFI con tus llaves maestras."
echo -e "Para empadronar las llaves en la placa base, la BIOS DEBE estar en 'Setup Mode'."
echo -e ""
read -p "¿Tu BIOS está configurada en Setup Mode AHORA MISMO? (y/n): " setup_mode_ans

if [[ "$setup_mode_ans" =~ ^[Yy]$ ]]; then
    print_info "Generando y empadronando llaves maestras..."
    sbctl create-keys || die "Fallo Crítico: sbctl no pudo generar llaves maestras."
    
    # Firma estricta
    sbctl sign -s "$KERNEL_EFI" || die "Fallo Crítico: Fallo al firmar el Kernel."
    [ -n "$SYSTEMD_EFI" ] && { sbctl sign -s "$SYSTEMD_EFI" || die "Fallo Crítico: Fallo al firmar systemd-boot."; }
    [ -n "$BOOT_EFI" ] && { sbctl sign -s "$BOOT_EFI" || die "Fallo Crítico: Fallo al firmar BOOTX64.EFI."; }
    
    sbctl enroll-keys --microsoft || die "Fallo Crítico: La placa base rechazó las llaves. ¿Seguro estabas en Setup Mode?"
    
    print_info "Recompilando NVIDIA con la nueva firma..."
    dkms autoinstall || die "Fallo Crítico: DKMS falló al compilar NVIDIA. El módulo quedará sin firmar."
    
    print_success "¡Secure Boot configurado y blindado exitosamente!"
else
    print_warn "Fase de Secure Boot pausada."
    
    mkdir -p "/home/$REAL_USER/Desktop"
    cat > "/home/$REAL_USER/Desktop/terminar-secureboot.sh" <<EOF
#!/bin/bash
set -euo pipefail
if [ "\$EUID" -ne 0 ]; then echo "Ejecuta con sudo."; exit 1; fi
echo "Finalizando configuración de Secure Boot..."
sbctl create-keys || { echo "Fallo al crear llaves."; exit 1; }
sbctl sign -s "$KERNEL_EFI" || { echo "Fallo al firmar Kernel."; exit 1; }
[ -n "$SYSTEMD_EFI" ] && sbctl sign -s "$SYSTEMD_EFI"
[ -n "$BOOT_EFI" ] && sbctl sign -s "$BOOT_EFI"
sbctl enroll-keys --microsoft || { echo "Fallo al empadronar llaves en placa base."; exit 1; }
dkms autoinstall || { echo "Fallo DKMS."; exit 1; }
echo "¡Secure Boot configurado y blindado!"
EOF
    chmod +x "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    chown "$REAL_USER:$REAL_USER" "/home/$REAL_USER/Desktop/terminar-secureboot.sh" || true
    
    echo -e "1. Reinicia tu PC y entra a la BIOS."
    echo -e "2. Borra las llaves de Secure Boot (Pon la BIOS en Setup Mode)."
    echo -e "3. Inicia sesión en Arch y ejecuta el script ${YELLOW}'terminar-secureboot.sh'${NC} en tu Escritorio."
fi

print_success "🎉 INSTALACIÓN MAESTRA COMPLETADA. Reinicia tu PC. 🎉"

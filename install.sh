#!/bin/bash
# ==============================================================================
# CACHYOS ULTIMATE INSTALLER (ENTERPRISE SELF-HEALING EDITION)
# ArchLinux Post-Install Script
# Architecture: Intel Core Ultra (Arrow Lake) + NVIDIA Blackwell (RTX 50-series)
# Features: CachyOS Repos, SCX_LAVD, Secure Boot, DKMS, NPU Support, Custom Routines
# ==============================================================================

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

REAL_USER=${SUDO_USER:-$(whoami)}
if [ "$REAL_USER" = "root" ] || [ -z "$REAL_USER" ]; then
    die "Fallo Crítico: Ejecuta este script como usuario normal usando 'sudo'. paru lo requiere."
fi

if [ ! -d "/sys/firmware/efi" ]; then
    die "Fallo Crítico: Este script requiere un sistema instalado en modo UEFI."
fi

# Auto-reparación inicial de red (DNS fallback)
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    print_warn "Problemas de resolución DNS detectados. Aplicando auto-reparación (Fallback a Cloudflare 1.1.1.1)..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
        die "Fallo Crítico: Sin conexión a internet física."
    fi
    print_success "DNS reparado temporalmente."
fi

print_success "Validaciones iniciales superadas."

# ==============================================================================
# ALGORITMOS DE SELF-HEALING (AUTO-REPARACIÓN)
# ==============================================================================

run_pacman() {
    local attempt=1
    local max_retries=3

    while [ $attempt -le $max_retries ]; do
        if pacman "$@" --noconfirm; then
            return 0
        fi

        print_warn "Pacman falló (Intento $attempt/$max_retries). Iniciando protocolo de auto-reparación..."

        # Nivel 1: Destruir bloqueos huérfanos
        if [ -f /var/lib/pacman/db.lck ]; then
            print_info "Healing [1/3]: Destruyendo /var/lib/pacman/db.lck..."
            rm -f /var/lib/pacman/db.lck
        fi

        # Nivel 2: Regenerar Keyring (Problemas de firmas)
        if [ $attempt -eq 2 ]; then
            print_info "Healing [2/3]: Regenerando llaves criptográficas de Arch/CachyOS..."
            pacman-key --init >/dev/null 2>&1 || true
            pacman-key --populate archlinux cachyos >/dev/null 2>&1 || pacman-key --populate archlinux >/dev/null 2>&1 || true
            pacman -Sy archlinux-keyring cachyos-keyring --noconfirm || true
        fi

        # Nivel 3: Refrescar Mirrors
        if [ $attempt -eq 3 ]; then
            print_info "Healing [3/3]: Actualizando lista de espejos..."
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

    die "Fallo Crítico: Pacman no pudo recuperarse tras 3 intentos de auto-reparación. Comando: pacman $*"
}

run_paru() {
    if sudo -u "$REAL_USER" bash -c "paru $@ --noconfirm"; then
        return 0
    fi
    
    print_warn "AUR/Paru falló. Iniciando auto-reparación de dependencias y caché..."
    run_pacman -S --needed base-devel git
    sudo -u "$REAL_USER" bash -c "paru -Sc --noconfirm" || true
    
    print_info "Reintentando compilación..."
    if ! sudo -u "$REAL_USER" bash -c "paru $@ --noconfirm"; then
        die "Fallo Crítico: AUR falló irreversiblemente tras auto-reparación. Comando: paru $*"
    fi
}

# ==============================================================================
# FASE 1: Cimientos y Cachyficación
# ==============================================================================
print_info "Fase 1: Descargando e inyectando Repositorios de CachyOS..."
cd /tmp
rm -rf /tmp/cachyos-repo* 2>/dev/null || true

# Auto-reparación de descarga de repositorio
if ! curl -sOf https://mirror.cachyos.org/cachyos-repo.tar.xz; then
    print_warn "Fallo de descarga principal. Reintentando desde GitHub RAW (Respaldo)..."
    if ! curl -sOfL https://raw.githubusercontent.com/CachyOS/CachyOS-Repo/master/cachyos-repo.tar.xz; then
        die "Fallo Crítico: No se pudo descargar el repositorio desde ningún origen."
    fi
fi

if ! tar xvf cachyos-repo.tar.xz >/dev/null 2>&1; then
    die "Fallo Crítico: Archivo cachyos-repo.tar.xz corrupto."
fi

cd cachyos-repo
chmod +x ./cachyos-repo.sh || true
./cachyos-repo.sh || die "Fallo Crítico: El script oficial de CachyOS falló."
print_success "Repositorios inyectados."

print_info "Sincronizando base de datos global de pacman (Self-Healing activo)..."
run_pacman -Syu

# ==============================================================================
# FASE 2: Núcleo Duro y Hardware Base (Intel Arrow Lake)
# ==============================================================================
print_info "Fase 2: Instalando Kernel, Microcódigo y Soporte Completo Intel Core Ultra..."
run_pacman -S --needed \
    linux-cachyos linux-cachyos-headers cachyos-settings \
    intel-ucode thermald mesa vulkan-intel intel-media-driver level-zero-loader \
    scx-scheds

print_info "Habilitando servicio térmico (thermald)..."
systemctl enable thermald || die "Fallo Crítico: No se pudo habilitar thermald."

print_info "Configurando Sched-Ext (SCX_LAVD)..."
mkdir -p /etc/default
if grep -q "^SCX_SCHEDULER=" /etc/default/scx 2>/dev/null; then
    sed -i 's/^SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx
else
    echo "SCX_SCHEDULER=scx_lavd" >> /etc/default/scx
fi

if [ ! -x "/usr/bin/scx_lavd" ]; then
    die "Fallo Crítico: El binario scx_lavd no existe. Pacman omitió su instalación."
fi
systemctl enable scx.service || die "Fallo Crítico: No se pudo habilitar scx.service."
print_success "Hardware base de Intel configurado y blindado."

# ==============================================================================
# FASE 3: NVIDIA Blackwell y Gestor de Arranque
# ==============================================================================
print_info "Fase 3: Instalando drivers NVIDIA Open DKMS (Blackwell)..."
run_pacman -S --needed \
    nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils

print_info "Inyectando nvidia-drm.modeset=1 en el gestor de arranque..."

inject_bootloader() {
    local injected=false
    
    # 1. systemd-boot
    if ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
        for conf in /boot/loader/entries/*.conf; do
            if ! grep -q "nvidia-drm.modeset=1" "$conf"; then
                sed -i 's/^options .*/& nvidia-drm.modeset=1/' "$conf"
            fi
        done
        print_success "Parámetros inyectados en las entradas de systemd-boot."
        injected=true
    fi

    # 2. GRUB
    if [ -f "/etc/default/grub" ]; then
        if ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || die "Fallo Crítico al reconstruir GRUB."
            print_success "Parámetros inyectados en GRUB."
        fi
        injected=true
    fi

    # 3. kernel-install (global config)
    if [ -d "/etc/kernel" ]; then
        if [ -f "/etc/kernel/cmdline" ]; then
            if ! grep -q "nvidia-drm.modeset=1" /etc/kernel/cmdline; then
                sed -i 's/$/ nvidia-drm.modeset=1/' /etc/kernel/cmdline
            fi
        else
            echo "nvidia-drm.modeset=1" > /etc/kernel/cmdline
        fi
        print_success "Parámetros añadidos a /etc/kernel/cmdline global."
        injected=true
    fi

    if [ "$injected" = true ]; then
        return 0
    fi
    return 1
}

if ! inject_bootloader; then
    print_warn "No se detectaron entradas de arranque. Iniciando Auto-Reparación..."
    print_info "Forzando regeneración de entradas reinstalando hooks del kernel..."
    run_pacman -S linux-cachyos
    
    if ! inject_bootloader; then
        die "Fallo Crítico irreversible: El gestor de arranque es fantasma. NVIDIA Blackwell fallará en Wayland."
    fi
fi

# ==============================================================================
# FASE 3.5: Early Boot & Initramfs Synchronization
# ==============================================================================
print_info "Fase 3.5: Configurando Early KMS y Microcódigo (Arranque de Bajo Nivel)..."

configure_mkinitcpio() {
    local mk_conf="/etc/mkinitcpio.conf"
    if [ ! -f "$mk_conf" ]; then
        print_warn "Archivo $mk_conf no encontrado. Saltando configuración de Early KMS."
        return 0
    fi

    # 1. Inyectar módulos de NVIDIA para Early KMS
    if ! grep -q "nvidia_drm" "$mk_conf"; then
        # Reemplazar la primera coincidencia de MODULES=(...) asegurando que no se rompan las comillas/paréntesis
        sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' "$mk_conf" || true
        # Si la línea MODULES="" es usada en su lugar
        sed -i 's/^MODULES="/MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm /' "$mk_conf" || true
        print_success "Módulos de NVIDIA (Early KMS) inyectados en $mk_conf."
    fi

    # 2. Asegurar el hook de microcódigo después de autodetect
    if ! grep -E -q "HOOKS=.*microcode" "$mk_conf"; then
        sed -i 's/\(HOOKS=(.*autodetect\)/\1 microcode/' "$mk_conf" || true
        sed -i 's/\(HOOKS=".*autodetect\)/\1 microcode/' "$mk_conf" || true
        print_success "Hook de microcódigo inyectado en $mk_conf."
    fi

    print_info "Sincronizando y reconstruyendo Ramdisk inicial..."
    if ! mkinitcpio -P >/dev/null 2>&1; then
        die "Fallo Crítico: mkinitcpio no pudo regenerar las imágenes de arranque. El sistema podría no iniciar."
    fi
    print_success "Initramfs reconstruido y sincronizado exitosamente."
}

configure_mkinitcpio

# ==============================================================================
# FASE 4: AUR y NPU de Intel
# ==============================================================================
print_info "Fase 4: Configurando AUR y Compilando Unidad Neuronal (NPU)..."
run_pacman -S --needed paru rebuild-detector fwupd

print_info "Descargando e instalando firmware de la NPU desde AUR..."
run_paru -S --needed intel-npu-driver-bin
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
        checkrebuild || true
    fi

    if command -v bootctl >/dev/null 2>&1 && bootctl status >/dev/null 2>&1; then
        if bootctl status | grep -q "Current Boot Loader:.*systemd-boot"; then
            echo -e "\n${yellow}[>] Updating systemd-boot bootloader...${nc}"
            sudo bootctl update || return 1
            if command -v sbctl >/dev/null 2>&1; then
                sudo sbctl sign-all >/dev/null 2>&1 || echo -e "${red}⚠ Fallo al re-firmar el gestor de arranque.${nc}"
            fi
        fi
    fi

    if command -v fwupdmgr >/dev/null 2>&1; then
        fwupdmgr refresh && fwupdmgr get-updates || true
    fi

    echo -e "${green}✅ Update completed successfully!${nc}"
}

cleanpc() {
    local red="\033[0;31m"
    local green="\033[0;32m"
    local yellow="\033[1;33m"
    local nc="\033[0m"

    if pacman -Qdtq >/dev/null 2>&1; then
        sudo pacman -Rns $(pacman -Qdtq) --noconfirm || true
    fi

    sudo paccache -ruk0 >/dev/null 2>&1 || true
    sudo paccache -rk2 >/dev/null 2>&1 || true

    if command -v paru >/dev/null 2>&1; then
        paru -Sc --noconfirm || true
    fi

    sudo journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    sudo rm -rf /tmp/* >/dev/null 2>&1 || true
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

print_success "Rutinas inyectadas."

# ==============================================================================
# FASE 6: Secure Boot Automation
# ==============================================================================
print_info "Fase 6: Despliegue de Secure Boot (Blindaje Automático)"
run_pacman -S --needed sbctl

print_info "Configurando enlace de firmas entre sbctl y DKMS (NVIDIA)..."
mkdir -p /etc/dkms/framework.conf.d/
cat > /etc/dkms/framework.conf.d/sbctl-signing.conf <<EOF
mok_signing_key="/var/lib/sbctl/keys/db/db.key"
mok_certificate="/var/lib/sbctl/keys/db/db.pem"
EOF

KERNEL_EFI=$(find /boot -name "vmlinuz-linux-cachyos" | head -n 1)
if [ -z "$KERNEL_EFI" ]; then
    die "Fallo Crítico: Kernel vmlinuz-linux-cachyos no encontrado en /boot. Abortando firma."
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
    sbctl create-keys || die "Fallo Crítico: sbctl no pudo generar llaves."
    
    sbctl sign -s "$KERNEL_EFI" || die "Fallo Crítico: Fallo al firmar el Kernel."
    [ -n "$SYSTEMD_EFI" ] && { sbctl sign -s "$SYSTEMD_EFI" || die "Fallo al firmar systemd-boot."; }
    [ -n "$BOOT_EFI" ] && { sbctl sign -s "$BOOT_EFI" || die "Fallo al firmar BOOTX64.EFI."; }
    
    sbctl enroll-keys --microsoft || die "Fallo Crítico: La placa base rechazó las llaves. Revise Setup Mode."
    
    print_info "Recompilando NVIDIA con la nueva firma..."
    dkms autoinstall || die "Fallo Crítico: DKMS falló al compilar NVIDIA."
    
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
sbctl enroll-keys --microsoft || { echo "Fallo empadronamiento. Reinicie BIOS a Setup Mode."; exit 1; }
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

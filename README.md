# CachyOS Ultimate Installer (Enterprise Transactional Edition)

A high-availability, fault-tolerant, and atomic bash script to transform a fresh Arch Linux installation into a fully optimized CachyOS workstation.

## ⚠️ CRITICAL SYSTEM REQUIREMENTS
**DO NOT RUN THIS SCRIPT ON AMD HARDWARE.** 
This script is architected *exclusively* for a highly specific hardware stack. Running this on AMD Ryzen processors, AMD Radeon GPUs, or older Intel architectures **may result in an unbootable system**.

### Mandatory Hardware Stack:
- **CPU:** Intel Core Ultra (Arrow Lake / Meteor Lake) *Required for `intel-ucode`, `thermald` tuning, and NPU driver compilation.*
- **GPU:** NVIDIA Blackwell (RTX 50-series) *Required for `nvidia-open-dkms` injection and Wayland Early KMS.*
- **Motherboard:** UEFI-based motherboard (ASUS Prime Z890P or similar) *Required for Secure Boot `sbctl` injection.*

### Mandatory Software Prerequisites:
- **OS:** A fresh, clean Arch Linux installation.
- **Bootloader:** `systemd-boot` or `GRUB`.
- **Network:** An active internet connection (the script has DNS fallback, but requires physical connection).
- **User:** You must execute the script as a normal user with `sudo` privileges. Do **NOT** run as `root` directly, as the AUR helper (`paru`) requires a standard user to compile the NPU drivers.

---

## 🚀 Usage

Execute the script on your fresh Arch Linux install:
```bash
git clone https://github.com/isaacwars/cachyos-ultimate-installer.git
cd cachyos-ultimate-installer
sudo ./install.sh
```
*(Downloading via git clone is recommended over curl piping to allow for transactional trap stability).*

## 🛠️ Enterprise Features
This is not a standard bash script. It is built with enterprise-grade server logic:
- **Idempotency:** The script can be run 100 times without duplicating code or corrupting configs.
- **Atomic Transactions (`traps`):** If the execution is interrupted (Ctrl+C, power loss), the script auto-cleans pacman locks (`db.lck`) and temporal files to prevent a corrupted state.
- **Self-Healing:** Intercepts `pacman` and `paru` failures, automatically rebuilding keyrings, hunting for faster mirrors, and clearing corrupt cache.
- **Early KMS:** Automatically edits `/etc/mkinitcpio.conf` to guarantee Wayland boots natively on NVIDIA.
- **Secure Boot Automation:** Generates keys and establishes a bridge with DKMS to auto-sign NVIDIA modules upon compilation.

## 🧬 Execution Phases
1. **Validations & Secure Boot Prep:** Validates the environment and asks for BIOS Setup Mode to prep cryptographic keys.
2. **Cachyfication**: Injects official CachyOS repositories (`[cachyos-v3]`).
3. **Hardware Enablement**: Installs `linux-cachyos`, Intel microcode, thermald, and the `scx_lavd` scheduler.
4. **NVIDIA Blackwell**: Injects `nvidia-drm.modeset=1` to the bootloader, auto-signs DKMS drivers, and rebuilds the `mkinitcpio` RAM disk.
5. **NPU Support**: Compiles Intel NPU firmware from the AUR.
6. **Maintenance Routines**: Injects robust `update` and `cleanpc` automated functions into `/etc/skel` and your `.bashrc`.
7. **Enrollment**: Signs the Bootloader and Kernel EFI binaries and enrolls the keys into your motherboard.

## 🛑 Warning
Use at your own risk. This script aggressively modifies bootloader parameters, pacman configurations, and initramfs files.

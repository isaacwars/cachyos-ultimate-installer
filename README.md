# CachyOS Ultimate Installer

A comprehensive, fault-tolerant bash script to transform a fresh Arch Linux installation into a fully optimized CachyOS workstation.

## 🎯 Architecture Focus
This installer is explicitly tailored and strictly ordered for the ultimate modern hardware stack:
- **CPU:** Intel Core Ultra (Arrow Lake / Meteor Lake) - Enables `intel-ucode`, VA-API, and the physical NPU via `intel-npu-driver-bin`.
- **GPU:** NVIDIA Blackwell (RTX 50-series) - Enforces open kernel modules (`nvidia-open-dkms`), lib32 support, and DRM modesetting for Wayland.
- **Scheduler:** Sched-ext BPF using `scx_lavd` for zero-latency gaming and desktop smoothness.
- **Security:** Fully automated Secure Boot deployment using `sbctl` and DKMS auto-signing hooks.

## 🚀 Usage
Execute the script as a normal user with `sudo` privileges. Do **NOT** run this while logged in directly as `root` in the tty, as the AUR helper (`paru`) requires a standard user to compile packages.

```bash
curl -sL https://raw.githubusercontent.com/isaacwars/cachyos-ultimate-installer/main/install.sh | sudo bash
```

## 🛠️ Phases Overview
1. **Cachyfication**: Injects official CachyOS repositories (`[cachyos-v3]`).
2. **Hardware Enablement**: Installs kernels, Intel microcode, thermald, and the `scx_lavd` scheduler.
3. **NVIDIA Blackwell**: Injects `nvidia-drm.modeset=1` to the bootloader and installs open DKMS drivers.
4. **NPU Support**: Compiles Intel NPU firmware from the AUR.
5. **Maintenance Routines**: Injects `update` and `cleanpc` automated functions into `/etc/skel` and your current `.bashrc`.
6. **Secure Boot**: Interactive phase. Generates keys and signs the kernel/bootloader ONLY if the BIOS is in Setup Mode. Otherwise, leaves a finisher script on the Desktop.

## ⚠️ Warning
Use at your own risk. This script modifies bootloader parameters and pacman configurations aggressively. Designed specifically for UEFI systems.

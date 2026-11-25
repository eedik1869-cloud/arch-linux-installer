#!/usr/bin/env bash
# Arch Linux Installer 0.1.0 — UEFI/GPT, ext4, GRUB, KDE Plasma, BORE
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="0.1.0"
LOG_DIR="/var/log/arch-linux-installer"
DRY_RUN=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say(){ printf '%b\n' "$*"; }
info(){ say "${BLUE}[INFO]${NC} $*"; }
ok(){ say "${GREEN}[ OK ]${NC} $*"; }
warn(){ say "${YELLOW}[WARN]${NC} $*"; }
die(){ say "${RED}[FAIL]${NC} $*" >&2; exit 1; }
usage(){ cat <<'HELP'
Arch Linux Installer 0.1.0

Из Arch Linux ISO:
  curl -fsSL https://raw.githubusercontent.com/USERNAME/arch-linux-installer/main/install.sh -o install.sh
  chmod +x install.sh
  ./install.sh --dry-run
  ./install.sh

Обычный запуск полностью очищает выбранный диск.
HELP
}
for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=1;; -h|--help) usage; exit 0;; *) die "Неизвестный параметр: $arg";; esac; done
[[ $EUID -eq 0 ]] || die "Запусти от root: sudo ./install.sh"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
cleanup(){ local rc=$?; if ((rc)); then warn "Ошибка (код $rc). Журнал: $LOG_FILE"; fi; }
trap cleanup EXIT
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

check_environment(){
  info "Проверка среды"
  [[ -d /sys/firmware/efi/efivars ]] || die "Arch ISO загружена не в UEFI. Перезагрузи её в режиме UEFI."
  mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars || die "Не удалось подключить efivarfs."
  [[ -f /etc/arch-release ]] || die "Скрипт нужно запускать из Arch Linux ISO."
  for c in pacman pacstrap arch-chroot lsblk sgdisk mkfs.fat mkfs.ext4 wipefs partprobe curl tar; do need_cmd "$c"; done
  curl -fsI --max-time 10 https://archlinux.org >/dev/null || die "Нет доступа к интернету."
  timedatectl set-ntp true || true
  ok "UEFI, Arch ISO и интернет доступны"
}

select_disk(){
  mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL,TRAN,TYPE | awk '$5=="disk" {print $1 "|" $2 "|" $3 "|" $4}')
  ((${#DISKS[@]})) || die "Диски не обнаружены."
  say "\nОбнаруженные диски:"
  local i=1 entry dev size model tran
  for entry in "${DISKS[@]}"; do IFS='|' read -r dev size model tran <<< "$entry"; printf ' %d) %-18s %-9s %-25s %s\n' "$i" "$dev" "$size" "${model:-unknown}" "$tran"; ((i+=1)); done
  local n
  read -rp $'\nВыбери номер диска для полной очистки: ' n
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISKS[@]})) || die "Некорректный номер диска."
  IFS='|' read -r TARGET_DISK _ <<< "${DISKS[$((n-1))]}"
  [[ -b "$TARGET_DISK" ]] || die "Выбранное устройство не является диском."
  say "\n${YELLOW}ВНИМАНИЕ: диск ${TARGET_DISK} будет полностью очищен!${NC}"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$TARGET_DISK"
  local confirm
  read -rp "Для подтверждения введи ERASE ${TARGET_DISK}: " confirm
  [[ "$confirm" == "ERASE ${TARGET_DISK}" ]] || die "Подтверждение не совпало."
}

collect_settings(){
  local default_tz="Etc/UTC" p1 p2 r1 r2
  read -rp "Имя компьютера [arch-pc]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch-pc}
  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Некорректное имя компьютера."
  read -rp "Имя пользователя (латиница, нижний регистр): " USERNAME
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя пользователя."
  read -rp "Часовой пояс [${default_tz}]: " TIMEZONE; TIMEZONE=${TIMEZONE:-$default_tz}
  [[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Неизвестный часовой пояс: $TIMEZONE"
  read -rsp "Пароль пользователя: " p1; printf '\n'; read -rsp "Повтори пароль: " p2; printf '\n'
  [[ -n "$p1" && "$p1" == "$p2" ]] || die "Пароли пользователя пустые или не совпадают."
  read -rsp "Пароль root: " r1; printf '\n'; read -rsp "Повтори пароль root: " r2; printf '\n'
  [[ -n "$r1" && "$r1" == "$r2" ]] || die "Пароли root пустые или не совпадают."
  # Секреты сохраняются только на целевой системе с правами 0600 и удаляются после настройки.
  mkdir -p /run/arch-linux-installer
  printf '%s\n%s\n' "$p1" "$r1" > /run/arch-linux-installer/secrets
  chmod 600 /run/arch-linux-installer/secrets
  unset p1 p2 r1 r2
}

partition_disk(){
  info "Разметка ${TARGET_DISK}: GPT, EFI 1 GiB, Ext4 root"
  while read -r part; do [[ -n "$part" ]] && umount "$part" 2>/dev/null || true; done < <(lsblk -lnpo NAME "$TARGET_DISK" | tail -n +2 | tac)
  wipefs -af "$TARGET_DISK"
  sgdisk --zap-all "$TARGET_DISK"
  sgdisk --clear --new=1:1MiB:+1GiB --typecode=1:ef00 --change-name=1:EFI --new=2:0:0 --typecode=2:8300 --change-name=2:ARCH_ROOT "$TARGET_DISK"
  partprobe "$TARGET_DISK"; udevadm settle; sleep 2
  if [[ "$TARGET_DISK" =~ nvme|mmcblk ]]; then EFI_PART="${TARGET_DISK}p1"; ROOT_PART="${TARGET_DISK}p2"; else EFI_PART="${TARGET_DISK}1"; ROOT_PART="${TARGET_DISK}2"; fi
  [[ -b "$EFI_PART" && -b "$ROOT_PART" ]] || die "Не удалось найти созданные разделы."
  mkfs.fat -F32 -n EFI "$EFI_PART"
  mkfs.ext4 -F -L ARCH_ROOT "$ROOT_PART"
  mount "$ROOT_PART" /mnt; mkdir -p /mnt/boot; mount "$EFI_PART" /mnt/boot
  ok "Разделы готовы"
}

install_base(){
  info "Установка базовой системы (обычное ядро Arch останется резервным)"
  pacstrap -K /mnt base linux linux-headers linux-firmware amd-ucode \
    sudo networkmanager grub efibootmgr dosfstools e2fsprogs \
    git base-devel curl wget rsync nano vim less man-db man-pages bash-completion
  genfstab -U /mnt >> /mnt/etc/fstab
  ok "Базовая система установлена"
}

configure_target(){
  info "Установка BORE, KDE, NVIDIA, Wine и приложений"
  arch-chroot /mnt /bin/bash -s -- "$HOSTNAME" "$USERNAME" "$TIMEZONE" <<'CHROOT'
set -Eeuo pipefail
HOSTNAME="$1"; USERNAME="$2"; TIMEZONE="$3"
mapfile -t SECRET < /root/.arch-installer-secrets
USER_PASSWORD="${SECRET[0]}"; ROOT_PASSWORD="${SECRET[1]}"
rm -f /root/.arch-installer-secrets

# Multilib для 32-битных Wine-библиотек.
sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf

# Официальный способ CachyOS подключить репозитории и их ключи.
mkdir -p /root/cachyos-repo-setup; cd /root/cachyos-repo-setup
curl -fL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
tar -xf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh </dev/tty

# Не используем репозиторий [cachyos] с модифицированным pacman.
# Возвращаем пакет pacman из официального Arch и оставляем CachyOS v3 repos.
pacman -S --noconfirm core/pacman
# Remove CachyOS-only pacman metadata fields before continuing with Arch pacman.
find /var/lib/pacman/local/ -type f -name desc -exec sed -i '/^%INSTALLED_DB%$/,+2d' {} \;
awk '/^\[cachyos\]$/ {skip=1; next} /^\[/ {skip=0} !skip {print}' /etc/pacman.conf > /etc/pacman.conf.tmp
install -m 644 /etc/pacman.conf.tmp /etc/pacman.conf; rm -f /etc/pacman.conf.tmp
pacman -Syyu --noconfirm
pacman -S --needed --noconfirm linux-cachyos-bore linux-cachyos-bore-headers

# KDE Plasma 6 с Wayland и отдельным X11-сеансом.
pacman -S --needed --noconfirm \
  plasma-meta plasma-x11-session kwin-x11 sddm konsole dolphin ark kate \
  spectacle gwenview okular filelight partitionmanager discover \
  firefox flatpak xorg-server xorg-xwayland \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  networkmanager bluez bluez-utils bluedevil \
  wine winetricks wine-mono wine-gecko \
  lib32-vulkan-icd-loader lib32-alsa-plugins lib32-libpulse \
  noto-fonts noto-fonts-emoji ttf-liberation hunspell-ru aspell-ru \
  fwupd cups cups-pdf system-config-printer vulkan-tools mesa-utils dkms

# Базовая конфигурация системы.
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i 's/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
cat > /etc/locale.conf <<'EOF'
LANG=ru_RU.UTF-8
LC_MESSAGES=ru_RU.UTF-8
EOF
echo 'KEYMAP=us' > /etc/vconsole.conf

printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,video,audio,storage,optical,input -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Alt+Shift для X11 и KDE/Wayland.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbModel" "pc105"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
EOF
mkdir -p "/home/${USERNAME}/.config"
cat > "/home/${USERNAME}/.config/kxkbrc" <<'EOF'
[Layout]
LayoutList=us,ru
Model=pc105
Options=grp:alt_shift_toggle
Use=true
EOF
chown -R "$USERNAME:$USERNAME" "/home/${USERNAME}/.config"

# ZRAM: до 16 GiB либо половина RAM, алгоритм Zstd.
pacman -S --needed --noconfirm zram-generator
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
swap-priority = 100
EOF

# NVIDIA proprietary DKMS modules and DRM modesetting.
cat > /etc/modules-load.d/nvidia.conf <<'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1
EOF
sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB for UEFI; ESP mounted at /boot.
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux --recheck
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet nvidia_drm.modeset=1"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Сначала подготовлены система и загрузчик. Если сборка AUR завершится ошибкой,
# обычное ядро Arch и GRUB уже останутся загрузочными.
useradd -m -s /bin/bash aurbuild
printf 'aurbuild ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/aurbuild
chmod 440 /etc/sudoers.d/aurbuild; visudo -cf /etc/sudoers.d/aurbuild
runuser -u aurbuild -- git clone https://aur.archlinux.org/paru-bin.git /home/aurbuild/paru-bin
say 'Проверь PKGBUILD paru-bin перед сборкой:'
sed -n '1,220p' /home/aurbuild/paru-bin/PKGBUILD
read -rp 'Если PKGBUILD тебя устраивает, нажми Enter для сборки paru-bin...' _ </dev/tty
runuser -u aurbuild -- bash -lc 'cd ~/paru-bin && makepkg --noconfirm'
pacman -U --noconfirm /home/aurbuild/paru-bin/paru-bin-*.pkg.tar.zst
say 'Далее paru покажет PKGBUILD AUR-пакетов NVIDIA и Яндекс Браузера для проверки.'
runuser -u aurbuild -- paru --needed -S nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils yandex-browser </dev/tty
rm -f /etc/sudoers.d/aurbuild; userdel -r aurbuild || true

systemctl enable NetworkManager sddm bluetooth fstrim.timer
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Do not create a Wine prefix as root. User can create a clean 64-bit prefix:
# WINEARCH=win64 wineboot -u
unset USER_PASSWORD ROOT_PASSWORD SECRET
CHROOT
}

finish_install(){
  sync; ok "Установка завершена. Журнал: $LOG_FILE"
  say "После перезагрузки в SDDM доступны Plasma (Wayland) и Plasma (X11)."
  say "Secure Boot должен быть отключён. Обычное ядро Arch оставлено резервным."
  read -rp "Перезагрузить сейчас? [y/N]: " answer
  if [[ "$answer" =~ ^[YyДд]$ ]]; then reboot; fi
}

main(){
  say "\n${BLUE}Arch Linux Installer ${VERSION}${NC}"
  say "UEFI/GPT | Ext4 | GRUB | Plasma 6 | CachyOS BORE | NVIDIA | Wine | ZRAM"
  check_environment
  if ((DRY_RUN)); then ok "DRY-RUN: проверки завершены, диск не изменялся."; exit 0; fi
  select_disk
  collect_settings
  read -rp "Последнее подтверждение: продолжить установку на ${TARGET_DISK}? [y/N]: " final_confirm
  [[ "$final_confirm" =~ ^[YyДд]$ ]] || die "Установка отменена."
  partition_disk
  install -D -m 600 /run/arch-linux-installer/secrets /mnt/root/.arch-installer-secrets
  rm -f /run/arch-linux-installer/secrets
  install_base
  configure_target
  finish_install
}
main "$@"

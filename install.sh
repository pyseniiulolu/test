#!/bin/bash

# Function to display colorful messages
print_message() {
    echo -e "\e[1;34m=> $1\e[0m"
}

print_error() {
    echo -e "\e[1;31m=> Error: $1\e[0m"
}

print_success() {
    echo -e "\e[1;32m=> $1\e[0m"
}

# Check CPU vendor
check_cpu() {
    if lscpu | grep -q "GenuineIntel"; then
        echo "intel"
    elif lscpu | grep -q "AuthenticAMD"; then
        echo "amd"
    else
        echo "unknown"
    fi
}

CPU_VENDOR=$(check_cpu)
print_message "Detected CPU vendor: ${CPU_VENDOR}"

# Error handling
set -e

# Function to display error messages
error() {
    print_error "$1" >&2
    exit 1
}

# Check if CPU is supported
if [ "$CPU_VENDOR" = "unknown" ]; then
    error "Unsupported CPU detected. This script supports Intel and AMD CPUs only."
fi

# Welcome message
print_message "Starting Arch Linux installation..."

# Check if running in UEFI mode
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    error "This script only supports UEFI systems"
fi

# Set Swedish keyboard layout
loadkeys sv-latin1 || error "Failed to set keyboard layout"

# Update system clock
timedatectl set-ntp true

# Disk selection
print_message "Available disks:"
lsblk
echo
read -p "Enter the disk to install Arch Linux (e.g., /dev/sda): " DISK
[[ -b "$DISK" ]] || error "Invalid disk selected"

# Disk partitioning
print_message "Creating partitions on $DISK..."
parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 boot on \
    mkpart primary linux-swap 513MiB 4.5GiB \
    mkpart primary ext4 4.5GiB 100% || error "Partitioning failed"

# Format partitions
print_message "Formatting partitions..."
mkfs.fat -F32 "${DISK}1" || error "Failed to format EFI partition"
mkswap "${DISK}2" || error "Failed to create swap"
mkfs.ext4 "${DISK}3" || error "Failed to format root partition"

# Mount partitions
print_message "Mounting partitions..."
mount "${DISK}3" /mnt || error "Failed to mount root partition"
mkdir -p /mnt/boot/efi
mount "${DISK}1" /mnt/boot/efi || error "Failed to mount EFI partition"
swapon "${DISK}2" || error "Failed to enable swap"

# Install base system
print_message "Installing base system..."
pacstrap /mnt base base-devel linux linux-firmware || error "Failed to install base system"

# Generate fstab
print_message "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab || error "Failed to generate fstab"

# Create GPU detection script based on CPU vendor
if [ "$CPU_VENDOR" = "intel" ]; then
    cat > /mnt/detect-gpu.sh <<'END'
#!/bin/bash
lspci -nn | grep -i nvidia | grep -i vga | cut -d '[' -f2 | cut -d ']' -f1
END
else
    cat > /mnt/detect-gpu.sh <<'END'
#!/bin/bash
lspci -nn | grep -i amd | grep -i vga | cut -d '[' -f2 | cut -d ']' -f1
END
fi
chmod +x /mnt/detect-gpu.sh

# Chroot configuration
print_message "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
# Set Swedish console keymap
echo "KEYMAP=sv-latin1" > /etc/vconsole.conf
echo "FONT=lat9w-16" >> /etc/vconsole.conf

# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime
hwclock --systohc

# Set locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo "arch" > /etc/hostname

# Configure network
cat > /etc/hosts <<END
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch.localdomain arch
END

# Get GPU IDs
GPU_IDS=\$(bash /detect-gpu.sh | tr '\n' ',' | sed 's/,$//')

# Install necessary packages based on CPU vendor
if [ "$CPU_VENDOR" = "intel" ]; then
    pacman -S --noconfirm \
        networkmanager \
        nano \
        vim \
        git \
        base-devel \
        wget \
        neofetch \
        qemu-full \
        virt-manager \
        virt-viewer \
        dnsmasq \
        vde2 \
        bridge-utils \
        openbsd-netcat \
        ebtables \
        iptables-nft \
        libguestfs \
        ovmf \
        intel-ucode \
        xf86-video-intel \
        mesa \
        lib32-mesa \
        vulkan-intel \
        lib32-vulkan-intel
else
    pacman -S --noconfirm \
        networkmanager \
        nano \
        vim \
        git \
        base-devel \
        wget \
        neofetch \
        qemu-full \
        virt-manager \
        virt-viewer \
        dnsmasq \
        vde2 \
        bridge-utils \
        openbsd-netcat \
        ebtables \
        iptables-nft \
        libguestfs \
        ovmf \
        amd-ucode \
        xf86-video-amdgpu \
        mesa \
        lib32-mesa \
        vulkan-radeon \
        lib32-vulkan-radeon
fi

# Set root password
print_message "Set root password:"
passwd

# Install and configure bootloader (GRUB)
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Configure GRUB for IOMMU
if [ "$CPU_VENDOR" = "intel" ]; then
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet intel_iommu=on iommu=pt vfio-pci.ids=\$GPU_IDS\"/" /etc/default/grub
else
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet amd_iommu=on iommu=pt vfio-pci.ids=\$GPU_IDS\"/" /etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Configure VFIO
cat > /etc/modprobe.d/vfio.conf <<END
options vfio-pci ids=\$GPU_IDS
END

# Configure mkinitcpio
if [ "$CPU_VENDOR" = "intel" ]; then
    sed -i 's/MODULES=()/MODULES=(vfio vfio_iommu_type1 vfio_pci vfio_virqfd intel_agp i915)/' /etc/mkinitcpio.conf
else
    sed -i 's/MODULES=()/MODULES=(vfio vfio_iommu_type1 vfio_pci vfio_virqfd amdgpu)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Create a new user
read -p "Enter username: " USERNAME
useradd -m -G wheel -s /bin/bash "\$USERNAME"
print_message "Set password for \$USERNAME:"
passwd "\$USERNAME"

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Add user to virtualization groups
usermod -aG libvirt "\$USERNAME"
usermod -aG kvm "\$USERNAME"

# Enable services
systemctl enable NetworkManager
systemctl enable libvirtd

# Create post-install script
cat > /home/\$USERNAME/install-ml4w.sh <<'END'
#!/bin/bash
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
yay -S --noconfirm brave-bin

# Clone and install ML4W Hyprland
cd ~
git clone --depth=1 https://github.com/mylinuxforwork/dotfiles.git
cd dotfiles/bin
./ml4w-hyprland-setup
END

# Create system check script
cat > /home/\$USERNAME/check-system.sh <<'END'
#!/bin/bash
echo "System Information:"
echo "=================="
echo -e "\nCPU Information:"
lscpu | grep -E "Model name|Vendor ID"
echo -e "\nGPU Information:"
lspci -k | grep -A 2 -E "(VGA|3D)"
echo -e "\nIOMMU Groups:"
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=${d#*/iommu_groups/*}
  n=${n%%/*}
  printf 'IOMMU Group %s ' "$n"
  lspci -nns "${d##*/}"
done
echo -e "\nLoaded GPU Modules:"
lsmod | grep -i "amdgpu\|nvidia\|intel\|vfio"
echo -e "\nVFIO Configuration:"
cat /etc/modprobe.d/vfio.conf
END

chmod +x /home/\$USERNAME/install-ml4w.sh
chmod +x /home/\$USERNAME/check-system.sh
chown \$USERNAME:\$USERNAME /home/\$USERNAME/install-ml4w.sh
chown \$USERNAME:\$USERNAME /home/\$USERNAME/check-system.sh

# Configure libvirt hooks directory
mkdir -p /etc/libvirt/hooks
cat > /etc/libvirt/hooks/qemu <<'END'
#!/bin/bash
END
chmod +x /etc/libvirt/hooks/qemu

EOF

# Unmount partitions
print_message "Unmounting partitions..."
umount -R /mnt

print_success "Installation complete! You can now reboot."
print_message "After reboot:"
print_message "1. Login with your user"
print_message "2. Connect to network: nmtui"
print_message "3. Run ./install-ml4w.sh to install Brave and ML4W Hyprland"
print_message "4. Run ./check-system.sh to verify system configuration"
print_message "5. Start libvirt with: sudo virsh net-start default"

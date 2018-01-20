#!/bin/bash
set -e

PKG_LIST="base-system lvm2 cryptsetup grub vim"
HOSTNAME="tuxbox"
KEYMAP="us"
TIMEZONE="Europe/Zurich"
LANG="en_US.UTF-8"
CRYPTDEVNAME="crypt-pool"
VGNAME="vgpool"

# wipe disk using either /dev/zero or /dev/urandom. Set this value to zero for new disks.
WIPEDEV="zero"

echo -e "Confirm the following settings:\nHOSTNAME=$HOSTNAME\nKEYMAP=$KEYMAP\nTIMEZONE=$TIMEZONE\nLANG=$LANG\nCRYPT DEVICE NAME=$CRYPTDEVNAME\nVOLUMEGROUP NAME=$VGNAME\nWIPE DISK USING /dev/$WIPEDEV"
read -p "Press ENTER to continue, CTRL-C to exit."

loadkeys $KEYMAP

# encrypted boot takes 200M, ESP takes up 100M [total:300M]
# root will take up the remaining empty space
SWAP=0
SWAPSIZE="8G"
HOME=0
HOMESIZE="80G"
VAR=0
VARSIZE="5G"
PARTSET="Partition Settings:"

if [ $SWAP ]; then
  PARTSET="$PARTSET\nSWAP=$SWAPSIZE"
else
  PARTSET="$PARTSET\nNO SWAP PARTITION"
fi
if [ $HOME ]; then
  PARTSET="$PARTSET\nHOME=$HOMESIZE"
else
  PARTSET="$PARTSET\nNO HOME PARTITION"
fi
if [ $VAR ]; then
  PARTSET="$PARTSET\nVAR=$VARSIZE"
else
  PARTSET="$PARTSET\nNO VAR PARTITION"
fi

echo -e "Confirm the following $PARTSET"
read -p "Press ENTER to continue, CTRL-C to exit."

# detect if we're in UEFI or legacy mode
[ -d /sys/firmware/efi ] && UEFI=1
if [ $UEFI ]; then
  PKG_LIST="$PKG_LIST grub-x86_64-efi efibootmgr"
fi

# install requirements
xbps-install -y -S -f cryptsetup parted lvm2

# wipe /dev/sda
dd if=/dev/${WIPEDEV} of=/dev/sda bs=1M count=100
if [ $UEFI ]; then
  DEVPART="2"
  parted /dev/sda mklabel gpt
  parted -a optimal /dev/sda mkpart primary 2048s 100M
  parted -a optimal /dev/sda mkpart primary 100M 100%
else
  DEVPART="1"
  parted /dev/sda mklabel msdos
  parted -a optimal /dev/sda mkpart primary 2048s 100%
fi
parted /dev/sda set 1 boot on

read -p "[!!] Please enter a STRONG passphrase for encryption when prompted. Press ENTER to continue."
cryptsetup luksFormat -c aes-xts-plain64 -s 512 /dev/sda${DEVPART}
cryptsetup luksOpen /dev/sda${DEVPART} ${CRYPTDEVNAME}

# create VG
pvcreate /dev/mapper/${CRYPTDEVNAME}
vgcreate ${VGNAME} /dev/mapper/${CRYPTDEVNAME}

# create encrypted partitions
if [ $UEFI ]; then
  lvcreate -L 200M -n boot ${VGNAME}
else
  lvcreate -L 300M -n boot ${VGNAME}
fi
if [ $SWAP ]; then
  lvcreate -C y -L ${SWAPSIZE} -n swap ${VGNAME}
fi
if [ $VAR ]; then
  lvcreate -L ${VARSIZE} -n var ${VGNAME}
fi
if [ $HOME ]; then
  lvcreate -L ${HOMESIZE} -n home ${VGNAME}
fi
lvcreate -l 100%FREE -n root ${VGNAME}

echo "Confirm the following lvm partition table:"
lvs -o lv_name,lv_size -S vg_name=${VGNAME}
read -p "Press ENTER to continue, CTRL-C to cancel the setup."

# format filesystems
if [ $UEFI ]; then
  mkfs.vfat -F32 /dev/sda1
fi
mkfs.ext2 /dev/mapper/${VGNAME}-boot
mkfs.ext4 -L root /dev/mapper/${VGNAME}-root
if [ $VAR ]; then
  mkfs.ext4 -L var /dev/mapper/${VGNAME}-var
fi
if [ $HOME ]; then
  mkfs.ext4 -L home /dev/mapper/${VGNAME}-home
fi
if [ $SWAP ]; then
  mkswap -L swap /dev/mapper/${VGNAME}-swap
  swapon /dev/mapper/${VGNAME}-swap
fi

# mount them
mount /dev/mapper/${VGNAME}-root /mnt
for dir in dev proc sys boot home var; do
  mkdir /mnt/${dir}
done

if [ $HOME ]; then
  mount /dev/mapper/${VGNAME}-home /mnt/home
fi
if [ $VAR ]; then
  mount /dev/mapper/${VGNAME}-var /mnt/var
fi
mount /dev/mapper/${VGNAME}-boot /mnt/boot
if [ $UEFI ]; then
  mkdir /mnt/boot/efi
  mount /dev/sda1 /mnt/boot/efi
fi

for fs in dev proc sys; do
  mount -o bind /${fs} /mnt/${fs}
done

# install void
xbps-install -y -S -R http://repo.voidlinux.eu/current -r /mnt $PKG_LIST

# set up system
echo "[!] Setting root password"
passwd -R /mnt root
echo $HOSTNAME > /mnt/etc/hostname
echo "TIMEZONE=${TIMEZONE}" >> /mnt/etc/rc.conf
echo "KEYMAP=${KEYMAP}" >> /mnt/etc/rc.conf
echo "TTYS=2" >> /mnt/etc/rc.conf
echo "LANG=$LANG" > /mnt/etc/locale.conf
echo "$LANG $(echo ${LANG} | cut -f 2 -d .)" >> /mnt/etc/default/libc-locales
chroot /mnt xbps-reconfigure -f glibc-locales

# add fstab entries
echo -e "/dev/mapper/${VGNAME}-boot\t/boot\text2\trw,relatime\t0 2" >> /mnt/etc/fstab
if [ $SWAP ]; then
  echo -e "/dev/mapper/${VGNAME}-swap\tnone\tswap\tsw\t0 0" >> /mnt/etc/fstab
fi
echo -e "/dev/mapper/${VGNAME}-root\t/\t/ext4\trw,relatime,data=ordered,discard\t0 1" >> /mnt/etc/fstab
if [ $HOME ]; then
  echo -e "/dev/mapper/${VGNAME}-home\t/home\t/ext4\trw,relatime,data=ordered,discard\t0 0" >> /mnt/etc/fstab
fi
if [ $VAR ]; then
  echo -e "/dev/mapper/${VGNAME}-var\t/home\t/ext4\trw,relatime,data=ordered,discard\t0 0" >> /mnt/etc/fstab
fi
if [ $UEFI ]; then
  echo -e "/dev/sda1   /boot/efi   vfat    defaults    0 0" >> /mnt/etc/fstab
fi
echo -e "tmpfs\t/tmp\ttmpfs\tsize=1G,defaults,nodev,nosuid\t0 0" >> /mnt/etc/fstab

# Link /var/tmp > /tmp
rm -rf /mnt/var/tmp
ln -s /tmp /mnt/var/tmp

# chroot into the new system
xbps-uchroot /mnt /bin/bash
echo "[CHROOT] using /bin/bash."

# create luks keyfile
echo -e "[!!] A keyfile will be created to decrypt rootfs on boot.\nThis saves you from having to type the password twice."
read -p "[!!!] Please enter the cryptsetup passphrase when requested. Press ENTER to continue."
dd bs=512 count=4 if=/dev/urandom of=/crypto_keyfile.bin
cryptsetup luksAddKey /dev/sda${DEVPART} /crypto_keyfile.bin
chmod 000 /crypto_keyfile.bin
chmod -R g-rwx,o-rwx /boot

echo "GRUB_PRELOAD_MODULES=\"cryptodisk luks\"" >> /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

# crypttab setup
LUKS_UUID="$(lsblk -o NAME,UUID | grep sda${DEVPART} | awk '{print $2}')"
echo -e "luks-${LUKS_UUID}\t/dev/sda${DEVPART}\t/crypto_keyfile.bin\tluks" >> /etc/crypttab

# Now tune the cryptsetup
KERNEL_VER=$(xbps-query -r /mnt -s linux4 | cut -f 2 -d ' ' | cut -f 1 -d -)

mkdir -p /etc/dracut.conf.d/
echo 'hostonly=yes' > /etc/dracut.conf.d/00-hostonly.conf
echo 'install_items+="/etc/crypttab /crypto_keyfile.bin"' > /etc/dracut.conf.d/10-crypt.conf
echo "GRUB_CMDLINE_LINUX=\"rd.vconsole.keymap=${KEYMAP} cryptdevice=/dev/sda${DEVPART} rd.luks.crypttab=1 rd.md=0 rd.dm=0 rd.lvm=1 rd.luks=1 rd.luks.allow-discards rd.luks.uuid=${LUKS_UUID}\"" >> /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg
grub-install /dev/sda
xbps-reconfigure -f ${KERNEL_VER}

exit
echo "The setup is complete!"
read -p "The script will now execute custom scripts. Press ENTER to continue."

# install custom scripts
if [ -d ./custom ]; then
  cp -r ./custom /mnt/tmp

  # run .sh scripts in chroot
  for SHFILE in /mnt/tmp/*.sh; do
    chroot /mnt sh /tmp/$(basename $SHFILE)
  done

  # cleanup chroot
  rm -rf /mnt/tmp/custom
fi

vgchange -a n  ${VGNAME}
cryptsetup luksClose ${CRYPTDEVNAME}

echo "Done installing Void Linux! You may now reboot."

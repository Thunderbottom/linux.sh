#!/bin/bash

# change root shell
chsh -s /bin/bash

# disable ipv6
mkdir -p /etc/sysctl.d
echo 'net.ipv6.conf.all.disable_ipv6 = 1' > /etc/sysctl.d/01-disable-ipv6.conf

# enable networking
ln -s /etc/sv/dhcpcd /var/service/
read -p "Add your \$HOSTNAME to the host file. Press ENTER to continue."
vim /etc/hosts

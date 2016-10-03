#!/bin/bash
#
# Continue Debian setup on a virtual server.
#
# VERSION       :1.0.0
# URL           :https://github.com/szepeviktor/debian-server-tools
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+
# CI            :shellcheck -x debian-setup2.sh
# CONFIG        :/root/server.yml

# Advise
#
# Prepare two terminals.

declare -i CPU_COUNT

set -e -x

. debian-setup-functions

VIRT="$(Data get-value virtualization)"
export VIRT

IP="$(ifconfig | sed -n -e '0,/^\s*inet addr:\([0-9\.]\+\)\b.*$/s//\1/p')"
export IP

# _check-system needs most
apt-get install -y most
debian-setup/most

# Manual checks
debian-setup/_check-system

# Basic packages
DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
    ipset time netcat-openbsd lftp \
    ncurses-term bash-completion mc htop most less \
    localepurge unattended-upgrades apt-listchanges cruft debsums \
    gcc libc6-dev make strace \
    moreutils logtail whois unzip heirloom-mailx \
    apg dos2unix ccze git colordiff mtr-tiny ntpdate \

# Backports
DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
    -t jessie-backports needrestart unscd
# testing
debian-setup/ca-certificates
# From custom repos
DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
    goaccess ipset-persistent

# Provider packages
if [ -n "$(Data get-value provider-package "")" ]; then
    # shellcheck disable=SC2046
    DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
        $(Data get-values provider-package)
fi

# Restore original sudoers file
debian-setup/sudo

debian-setup/locales

# tzdata first as it may modify system time
debian-setup/tzdata
debian-setup/rsyslog

debian-setup/localepurge
debian-setup/unattended-upgrades

# Custom APT repository script
Dinstall package/apt-add-repo.sh

# @FIXME
#debian-setup/ifupdown

debian-setup/_resolv_conf

# Block dangerous networks
# @FIXME Depends on repo
(
    cd /usr/local/src/debian-server-tools/security/myattackers-ipsets/
    ./ipset-install.sh
)

# Micro Name Service Caching
debian-setup/unscd

debian-setup/kmod

debian-setup/mount

debian-setup/initscripts

# Alert on boot and on halt
Dinstall monitoring/boot-alert
Dinstall monitoring/halt-alert
insserv -v boot-alert
insserv -v halt-alert

# IRQ balance
CPU_COUNT="$(grep -c "^processor" /proc/cpuinfo)"
if [ "$CPU_COUNT" -gt 1 ]; then
    # Stable has a bug, it exits
    apt-get install -t jessie-backports -y irqbalance
    cat /proc/interrupts
elif Is_installed "irqbalance"; then
    apt-get purge -y irqbalance
fi

# Time synchronization
debian-setup/util-linux
# @TODO
# if grep "kvm-clock" /sys/devices/system/clocksource/clocksource0/current_clocksource \
#     || dmesg | grep -w "kvm-clock"; then
#     # Display clock sources
#     cat /sys/devices/system/clocksource/clocksource0/available_clocksource
#     echo "https://s19n.net/articles/2011/kvm_clock.html"
# fi
if [ "$VIRT" == "kvm" ] && [ "$WITHOUT_SYSTEMD" == "yes" ]; then
    apt-get install -t jessie-backports -y libseccomp2
    apt-get install -y chrony
    debian-setup/chrony
fi
# Monitor clock without monit
#     Dinstall monitoring/monit/services/ntpdate_script
#     echo -e '#!/bin/bash\n/usr/local/bin/ntp-alert.sh' > /etc/cron.daily/ntp-alert1
#     chmod +x /etc/cron.daily/ntp-alert1

# Entropy
if Is_installed "rng-tools"; then
    # VirtIO RNG on KVM
    [ -c /dev/hwrng ]
    cat /sys/devices/virtual/misc/hw_random/rng_{available,current}
else
    # Software based entropy source
    cat /proc/sys/kernel/random/entropy_avail
    apt-get install -y haveged
    cat /proc/sys/kernel/random/entropy_avail
fi

# @TODO
#if [ "$VIRT" == "kvm" ]; then
#    debian-setup/_virt-kvm
#fi
if [ "$VIRT" == "xen" ]; then
    debian-setup/_virt-xen
fi
if [ "$VIRT" == "vmware" ]; then
    debian-setup/_virt-vmware
fi

# For Aruba Cloud
if [ -n "$(Data get-value software.serclient "")" ]; then
    debian-setup/serclient
fi

debian-setup/cron

debian-setup/debsums

debian-setup/openssh-client

debian-setup/mc

# myattackers
Dinstall security/myattackers.sh
# Initialize iptables chain
myattackers.sh -i

# After security/myattackers.sh
debian-setup/fail2ban

#debian-setup/_cert-szepenet

#debian-setup/proftpd-basic

# Courier MTA - deliver all messages to a smarthost
mail/courier-mta-satellite-system.sh

if Is_installed "msmtp-mta"; then
    debian-setup/msmtp-mta
fi
#if Is_installed "nullmailer"; then
#    debian-setup/nullmailer
#fi

# Monitor certificates
Dinstall monitoring/cert-expiry.sh

# Tools
for TOOL in catconf cnet hosthost hostinfo ip.sh lsrev msec reboot revip \
    sortip swap-usage.sh u udrush uwp whichdo whoistop; do
    Dinstall "tools/${TOOL}"
done

# Apache 2.4
webserver/apache-httpd.sh
Dinstall webserver/apache-resolve-hostnames.sh
if Is_installed "mod-pagespeed-stable"; then
    debian-setup/mod-pagespeed-stable
fi
# PHP-FPM
#webserver/php5-fpm.sh
webserver/php7-fpm.sh

# Package managers
debian-setup/_package-python-pip
# Needs PHP-CLI
debian-setup/_package-php-composer
# Node.js
if Is_installed "nodejs"; then
    debian-setup/nodejs
fi

# Webserver reload
Dinstall webserver/webrestart.sh
# Redis server and PHP extension
webserver/redis-php.sh
# MariaDB
debian-setup/mariadb-server

# Add the development website, needs composer
webserver/add-prg-site-auto.sh
# Add a production website
# See /webserver/add-site.sh

# apache-default, apache-combined and apache-instant Fail2ban jails are enabled by default
service fail2ban restart

# Backup
apt-get install -t jessie-backports -y python3-requests
apt-get install -y s3ql

# CLI tools
debian-setup/php-wpcli
# WordPress cron
Dinstall webserver/wp-cron-cli.sh
#debian-setup/php-drush

# Monit - monitoring
# @FIXME Needs a production website for apache2 and php7.0-fpm
# @FIXME Defaults config file editor
# @FIXME Depends on repo
(
    cd /usr/local/src/debian-server-tools/monitoring/monit/
    install --mode=0640 -D -t /etc/monit monit.defaults
    editor /etc/monit/monit.defaults
    ./monit-debian-setup.sh
)

# After monit
debian-setup/libpam-modules

# @TODO
# Munin - network-wide graphing
#monitoring/munin/munin-debian-setup.sh

# Clean up
apt-get autoremove --purge -y
apt-get clean

# Throttle automatic package downloads
echo -e 'Acquire::Queue-mode "access";\nAcquire::http::Dl-Limit "1000";' > /etc/apt/apt.conf.d/76download

# etckeeper at last
apt-get install -y etckeeper
debian-setup/etckeeper

# Clear Bash history
history -c

echo "OK."
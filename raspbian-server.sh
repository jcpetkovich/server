#!/bin/bash

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

read -r -d '' HELP <<EOF
Usage: raspbian-server.sh [options]

Take a raspbian install and set it up with my server configuration.

    Command options:
    -h    Print this help documentation.
    -f    Force each step.
    -p    Pretend.
EOF

function info () {
    echo -e '\033k'$1'\033\\'
    printf "  [ \033[00;34m..\033[0m ] $1 \n"
}

function user () {
    printf "\r  [ \033[0;33m?\033[0m ] $1 \n"
}

function success () {
    printf "\r\033[2K  [ \033[00;32mOK\033[0m ] $1\n"
}

function fail () {
    printf "\r\033[2K  [\033[0;31mFAIL\033[0m] $1\n"
    echo ''
    exit 1
}

FORCE=false
PRETEND=false

while getopts ":hfp" opt; do
    case $opt in
        h ) echo "$HELP"
            exit 0;;
        f ) FORCE=true
            exit 0;;
        p ) PRETEND=true
            exit 0;;
        ? ) echo "Invalid option -${OPTARG}..."
            echo "$HELP"
            exit 0;;
    esac
done
shift $(($OPTIND - 1))

NEWHOSTNAME=ptk.io
MYSQLDB="/media/storage/mysql/"
DOMAIN=ptk.io
PACKAGES="
apache2
mysql-server
screen
cryptsetup
btrfs-tools
rtorrent
"

echo "Enter your pi's new user"
read -p "User: " USER

if ! grep -E "^${USER}:" /etc/passwd > /dev/null; then

    info "user $USER not found, adding"

    echo "Enter your pi's user password"
    read -s -p "Password: " PASSWORD

    # setup user
    useradd -m -G adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,netdev,spi,i2c,gpio -s /bin/bash $USER
    echo "${USER}:${PASSWORD}" | chpasswd

    success "user added"
else
    success "user already exists"
fi

# ssh
if grep -E "UsePAM\s+yes" /etc/ssh/sshd_config > /dev/zero; then
    info "first thing's first, fixing ssh config"
    sed -i 's/UsePAM no'
    sed -r -i 's/^UsePAM\s+(\S+)/UsePAM no/' /etc/ssh/sshd_config
    sed -r -i 's/^.*PasswordAuthentication\s+(\S+)/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart ssh.service
    success "fixed!"
else
    success "ssh secure"
fi

# timezone
if ! timedatectl | grep "America/Toronto" > /dev/null; then
    info "fixing date"
    timedatectl set-timezone America/Toronto
    success "fixed!"
else
    success "date correct"
fi

# locale
if ! grep -E "^en_US" /etc/locale.gen > /dev/null; then
    info "fixing locale"
    cat <<EOF | tee -a /etc/locale.gen > /dev/null
en_US ISO-8859-1
en_US.ISO-8859-15 ISO-8859-15
en_US.UTF-8 UTF-8
EOF
    locale-gen
    localectl set-locale LANG=en_US.UTF-8
    success "fixed locale"
else
    success "locale correct"
fi

# hdparm
if ! grep -E "^/dev/sda" /etc/hdparm.conf > /dev/null; then
    info "fixing hdparm configs"
    cat <<EOF | tee -a /etc/hdparm.conf > /dev/null
/dev/sda {
    write_cache = on
    spindown_time = 30
    apm = 127
    apm_battery = 127
}
EOF
    systemctl enable hdparm
    systemctl restart hdparm
    success "fixed hdparm configs"
else
    success "hdparm configs correct"
fi

# hostname fixing
if ! grep -E $NEWHOSTNAME /etc/hostname > /dev/null; then
    info "better hostname"
    echo $NEWHOSTNAME > /etc/hostname
    sed -i "s/raspberrypi/${NEWHOSTNAME}/" /etc/hosts
    success "fixed hostname"
else
    success "correct hostname"
fi

# default boot in server mode (no autologin)
if ! [[ $(readlink /lib/systemd/system/getty@.service) == "/etc/systemd/system/getty.target.wants/getty@tty1.service" ]]; then
    info "setting boot option to headless"
    systemctl set-default multi-user.target
    ln -fs /lib/systemd/system/getty@.service \
       /etc/systemd/system/getty.target.wants/getty@tty1.service
    success "headless boot"
else
    success "boot probably headless"
fi

# package munging
info "updating packages"
apt-get update -y && \
    apt-get upgrade -y && \
    apt-get dist-upgrade -y && \
    success "packages up-to-date"
info "trying to update firmware"
rpi-update && success "firmware updated"

for p in $PACKAGES; do
    if dpkg -s "${p}" > /dev/null; then
        success "package ${p} found, skipping"
    else
        info "installing $p"
        apt-get install -y "$p" && success "installed $p"
    fi
done

# configure mysql
if ! grep -E "$MYSQLDB" /etc/mysql/my.cnf > /dev/null; then
    info "mysql looks unconfigured, adjusting"
    systemctl stop mysql
    sed -r -i 's|datadir(\s+)=(.*)|datadir\1= '$MYSQLDB'|' /etc/mysql/my.cnf
    if ! [[ -d "$MYSQLDB" ]]; then
        info "skipping starting mysql, make sure your database is in place first"
    else
        systemctl start mysql
    fi
    success "mysql configured"
else
    success "mysql already setup, skipping"
fi

# certbot
# first we need backports for sources
if ! grep jessie-backports /etc/apt/sources.list > /dev/null; then
    info "adding deb-srcs"
    echo "deb-src http://ftp.debian.org/debian jessie-backports main" >> /etc/apt/sources.list
    echo "deb http://ftp.debian.org/debian jessie-backports main" >> /etc/apt/sources.list
    apt-get update || fail "could not get sources, try something like:\ngpg --keyserver pgpkeys.mit.edu --recv-key 8B48AD6246925553 \ngpg -a --export 8B48AD6246925553 | sudo apt-key add - \n"
    success "added apt sources"
else
    success "apt sources present, skipping"
fi

if ! [[ -d /etc/letsencrypt/live ]]; then
    info "lets encrypt!"
    apt-get install -t jessie-backports certbot
    sed -r -i 's/#ServerName.*/ServerName '$DOMAIN'/'
    certbot --apache
    info "testing automatic renewal"

    certbot
    success "encryption is great!"
else
    success "already encrypted, great!"
fi

# certbot service
if ! [[ -f /etc/systemd/system/certbot.service ]]; then
    info "adding certbot renewal service"
    cat <<EOF | tee /etc/systemd/system/certbot.service > /dev/null
[Unit]
Description=Let's Encrypt renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew
EOF
    success "added certbot renewal service"
else
    success "certbot service already present"
fi

if ! [[ -f /etc/systemd/system/certbot.timer ]]; then
    info "adding certbot renewal service"
    cat <<EOF | tee /etc/systemd/system/certbot.timer > /dev/null
[Unit]
Description=Daily renewal of Let's Encrypt's certificates

[Timer]
OnCalendar=daily
RandomizedDelaySec=1day
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl start certbot.service && systemctl enable certbot.timer
    success "added certbot renewal service"
else
    success "certbot service already present"
fi

# owncloud
if ! dpkg -s owncloud > /dev/null; then

    info "adding opensuse owncloud repo"
    OWNCLOUDWORK=$(mktemp -d)
    pushd $OWNCLOUDWORK
    wget -nv https://download.owncloud.org/download/repositories/9.1/Debian_8.0/Release.key -O Release.key
    apt-key add - < Release.key
    popd
    rm -r $OWNCLOUDWORK

    echo 'deb http://download.owncloud.org/download/repositories/9.1/Debian_8.0/ /' > /etc/apt/sources.list.d/owncloud.list
    apt-get update
    info "installing owncloud"
    apt-get install -y owncloud && success "successfully installed owncloud!"
else
    success "owncloud already installed"
fi

cp $DIR/owncloud/config.php /etc/owncloud/config.php
success "configured owncloud!"

exit 0

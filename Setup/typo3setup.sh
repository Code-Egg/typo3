#!/usr/bin/env bash
set -euo pipefail

function usage
{
    echo 'Usage:'
    echo '  bash typo3setup.sh'
    echo '  DB_NAME=typo3db DB_USER=typo3user DB_PASS='StrongPass' DOMAIN=example.com bash typo3setup.sh'
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

DB_NAME="${DB_NAME:-typo3db}"
DB_USER="${DB_USER:-typo3user}"
DB_PASS="${DB_PASS:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)}"
SITE_DIR="${SITE_DIR:-/var/www/vhosts/localhost/html}"
TYPO3_VERSION="${TYPO3_VERSION:-^12.4}"
DOMAIN="${DOMAIN:-localhost}"
PHP_VER="${PHP_VER:-8.2}"
LSWSFD="${LSWSFD:-/usr/local/lsws}"
DOCHM="${DOCHM:-/var/www/html.old}"
DOCLAND="${DOCLAND:-/var/www/html}"
PHPCONF="${PHPCONF:-/var/www/phpmyadmin}"
LSWSVCONF="${LSWSVCONF:-${LSWSFD}/conf/vhosts}"
LSWSCONF="${LSWSCONF:-${LSWSFD}/conf/httpd_config.conf}"
WPVHCONF="${WPVHCONF:-${LSWSFD}/conf/vhosts/wordpress/vhconf.conf}"
EXAMPLECONF="${EXAMPLECONF:-${LSWSFD}/conf/vhosts/wordpress/vhconf.conf}"
PHPVERD="${PHPVERD:-8.4}"

log() {
  printf "\n==> %s\n" "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

configure_ols_repo() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release

  if [[ ! -f /etc/apt/trusted.gpg.d/lst_debian_repo.gpg ]]; then
    curl -fsSL https://repo.litespeed.sh | bash
  fi
}

install_packages() {
  apt-get update

  apt-get install -y \
    openlitespeed \
    mariadb-server \
    curl \
    unzip \
    git \
    software-properties-common

  apt-get install -y \
    lsphp${PHP_VER/./} \
    lsphp${PHP_VER/./}-common \
    lsphp${PHP_VER/./}-mysql \
    lsphp${PHP_VER/./}-curl \
    lsphp${PHP_VER/./}-intl \
    lsphp${PHP_VER/./}-zip \
    lsphp${PHP_VER/./}-xml \
    lsphp${PHP_VER/./}-gd \
    lsphp${PHP_VER/./}-mbstring \
    lsphp${PHP_VER/./}-opcache \
    lsphp${PHP_VER/./}-soap \
    lsphp${PHP_VER/./}-bcmath \
    lsphp${PHP_VER/./}-imagick \
    lsphp${PHP_VER/./}-redis \
    lsphp${PHP_VER/./}-sodium \
    composer
}

configure_php_handler() {
  local ols_conf="/usr/local/lsws/conf/httpd_config.conf"

  if ! grep -q "lsphp${PHP_VER/./}" "$ols_conf"; then
    cat >>"$ols_conf" <<EOF

extprocessor lsphp${PHP_VER/./} {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp${PHP_VER/./}.sock
  maxConns                35
  env                     PHP_LSAPI_CHILDREN=35
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    /usr/local/lsws/lsphp${PHP_VER/./}/bin/lsphp
  backlog                 100
  instances               1
  extUser                 nobody
  extGroup                nogroup
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}

scriptHandler {
  add                     lsapi:lsphp${PHP_VER/./} php
}
EOF
  fi
}

configure_db() {
  mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
}

install_typo3() {
  rm -rf "$SITE_DIR"
  mkdir -p "$SITE_DIR"

  require_cmd composer

  cd "$SITE_DIR"
  composer create-project typo3/cms-base-distribution:"${TYPO3_VERSION}" . --no-interaction

  chown -R nobody:nogroup "$SITE_DIR"
  find "$SITE_DIR" -type d -exec chmod 755 {} \;
  find "$SITE_DIR" -type f -exec chmod 644 {} \;

  mkdir -p "$SITE_DIR/public/fileadmin" "$SITE_DIR/var"
  touch "$SITE_DIR/public/FIRST_INSTALL"
  chown -R nobody:nogroup "$SITE_DIR/public/fileadmin" "$SITE_DIR/var"
}

configure_virtual_host() {
  local vhost_conf="/usr/local/lsws/conf/vhosts/localhost/vhconf.conf"
  mkdir -p /usr/local/lsws/conf/vhosts/localhost

  cat >"$vhost_conf" <<EOF
docRoot                   ${SITE_DIR}/public/
enableGzip                1

index  {
  useServer               0
  indexFiles              index.php, index.html
}

context / {
  allowBrowse             1
  rewrite  {
    enable                1
    autoLoadHtaccess      1
  }
  addDefaultCharset       off
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
EOF
}

secure_typo3_dirs() {
  cat >"${SITE_DIR}/public/.htaccess" <<'EOF'
<IfModule LiteSpeed>
RewriteEngine On
RewriteRule ^(?:fileadmin/|typo3conf/|typo3temp/|uploads/|favicon\.ico|robots\.txt) - [L]
RewriteRule ^(?:typo3/|index\.php)(?:$|/) - [L]
RewriteRule .* index.php [L]
</IfModule>
EOF
}

start_services() {
  systemctl enable mariadb lsws
  systemctl restart mariadb
  /usr/local/lsws/bin/lswsctrl restart
}

print_summary() {
  local ip
  ip="$(hostname -I | awk '{print $1}')"

  cat <<EOF

OpenLiteSpeed + TYPO3 setup complete.

Site URL:
  http://${DOMAIN}
  http://${ip}

TYPO3 install tool:
  http://${DOMAIN}/typo3/install.php

Database:
  Name: ${DB_NAME}
  User: ${DB_USER}
  Pass: ${DB_PASS}

Web root:
  ${SITE_DIR}/public

OpenLiteSpeed admin:
  http://${ip}:7080
  Username: admin
  Password: (set with /usr/local/lsws/admin/misc/admpass.sh)
EOF
}

main() {
  log "Configuring OpenLiteSpeed repository"
  configure_ols_repo

  log "Installing OpenLiteSpeed, PHP, MariaDB, and utilities"
  install_packages

  log "Configuring OpenLiteSpeed PHP handler"
  configure_php_handler

  log "Configuring MariaDB database/user for TYPO3"
  configure_db

  log "Installing TYPO3"
  install_typo3

  log "Configuring OpenLiteSpeed virtual host"
  configure_virtual_host

  log "Adding TYPO3 rewrite rules"
  secure_typo3_dirs

  log "Starting services"
  start_services

  print_summary
}

main "$@"

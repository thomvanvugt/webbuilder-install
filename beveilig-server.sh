#!/bin/sh
# Webbuilder - de computer zelf beveiligen (Debian/Ubuntu).
#
#   cd /opt/webbuilder && sudo sh beveilig-server.sh
#
# install.sh roept dit aan; je kunt het ook later (opnieuw) draaien. Elke stap
# wordt eerst gevraagd:
#   1. automatische beveiligingsupdates, en zo nodig 's nachts om 05:00
#      herstarten (na de back-up van 04:00) - bv. na een kernel-update;
#   2. SSH alleen nog met een sleutel (geen wachtwoorden, niet als root);
#   3. firewall: alleen open wat nodig is (bij NetBird: alles via de tunnel,
#      plus SSH vanaf het lokale netwerk als noodroute).
set -eu

DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() {
  if (exec < /dev/tty) 2>/dev/null; then
    printf '%s%s: ' "$1" "${2:+ [$2]}" > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    answer=""
  fi
  [ -n "$answer" ] && echo "$answer" || echo "${2:-}"
}
env_get() { sed -n "s/^$1=//p" "$DIR/.env" 2>/dev/null | tail -n1; }

[ "$(id -u)" -eq 0 ] || { echo "Draai dit met sudo: sudo sh beveilig-server.sh"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "Dit script is voor Debian/Ubuntu; sla het over op andere systemen."; exit 0; }
MODE="${ACCESS_MODE:-$(env_get ACCESS_MODE)}"
PORT="${FRONTEND_PORT:-$(env_get FRONTEND_PORT)}"

# --- 1. Automatische updates ----------------------------------------------
if [ "$(ask 'Automatische beveiligingsupdates aanzetten (en zo nodig herstarten om 05:00)? (j/n)' j)" = "j" ]; then
  apt-get install -y -q unattended-upgrades >/dev/null
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
  cat > /etc/apt/apt.conf.d/52webbuilder-upgrades <<'CONF'
// Webbuilder: na een update die een herstart nodig heeft (bv. de kernel)
// 's nachts herstarten, na de back-up van 04:00. De website start daarna
// vanzelf weer op.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
CONF
  echo "Aan."
fi

# --- 2. SSH alleen met sleutel ---------------------------------------------
if [ -d /etc/ssh ] && command -v sshd >/dev/null 2>&1; then
  say "SSH (inloggen op afstand)"
  echo "Advies: alleen inloggen met een SSH-sleutel. Plak de PUBLIEKE sleutel van de beheerder"
  echo "(één regel, begint met ssh-ed25519 of ssh-rsa; staat bv. in ~/.ssh/id_ed25519.pub)."
  KEY=$(ask "Publieke SSH-sleutel (leeg = overslaan)" "")
  if [ -n "$KEY" ]; then
    case "$KEY" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *) ;;
      *) echo "Dat lijkt geen publieke SSH-sleutel; SSH blijft ongewijzigd."; KEY="" ;;
    esac
  fi
  if [ -n "$KEY" ]; then
    U="${SUDO_USER:-}"
    [ -n "$U" ] && [ "$U" != "root" ] || U=$(ask "Voor welke gebruiker (niet root)?" "")
    HOME_U=$(getent passwd "$U" | cut -d: -f6)
    if [ -z "$U" ] || [ "$U" = "root" ] || [ -z "$HOME_U" ]; then
      echo "Geen geldige gebruiker; SSH blijft ongewijzigd."
    else
      install -d -m 700 -o "$U" -g "$(id -gn "$U")" "$HOME_U/.ssh"
      touch "$HOME_U/.ssh/authorized_keys"
      grep -qxF "$KEY" "$HOME_U/.ssh/authorized_keys" || echo "$KEY" >> "$HOME_U/.ssh/authorized_keys"
      chown "$U:$(id -gn "$U")" "$HOME_U/.ssh/authorized_keys"; chmod 600 "$HOME_U/.ssh/authorized_keys"
      echo "Sleutel toegevoegd voor $U."
      if [ "$(ask 'Inloggen met wachtwoord en als root nu uitzetten? Test eerst in een TWEEDE venster of inloggen met de sleutel werkt! (j/n)' j)" = "j" ]; then
        mkdir -p /etc/ssh/sshd_config.d
        grep -qi '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config || \
          sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        cat > /etc/ssh/sshd_config.d/10-webbuilder.conf <<'CONF'
# Webbuilder: alleen inloggen met een SSH-sleutel, nooit als root.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
        if sshd -t; then
          systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
          echo "SSH: alleen nog met sleutel."
        else
          rm -f /etc/ssh/sshd_config.d/10-webbuilder.conf
          echo "SSH-instelling klopte niet; teruggedraaid."
        fi
      fi
    fi
  fi
fi

# --- 3. Firewall -----------------------------------------------------------
say "Firewall"
case "$MODE" in
  1) echo "Alles via de NetBird-tunnel; van buiten staat niets open." ;;
  2) echo "Open: SSH (22), HTTP (80) en HTTPS (443)." ;;
  *) echo "Open: SSH (22) en poort ${PORT:-8110} voor je reverse proxy." ;;
esac
if [ "$(ask 'Firewall (ufw) aanzetten? Bestaande ufw-regels worden vervangen. (j/n)' j)" = "j" ]; then
  apt-get install -y -q ufw >/dev/null
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  case "$MODE" in
    1)
      ufw allow in on wt0 comment 'NetBird' >/dev/null
      if [ "$(ask 'SSH ook vanaf het lokale netwerk toestaan (noodroute als NetBird niet werkt)? (j/n)' j)" = "j" ]; then
        for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do ufw allow from "$net" to any port 22 proto tcp comment 'SSH lokaal' >/dev/null; done
      fi
      ;;
    2)
      ufw allow 22/tcp comment 'SSH' >/dev/null
      ufw allow 80/tcp comment 'HTTP' >/dev/null
      ufw allow 443 comment 'HTTPS' >/dev/null
      ;;
    *)
      ufw allow 22/tcp comment 'SSH' >/dev/null
      ufw allow "${PORT:-8110}/tcp" comment 'Webbuilder' >/dev/null
      ;;
  esac
  ufw --force enable >/dev/null
  echo "Aan. Let op: poorten die Docker openzet gaan langs ufw heen; daarom luistert de"
  echo "website bij NetBird alleen op het NetBird-adres en bij Caddy alleen op 127.0.0.1."
fi

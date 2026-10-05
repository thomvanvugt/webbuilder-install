#!/bin/sh
# Webbuilder - starten na het opstarten van de computer.
#
# Wordt door systemd (webbuilder.service) aangeroepen; je hoeft dit normaal
# niet zelf te doen. Het:
#   1. wacht (bij NetBird) tot de NetBird-verbinding er is, zodat de website
#      alleen via de tunnel bereikbaar is en niet op het lokale netwerk;
#   2. ontgrendelt (als de gegevensmap versleuteld is) de map data/ met de
#      sleutel uit de kluis van de beheerder. Is die even niet bereikbaar,
#      dan wordt het elke 30 seconden opnieuw geprobeerd;
#   3. start de website (docker compose up -d).
#
#   sudo sh start.sh start        zie hierboven
#   sudo sh start.sh stop         netjes stoppen en de map weer vergrendelen
#   sudo sh start.sh installeer   de systemd-dienst (webbuilder.service) aanmaken
#   sudo sh start.sh herstelcode  ontgrendelen met de herstelcode (noodroute,
#                                 als de kluis van de beheerder weg is)
set -u

DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$DIR" || exit 1
CIPHER="$DIR/.data-versleuteld"
PLAIN="$DIR/data"
KLUIS_CONF="${KLUIS_CONF:-/etc/webbuilder/kluis.conf}"

log() { echo "[webbuilder] $*"; }
env_get() { sed -n "s/^$1=//p" "$DIR/.env" 2>/dev/null | tail -n1; }
conf_get() { sed -n "s/^$1=//p" "$KLUIS_CONF" 2>/dev/null | tail -n1; }
encrypted() { [ -f "$CIPHER/gocryptfs.conf" ]; }
unlocked() { grep -q " $PLAIN fuse.gocryptfs " /proc/mounts 2>/dev/null; }

# Sleutel uit de kluis (alleen via NetBird bereikbaar). Wordt door gocryptfs
# zelf aangeroepen (-extpass); de sleutel komt nooit op schijf.
sleutel() {
  url=$(conf_get KLUIS_URL); user=$(conf_get KLUIS_USER); pass=$(conf_get KLUIS_PASS)
  [ -n "$url" ] && [ -n "$user" ] || { echo "Geen kluis ingesteld ($KLUIS_CONF)" >&2; return 1; }
  # Wachtwoord via een config-bestand aan curl, niet op de opdrachtregel (anders zichtbaar in ps).
  printf 'user = "%s:%s"\n' "$user" "$pass" | curl -fsS --max-time 15 -K - "$url/$user.key"
}

wacht_op_netbird() {
  [ "$(env_get ACCESS_MODE)" = "1" ] || return 0
  bind=$(env_get FRONTEND_BIND)
  case "$bind" in 0.0.0.0|127.0.0.1|"") return 0 ;; esac
  i=0
  until ip -4 addr 2>/dev/null | grep -q "inet $bind/"; do
    [ $i -eq 0 ] && log "Wachten op NetBird ($bind)..."
    i=$((i + 1))
    if [ $i -ge 300 ]; then
      log "NetBird-adres $bind is er na 10 minuten nog niet; toch starten (de website is dan nog niet bereikbaar)."
      return 0
    fi
    sleep 2
  done
}

ontgrendel() {
  encrypted || return 0
  unlocked && return 0
  i=0
  while :; do
    unlocked && return 0 # bv. intussen met de herstelcode ontgrendeld
    if gocryptfs -q -nosyslog -allow_other -extpass "/bin/sh $DIR/start.sh sleutel" "$CIPHER" "$PLAIN" </dev/null >/dev/null 2>&1; then
      log "Gegevensmap ontgrendeld."
      return 0
    fi
    [ $i -eq 0 ] && log "Kluis van de beheerder niet bereikbaar; elke 30 seconden opnieuw proberen. (Noodroute: sudo sh $DIR/start.sh herstelcode)"
    i=$((i + 1))
    sleep 30
  done
}

# systemd-dienst die dit script bij het opstarten aanroept.
installeer() {
  [ -d /run/systemd/system ] || { echo "(Geen systemd: start na een herstart zelf met: sudo sh $DIR/start.sh start)"; return 0; }
  cat > /etc/systemd/system/webbuilder.service <<UNIT
[Unit]
Description=Webbuilder starten (na NetBird, en na ontgrendelen van de gegevensmap)
After=docker.service netbird.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
RemainAfterExit=yes
Environment=PROJECT_DIR=$DIR
ExecStart=/bin/sh $DIR/start.sh start
ExecStop=/bin/sh $DIR/start.sh stop
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable webbuilder.service >/dev/null 2>&1
  echo "Dienst webbuilder.service ingesteld (start na NetBird en ontgrendelen)."
}

case "${1:-start}" in
  sleutel) sleutel; exit $? ;;
  installeer) installeer ;;
  start)
    wacht_op_netbird
    ontgrendel
    docker compose --project-directory "$DIR" up -d
    ;;
  stop)
    docker compose --project-directory "$DIR" stop
    if unlocked; then fusermount -u "$PLAIN" 2>/dev/null || umount "$PLAIN"; log "Gegevensmap vergrendeld."; fi
    ;;
  herstelcode)
    encrypted || { echo "De gegevensmap is niet versleuteld."; exit 0; }
    unlocked && { echo "De gegevensmap is al ontgrendeld."; exit 0; }
    printf 'Herstelcode (64 tekens, streepjes mogen): ' > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    read -r code < /dev/tty
    stty echo < /dev/tty 2>/dev/null || true
    echo > /dev/tty
    code=$(echo "$code" | tr -cd '0-9a-fA-F')
    if echo "$code" | gocryptfs -q -nosyslog -allow_other -masterkey=stdin "$CIPHER" "$PLAIN" >/dev/null 2>&1; then
      log "Ontgrendeld met de herstelcode."
      docker compose --project-directory "$DIR" up -d
    else
      echo "Dat lukte niet. Klopt de herstelcode?"; exit 1
    fi
    ;;
  *) echo "Gebruik: start.sh start|stop|installeer|herstelcode"; exit 1 ;;
esac

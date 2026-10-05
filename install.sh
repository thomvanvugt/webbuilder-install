#!/bin/sh
# Webbuilder - installatie op een eigen server (Linux met Docker).
#
#   curl -fsSL https://raw.githubusercontent.com/thomvanvugt/webbuilder-install/main/install.sh | sh
#
# of, met een andere map:
#
#   curl -fsSL .../install.sh | INSTALL_DIR=/srv/mijnvereniging sh
#
# Wat dit doet:
#   1. controleert of Docker er is (en biedt aan het te installeren)
#   2. vraagt het domein (bv. www.mijnvereniging.nl) of je eigen proxy-poort
#   3. maakt de map aan met docker-compose.yml, onderhoud.sh en een .env
#      met willekeurig gemaakte wachtwoorden en sleutels
#   4. start alles en laat de link + installatiecode zien
# Daarna open je de website en doorloop je de installatie-wizard.
set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/thomvanvugt/webbuilder-install/main}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/thomvanvugt/webbuilder}"
INSTALL_DIR="${INSTALL_DIR:-/opt/webbuilder}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() { # ask "vraag" "standaard"
  if [ -r /dev/tty ]; then
    printf '%s%s: ' "$1" "${2:+ [$2]}" > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    answer=""
  fi
  [ -n "$answer" ] && echo "$answer" || echo "${2:-}"
}
rand() { head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$1"; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

say "Webbuilder installeren"

# 1. Docker
if ! command -v docker >/dev/null 2>&1; then
  if [ "$(ask 'Docker is niet geinstalleerd. Nu installeren? (j/n)' j)" = "j" ]; then
    curl -fsSL https://get.docker.com | $SUDO sh
  else
    echo "Installeer eerst Docker: https://docs.docker.com/engine/install/"; exit 1
  fi
fi
if ! $SUDO docker compose version >/dev/null 2>&1; then
  echo "De Docker Compose-plugin ontbreekt. Zie https://docs.docker.com/compose/install/"; exit 1
fi

# 2. Map
if [ -f "$INSTALL_DIR/.env" ]; then
  echo "Er staat al een installatie in $INSTALL_DIR."
  echo "Bijwerken gaat vanzelf; handmatig: cd $INSTALL_DIR && docker compose pull && docker compose up -d"
  exit 1
fi
$SUDO mkdir -p "$INSTALL_DIR/data/backups"
cd "$INSTALL_DIR"

say "Bestanden ophalen"
$SUDO curl -fsSL "$REPO_RAW/docker-compose.yml" -o docker-compose.yml
$SUDO curl -fsSL "$REPO_RAW/onderhoud.sh" -o onderhoud.sh

# 3. Vragen
say "Een paar vragen"
DOMAIN=$(ask "Domeinnaam van de website (leeg = ik heb al een eigen reverse proxy)" "")
PROFILES="autoupdate"
BIND="127.0.0.1"
PORT="8110"
if [ -n "$DOMAIN" ]; then
  DOMAIN=$(echo "$DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##')
  PROFILES="https,autoupdate"
  URL="https://$DOMAIN"
  echo "Zorg dat $DOMAIN naar het IP-adres van deze server wijst (A-record bij je domeinprovider)."
  echo "Poort 80 en 443 moeten open staan; het HTTPS-certificaat wordt automatisch aangevraagd."
else
  BIND="0.0.0.0"
  PORT=$(ask "Op welke poort moet de website luisteren? (stuur je proxy hierheen)" "8110")
  URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
fi
AUTO=$(ask "Automatisch bijwerken naar nieuwe versies? (j/n)" j)
[ "$AUTO" = "j" ] && AUTO_UPDATE=true || AUTO_UPDATE=false
NAME=$(basename "$INSTALL_DIR" | tr -cd 'a-z0-9-' )
[ -n "$NAME" ] || NAME=webbuilder
CODE="$(rand 4 | tr 'a-f' 'A-F')-$(rand 4 | tr 'a-f' 'A-F')"

$SUDO sh -c "cat > .env" <<ENV
# Webbuilder - gemaakt door install.sh op $(date '+%Y-%m-%d').
# Deel dit bestand nooit: hier staan de wachtwoorden en sleutels in.
# De meeste instellingen (naam, mail, ...) wijzig je in de website zelf:
# accountmenu -> Systeeminstellingen.

COMPOSE_PROJECT_NAME=$NAME
COMPOSE_PROFILES=$PROFILES
PROJECT_DIR=$INSTALL_DIR
IMAGE_PREFIX=$IMAGE_PREFIX
# "latest" = altijd de nieuwste versie. Vastzetten kan, bv. WEBBUILDER_VERSION=1.2.0
WEBBUILDER_VERSION=latest
AUTO_UPDATE=$AUTO_UPDATE
UPDATE_HOUR=4

DOMAIN=$DOMAIN
FRONTEND_BIND=$BIND
FRONTEND_PORT=$PORT

POSTGRES_USER=webbuilder
POSTGRES_DB=webbuilder
POSTGRES_PASSWORD=$(rand 40)
JWT_SECRET=$(rand 64)
TOTP_ENCRYPTION_KEY=$(rand 64)
# Eenmalige code voor de installatie-wizard.
SETUP_CODE=$CODE
APP_TIMEZONE=Europe/Amsterdam
ENV
$SUDO chmod 600 .env

# 4. Starten
say "Starten (de eerste keer duurt dit een paar minuten)"
$SUDO docker compose pull
$SUDO docker compose up -d

printf 'Wachten tot de website klaar is'
i=0
while [ $i -lt 60 ]; do
  if $SUDO docker compose exec -T backend wget -qO- http://127.0.0.1:4000/health >/dev/null 2>&1; then break; fi
  printf '.'; sleep 5; i=$((i + 1))
done
echo

say "Klaar!"
echo "Open:             $URL/setup?code=$CODE"
echo "Installatiecode:  $CODE"
echo
echo "Map:              $INSTALL_DIR"
echo "Back-ups:         $INSTALL_DIR/data/backups (elke nacht)"
echo "Logs bekijken:    cd $INSTALL_DIR && docker compose logs -f backend"

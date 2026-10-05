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
#   2. vraagt hoe de website bereikbaar wordt:
#        - via NetBird (mini-pc bij een vereniging: geen poorten openzetten,
#          en jij kunt er op afstand bij),
#        - rechtstreeks met eigen domein (server met publiek IP, bv. VPS), of
#        - achter je eigen reverse proxy (bv. Nginx Proxy Manager)
#   3. maakt de map aan met docker-compose.yml, onderhoud.sh en een .env
#      met willekeurig gemaakte wachtwoorden en sleutels
#   4. start alles, koppelt (bij NetBird) het domein en laat de link +
#      installatiecode zien
#   5. biedt aan de computer te beveiligen (updates, SSH, firewall) en - als
#      extra dienst - de beheerservice aan te zetten (externe back-up en
#      versleutelde gegevensmap). Zonder beheerservice werkt alles gewoon lokaal.
# Daarna open je de website en doorloop je de installatie-wizard.
set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/thomvanvugt/webbuilder-install/main}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/thomvanvugt/webbuilder}"
INSTALL_DIR="${INSTALL_DIR:-/opt/webbuilder}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() { # ask "vraag" "standaard"
  if (exec < /dev/tty) 2>/dev/null; then
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
for f in netbird-website.sh start.sh beheerservice.sh beveilig-server.sh; do
  $SUDO curl -fsSL "$REPO_RAW/$f" -o "$f"
done

# 3. Vragen
say "Hoe wordt de website bereikbaar?"
cat <<'TXT'
  1) Via NetBird - voor een mini-pc bij een vereniging (aanbevolen).
     Geen poorten openzetten in de router; jij kunt er op afstand bij.
  2) Rechtstreeks met eigen domein - server met een publiek IP-adres (bv. een VPS).
     HTTPS-certificaat via Caddy; poort 80 en 443 moeten open staan.
  3) Achter mijn eigen reverse proxy (bv. Nginx Proxy Manager).
TXT
MODE=$(ask "Keuze (1, 2 of 3)" "1")
PROFILES="autoupdate"
BIND="127.0.0.1"
PORT="8110"
DOMAIN=""
case "$MODE" in
  1)
    DOMAIN=$(ask "Domeinnaam (bv. mijnvereniging.nl; de website wordt www.mijnvereniging.nl)" "")
    [ -n "$DOMAIN" ] || { echo "Een domeinnaam is nodig."; exit 1; }
    DOMAIN=$(echo "$DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##' -e 's/^www\.//' | tr 'A-Z' 'a-z')
    # NetBird stuurt bezoekers via de tunnel naar deze poort.
    BIND="0.0.0.0"
    URL="https://www.$DOMAIN"
    command -v jq >/dev/null 2>&1 || { $SUDO apt-get update -q >/dev/null 2>&1; $SUDO apt-get install -y -q jq >/dev/null 2>&1; } || { echo "Installeer eerst jq."; exit 1; }
    if ! $SUDO netbird status 2>/dev/null | grep -q "Management: Connected"; then
      echo
      echo "Koppel deze computer aan je NetBird-account. Maak een setup key aan in"
      echo "app.netbird.io -> Setup Keys -> Create Setup Key."
      echo "Kies: eenmalig te gebruiken (One-off), korte geldigheid (bv. 1 dag), en de groep"
      echo "\"webbuilder-kastjes\" (zie README: zo mag dit kastje alleen bij wat nodig is)."
      NB_KEY=$(ask "NetBird setup key" "")
      [ -n "$NB_KEY" ] || { echo "Zonder setup key kan NetBird niet gekoppeld worden."; exit 1; }
      command -v netbird >/dev/null 2>&1 || curl -fsSL https://pkgs.netbird.io/install.sh | $SUDO sh
      $SUDO netbird up --setup-key "$NB_KEY" --hostname "webbuilder-$(echo "$DOMAIN" | tr '.' '-')"
    else
      echo "Deze computer is al met NetBird verbonden."
    fi
    # De website luistert alleen op het NetBird-adres: bereikbaar via de
    # tunnel (voor bezoekers via de NetBird-proxy, en voor jou), niet op het
    # lokale netwerk van de vereniging.
    i=0
    NB_IP=""
    while [ -z "$NB_IP" ] && [ $i -lt 30 ]; do
      NB_IP=$($SUDO netbird status --json 2>/dev/null | jq -r '.netbirdIp // empty' | cut -d/ -f1)
      [ -n "$NB_IP" ] || sleep 2
      i=$((i + 1))
    done
    [ -n "$NB_IP" ] || { echo "NetBird heeft nog geen adres. Controleer: netbird status"; exit 1; }
    BIND="$NB_IP"
    ;;
  2)
    DOMAIN=$(ask "Domeinnaam van de website (bv. www.mijnvereniging.nl)" "")
    [ -n "$DOMAIN" ] || { echo "Een domeinnaam is nodig."; exit 1; }
    DOMAIN=$(echo "$DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##')
    PROFILES="https,autoupdate"
    URL="https://$DOMAIN"
    echo "Zorg dat $DOMAIN naar het IP-adres van deze server wijst (A-record bij je domeinprovider)."
    echo "Poort 80 en 443 moeten open staan; het HTTPS-certificaat wordt automatisch aangevraagd."
    ;;
  *)
    BIND="0.0.0.0"
    PORT=$(ask "Op welke poort moet de website luisteren? (stuur je proxy hierheen)" "8110")
    URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
    ;;
esac
AUTO=$(ask "Automatisch bijwerken naar nieuwe versies? (j/n)" j)
[ "$AUTO" = "j" ] && AUTO_UPDATE=true || AUTO_UPDATE=false
DELAY=0
if [ "$AUTO_UPDATE" = "true" ]; then
  DELAY=$(ask "Nieuwe versies na hoeveel dagen installeren? (0 = meteen, voor een testkastje)" 3)
  case "$DELAY" in ''|*[!0-9]*) DELAY=3 ;; esac
fi

say "Meldingen en bewaking (optioneel)"
echo "Krijg een pushmelding (ntfy-app) als er iets misgaat, en laat Uptime Kuma"
echo "bewaken of dit kastje nog leeft. Leeg laten = uit (kan later in .env)."
echo "Gebruik je straks de beheerservice, laat dit dan leeg: dat regelt de koppelcode."
NTFY=$(ask "ntfy-adres (bv. https://ntfy.voorbeeld.nl/webbuilder-vereniging)" "")
NTFY_TOKEN=""
[ -n "$NTFY" ] && NTFY_TOKEN=$(ask "ntfy-token (leeg als je server er geen vraagt)" "")
HEARTBEAT=$(ask "Uptime Kuma push-adres (leeg = geen)" "")
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
# Nieuwe versies pas na zoveel dagen installeren (0 = meteen; testkastjes).
UPDATE_DELAY_DAYS=$DELAY

# Bereikbaarheid: 1 = NetBird, 2 = Caddy (eigen domein), 3 = eigen reverse proxy
ACCESS_MODE=$MODE
DOMAIN=$DOMAIN
FRONTEND_BIND=$BIND
FRONTEND_PORT=$PORT
# Aantal proxies vóór de backend (NetBird/Caddy/eigen proxy + de website zelf).
# Zo ziet de website het echte IP-adres van bezoekers. Controleren kan in
# Systeeminstellingen -> Verbinding.
TRUST_PROXY=2

# Meldingen (ntfy) en bewaking (Uptime Kuma push). Leeg = uit.
NTFY_URL=$NTFY
NTFY_TOKEN=$NTFY_TOKEN
HEARTBEAT_URL=$HEARTBEAT

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

if [ "$MODE" = "1" ]; then
  # Na een herstart eerst op NetBird wachten (de website luistert op dat adres).
  $SUDO env PROJECT_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/start.sh" installeer || true
  say "Website koppelen via NetBird"
  $SUDO env PROJECT_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/netbird-website.sh" || \
    echo "Koppelen is nog niet gelukt. Later opnieuw: cd $INSTALL_DIR && sudo sh netbird-website.sh"
fi

say "De computer beveiligen"
$SUDO env PROJECT_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/beveilig-server.sh" || \
  echo "Later opnieuw: cd $INSTALL_DIR && sudo sh beveilig-server.sh"

say "Beheerservice (optioneel)"
cat <<'TXT'
Extra dienst van de beheerder:
  - elke nacht een versleutelde back-up buiten de deur (niet te wissen vanaf hier);
  - een versleutelde gegevensmap (onleesbaar als de computer wordt gestolen);
  - meldingen en bewaking.
Zonder beheerservice werkt alles gewoon lokaal, met elke nacht een back-up op deze computer.
Je hebt er een koppelcode van de beheerder voor nodig. Later aanzetten kan ook:
  cd <map van de installatie> && sudo sh beheerservice.sh
TXT
if [ "$(ask 'Beheerservice nu aanzetten? (j/n)' n)" = "j" ]; then
  $SUDO env PROJECT_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/beheerservice.sh" || \
    echo "Nog niet gelukt. Later opnieuw: cd $INSTALL_DIR && sudo sh beheerservice.sh"
fi

say "Klaar!"
echo "Open:             $URL/setup?code=$CODE"
echo "Installatiecode:  $CODE"
echo
echo "Map:              $INSTALL_DIR"
echo "Back-ups:         $INSTALL_DIR/data/backups (elke nacht)"
echo "Beheerservice:    cd $INSTALL_DIR && sudo sh beheerservice.sh status"
echo "Logs bekijken:    cd $INSTALL_DIR && docker compose logs -f backend"
if [ "$MODE" = "1" ]; then
  echo
  echo "Beheer op afstand: verbind je eigen laptop met NetBird en gebruik"
  echo "                  ssh <gebruiker>@${NB_IP:-<NetBird-IP van deze computer>}"
fi

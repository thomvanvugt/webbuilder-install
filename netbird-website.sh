#!/bin/sh
# Webbuilder - de website via NetBird bereikbaar maken voor bezoekers.
#
# Zet in NetBird (via de API) een "reverse proxy service" klaar:
#   https://www.<domein>  ->  deze computer, poort FRONTEND_PORT
# NetBird regelt het HTTPS-certificaat; bij de vereniging hoeft er niets
# open in de router. install.sh roept dit script aan; je kunt het ook later
# los draaien (bv. als het DNS-record er nog niet was):
#
#   cd /opt/webbuilder && sudo sh netbird-website.sh
#
# Nodig: deze computer is al met "netbird up" aan je NetBird-account gekoppeld,
# en een NetBird API-token (Settings -> Personal Access Tokens). Het token wordt
# alleen tijdens dit script gebruikt en NERGENS opgeslagen. Maak het met een
# korte geldigheid (1 dag) en verwijder het daarna in het dashboard.
#
# Ook:
#   - alleen een EU-proxycluster (adres begint met eu, bv. eu1.netbird.services) wordt gebruikt
#     (AVG: bezoekersverkeer via de EU). Anders stopt het script;
#   - deze computer komt in de NetBird-groep "webbuilder-kastjes", zodat je
#     met policies kunt regelen waar hij wel en niet bij mag;
#   - een waarschuwing als de "Default"-policy (iedereen mag overal bij) nog aan staat.
set -eu

API="${NB_API_URL:-https://api.netbird.io}"
DIR="${PROJECT_DIR:-$(pwd)}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mFOUT:\033[0m %s\n' "$*" >&2; exit 1; }
ask() {
  if (exec < /dev/tty) 2>/dev/null; then
    printf '%s%s: ' "$1" "${2:+ [$2]}" > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    answer=""
  fi
  [ -n "$answer" ] && echo "$answer" || echo "${2:-}"
}
ask_secret() {
  (exec < /dev/tty) 2>/dev/null || { echo ""; return; }
  printf '%s: ' "$1" > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || true
  read -r answer < /dev/tty || answer=""
  stty echo < /dev/tty 2>/dev/null || true
  echo > /dev/tty
  echo "$answer"
}
env_get() { [ -f "$DIR/.env" ] && sed -n "s/^$1=//p" "$DIR/.env" | tail -n1; }

command -v jq >/dev/null 2>&1 || fail "jq ontbreekt (installeer met: apt-get install -y jq)."
command -v netbird >/dev/null 2>&1 || fail "NetBird is niet geinstalleerd op deze computer."

DOMAIN="${DOMAIN:-$(env_get DOMAIN)}"
PORT="${FRONTEND_PORT:-$(env_get FRONTEND_PORT)}"
PORT="${PORT:-8110}"
[ -n "$DOMAIN" ] || DOMAIN=$(ask "Domeinnaam (bv. mijnvereniging.nl)" "")
[ -n "$DOMAIN" ] || fail "Geen domeinnaam opgegeven."
BASE=$(echo "$DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##' -e 's/^www\.//' | tr 'A-Z' 'a-z')
SITE="www.$BASE"

TOKEN="${NB_API_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo
  echo "Voor het automatisch instellen is een NetBird API-token nodig:"
  echo "  app.netbird.io -> Settings -> Personal Access Tokens -> Create Token"
  echo "  (kies een korte geldigheid, bv. 1 dag; het token wordt nergens opgeslagen)"
  echo "(Leeg laten = de stappen voor het NetBird-dashboard laten zien.)"
  TOKEN=$(ask_secret "NetBird API-token")
fi

if [ -z "$TOKEN" ]; then
  say "Handmatig instellen in het NetBird-dashboard"
  cat <<TXT
0. Zet deze computer in de groep "webbuilder-kastjes" (Peers -> deze computer -> Groups)
1. Reverse Proxy -> Custom Domains -> Add Domain: $BASE (kies het EU-cluster, bv. eu1.netbird.services - alleen EU!)
2. Zet bij je domeinprovider:  CNAME  *.$BASE  ->  (het adres dat NetBird toont, bv. eu1.netbird.services)
   en klik daarna in NetBird op "Verify Domain".
3. Reverse Proxy -> Services -> Add Service:
     domein  $SITE
     doel    Peer: deze computer ($(hostname)), protocol http, poort $PORT
TXT
  exit 0
fi

api() { # api METHODE PAD [JSON]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" "$API$2" -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" -d "$3"
  else
    curl -sS -X "$1" "$API$2" -H "Authorization: Token $TOKEN" -H "Accept: application/json"
  fi
}

say "NetBird controleren"
NB_IP=$(netbird status --json 2>/dev/null | jq -r '.netbirdIp // empty' | cut -d/ -f1)
[ -n "$NB_IP" ] || fail "Deze computer is niet verbonden met NetBird. Draai eerst: netbird up --setup-key <sleutel>"
PEERS=$(api GET "/api/peers?ip=$NB_IP")
echo "$PEERS" | jq -e 'type == "array"' >/dev/null 2>&1 || fail "API-token klopt niet of heeft geen rechten: $(echo "$PEERS" | head -c 200)"
PEER_ID=$(echo "$PEERS" | jq -r '.[0].id // empty')
[ -n "$PEER_ID" ] || fail "Deze computer ($NB_IP) staat niet in je NetBird-account."
echo "Deze computer: $(echo "$PEERS" | jq -r '.[0].name') ($NB_IP)"

say "Toegang (groepen en policies)"
GROUP="${NB_GROUP:-webbuilder-kastjes}"
G=$(api GET /api/groups | jq -c --arg g "$GROUP" '[.[]? | select(.name == $g)][0] // empty')
if [ -z "$G" ]; then
  RES=$(api POST /api/groups "$(jq -nc --arg g "$GROUP" --arg p "$PEER_ID" '{name: $g, peers: [$p]}')")
  if echo "$RES" | jq -e '.id' >/dev/null 2>&1; then echo "Groep $GROUP aangemaakt met deze computer erin."; else echo "Let op: groep $GROUP aanmaken lukte niet: $(echo "$RES" | head -c 200)"; fi
elif ! echo "$G" | jq -e --arg p "$PEER_ID" '[.peers[]? | (.id // .)] | index($p)' >/dev/null; then
  BODY=$(echo "$G" | jq -c --arg p "$PEER_ID" '{name: .name, peers: ([.peers[]? | (.id // .)] + [$p] | unique)}')
  RES=$(api PUT "/api/groups/$(echo "$G" | jq -r '.id')" "$BODY")
  if echo "$RES" | jq -e '.id' >/dev/null 2>&1; then echo "Deze computer is toegevoegd aan groep $GROUP."; else echo "Let op: toevoegen aan $GROUP lukte niet: $(echo "$RES" | head -c 200)"; fi
else
  echo "Deze computer zit al in groep $GROUP."
fi
OPEN=$(api GET /api/policies | jq -r '[.[]? | select(.enabled) | select(any(.rules[]?; any(.sources[]?; (.name // .) == "All") and any(.destinations[]?; (.name // .) == "All"))) | .name] | join(", ")' 2>/dev/null || true)
if [ -n "$OPEN" ]; then
  cat <<TXT
LET OP: de policy "$OPEN" staat aan. Daarmee mag elk apparaat in je NetBird bij
elk ander apparaat - dus ook dit kastje bij je eigen computers, en de kastjes
onderling. Zet hem uit en maak in plaats daarvan (Access Control -> Policies):
  - "beheer -> $GROUP"          jouw eigen apparaten mogen bij de kastjes (SSH, poort 8110)
  - "$GROUP -> beheerservice"   alleen naar de poorten van de back-upserver/kluis/meldingen
Zie de README, onderdeel "NetBird-toegang".
TXT
else
  echo "Geen open \"iedereen mag overal bij\"-policy gevonden."
fi

CLUSTERS=$(api GET /api/reverse-proxies/clusters)
CLUSTER=$(echo "$CLUSTERS" | jq -r '[.[]? | select(.online != false) | select(.address | test("^eu[0-9]*[.-]"))][0].address // empty')
if [ -z "$CLUSTER" ]; then
  [ "${NB_ALLOW_NON_EU:-}" = "1" ] || fail "Geen proxy-cluster in de EU (eu…) gevonden ($(echo "$CLUSTERS" | jq -r '[.[]?.address] | join(", ")' 2>/dev/null)). Voor de AVG loopt bezoekersverkeer alleen via de EU. Bewust anders? Draai dan met NB_ALLOW_NON_EU=1."
  CLUSTER=$(echo "$CLUSTERS" | jq -r '[.[]? | select(.online != false)][0].address // empty')
  [ -n "$CLUSTER" ] || fail "Geen NetBird proxy-cluster gevonden. Staat Reverse Proxy aan in je account?"
fi
echo "Proxy-cluster: $CLUSTER"

say "Domein $BASE"
domain_json() { api GET /api/reverse-proxies/domains | jq -c --arg d "$BASE" '[.[] | select(.domain == $d)][0] // empty'; }
DOM=$(domain_json)
if [ -z "$DOM" ]; then
  RES=$(api POST /api/reverse-proxies/domains "$(jq -nc --arg d "$BASE" --arg c "$CLUSTER" '{domain: $d, target_cluster: $c}')")
  echo "$RES" | jq -e '.id' >/dev/null 2>&1 || fail "Domein toevoegen lukte niet: $(echo "$RES" | head -c 300)"
  DOM=$(domain_json)
fi
DOM_ID=$(echo "$DOM" | jq -r '.id')
TARGET=$(echo "$DOM" | jq -r '.target_cluster // empty')
[ -n "$TARGET" ] || TARGET="$CLUSTER"

if [ "$(echo "$DOM" | jq -r '.validated')" != "true" ]; then
  cat <<TXT

Zet deze DNS-records bij de site waar je het domein hebt gekocht:

  Type    Naam                Waarde
  CNAME   *  (= *.$BASE)       $TARGET

  - Staat er al een record voor "www", haal dat dan weg (anders gaat www niet naar NetBird).
  - Het domein zonder www ($BASE) kun je bij je provider laten doorsturen
    ("URL-doorverwijzing") naar https://$SITE
  - Staan er CAA-records op je domein, voeg dan ook toe: CAA 0 issue "sectigo.com" en CAA 0 issuewild "sectigo.com"

Een nieuw record werkt meestal binnen een paar minuten, soms pas na een paar uur.
Je hebt 48 uur; daarna moet je dit script opnieuw draaien.
TXT
  tries=0
  while :; do
    tries=$((tries + 1))
    if (exec < /dev/tty) 2>/dev/null; then
      k=$(ask "Druk op Enter als het record staat (of typ 'later' om te stoppen)" "")
    else
      # Geen toetsenbord (automatisch gestart): elke 20 seconden opnieuw, max. 15 minuten.
      [ $tries -gt 45 ] && k="later" || { sleep 20; k=""; }
    fi
    if [ "$k" = "later" ]; then
      echo "Prima. Draai later opnieuw: cd $DIR && sudo sh netbird-website.sh"
      exit 0
    fi
    api GET "/api/reverse-proxies/domains/$DOM_ID/validate" >/dev/null || true
    sleep 3
    if [ "$(domain_json | jq -r '.validated')" = "true" ]; then echo "Domein bevestigd."; break; fi
    echo "Nog niet gevonden. Controleer het record (of wacht nog even) en probeer opnieuw."
  done
else
  echo "Domein is al bevestigd."
fi

say "Website $SITE koppelen"
SERVICES=$(api GET /api/reverse-proxies/services)
SVC_ID=$(echo "$SERVICES" | jq -r --arg s "$SITE" '[.[] | select(.domain == $s)][0].id // empty')
BODY=$(jq -nc --arg n "webbuilder-$BASE" --arg s "$SITE" --arg p "$PEER_ID" --argjson port "$PORT" '{
  name: $n, domain: $s, mode: "http", enabled: true, pass_host_header: true,
  targets: [{ target_id: $p, target_type: "peer", protocol: "http", port: $port, path: "/", enabled: true }]
}')
if [ -n "$SVC_ID" ]; then
  RES=$(api PUT "/api/reverse-proxies/services/$SVC_ID" "$BODY")
else
  RES=$(api POST /api/reverse-proxies/services "$BODY")
fi
echo "$RES" | jq -e '.id' >/dev/null 2>&1 || fail "Website koppelen lukte niet: $(echo "$RES" | head -c 300)"
SVC_ID=$(echo "$RES" | jq -r '.id')

printf 'Wachten op het HTTPS-certificaat'
i=0
while [ $i -lt 40 ]; do
  ST=$(api GET "/api/reverse-proxies/services/$SVC_ID" | jq -r '.meta.status // empty')
  [ "$ST" = "active" ] && break
  printf '.'; sleep 6; i=$((i + 1))
done
echo
if [ "${ST:-}" = "active" ]; then
  say "Klaar: https://$SITE"
else
  echo "De koppeling staat klaar (status: ${ST:-onbekend}). Het certificaat kan nog een paar minuten duren."
  echo "Kijk in het NetBird-dashboard onder Reverse Proxy -> Services."
fi

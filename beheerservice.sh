#!/bin/sh
# Webbuilder - beheerservice aanzetten (optioneel).
#
# Zonder beheerservice werkt alles gewoon lokaal: de website draait op deze
# computer, met elke nacht een back-up op dezelfde computer.
# Met de beheerservice komt daar bij:
#   - elke nacht een versleutelde back-up (database, uploads, instellingen)
#     naar de back-upserver van de beheerder, via NetBird. Die server staat
#     op "append-only": vanaf deze computer kan niets worden gewist;
#   - (optioneel) een versleutelde gegevensmap: de map data/ wordt pas na het
#     opstarten ontgrendeld met een sleutel uit de kluis van de beheerder.
#     Wordt de computer gestolen, dan haalt de beheerder hem uit NetBird en
#     zijn de gegevens onleesbaar. Noodroute: de herstelcode;
#   - meldingen en een "leeft hij nog"-signaal naar de beheerder.
#
#   cd /opt/webbuilder && sudo sh beheerservice.sh             aanzetten (vraagt om de koppelcode)
#   sudo sh beheerservice.sh versleutel                        alleen de gegevensmap versleutelen
#   sudo sh beheerservice.sh status                            hoe staat het ervoor
#   sudo sh beheerservice.sh herstel-extern                    laatste externe back-up terughalen
#   sudo sh beheerservice.sh uitzetten                         externe back-up uitzetten
#
# De koppelcode maakt de beheerder op zijn server met: sudo sh beheer.sh nieuw <naam>
set -eu

DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$DIR"
KLUIS_DIR=/etc/webbuilder
KLUIS_CONF="$KLUIS_DIR/kluis.conf"
CIPHER="$DIR/.data-versleuteld"
PLAIN="$DIR/data"
DC="docker compose --project-directory $DIR"

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
env_get() { sed -n "s/^$1=//p" "$DIR/.env" 2>/dev/null | tail -n1; }
env_set() { # env_set SLEUTEL waarde  (leeg = weghalen)
  sed -i "/^$1=/d" "$DIR/.env"
  [ -z "$2" ] || printf '%s=%s\n' "$1" "$2" >> "$DIR/.env"
}
encrypted() { [ -f "$CIPHER/gocryptfs.conf" ]; }
unlocked() { grep -q " $PLAIN fuse.gocryptfs " /proc/mounts 2>/dev/null; }

[ "$(id -u)" -eq 0 ] || fail "Draai dit met sudo: sudo sh beheerservice.sh"
[ -f "$DIR/.env" ] || fail "Geen installatie gevonden in $DIR (geen .env)."

# --- Koppelcode lezen ------------------------------------------------------
# WB1:<base64 van regels SLEUTEL=waarde>. Alleen bekende sleutels en veilige
# tekens worden geaccepteerd (er wordt niets uitgevoerd).
KEYS="VERENIGING OFFSITE_REPO OFFSITE_PASSWORD KLUIS_URL KLUIS_USER KLUIS_PASS NTFY_URL NTFY_TOKEN HEARTBEAT_URL BACKUP_HEARTBEAT_URL"
read_code() {
  code=$(echo "$1" | tr -d ' \r\n')
  case "$code" in WB1:*) ;; *) fail "Dit is geen geldige koppelcode (moet beginnen met WB1:)." ;; esac
  decoded=$(echo "${code#WB1:}" | base64 -d 2>/dev/null) || fail "De koppelcode is beschadigd (niet volledig gekopieerd?)."
  for k in $KEYS; do
    v=$(printf '%s\n' "$decoded" | sed -n "s/^$k=//p" | head -n1)
    case "$v" in *[!A-Za-z0-9:/._@?=\&%+-]*) fail "Ongeldige waarde voor $k in de koppelcode." ;; esac
    eval "KC_$k=\$v"
  done
  [ -n "$KC_OFFSITE_REPO" ] && [ -n "$KC_OFFSITE_PASSWORD" ] || fail "De koppelcode mist de back-upgegevens."
}

test_offsite() {
  RESTIC_REPOSITORY="$1" RESTIC_PASSWORD="$2" docker run --rm --network host -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    restic/restic:latest cat config >/dev/null 2>&1 && return 0
  RESTIC_REPOSITORY="$1" RESTIC_PASSWORD="$2" docker run --rm --network host -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    restic/restic:latest init
}

aanzetten() {
  say "Beheerservice aanzetten"
  cat <<'TXT'
Je hebt een koppelcode nodig van de beheerder (begint met WB1:).
Die maakt hij op zijn server met:  sudo sh beheer.sh nieuw <naam>
TXT
  code=$(ask "Koppelcode" "")
  [ -n "$code" ] || fail "Geen koppelcode opgegeven."
  read_code "$code"

  say "Verbinding met de back-upserver controleren"
  docker pull -q restic/restic:latest >/dev/null
  test_offsite "$KC_OFFSITE_REPO" "$KC_OFFSITE_PASSWORD" >/dev/null || fail "De back-upserver is niet bereikbaar. Is deze computer met NetBird verbonden en mag hij (NetBird-policy) bij de server van de beheerder?"
  echo "In orde."

  env_set OFFSITE_REPO "$KC_OFFSITE_REPO"
  env_set OFFSITE_PASSWORD "$KC_OFFSITE_PASSWORD"
  for k in NTFY_URL NTFY_TOKEN HEARTBEAT_URL BACKUP_HEARTBEAT_URL; do
    eval "v=\$KC_$k"
    [ -n "$v" ] && env_set "$k" "$v"
  done
  if [ -n "$KC_KLUIS_URL" ]; then
    mkdir -p "$KLUIS_DIR"; chmod 700 "$KLUIS_DIR"
    umask 077
    printf 'KLUIS_URL=%s\nKLUIS_USER=%s\nKLUIS_PASS=%s\n' "$KC_KLUIS_URL" "$KC_KLUIS_USER" "$KC_KLUIS_PASS" > "$KLUIS_CONF"
    chmod 600 "$KLUIS_CONF"
  fi
  chmod 600 "$DIR/.env"

  say "Eerste externe back-up maken"
  $DC up -d onderhoud >/dev/null 2>&1
  sleep 3
  $DC exec -T onderhoud sh onderhoud.sh backup >/dev/null && $DC exec -T onderhoud sh onderhoud.sh offsite || \
    echo "De eerste externe back-up lukte nog niet; vannacht wordt het opnieuw geprobeerd."

  if [ -n "$KC_KLUIS_URL" ] && ! encrypted; then
    echo
    echo "Ook de gegevensmap versleutelen? Dan zijn de gegevens onleesbaar als de computer"
    echo "wordt gestolen. De computer heeft na elke herstart even de kluis van de beheerder nodig."
    if [ "$(ask 'Versleutelen? (j/n)' j)" = "j" ]; then versleutel; fi
  fi
  say "Beheerservice staat aan."
}

# --- Gegevensmap versleutelen ---------------------------------------------
versleutel() {
  encrypted && { echo "De gegevensmap is al versleuteld."; return 0; }
  [ -f "$KLUIS_CONF" ] || fail "Er is nog geen kluis ingesteld. Zet eerst de beheerservice aan (koppelcode)."
  if ! command -v gocryptfs >/dev/null 2>&1 || ! command -v gocryptfs-xray >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "Installeer eerst gocryptfs."
    apt-get install -y -q gocryptfs >/dev/null
  fi
  grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo user_allow_other >> /etc/fuse.conf
  KEY=$(sh "$DIR/start.sh" sleutel) || fail "De sleutel uit de kluis kon niet worden opgehaald. Staat hij klaar op de server van de beheerder?"
  [ ${#KEY} -ge 32 ] || fail "De sleutel uit de kluis is te kort."

  say "Gegevensmap versleutelen"
  echo "De website gaat hiervoor even uit."
  $DC stop >/dev/null 2>&1 || true
  [ -e "$DIR/data.onversleuteld" ] && fail "$DIR/data.onversleuteld bestaat al; ruim die eerst op."
  mv "$PLAIN" "$DIR/data.onversleuteld"
  mkdir -p "$CIPHER" "$PLAIN"
  chmod 700 "$CIPHER"
  gocryptfs -q -nosyslog -init -extpass "/bin/sh $DIR/start.sh sleutel" "$CIPHER" 2>/dev/null
  MASTER=$(sh "$DIR/start.sh" sleutel | gocryptfs-xray -dumpmasterkey "$CIPHER/gocryptfs.conf" 2>/dev/null | tail -n1)
  [ ${#MASTER} -eq 64 ] || fail "Kon de herstelcode niet maken."
  # Zolang de map niet ontgrendeld is, kan er niets in worden geschreven
  # (anders zou de database leeg opnieuw beginnen).
  chattr +i "$PLAIN" 2>/dev/null || echo "Let op: kon de lege map niet vergrendelen (chattr)."
  gocryptfs -q -nosyslog -allow_other -extpass "/bin/sh $DIR/start.sh sleutel" "$CIPHER" "$PLAIN" </dev/null >/dev/null 2>&1 || fail "Ontgrendelen lukte niet."
  cp -a "$DIR/data.onversleuteld/." "$PLAIN/"
  a=$(find "$DIR/data.onversleuteld" | wc -l); b=$(find "$PLAIN" | wc -l)
  [ "$a" = "$b" ] || fail "Kopiëren is niet volledig gelukt ($a tegen $b bestanden). De oude map staat nog in data.onversleuteld."

  sh "$DIR/start.sh" installeer
  $DC up -d >/dev/null
  printf 'Wachten tot de website weer draait'
  i=0
  until $DC exec -T backend wget -qO- http://127.0.0.1:4000/health >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -gt 60 ] && break
    printf '.'; sleep 5
  done
  echo
  rm -rf "$DIR/data.onversleuteld"

  CODE=$(echo "$MASTER" | sed 's/.\{8\}/&-/g; s/-$//')
  cat <<TXT

==================================================================
 HERSTELCODE (noodroute) - schrijf deze op, hij wordt NERGENS bewaard:

   $CODE

 Nodig als de kluis van de beheerder niet meer bestaat. Ontgrendelen:
   sudo sh $DIR/start.sh herstelcode
 Advies: bewaar hem in je wachtwoordmanager, en geef het bestuur een
 papieren kopie in een dichte envelop.
==================================================================
TXT
  echo "Klaar: de gegevensmap is versleuteld en wordt na elke herstart automatisch ontgrendeld."
}

status() {
  say "Beheerservice"
  if [ -n "$(env_get OFFSITE_REPO)" ]; then
    echo "Externe back-up:  aan"
    if [ -f "$PLAIN/.onderhoud/offsite-ok" ]; then
      echo "Laatst gelukt:    $(date -d "@$(cat "$PLAIN/.onderhoud/offsite-ok")" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    else
      echo "Laatst gelukt:    nog niet"
    fi
  else
    echo "Externe back-up:  uit (alleen lokale back-ups in data/backups)"
  fi
  if encrypted; then
    unlocked && echo "Gegevensmap:      versleuteld, nu ontgrendeld" || echo "Gegevensmap:      versleuteld, VERGRENDELD"
    sh "$DIR/start.sh" sleutel >/dev/null 2>&1 && echo "Kluis:            bereikbaar" || echo "Kluis:            NIET bereikbaar"
  else
    echo "Gegevensmap:      niet versleuteld"
  fi
  [ -n "$(env_get NTFY_URL)" ] && echo "Meldingen:        aan" || echo "Meldingen:        uit"
  [ -n "$(env_get HEARTBEAT_URL)" ] && echo "Bewaking:         aan" || echo "Bewaking:         uit"
}

herstel_extern() {
  repo=$(env_get OFFSITE_REPO); pw=$(env_get OFFSITE_PASSWORD)
  [ -n "$repo" ] || fail "De externe back-up staat niet aan."
  name=$(env_get COMPOSE_PROJECT_NAME)
  target="$PLAIN/herstel-$(date +%Y%m%d-%H%M)"
  mkdir -p "$target"
  say "Laatste externe back-up ophalen naar $target"
  RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pw" docker run --rm --network host -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    -v "$target:/herstel" restic/restic:latest restore latest --host "${name:-webbuilder}" --target /herstel
  dump=$(find "$target" -name 'database-*.sql.gz' | head -n1)
  cat <<TXT

Opgehaald. Daarin staan (onder het oorspronkelijke pad):
  - de database:  ${dump:-niet gevonden}
  - de uploads (data/uploads) en .env

Database terugzetten:
  docker compose exec onderhoud sh onderhoud.sh herstel ${dump:-<bestand>}
Uploads terugzetten:
  cp -a <map>/data/uploads/. $PLAIN/uploads/
TXT
}

uitzetten() {
  for k in OFFSITE_REPO OFFSITE_PASSWORD; do env_set "$k" ""; done
  $DC up -d onderhoud >/dev/null 2>&1 || true
  echo "Externe back-up staat uit. Lokale back-ups gaan gewoon door."
  encrypted && echo "Let op: de gegevensmap blijft versleuteld en heeft de kluis (of de herstelcode) nodig."
  return 0
}

case "${1:-aanzetten}" in
  aanzetten) aanzetten ;;
  versleutel) versleutel ;;
  status) status ;;
  herstel-extern) herstel_extern ;;
  uitzetten) uitzetten ;;
  *) echo "Gebruik: sudo sh beheerservice.sh [aanzetten|versleutel|status|herstel-extern|uitzetten]"; exit 1 ;;
esac

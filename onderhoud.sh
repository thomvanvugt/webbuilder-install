#!/bin/sh
# Onderhoud van een Webbuilder-installatie (draait in de container "onderhoud").
#
# Elke nacht om UPDATE_HOUR uur:
#   1. back-up van de database naar data/backups (de laatste BACKUP_KEEP blijven bewaard)
#   2. als AUTO_UPDATE=true: nieuwe versie ophalen en starten
#   3. komt de nieuwe versie niet goed op, dan wordt de vorige teruggezet
#
# Handmatig (op de server, in de map van de installatie):
#   docker compose exec onderhoud sh onderhoud.sh backup   -> nu een back-up
#   docker compose exec onderhoud sh onderhoud.sh update   -> nu bijwerken
set -u

DIR="${PROJECT_DIR:-$(pwd)}"
cd "$DIR" || exit 1
BACKUP_DIR="$DIR/data/backups"
KEEP="${BACKUP_KEEP:-14}"
DC="docker compose --project-directory $DIR"

# Tijdzone-gegevens (zodat UPDATE_HOUR in Nederlandse tijd is).
[ -e /usr/share/zoneinfo ] || apk add --no-cache tzdata >/dev/null 2>&1 || true

log() { echo "[onderhoud $(date '+%Y-%m-%d %H:%M')] $*"; }

backup() {
  mkdir -p "$BACKUP_DIR"
  file="$BACKUP_DIR/database-$(date +%Y%m%d-%H%M)${1:+-$1}.sql.gz"
  if $DC exec -T db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$file.tmp" && [ -s "$file.tmp" ]; then
    mv "$file.tmp" "$file"
    log "Back-up gemaakt: $(basename "$file")"
  else
    rm -f "$file.tmp"
    log "FOUT: back-up mislukt"
    return 1
  fi
  # Oude back-ups opruimen.
  ls -1t "$BACKUP_DIR"/database-*.sql.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f "$old"; done
}

image_id() { docker inspect --format '{{.Image}}' "$($DC ps -q "$1" 2>/dev/null | head -n1)" 2>/dev/null; }
image_ref() { $DC config --images 2>/dev/null | grep -- "-$1:" | head -n1; }

healthy() {
  # Wacht tot de backend "healthy" is (max 4 minuten).
  i=0
  while [ $i -lt 48 ]; do
    cid=$($DC ps -q backend | head -n1)
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null)
    [ "$state" = "healthy" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  return 1
}

update() {
  old_backend=$(image_id backend)
  old_frontend=$(image_id frontend)
  if ! $DC pull -q backend frontend; then
    log "Ophalen van updates mislukt (geen internet?). Volgende keer opnieuw."
    return 1
  fi
  new_backend=$(docker image inspect --format '{{.Id}}' "$(image_ref backend)" 2>/dev/null)
  new_frontend=$(docker image inspect --format '{{.Id}}' "$(image_ref frontend)" 2>/dev/null)
  if [ "$new_backend" = "$old_backend" ] && [ "$new_frontend" = "$old_frontend" ]; then
    log "Geen nieuwe versie."
    return 0
  fi
  log "Nieuwe versie gevonden - eerst een back-up..."
  backup voor-update || { log "Geen back-up, dus ook geen update."; return 1; }
  $DC up -d --no-deps backend frontend
  if healthy; then
    log "Bijgewerkt en draait goed."
    docker image prune -f >/dev/null 2>&1
    return 0
  fi
  log "FOUT: de nieuwe versie start niet goed - de vorige versie wordt teruggezet."
  [ -n "$old_backend" ] && docker tag "$old_backend" "$(image_ref backend)"
  [ -n "$old_frontend" ] && docker tag "$old_frontend" "$(image_ref frontend)"
  $DC up -d --no-deps backend frontend
  healthy && log "Vorige versie draait weer." || log "Let op: ook de vorige versie draait niet goed. Kijk in: docker compose logs backend"
  return 1
}

case "${1:-loop}" in
  backup) backup handmatig; exit $? ;;
  update) update; exit $? ;;
esac

log "Gestart. Dagelijks om ${UPDATE_HOUR:-4}:00 een back-up$( [ "${AUTO_UPDATE:-true}" = "true" ] && echo " en controle op updates")."
last=""
while true; do
  today=$(date +%Y%m%d)
  hour=$(date +%H | sed 's/^0//')
  if [ "$hour" = "${UPDATE_HOUR:-4}" ] && [ "$last" != "$today" ]; then
    last="$today"
    backup nacht
    [ "${AUTO_UPDATE:-true}" = "true" ] && update
  fi
  sleep 300
done

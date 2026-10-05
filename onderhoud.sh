#!/bin/sh
# Onderhoud van een Webbuilder-installatie (draait in de container "onderhoud").
#
# Elke nacht om UPDATE_HOUR uur:
#   1. back-up van de database naar data/backups (de laatste BACKUP_KEEP blijven bewaard)
#   2. als de beheerservice aan staat (OFFSITE_REPO): versleutelde kopie van
#      database + uploads + .env naar de back-upserver van de beheerder
#   3. als AUTO_UPDATE=true: nieuwe versie ophalen en starten (eventueel pas na
#      UPDATE_DELAY_DAYS dagen); ook database, Caddy en dit onderhoud zelf
#      krijgen hun (beveiligings)updates
#   4. komt de nieuwe versie niet goed op, dan wordt de vorige teruggezet
# Elke 5 minuten: controle of de website draait (HEARTBEAT_URL / melding).
# Meldingen gaan naar NTFY_URL (pushmelding op de telefoon van de beheerder).
#
# Handmatig (op de server, in de map van de installatie):
#   docker compose exec onderhoud sh onderhoud.sh backup            -> nu een back-up
#   docker compose exec onderhoud sh onderhoud.sh update            -> nu bijwerken (zonder wachttijd)
#   docker compose exec onderhoud sh onderhoud.sh offsite           -> nu een back-up naar de beheerder
#   docker compose exec onderhoud sh onderhoud.sh export            -> alles in één bestand (bv. bij opzeggen)
#   docker compose exec onderhoud sh onderhoud.sh herstel <bestand> -> database terugzetten uit een back-up
#   docker compose exec onderhoud sh onderhoud.sh test-melding      -> proefmelding naar NTFY_URL
set -u

DIR="${PROJECT_DIR:-$(pwd)}"
cd "$DIR" || exit 1
BACKUP_DIR="$DIR/data/backups"
STATE_DIR="$DIR/data/.onderhoud"
KEEP="${BACKUP_KEEP:-14}"
DC="${DC:-docker compose --project-directory $DIR}"
NAME="${COMPOSE_PROJECT_NAME:-webbuilder}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"
POSTGRES_USER="${POSTGRES_USER:-webbuilder}"
POSTGRES_DB="${POSTGRES_DB:-webbuilder}"

# Tijdzone-gegevens (zodat UPDATE_HOUR in Nederlandse tijd is).
[ -e /usr/share/zoneinfo ] || apk add --no-cache tzdata >/dev/null 2>&1 || true
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { echo "[onderhoud $(date '+%Y-%m-%d %H:%M')] $*"; }

# --- Meldingen -------------------------------------------------------------
# melding "titel" "tekst" [prioriteit: min|low|default|high|urgent] [tags]
melding() {
  log "MELDING: $1 - $2"
  [ -n "${NTFY_URL:-}" ] || return 0
  set -- "$1" "$2" "${3:-default}" "${4:-}"
  if [ -n "${NTFY_TOKEN:-}" ]; then
    wget -q -O /dev/null -T 10 --header "Title: $NAME: $1" --header "Priority: $3" --header "Tags: $4" \
      --header "Authorization: Bearer $NTFY_TOKEN" --post-data "$2" "$NTFY_URL" 2>/dev/null
  else
    wget -q -O /dev/null -T 10 --header "Title: $NAME: $1" --header "Priority: $3" --header "Tags: $4" \
      --post-data "$2" "$NTFY_URL" 2>/dev/null
  fi || log "Melding versturen lukte niet (is NTFY_URL bereikbaar?)"
}

# Uptime Kuma "push"-monitor: ping_url <url> up|down "bericht"
ping_url() {
  [ -n "$1" ] || return 0
  msg=$(echo "$3" | sed 's/ /+/g')
  wget -q -O /dev/null -T 10 "${1%%\?*}?status=$2&msg=$msg&ping=" 2>/dev/null || true
}

# --- Back-up ---------------------------------------------------------------
backup() {
  mkdir -p "$BACKUP_DIR"
  file="$BACKUP_DIR/database-$(date +%Y%m%d-%H%M)${1:+-$1}.sql.gz"
  # Alleen goedkeuren als pg_dump tot het eind is gekomen (een mislukte dump
  # geeft anders gewoon een klein, "geldig" gz-bestand).
  $DC exec -T db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$file.tmp"
  if gzip -t "$file.tmp" 2>/dev/null && gunzip -c "$file.tmp" | tail -n 5 | grep -q "PostgreSQL database dump complete"; then
    mv "$file.tmp" "$file"
    log "Back-up gemaakt: $(basename "$file")"
  else
    rm -f "$file.tmp"
    melding "Back-up mislukt" "De back-up van de database is niet gelukt. Kijk in: docker compose logs onderhoud" high warning
    return 1
  fi
  # Oude back-ups opruimen.
  ls -1t "$BACKUP_DIR"/database-*.sql.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f "$old"; done
}

# Versleutelde kopie naar de back-upserver van de beheerder (beheerservice).
# Die server staat op "append-only": vanaf hier kan niets worden gewist of
# overschreven, ook niet door iemand die deze computer overneemt.
restic_run() {
  docker run --rm --network host \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    -v "$DIR:$DIR:ro" -v "$STATE_DIR/restic-cache:/root/.cache/restic" \
    "$RESTIC_IMAGE" "$@"
}
offsite() {
  [ -n "${OFFSITE_REPO:-}" ] || return 0
  [ -n "${OFFSITE_PASSWORD:-}" ] || { melding "Externe back-up niet ingesteld" "OFFSITE_PASSWORD ontbreekt in .env." high warning; return 1; }
  export RESTIC_REPOSITORY="$OFFSITE_REPO" RESTIC_PASSWORD="$OFFSITE_PASSWORD"
  latest=$(ls -1t "$BACKUP_DIR"/database-*.sql.gz 2>/dev/null | head -n1)
  [ -n "$latest" ] || { log "Nog geen database-back-up om te versturen."; return 1; }
  mkdir -p "$STATE_DIR/restic-cache"
  restic_run cat config >/dev/null 2>&1 || restic_run init >/dev/null 2>&1 || true
  set -- "$latest" "$DIR/.env"
  [ -d "$DIR/data/uploads" ] && set -- "$@" "$DIR/data/uploads"
  if out=$(restic_run backup --host "$NAME" --tag nacht "$@" 2>&1); then
    log "Externe back-up gelukt. $(echo "$out" | grep -i 'snapshot .* saved' | head -n1)"
    date +%s > "$STATE_DIR/offsite-ok"
    return 0
  fi
  echo "$out" | tail -n 5
  melding "Externe back-up mislukt" "De versleutelde back-up naar de beheerder is niet gelukt (back-upserver of NetBird offline?). De lokale back-up is er wel. $(echo "$out" | tail -n1)" high warning
  return 1
}

# --- Bijwerken -------------------------------------------------------------
cid() { $DC ps -q "$1" 2>/dev/null | head -n1; }
image_id() { c=$(cid "$1"); [ -n "$c" ] && docker inspect --format '{{.Image}}' "$c" 2>/dev/null; }
image_ref() { c=$(cid "$1"); [ -n "$c" ] && docker inspect --format '{{.Config.Image}}' "$c" 2>/dev/null; }
local_id() { [ -n "$1" ] && docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
status_of() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$(cid "$1")" 2>/dev/null; }

healthy() { # healthy <dienst> - wacht max. 4 minuten
  i=0
  while [ $i -lt "${HEALTH_TRIES:-48}" ]; do
    state=$(status_of "$1")
    [ "$state" = "healthy" ] && return 0
    [ "$state" = "running" ] && [ "$1" != "backend" ] && [ "$1" != "db" ] && return 0
    sleep "${HEALTH_SLEEP:-5}"
    i=$((i + 1))
  done
  return 1
}

# Nieuwe versie van de website zelf (backend + frontend), met terugzetten.
update_app() {
  old_b=$(image_id backend); old_f=$(image_id frontend)
  ref_b=$(image_ref backend); ref_f=$(image_ref frontend)
  new_b=$(local_id "$ref_b"); new_f=$(local_id "$ref_f")
  if [ "$new_b" = "$old_b" ] && [ "$new_f" = "$old_f" ]; then
    rm -f "$STATE_DIR/wacht"
    log "Website: geen nieuwe versie."
    return 0
  fi

  # Gefaseerd uitrollen: een nieuwe versie pas na UPDATE_DELAY_DAYS dagen
  # installeren (dan heeft hij eerst op de testkastjes gedraaid).
  delay="${UPDATE_DELAY_DAYS:-0}"
  if [ "${1:-}" != "nu" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
    now=$(date +%s)
    if [ -f "$STATE_DIR/wacht" ] && [ "$(cut -d' ' -f1,2 "$STATE_DIR/wacht")" = "$new_b $new_f" ]; then
      since=$(cut -d' ' -f3 "$STATE_DIR/wacht")
    else
      since=$now
      echo "$new_b $new_f $now" > "$STATE_DIR/wacht"
    fi
    if [ $((now - since)) -lt $((delay * 86400)) ]; then
      log "Website: nieuwe versie gevonden; wordt geïnstalleerd na $delay dag(en) wachttijd."
      # Lokaal weer laten wijzen naar wat nu draait, zodat een herstart niet
      # per ongeluk alsnog de nieuwe versie start.
      [ -n "$old_b" ] && docker tag "$old_b" "$ref_b"
      [ -n "$old_f" ] && docker tag "$old_f" "$ref_f"
      return 0
    fi
  fi

  log "Website: nieuwe versie wordt geïnstalleerd."
  $DC up -d --no-deps backend frontend
  if healthy backend; then
    rm -f "$STATE_DIR/wacht"
    log "Bijgewerkt en draait goed."
    melding "Bijgewerkt" "De website is bijgewerkt naar een nieuwe versie en draait goed." low white_check_mark
    return 0
  fi
  [ -n "$old_b" ] && docker tag "$old_b" "$ref_b"
  [ -n "$old_f" ] && docker tag "$old_f" "$ref_f"
  $DC up -d --no-deps backend frontend
  if healthy backend; then
    melding "Update teruggedraaid" "De nieuwe versie startte niet goed; de vorige versie is teruggezet en draait weer." high warning
  else
    melding "Website draait niet" "De nieuwe versie startte niet en de vorige ook niet. Kijk in: docker compose logs backend" urgent rotating_light
  fi
  return 1
}

# (Beveiligings)updates van de onderdelen: database (alleen binnen dezelfde
# hoofdversie, die staat vast in docker-compose.yml), Caddy en dit onderhoud.
update_infra() {
  for svc in db caddy; do
    [ -n "$(cid "$svc")" ] || continue
    old=$(image_id "$svc"); new=$(local_id "$(image_ref "$svc")")
    { [ -n "$new" ] && [ "$new" != "$old" ]; } || continue
    log "$svc: update wordt geïnstalleerd."
    $DC up -d --no-deps "$svc"
    if healthy "$svc"; then
      [ "$svc" = "db" ] && $DC restart backend >/dev/null 2>&1
      log "$svc bijgewerkt."
    else
      melding "Update van $svc mislukt" "Na de update draait $svc niet goed. Kijk in: docker compose logs $svc" urgent rotating_light
    fi
  done
  [ -n "${OFFSITE_REPO:-}" ] && { docker pull -q "$RESTIC_IMAGE" >/dev/null 2>&1 || true; }
  # Dit onderhoud zelf: kan zichzelf niet vervangen, dus een hulpcontainer
  # doet dat over 30 seconden (als dit script klaar is).
  ref=$(image_ref onderhoud); old=$(image_id onderhoud); new=$(local_id "$ref")
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    log "onderhoud: update wordt over 30 seconden geïnstalleerd."
    docker run -d --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$DIR:$DIR" -w "$DIR" \
      --entrypoint sh "$ref" -c "sleep 30; docker compose --project-directory $DIR up -d --no-deps onderhoud" >/dev/null 2>&1 || true
  fi
}

update() {
  if ! $DC pull -q; then
    log "Ophalen van updates mislukt (geen internet?). Volgende keer opnieuw."
    return 1
  fi
  if [ "$(image_id backend)" != "$(local_id "$(image_ref backend)")" ] || [ "$(image_id db)" != "$(local_id "$(image_ref db)")" ]; then
    backup voor-update || { log "Geen back-up, dus ook geen update."; return 1; }
  fi
  update_infra
  update_app "${1:-}"
  rc=$?
  # Ruimt ook een uitgestelde versie op; die wordt de volgende nacht opnieuw
  # opgehaald (gaat snel, de meeste lagen zijn er al).
  docker image prune -f >/dev/null 2>&1
  return $rc
}

# --- Export (bij opzeggen of verhuizen) -----------------------------------
export_all() {
  backup export || return 1
  out="$DIR/data/export"; mkdir -p "$out"
  f="$out/webbuilder-export-$(date +%Y%m%d-%H%M).tar.gz"
  latest=$(ls -1t "$BACKUP_DIR"/database-*-export.sql.gz | head -n1)
  tmp=$(mktemp -d)
  cat > "$tmp/LEESMIJ.txt" <<TXT
Export van de website ($NAME), gemaakt op $(date '+%Y-%m-%d %H:%M').

database.sql.gz   alle gegevens (PostgreSQL 16, gemaakt met pg_dump)
uploads/          alle geüploade foto's en bestanden
.env              instellingen en sleutels van deze installatie.
                  BEWAAR DIT VEILIG: hiermee kun je de opgeslagen
                  wachtwoorden en tweestapsverificatie ontsleutelen.

Terugzetten op een nieuwe installatie van Webbuilder:
  1. installeer Webbuilder (install.sh) en neem uit deze .env over:
     POSTGRES_PASSWORD hoeft niet, maar JWT_SECRET en TOTP_ENCRYPTION_KEY wel
  2. kopieer uploads/ naar data/uploads/
  3. kopieer database.sql.gz naar data/backups/ en draai:
     docker compose exec onderhoud sh onderhoud.sh herstel data/backups/database.sql.gz
TXT
  cp "$latest" "$tmp/database.sql.gz"
  cp "$DIR/.env" "$tmp/.env"
  set -- LEESMIJ.txt database.sql.gz .env
  if [ -d "$DIR/data/uploads" ]; then ln -s "$DIR/data/uploads" "$tmp/uploads"; set -- "$@" uploads/; fi
  if tar -czhf "$f" -C "$tmp" "$@"; then
    rm -rf "$tmp"; chmod 600 "$f"
    log "Export klaar: $f"
    return 0
  fi
  rm -rf "$tmp" "$f"
  log "FOUT: export mislukt."
  return 1
}

# --- Herstellen uit een back-up -------------------------------------------
herstel() {
  file="${1:-}"
  case "$file" in /*) ;; ?*) file="$DIR/$file" ;; esac
  [ -f "$file" ] || { echo "Gebruik: onderhoud.sh herstel <back-upbestand .sql.gz>  (zie data/backups/)"; return 1; }
  gzip -t "$file" || { echo "Dit bestand is beschadigd."; return 1; }
  backup voor-herstel || { echo "Kon geen back-up van de huidige toestand maken; gestopt."; return 1; }
  log "Database terugzetten uit $(basename "$file")..."
  $DC stop backend
  if $DC exec -T db psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
       -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";" \
     && gunzip -c "$file" | $DC exec -T db psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null; then
    $DC start backend
    healthy backend && { log "Teruggezet; de website draait weer."; return 0; }
  fi
  log "FOUT bij terugzetten. De toestand van vlak ervoor staat in data/backups (…-voor-herstel.sql.gz)."
  $DC start backend
  return 1
}

# --- Bewaking -------------------------------------------------------------
check() {
  be=$(status_of backend)
  fe=$(status_of frontend)
  bad_file="$STATE_DIR/storing"
  if [ "$be" = "healthy" ] && { [ "$fe" = "running" ] || [ "$fe" = "healthy" ]; }; then
    ping_url "${HEARTBEAT_URL:-}" up "OK"
    if [ -f "$bad_file" ]; then
      [ "$(cat "$bad_file")" -ge 2 ] && melding "Website draait weer" "De website is weer in orde." default white_check_mark
      rm -f "$bad_file"
    fi
  else
    n=$(( $(cat "$bad_file" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$bad_file"
    ping_url "${HEARTBEAT_URL:-}" down "backend=${be:-weg} frontend=${fe:-weg}"
    # Pas na twee keer (10 minuten) melden, niet bij elke herstart.
    [ "$n" -eq 2 ] && melding "Website draait niet goed" "backend: ${be:-niet gestart}, frontend: ${fe:-niet gestart}. Kijk in: docker compose logs backend" urgent rotating_light
  fi
}

nacht() {
  date +%Y%m%d > "$STATE_DIR/laatste-nacht"
  ok=true
  backup nacht || ok=false
  offsite || ok=false
  [ "${AUTO_UPDATE:-true}" = "true" ] && { update || true; }
  if $ok; then ping_url "${BACKUP_HEARTBEAT_URL:-}" up "back-up OK"; fi
}

case "${1:-loop}" in
  backup) backup handmatig; exit $? ;;
  offsite) offsite; exit $? ;;
  update) update nu; exit $? ;;
  nacht) nacht; exit 0 ;;
  controle) check; exit 0 ;;
  export) export_all; exit $? ;;
  herstel) herstel "${2:-}"; exit $? ;;
  test-melding)
    [ -n "${NTFY_URL:-}" ] || { echo "NTFY_URL staat niet in .env"; exit 1; }
    melding "Testmelding" "Meldingen van het onderhoud komen aan." default bell; exit 0 ;;
  loop) ;;
  *) echo "Onbekende opdracht: $1"; exit 1 ;;
esac

log "Gestart. Dagelijks om ${UPDATE_HOUR:-4}:00 een back-up$( [ -n "${OFFSITE_REPO:-}" ] && echo " (ook extern)")$( [ "${AUTO_UPDATE:-true}" = "true" ] && echo " en controle op updates")."
while true; do
  today=$(date +%Y%m%d)
  hour=$(date +%H | sed 's/^0//')
  if [ "$hour" = "${UPDATE_HOUR:-4}" ] && [ "$(cat "$STATE_DIR/laatste-nacht" 2>/dev/null)" != "$today" ]; then
    nacht
  fi
  check
  sleep 300
done

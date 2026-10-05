# Webbuilder installeren

Een complete website voor buurtverenigingen en woongemeenschappen.

Op een server met Linux (een kleine VPS is genoeg):

```sh
curl -fsSL https://raw.githubusercontent.com/thomvanvugt/webbuilder-install/main/install.sh | sh
```

Het script installeert zo nodig Docker, vraagt je domeinnaam, maakt alle
wachtwoorden zelf aan en start de website. Daarna open je de link die het
script laat zien en doorloop je de installatie-wizard.

- Elke nacht een back-up van de database in `data/backups/`.
- Nieuwe versies worden automatisch geïnstalleerd (uit te zetten met
  `AUTO_UPDATE=false` in `.env`); start een nieuwe versie niet goed, dan wordt
  de vorige teruggezet.
- Al een eigen reverse proxy (Nginx Proxy Manager e.d.)? Laat de domeinnaam
  leeg; de website luistert dan op een poort (standaard 8110).

Deze repository bevat alleen de installatiebestanden; ze worden bij elke
release automatisch bijgewerkt.

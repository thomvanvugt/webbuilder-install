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
- Het script vraagt hoe de website bereikbaar wordt:
  1. **NetBird**: voor een mini-pc bij een vereniging. Geen poorten openzetten;
     bezoekers komen via de NetBird-proxy binnen en jij beheert op afstand.
  2. **Eigen domein**: server met een publiek IP-adres (bv. een VPS), HTTPS via Caddy.
  3. **Eigen reverse proxy** (Nginx Proxy Manager e.d.): de website luistert op een poort.

Deze repository bevat alleen de installatiebestanden; ze worden bij elke
release automatisch bijgewerkt.

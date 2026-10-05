# Lokale Tests

Automatische Tests für LagerPal, die **ohne** Supabase laufen: eine lokale Postgres-
Datenbank mit genau dem Schema aus `supabase/00_KOMPLETT_neu_aufsetzen.sql`, davor
PostgREST (dieselbe Schnittstelle, die Supabase nutzt) und ein kleiner Test-Server.
Die App selbst (`index.html`) wird unverändert im Browser (Playwright) getestet.

Gedacht für einen Entwicklungs-Container (Postgres 16, Node, Playwright vorhanden).

```
tests/e2e/start.sh                                      # Testumgebung starten (frische DB + Testdaten)
NODE_PATH=$(npm root -g) node tests/e2e/paket1.test.js  # Tests ausführen
psql -h /tmp -p 54329 -U postgres -d lp -At -f tests/sql/fingerabdruck.sql   # Schema-Fingerabdruck
```

`fingerabdruck.sql` lässt sich auch im Supabase SQL-Editor ausführen: Gleicher Wert
in Supabase und lokal = gleiche Datenbankstruktur.

## Bibliotheken aktualisieren (Paket 3b)

`index.html` lädt supabase-js, papaparse und xlsx mit fester Version und Prüfsumme
(`integrity`). Für eine neue Version: Paket von npm holen, Prüfsumme der Datei bilden
und Version + Prüfsumme im `<script>`-Tag ersetzen, z. B.

```
npm pack @supabase/supabase-js@2.x.y && tar xzf supabase-supabase-js-2.x.y.tgz
echo "sha384-$(openssl dgst -sha384 -binary package/dist/umd/supabase.js | base64 -w0)"
```

jsDelivr liefert die npm-Dateien unverändert aus, die Prüfsumme passt also.

`tests/e2e/jtl_vergleich.js` vergleicht die JTL-Kommentar-Datei der Datenbank
(`jtl_kommentar_csv`) mit der früheren JavaScript-Logik.

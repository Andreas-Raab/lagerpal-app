# WICHTIG – zuerst lesen (für jede KI / jeden Chat, der an LagerPal arbeitet)

Stand: 12.11.2026

## Die einzige gültige Quelle ist GitHub

- **Repository:** github.com/Andreas-Raab/lagerpal-app, Zweig `main`
  (App: https://andreas-raab.github.io/lagerpal-app/)
- Dort liegen die aktuelle `index.html`, die SQL-Dateien (`supabase/…`), die Backup-Funktion
  (`supabase/functions/lagerpal-backup/index.ts`), Doku (`docs/`) und Tests (`tests/`).
- Änderungen wurden zeitweise **direkt auf GitHub** gemacht (Pull-Requests einer anderen
  Claude-Sitzung, 03.10.–06.11.2026). Lokale Kopien können deshalb veraltet sein.
- Der Ordner `supabase_ALT_bis_Sept` enthält den Stand bis Ende September 2026. Er ist
  **veraltet** und nur noch als Archiv da. **Nie daraus etwas hochladen oder einspielen.**

## Was am 12.11.2026 schiefging (damit es nicht wieder passiert)

Eine Änderung wurde in die veraltete lokale `index.html` (Stand 29.09.) eingebaut und
hochgeladen. Dadurch waren alle Änderungen vom 03.10.–06.11. online kurz überschrieben.
Behoben durch Wiederherstellen der Version vom 06.11. (Commit 71e327b) und erneutes
Einbauen auf dieser Basis (Commit 9a823be, nur +18 Zeilen).

## Pflicht-Ablauf vor JEDER Änderung

1. **Aktuellen Stand auf GitHub feststellen:** Commit-Verlauf von `main` ansehen
   (github.com/Andreas-Raab/lagerpal-app/commits/main) und die SHA-256-Prüfsumme der Datei
   auf `main` bestimmen (z. B. im Browser auf github.com:
   `fetch('/Andreas-Raab/lagerpal-app/raw/main/index.html')` + `crypto.subtle.digest`).
2. **Nur mit einer Arbeitskopie arbeiten, deren Prüfsumme mit `main` übereinstimmt**
   (frisches „Code → Download ZIP“ in den LagerPal-Ordner). Stimmt sie nicht: neues ZIP
   anfordern, nicht weiterarbeiten.
3. **Änderung als reine, minimale Ergänzung** einbauen; danach Unterschied (diff) erzeugen
   und dem Nutzer zeigen. Gegenprobe: eingefügte Zeilen wieder herausnehmen → muss
   byte-genau die Ausgangsdatei ergeben.
4. Syntax-Prüfung (node --check auf den Skriptblock) und Funktionstest.
5. Fertige Datei in `zum_Hochladen/` legen. Der Nutzer lädt sie über GitHub hoch.
6. **Nach dem Hochladen prüfen:** Prüfsumme auf `main` = Prüfsumme der geprüften Datei, und
   der neue Commit ändert nur die erwarteten Dateien/Zeilen.
7. Datenbank-Änderungen (SQL) immer zuerst in der Testumgebung
   (Supabase-Projekt kedovlfzdgylajeioiuq), in Produktion (csrjwhqhvkuvdnshazix) nur mit
   ausdrücklicher Freigabe des Nutzers. Vorher prüfen, welche SQL-Updates aus
   `supabase/updates/` auf GitHub bereits eingespielt sind.

## Weitere Regeln des Nutzers

- Dateien im LagerPal-Ordner nicht ohne Erlaubnis löschen oder umbenennen.
- Keine Passwörter oder API-Schlüssel in Felder eingeben.
- `02_data.sql` (echte Daten) nicht hochladen.
- Vor größeren Änderungen eine Sicherung im Ordner `Versionen` anlegen.

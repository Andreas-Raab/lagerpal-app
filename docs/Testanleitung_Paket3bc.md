# Testanleitung Paket 3b/3c – Sicherheit, Stabilität, Aufräumen

Wie bei Paket 3a: erst das Datenbank-Update im **Testsystem**, dann die neue `index.html` testen. Die alte App läuft mit der aktualisierten Datenbank unverändert weiter.

## A. Datenbank-Update im Testsystem (ca. 2 Minuten)

1. GitHub → Branch `claude/cloud-sessions-credits-9xe0tz` → `supabase/updates/2026-10_paket3bc.sql` → **„Copy raw file“**.
2. Supabase → **Testprojekt** → **SQL Editor** → **New query** → einfügen → **Run**.
3. Ganz unten muss der Fingerabdruck **`c014bb6d7daf8e1c9166fc16c32b91d8`** stehen.

## B. App testen (ca. 10 Minuten)

Neue `index.html` herunterladen und mit dem **Testsystem** verbinden.

### 1. App startet normal (Punkt 4)
- [ ] Die App lädt, Anmelden klappt, die Suche zeigt Artikel.
      Die Bibliotheken haben jetzt eine feste Version und eine Prüfsumme. Würde jemand die Dateien beim Anbieter verändern, lädt der Browser sie nicht. Im Normalbetrieb merkst du davon nichts.
- [ ] Ein Excel-Import (z. B. Bestandsimport mit einer .xlsx-Datei) funktioniert wie bisher.

### 2. Exporte (Punkte 5, 51)
- [ ] **Import/Export → „Lagerbestandskommentar (JTL)“** herunterladen und mit einer Datei von vorher vergleichen (gleicher Aufbau: `Artikelnummer;Kommentar`, „Platz (Menge), …“).
      Die Datei kommt jetzt aus der Datenbank, genau wie die nächtliche Datei in Dropbox.
- [ ] **„Artikel (mit Bestand)“** exportieren und in Excel öffnen: sieht aus wie bisher.

### 3. Glocke (Punkt 37)
- [ ] Die Zahl an der Glocke aktualisiert sich weiter (etwa alle 15 Sekunden). Glocke öffnen: Die Meldungen erscheinen.
- [ ] Tab im Hintergrund lassen und wieder öffnen: Die Zahl ist sofort aktuell.

### 4. Texte (Punkt 47)
- [ ] **Import/Export** ganz unten: Die Texte zu Sicherung, Reset und Einspielen erwähnen jetzt Paletten, Abgleich-Fälle und die nächtliche Dropbox-Sicherung.
- [ ] **Protokoll** → Filter: „Palette angelegt“ und „Palette umbenannt“ sind auswählbar.

### 5. Sicherung und „Alles löschen“ (Punkt 43, Frage 50)
- [ ] **„Sicherung jetzt herunterladen“** → die Datei lässt sich unter „Sicherung einspielen“ wieder einspielen.
- [ ] *(Nur im Testsystem!)* **„Alles löschen“**: Danach ist auch die **Palettenliste** leer. Anschließend die Sicherung von eben einspielen → alles ist wieder da, auch die Paletten.

## C. Edge Function neu deployen (nach dem Live-Gang, kann auch später)

Die nächtliche Sicherung (`supabase/functions/lagerpal-backup/index.ts`) nutzt jetzt die neue Datenbank-Funktion für die JTL-Datei und schreibt das einheitliche Backup-Format. Bis du sie neu deployst, läuft die alte Version weiter und erzeugt dieselbe JTL-Datei wie bisher. Erst die Datenbank aktualisieren, dann deployen.

## Später: Live schalten

1. Abends in der App **„Sicherung jetzt“**.
2. `supabase/updates/2026-10_paket3bc.sql` im **echten** System ausführen. Der Fingerabdruck muss derselbe sein wie im Testsystem.
3. Pull Request mit **„Squash and merge“** zusammenführen → alle Geräte einmal neu laden.
4. Optional: Edge Function neu deployen (siehe C).

**Zurück, falls nötig:** Pull Request „Revert“. Das Datenbank-Update darf bleiben.

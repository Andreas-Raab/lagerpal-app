# Testanleitung Paket 3a – Datenrichtigkeit bei Import, Inventur und Export

Paket 3a ändert die App **und** die Datenbank. Die Reihenfolge ist wie bei Paket 2:

1. **Datenbank-Update im Testsystem** einspielen (Schritt A)
2. Neue `index.html` mit dem Testsystem testen (Schritt B)
3. Später live: erst das Datenbank-Update im **echten** System, danach die App

Die **alte** App läuft mit der aktualisierten Datenbank unverändert weiter.

## A. Datenbank-Update im Testsystem (ca. 3 Minuten)

1. GitHub → Branch `claude/cloud-sessions-credits-9xe0tz` → Datei `supabase/updates/2026-10_paket3a.sql` öffnen → **„Copy raw file“**.
2. Supabase → **Testprojekt** → **SQL Editor** → **New query** → einfügen → **Run**.
3. Ganz unten erscheint der **Fingerabdruck**. Erwartet: **`FINGERABDRUCK`**
   Einen eigenen Kontrolllauf brauchst du diesmal nicht, er ist im Skript enthalten.
   Kommt eine Fehlermeldung: nichts weiter tun, mir den Text schicken. Das Skript ändert dann nichts.

## B. App testen

Neue `index.html` herunterladen wie bei Paket 1 und mit dem **Testsystem** verbinden (oben steht dann das TESTSYSTEM-Banner).

### 1. Bestandsimport mit Excel-Datei (Punkt 25)
- [ ] In Excel eine Datei mit den Spalten **Artikelnummer, Lagerplatz, Bestand, EAN** anlegen. Bei einem Artikel, dessen EAN mit **0** beginnt, die EAN als **Zahl** eintragen (Excel entfernt dann die Nullen).
      **Import/Export → Bestandsimport → Teil-Import**, Haken **„neu anlegen …“** setzen, Datei wählen.
      Erwartet: In der Vorschau steht „🔧 … EAN(s) ohne führende Nullen erkannt …“. Nach dem Import hat der Artikel **seine alte EAN** (mit Nullen) und wird beim Scannen weiter gefunden.
- [ ] Eine EAN absichtlich falsch eintippen (z. B. letzte Ziffer ändern).
      Erwartet: „⚠️ … EAN(s) mit falscher Länge oder Prüfziffer werden nicht übernommen“. Die alte EAN bleibt.

### 2. Stammdaten im Import (Punkt 28)
- [ ] Datei mit einer Spalte **Artikelname**, bei einem Artikel einen anderen Namen eintragen, Haken **„neu anlegen …“** gesetzt.
      Erwartet: Die Vorschau zeigt eine Tabelle „Artikel bekommen geänderte Stammdaten“ mit **bisher → neu**.
- [ ] Haken **wegnehmen**: Die Vorschau rechnet neu, die Namensänderung verschwindet.
- [ ] Import ausführen → **Protokoll** → Typ **„Artikeländerung (Import)“**: Die Änderung steht dort mit altem und neuem Namen.

### 3. Inventur (Punkt 16)
- [ ] Reiter **Inventur**: In der Platzliste stehen jetzt auch **leere** Plätze („leer“). Einen leeren Platz wählen, einen Artikel scannen, Menge eintragen, **„Inventur übernehmen“**.
      Erwartet: Der Bestand ist auf dem Platz.
- [ ] Zwei Geräte: Auf Gerät 1 einen Platz zur Inventur öffnen und eine Menge ändern. **Bevor** du übernimmst, auf Gerät 2 einen Artikel von genau diesem Platz ausbuchen. Dann auf Gerät 1 **„Inventur übernehmen“**.
      Erwartet: Meldung „Während der Zählung wurde auf diesem Platz gebucht. Nichts übernommen.“ Die Zeile ist gelb und zeigt „Soll war X, jetzt Y“. Ein zweiter Klick übernimmt die Zählung.

### 4. Amazon-Status-Import (Punkt 24)
- [ ] Eine Amazon-Datei mit einem ungewöhnlichen Status (z. B. „Unvollständig“ oder „Gesperrt“) wählen.
      Erwartet: Ein gelber Kasten **„Unbekannte Statuswerte – bitte zuordnen“** mit Auswahl *nicht ändern / online / nicht online*. Standard ist „nicht ändern“.
- [ ] Zuordnung wählen → die Zahlen in der Vorschau ändern sich. Übernehmen.
      Erwartet: Die Erfolgsmeldung zählt bei „geändert“ nur Artikel, die **wirklich** einen anderen Status bekommen haben.
- [ ] Dieselbe Datei noch einmal wählen: Die Zuordnung ist gemerkt.

### 5. Kleinigkeiten (Punkte 27, 28)
- [ ] **Übersicht**: Nach einem Einräum-Scan mit Mehrmenge zählt die Mehrmenge **nicht** bei „Heute ein“.
- [ ] **Protokoll** nach Palette sortieren oder Komplett ausbuchen: Spalte **Gesamt** ist gefüllt.
- [ ] **Artikel (mit Bestand)** exportieren: Die Spalte Gesamtbestand stimmt.

### 6. Gegenprobe
- [ ] Scanner Ein-/Ausbuchen, Umlagern, Palette sortieren, Abgleich funktionieren wie gewohnt
- [ ] Alle Reiter öffnen sich ohne Fehlermeldung

## Später: Live schalten

1. Abends, wenn niemand bucht: in der App **„Sicherung jetzt“**.
2. `supabase/updates/2026-10_paket3a.sql` im **echten** System ausführen. Der Fingerabdruck unten muss derselbe sein wie im Testsystem.
3. Pull Request mit **„Squash and merge“** zusammenführen → alle Geräte einmal neu laden.

**Zurück, falls nötig:** Pull Request „Revert“. Das Datenbank-Update darf bleiben, die alte App läuft damit.

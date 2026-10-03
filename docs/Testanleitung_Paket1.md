# Testanleitung Paket 1 – Bedienung im Lager

**Gut zu wissen:** Paket 1 ändert nur die App (`index.html`), **nicht die Datenbank**. Es gibt kein SQL-Skript einzuspielen. Live gehen heißt später nur: Pull Request zusammenführen. Zurück geht es mit einem Klick auf „Revert“.

## Vorbereitung (einmalig, ca. 5 Minuten)

1. Die neue `index.html` herunterladen:
   GitHub → Repo `lagerpal-app` → Branch `claude/cloud-sessions-credits-9xe0tz` → `index.html` → Knopf **„Download raw file“**.
2. Die Datei z. B. als `LagerPal-TEST.html` auf dem PC speichern und per Doppelklick im Browser (Chrome oder Edge) öffnen.
3. Beim ersten Start fragt die App nach **Project URL** und **anon public key**. Dort die Werte des **Testsystems** eintragen (Supabase → Testprojekt → Project Settings → API).
   Die Datei auf dem PC merkt sich diese Eingaben getrennt von der echten App. Die Lagergeräte arbeiten unverändert weiter.
4. Mit einem Benutzer des Testsystems anmelden.

> **Wichtig:** Oben in der App steht nichts von „Test“. Prüfe vor dem ersten Buchen, ob die Artikel aus dem Testsystem zu sehen sind.

Wenn du einen USB-Barcode-Scanner am PC hast: umso besser, dann ist der Test realistisch. Sonst Code eintippen und Enter drücken.

## Testfälle

Hake jeden Punkt ab. Wenn etwas anders ist als beschrieben, notier es dir. Ein Screenshot reicht.

### 1. Doppelklick bucht nur einmal
- [ ] **Scanner → „− Ausbuchen“**: Artikel scannen, der auf **mehreren** Plätzen liegt. Bei der Platzwahl **zweimal schnell** auf denselben Platz tippen.
      Erwartet: Im Protokoll steht **ein** Ausgang, der Bestand ist nur um 1 gesunken.
- [ ] **Suche**: Bei einem Artikel zweimal schnell auf **„+ Ein“** klicken (Doppelklick), danach dasselbe mit **„− Aus“**.
      Erwartet: Je **eine** Buchung im Protokoll. Die Knöpfe dieser Zeile sind nach einer Buchung ca. 1,5 Sekunden ausgegraut.
      Wer bewusst zweimal buchen will, wartet kurz, bis die Knöpfe wieder aktiv sind.
- [ ] **Umlagern**: Alles ausfüllen und zweimal schnell auf **„🔀 Umlagern“** klicken.
      Erwartet: **eine** Umlagerung.

### 2. Scanner-Enter bestätigt keine Rückfrage mehr
- [ ] **Scanner → „− Ausbuchen“**: einen **Set-Artikel** scannen. Es erscheint ein gelb umrandetes Fenster „SET-ARTIKEL“ und die Ansage „Set, bitte bestätigen“.
      Jetzt **sofort den nächsten Artikel scannen**.
      Erwartet: Das Fenster bleibt offen und es wird nichts gebucht. Erst nach Tippen auf **„Fortfahren“** wird das Set gebucht. Darunter steht rot: „Während der Rückfrage wurde gescannt – dieser Artikel wurde **nicht** gebucht“.
- [ ] **Palette sortieren**: Sortierung starten, Menge auf **mehr** stellen als auf der Quelle liegt, dann scannen. Die Rückfrage „… zusätzlichen als Inventur-Zugang buchen?“ erscheint.
      Mehrmals **Enter** drücken bzw. scannen.
      Erwartet: Das Fenster bleibt offen. **„Nein, abbrechen“** bucht nichts.

### 3. Palette sortieren: schnelle Scans gehen nicht mehr verloren
- [ ] Zwei Artikel **direkt hintereinander** scannen, so schnell wie möglich.
      Erwartet: Entweder werden beide gebucht, oder der zweite wird mit Warnton und rotem Hinweis „wurde **nicht** gebucht – bitte noch einmal scannen“ abgewiesen. Es darf **nie** passieren, dass der zweite still verschwindet.
- [ ] Das Scanfeld ist nach jedem Scan sofort leer, es hängen keine zwei Codes aneinander.

### 4. Karton-Blätter
- [ ] **Palette sortieren → „✓ Palette fertig“**, wenn beide Kartons befüllt sind.
      Erwartet: Es öffnet sich **ein** Fenster mit **beiden** Karton-Blättern, je eine Seite. Kein „Bitte Pop-ups erlauben“.
- [ ] **„📄 Karton voll → drucken & nächster“**: Blatt öffnet sich, es geht mit dem nächsten Karton weiter.
- [ ] **Lagerplätze → Palette wählen → „🖨️ Nachdruck“**: Das Blatt öffnet sich wie gewohnt.

### 5. Suche
- [ ] *(Optional, nur wenn es bei euch solche Plätze gibt)* Artikel mit zwei ähnlich heißenden Plätzen, z. B. „Regal-1“ und „Regal 1“: Bei der **zweiten** Zeile eine Menge eintragen und ausbuchen.
      Erwartet: Genau dieser Platz ändert sich. Dieser Fall wird auch automatisch getestet. Gibt es keine solchen Plätze, einfach überspringen.
- [ ] Nach „+ Ein“ / „− Aus“ zeigt die Tabelle **sofort** den neuen Bestand, ohne „Wird geladen…“.
- [ ] Artikel ankreuzen, dann etwas anderes suchen.
      Erwartet: Die Leiste zeigt „… ausgewählt (davon X durch Suche/Filter ausgeblendet)“. „Komplett ausbuchen“ listet die Artikel auf und warnt vor den ausgeblendeten.

### 6. Gegenprobe: Gewohntes funktioniert weiter
- [ ] Scanner Einbuchen mit vorher gewähltem Lagerplatz
- [ ] Scanner Einbuchen **ohne** gewählten Platz → Platzwahl erscheint → Buchung
- [ ] Unbekannte EAN einbuchen → landet im Klärfall-Karton „Unbekannt-…“
- [ ] Rückgängig-Leiste unten nimmt die letzte Buchung zurück
- [ ] Alle Reiter öffnen sich ohne Fehlermeldung (Inventur, Lagerplätze, Protokoll, Import/Export, Übersicht)
- [ ] Geschwindigkeit: Scannen fühlt sich mindestens so schnell an wie bisher, eher schneller

## Wenn alles passt

Sag mir Bescheid. Ich lege dann den Pull Request an. Du führst ihn auf GitHub mit **„Merge“** zusammen, und nach 1–2 Minuten haben alle Geräte die neue Version (eventuell einmal die Seite neu laden).

**Zurück zur alten Version:** im Pull Request auf **„Revert“** klicken und den neuen Pull Request mergen.

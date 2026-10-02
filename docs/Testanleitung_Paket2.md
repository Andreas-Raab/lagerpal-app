# Testanleitung Paket 2 – Mehrere Geräte, Rückgängig, Robustheit

Paket 2 ändert die App **und** die Datenbank. Die Reihenfolge ist wichtig:

1. **Datenbank-Update im Testsystem** einspielen (unten, Schritt A)
2. Neue `index.html` mit dem Testsystem testen (Schritt B)
3. Später live: erst das Datenbank-Update im **echten** System, danach die App

Die **alte** App läuft mit der aktualisierten Datenbank unverändert weiter. Deshalb ist die Reihenfolge „erst Datenbank, dann App“ sicher.

## A. Datenbank-Update im Testsystem (ca. 5 Minuten)

1. GitHub → Branch `claude/cloud-sessions-credits-9xe0tz` → Datei `supabase/updates/2026-10_paket2.sql` öffnen → Knopf **„Copy raw file“** (Symbol mit zwei Blättern).
2. Supabase → **Testprojekt** → **SQL Editor** → **New query** → einfügen → **Run**.
   Erwartet: unten erscheinen zwei Zeilen `karton_neu` und `rueckgaengig_eine`.
   Kommt eine Fehlermeldung: nichts weiter tun, mir den Text schicken. Das Skript läuft in einer Transaktion, bei einem Fehler wird **nichts** geändert.
3. Kontrolle: Inhalt von `tests/sql/fingerabdruck.sql` im SQL-Editor ausführen.
   Erwartet: **`76b4e7daca091e8b7f52d67079fcb6f6`**. Das ist exakt der Stand, gegen den ich getestet habe.

## B. App testen

Neue `index.html` herunterladen wie bei Paket 1 und mit dem **Testsystem** verbinden. Paket 1 ist darin enthalten. Die Tests aus Paket 1 musst du nicht wiederholen, außer du hast Zeit.

### 1. Rückgängig nimmt ganze Vorgänge zurück
- [ ] **Suche**: zwei Artikel ankreuzen → **„Komplett ausbuchen“** → unten in der Rückgängig-Leiste **„Rückgängig“**.
      Erwartet: **Alle** Bestände sind wieder da. Die Meldung nennt „+ X weitere Teile desselben Vorgangs“.
- [ ] **Palette sortieren**: Mehr scannen als auf der Quelle liegt, Rückfrage mit „Ja“ bestätigen → **Rückgängig**.
      Erwartet: Der ganze Scan ist zurück, nicht nur der Mehr-Teil. Der Karton ist wieder leer, die Quelle hat ihren alten Bestand.
- [ ] Artikel bearbeiten, der eine EAN mit einem anderen Artikel teilt (z. B. Defekt-Zweitartikel), nur den Namen ändern → **Rückgängig**.
      Erwartet: klappt. Vorher kam „GTIN anderweitig vergeben“.
- [ ] **Lagerplätze**: einen Karton mit Palette und Farbe (online/offline) löschen → **Rückgängig**.
      Erwartet: Er ist wieder unter seiner Palette, mit derselben Farbe.
- [ ] Zwei Kartons **zusammenlegen** → **Rückgängig**.
      Erwartet: Beide wieder mit Palette und Farbe. Ein neu angelegter Zielname ist wieder verschwunden.

### 2. Mehrere Geräte
- [ ] Zwei Geräte (oder zwei Browserfenster) sortieren **gleichzeitig auf dieselbe Palette** und tippen beide etwa gleichzeitig auf **„Karton voll → drucken & nächster“**.
      Erwartet: **verschiedene** Kartonnummern, z. B. K05 und K06. Nie zweimal dieselbe.

### 3. Robustheit
- [ ] **Import/Export → Bestandsimport → Teil-Import**: Datei auswählen.
      Erwartet: Erst eine **Vorschau** mit „Bestand jetzt → neu“. Erst nach **„Import ausführen“** ändert sich etwas. „Abbrechen“ ändert nichts.
- [ ] **Protokoll**: nach einem Artikel suchen, der **vor längerer Zeit** gebucht wurde.
      Erwartet: Er wird gefunden, auch wenn seitdem viel gebucht wurde.
- [ ] **WLAN kurz aus** (am PC: Netzwerk trennen), dann im Scanner etwas scannen.
      Erwartet: Eine **Fehlermeldung**, nicht „Nicht gefunden“. Nach dem Wiederverbinden funktioniert der nächste Scan normal.
- [ ] **Glocke** nach einem Sammel-Ausbuchen: Die Meldungen zeigen **Artikel und Platz**, nicht „Einräum-Hinweis“.

### 4. Gegenprobe
- [ ] Scanner Ein-/Ausbuchen, Umlagern, Palette sortieren mit „Palette fertig“ funktionieren wie gewohnt
- [ ] Alle Reiter öffnen sich ohne Fehlermeldung

## Später: Live schalten (Paket 1 + 2 zusammen)

1. Abends, wenn niemand bucht: in der App **„Sicherung jetzt“** (Import/Export).
2. `supabase/updates/2026-10_paket2.sql` im **echten** System im SQL-Editor ausführen. Danach den Fingerabdruck prüfen, er muss wieder `76b4e7da…` sein.
3. Pull Request mergen → nach 1–2 Minuten haben alle Geräte die neue App (einmal neu laden).

**Zurück, falls nötig:** Pull Request „Revert“ genügt. Das Datenbank-Update darf bleiben, die alte App läuft damit.

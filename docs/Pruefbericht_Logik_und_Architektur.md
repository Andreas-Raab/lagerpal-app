# Prüfbericht LagerPal – Logik, Fachlichkeit, Architektur, Sicherheit, Betrieb

**Stand:** 02.10.2026 · **Geprüfte Dateien (vollständig gelesen):**
- `index.html` (3141 Zeilen, Frontend)
- `supabase/00_KOMPLETT_neu_aufsetzen.sql` (1630 Zeilen, Datenbank)
- `supabase/functions/lagerpal-backup/index.ts` (378 Zeilen, nächtliches Backup + JTL-Export)

Es wurde **kein Code geändert**. Zeilenangaben beziehen sich auf den Stand von Commit `77317bc`.

---

## 1. Zusammenfassung und Gesamturteil

### Was die App macht (kurz)
LagerPal verwaltet für ein Lager **Artikel** (Nummer, Name, EAN, Set-Kennzeichen, Amazon-Status), deren **Bestände je Lagerplatz/Karton**, **Paletten** (Gruppen von Kartons), ein **Protokoll** aller Buchungen, **Leermeldungen** („Glocke“, wenn ein Platz leer wird), eine **Inventur** je Lagerplatz, den Ablauf **„Palette sortieren“** (Quelle ausräumen und Artikel nach Amazon-Status in Online-/Offline-Kartons einsortieren), **unbekannte Artikel** (Platzhalter WE-0-… in Klärfall-Kartons), **Importe** (Bestände aus JTL/CSV/Excel, Amazon-Status) und **Exporte** (u. a. JTL-Lagerbestand und JTL-Lagerbestandskommentar). Jede Nacht sichert eine Edge Function alle Daten nach Dropbox und legt dort die JTL-Kommentar-Datei ab.

### Gesamturteil
Die **Grundarchitektur ist gut**: Alle Bestandsänderungen laufen über Datenbank-Funktionen (RPC), jede Funktion ist eine Transaktion (alles oder nichts). Ausbuchungen ziehen nur ab, wenn genug Bestand da ist (bedingtes `UPDATE … WHERE menge >= x`), die Datenbank verbietet negative Bestände selbst (CHECK-Constraint), direkte Schreibzugriffe aus dem Browser sind gesperrt, die Funktionen haben einen festen `search_path`, und die Texte werden im Frontend durchgängig gegen Schadcode (XSS) maskiert. Der Frontend-Export „Lagerbestandskommentar (JTL)“ und der nächtliche Export der Edge Function erzeugen **nachweislich dieselbe Datei** (gleiche Sortierung, Spalten, Trennzeichen, CRLF, UTF-8-BOM, gleiche Ausnahme für unbekannte Artikel).

Die **Schwachstellen** liegen weniger in den Rechenwegen als in vier Bereichen:
1. **Zugriffsrechte:** Jeder angemeldete Nutzer darf alles – auch „Alles löschen“ und „Backup einspielen“. Ob sich Fremde selbst registrieren können, steht nicht im Code und muss sofort geprüft werden.
2. **Bedienung im Lager:** Doppelklicks, Netzfehler und die Enter-Taste des Barcode-Scanners können **Doppelbuchungen oder unbeabsichtigte Bestätigungen** auslösen.
3. **Mehrere Geräte gleichzeitig:** Karton-Nummernvergabe, Rückgängig-Leiste und Inventur sind auf einen einzelnen Nutzer ausgelegt.
4. **Wachstum und Notfall:** Viele Abfragen laden ganze Tabellen in den Browser. Das Einspielen eines Backups läuft als eine einzige große Anfrage und ist bei wachsender Datenmenge nicht abgesichert. Die Wiederherstellung ist nicht erprobt.

**Bilanz:** 37 Funde – 1 kritisch, 4 hoch, 17 mittel, 15 niedrig. Keiner der Funde verursacht unbemerkt *negative* Bestände. Mehrere können aber zu **falschen Beständen** führen, also zu Doppel- oder Fehlbuchungen. Dazu kommen **Datenverlust durch Fehlbedienung oder Fremdzugriff** und **Ausfälle bei wachsender Datenmenge**.

---

## 2. Übersicht aller Funde

| Nr. | Schwere | Bereich | Kurztitel |
|---|---|---|---|
| 1 | **Kritisch** (Prüfen) | Sicherheit | Offene Selbstregistrierung würde Fremden vollen Schreib-/Löschzugriff geben |
| 2 | **Hoch** | Sicherheit / Architektur | Keine Rollen: jeder Nutzer darf alles löschen, überschreiben, einspielen |
| 3 | **Hoch** | Logik | Doppelbuchungen durch Doppelklick oder Wiederholen nach Netzfehler |
| 4 | **Hoch** | Logik / Fachlich | Scanner-Enter bestätigt Rückfragen (Inventur-Zugang, Set-Warnung) ungewollt |
| 5 | **Hoch** (Prüfen) | Betrieb | Backup-Einspielen bei wachsender Datenmenge nicht abgesichert und nie erprobt |
| 6 | Mittel | Logik | „Palette sortieren“: schnelle Folge-Scans gehen still verloren |
| 7 | Mittel | Logik / Mehrgeräte | Karton-Vergabe im Browser; bestehende Kartons werden überschrieben/doppelt belegt |
| 8 | Mittel | Architektur | 1000-Zeilen-Grenze: Lagerplatz-/Karton-Listen werden ab 1000 Plätzen still abgeschnitten |
| 9 | Mittel | Fachlich | Rückgängig-Leiste ist global (fremde Aktionen, durch jede fremde Buchung blockiert) |
| 10 | Mittel | Fachlich / Logik | Inventur: leere Plätze nicht zählbar; Buchungen zwischen Laden und Übernahme gehen verloren |
| 11 | Mittel | Fachlich | Leermeldungs-Flut beim Palette-Sortieren und Sammel-Ausbuchen |
| 12 | Mittel | Fachlich | Teil-Import schreibt sofort ohne Vorschau/Bestätigung |
| 13 | Mittel | Logik | Amazon-Import: unbekannte Statuswerte werden als „online“ gesetzt |
| 14 | Mittel | Logik | Excel-Import verliert führende Nullen → EANs werden falsch überschrieben |
| 15 | Mittel | Datenmodell | Lagerplätze/Paletten sind Freitext ohne Fremdschlüssel und ohne Normalisierung |
| 16 | Mittel | Nachvollziehbarkeit | Protokoll speichert nicht, *wer* gebucht hat |
| 17 | Mittel (Prüfen) | Schnittstelle JTL | JTL-Lagerbestand-Export: gelöschte/umbenannte Plätze tauchen nicht mit 0 auf |
| 18 | Mittel | Skalierung | Nach jeder Buchung werden ganze Tabellen neu geladen |
| 19 | Mittel | Betrieb | Backup: Offset-Blättern, keine konsistente Momentaufnahme, wächst unbegrenzt |
| 20 | Mittel | Fachlich | Protokoll: nur die neuesten 200 Einträge durchsuchbar, Meldung irreführend |
| 21 | Mittel | Sicherheit / Betrieb | Fremdbibliotheken ungepinnt (supabase-js@2), ohne Integritätsprüfung, xlsx mit bekannten Lücken |
| 22 | Mittel | Betrieb | Notfall-Wiederherstellung unvollständig (Nutzer, Zeitplan, Secrets, Setup-Skript nicht wiederholbar) |
| 23 | Niedrig | Logik | Rückgängig von „Zusammenlegung“/„Lagerplatz gelöscht“ stellt Palette/Kanal nicht wieder her |
| 24 | Niedrig | Logik | Rückgängig „Artikeländerung“ blockiert bei geteilter EAN (Widerspruch zum Konzept) |
| 25 | Niedrig | Logik | „Palette sortieren“: Rückgängig nimmt nur die Hälfte eines Scans zurück |
| 26 | Niedrig | Logik | Sammel-Ausbuchen protokolliert ggf. eine veraltete Menge |
| 27 | Niedrig | Datenmodell | Doppelte offene Leermeldungen möglich |
| 28 | Niedrig | Logik | Suche: Mengenfeld kann bei ähnlichen Platznamen vom falschen Feld gelesen werden |
| 29 | Niedrig | Logik | Artikel-Export: Gesamtbestand falsch, wenn Lagerplatz einen Doppelpunkt enthält |
| 30 | Niedrig | Texte | Falsche bzw. irreführende Beschriftungen |
| 31 | Niedrig | Nachvollziehbarkeit | Stammdatenänderungen per Import ohne Protokoll; Protokollspalten uneinheitlich genutzt |
| 32 | Niedrig | Logik | Suche: veraltete Antwort kann neuere überschreiben; Auswahl bleibt über Filterwechsel |
| 33 | Niedrig | Fehlerbehandlung | Mehrere Fehler werden still verschluckt (leere Listen ohne Meldung) |
| 34 | Niedrig (Prüfen) | Sicherheit | Backup-Funktion von außen mit dem öffentlichen Schlüssel auslösbar |
| 35 | Niedrig | Sicherheit (Härtung) | `esc()` maskiert keine Anführungszeichen; CSV-Formel-Injection möglich |
| 36 | Niedrig (Prüfen) | Fachlich | Platzhalter-Nummernkreis WE-0-… nicht gegen JTL-Nummern abgesichert |
| 37 | Niedrig | Mehrgeräte | Gleichzeitiger Scan derselben neuen EAN: zweites Gerät erhält Fehler |

---

## 3. Funde im Detail

### Fund 1 – Offene Selbstregistrierung würde Fremden vollen Zugriff geben · **Kritisch (Prüfen)**

**Fundstelle:** `00_KOMPLETT_neu_aufsetzen.sql:128-163` (Sicherheitsmodell: „angemeldet = darf alle Funktionen aufrufen“), z. B. `alles_loeschen` `:1221-1253` und `backup_wiederherstellen` `:1262-1394`, jeweils `grant execute … to authenticated`. `index.html:161-163` und `:538` (anon-Key wird eingegeben und im Browser gespeichert).

**Beschreibung:** Die gesamte Sicherheit beruht darauf, dass nur Lager-Mitarbeiter ein Konto haben („authenticated“). Supabase erlaubt bei neuen Projekten aber **standardmäßig die Selbstregistrierung** („Allow new users to sign up“). Der anon-Key ist kein Geheimnis: Er steht im Browser jedes Lagergeräts (localStorage) und ist in jedem Netzwerk-Mitschnitt sichtbar. Ob die Registrierung abgeschaltet ist, lässt sich aus dem Code nicht erkennen.

**Auslöse-Szenario:** Jemand kennt die Projekt-URL und den anon-Key (z. B. ehemaliger Mitarbeiter, Aushilfe, Blick in den Browser eines Lagergeräts). Er ruft `auth.signUp()` mit einer eigenen E-Mail auf, bestätigt die Mail und ruft anschließend `rpc('alles_loeschen', {p_bestaetigung:'ALLES LOESCHEN'})` auf. Die Bestätigungsphrase steht im Klartext im Quelltext.

**Auswirkung:** Kompletter Datenverlust oder unbemerkte Manipulation (über `backup_wiederherstellen` lassen sich beliebige Bestände und ein gefälschtes Protokoll einspielen). Außerdem kann der Angreifer alle Geschäftsdaten lesen (Artikel, Bestände, Protokoll).

**Lösungsvorschlag:**
1. **Sofort** im Supabase-Dashboard unter *Authentication → Sign In / Providers* „Allow new users to sign up“ **ausschalten**. Nutzer nur noch per Einladung anlegen.
2. Bestehende Nutzerliste prüfen und unbekannte Konten löschen.
3. Zusätzlich Fund 2 umsetzen (Rollen), damit auch ein kompromittiertes Mitarbeiterkonto nicht alles löschen kann.

---

### Fund 2 – Keine Rollen: jeder Nutzer darf alles · **Hoch**

**Fundstelle:** SQL `:1214-1215` (`bestand_csv_import`), `:1252-1253` (`alles_loeschen`), `:1393-1394` (`backup_wiederherstellen`), `:1009-1010` (`amazon_status_setzen`), `:621-622` (`artikel_loeschen`), `:979-980` (`lagerplatz_loeschen`). Frontend `index.html:469-504` (Reset- und Einspiel-Bereich für alle sichtbar).

**Beschreibung:** Es gibt nur eine Berechtigungsstufe. Ein Lagerhelfer am Scanner-Gerät hat dieselben Rechte wie der Inhaber: Komplett-Import (setzt alle nicht genannten Bestände auf 0), Backup einspielen, alles löschen, Artikel mit Bestand löschen.

**Auslöse-Szenario:** Ein Mitarbeiter will „nur mal den Import ausprobieren“, wählt „Komplett-Import“ mit einer Teilliste und bestätigt. Alle Plätze, die nicht in der Datei stehen, werden auf 0 gesetzt. Das ist nicht per Rückgängig umkehrbar (Import ist nicht in der Rückgängig-Liste).

**Auswirkung:** Hohes Risiko großflächiger Fehlbestände durch Fehlbedienung. Eine Korrektur ist nur über ein Backup möglich, und dabei gehen alle späteren Buchungen verloren.

**Lösungsvorschlag:** Eine Rolle „admin“ einführen (z. B. in `auth.users.raw_app_meta_data->>'role'` oder eine Tabelle `benutzer_rollen`) und in den gefährlichen Funktionen am Anfang prüfen:
`if coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then raise exception 'Nur für Administratoren'; end if;`
Im Frontend die Bereiche „Komplett-Import“, „Reset“, „Backup einspielen“, „Artikel löschen“ und „Amazon-Vollabgleich“ nur Admins anzeigen.

---

### Fund 3 – Doppelbuchungen durch Doppelklick oder Wiederholung nach Netzfehler · **Hoch**

**Fundstelle:**
- `index.html:2070-2081` `ssBookPick` (Platzwahl-Knöpfe im Scanner, `:2143-2144`, `:2159`) – keine Sperre gegen mehrfachen Aufruf.
- `index.html:838-858` `sucheBuchen` („+ Ein“/„− Aus“ in der Suche) – keine Sperre.
- `index.html:1806-1824` `umlagern` – Knopf bleibt aktiv.
- `index.html:1275-1340` `erScan` („Buchen“-Knopf und Enter) – keine Sperre (anders als `ssScan`, `:2085-2090`, der eine hat).
- SQL `buchen` `:256-330`, `umlagern` `:335-393`, `einraeumen_scan` `:406-479`: Keine dieser Funktionen erkennt einen bereits verarbeiteten Vorgang wieder (kein „Idempotenzschlüssel“).

**Beschreibung:** Jeder Klick erzeugt einen eigenen Datenbank-Aufruf. Bei langsamer Verbindung (WLAN im Lager) sieht der Nutzer nach dem ersten Klick keine Reaktion und klickt erneut. Bei einem Netzfehler *nach* dem Speichern (Antwort geht verloren) meldet die App „Fehler“, obwohl gebucht wurde. Der Nutzer wiederholt dann die Buchung.

**Auslöse-Szenario A:** Scanner im Modus „Ausbuchen“, Artikel liegt auf zwei Plätzen. Nutzer tippt zweimal schnell auf „Regal 3 (12)“. Ergebnis: zwei Ausgänge, Bestand 12 → 10 statt 11.
**Szenario B:** In der Suche Menge 5 eintragen, „+ Ein“ klicken, WLAN bricht kurz ab. Die Buchung ist gespeichert, aber die App zeigt „Fehler: Failed to fetch“. Der Nutzer klickt erneut, und es sind 10 statt 5 eingebucht.

**Auswirkung:** Falsche Bestände, die nur bei der nächsten Inventur auffallen. Dadurch entstehen auch falsche JTL-Exporte.

**Lösungsvorschlag:**
1. **Frontend:** In allen Buchungsfunktionen eine Sperre wie `ssLaeuft` einbauen und den geklickten Knopf bzw. die Platzwahl-Knöpfe bis zur Antwort deaktivieren.
2. **Datenbank:** Den Funktionen `buchen`, `umlagern`, `einraeumen_scan`, `unbekannt_einbuchen` einen Parameter `p_vorgang_id uuid` geben. Das Frontend erzeugt pro Klick eine UUID (`crypto.randomUUID()`) und sendet bei einer Wiederholung dieselbe. In `buchungen` eine Spalte `vorgang_id uuid unique` anlegen. Ist die ID schon vorhanden, gibt die Funktion das alte Ergebnis zurück statt erneut zu buchen.
3. Bei Netzfehlern den Text „Unklar, ob gebucht wurde – bitte Protokoll prüfen“ anzeigen statt nur „Fehler“.

---

### Fund 4 – Scanner-Enter bestätigt Rückfragen ungewollt · **Hoch**

**Fundstelle:**
- `index.html:1318-1321` (`erScan`: `confirm("… zusätzlichen als Inventur-Zugang … buchen?")`)
- `index.html:2126-2130` (`ssScanIntern`: Set-Artikel-Warnung per `confirm`)
- `index.html:849-852` (Suche, Set-Warnung)
- Der Code selbst stellt fest (`:1844-1846`, `:1860-1862`): „man kann sich nicht darauf verlassen, dass jemand auf den Bildschirm schaut“.

**Beschreibung:** Browser-Dialoge (`confirm`) haben den „OK“-Knopf vorausgewählt. Ein Handscanner schickt nach jedem Barcode ein Enter. Ist der Dialog offen und scannt der Mitarbeiter schon den nächsten Artikel, landen die Ziffern im Dialog (werden ignoriert) und das **Enter drückt „OK“**.

**Auslöse-Szenario:** „Palette sortieren“: Auf der Quelle sind laut System 2 Stück gebucht, der Mitarbeiter scannt Menge 5. Der Dialog „3 zusätzliche als Inventur-Zugang buchen?“ erscheint. Der Mitarbeiter schaut nicht hin und scannt den nächsten Artikel. Das Enter bestätigt den Dialog, und 3 Stück werden als Zugang gebucht. Der nächste Artikel ist nicht gebucht, obwohl er im Karton liegt. Bei der Set-Warnung ist es dasselbe: Die Warnung wird „weggescannt“.

**Auswirkung:** Phantom-Bestand (Inventur-Zugänge, die niemand bewusst bestätigt hat), fehlende Buchungen für den Folge-Artikel, wirkungslose Set-Warnung.

**Lösungsvorschlag:** `confirm()` in Scan-Abläufen durch einen eigenen Dialog (HTML-Modal) ersetzen. Bestätigen nur per Maus/Touch oder mit einer bestimmten Taste (z. B. „J“). Enter und Ziffern ignorieren, solange der Dialog offen ist. Zusätzlich einen Warnton und eine Sprachansage abspielen („Mehrmenge – bitte bestätigen“), wie es die App bei unbekannten Artikeln bereits tut.

---

### Fund 5 – Backup-Einspielen bei wachsender Datenmenge nicht abgesichert · **Hoch (Prüfen)**

**Fundstelle:** `index.html:2568` (die komplette Sicherungsdatei wird als **ein einziger** RPC-Aufruf gesendet), SQL `backup_wiederherstellen` `:1262-1392`. Ähnlich `bestand_csv_import` im Komplett-Modus `:1178-1201` (Schleife über *alle* Artikel mit Einzelabfragen).

**Beschreibung:** Supabase begrenzt für angemeldete Nutzer die Laufzeit einer Abfrage standardmäßig auf **8 Sekunden** (`statement_timeout` der Rolle `authenticated`). Die Wiederherstellung löscht und befüllt alle Tabellen in einer Anfrage. Das Protokoll (`buchungen`) wächst unbegrenzt (jeder Scan ist eine Zeile). Mit der Zeit wird die Sicherungsdatei mehrere 10 MB groß und das Einfügen dauert länger als das Zeitlimit. Dann wird **alles zurückgerollt** (das ist sicher, aber das Einspielen schlägt fehl). Dasselbe gilt für den Komplett-Import bei großen Artikelzahlen. Eine Probe-Wiederherstellung ist im Repo nicht dokumentiert.

**Auslöse-Szenario:** Nach einem Jahr Betrieb mit ca. 1000 Scans pro Tag hat das Protokoll ca. 365 000 Zeilen. Nach einem Datenunfall wird das Backup eingespielt, und nach 8 Sekunden kommt „canceling statement due to statement timeout“. Die Wiederherstellung ist über die App nicht möglich, und genau dann fehlt die Zeit für eine Lösung.

**Auswirkung:** Der Notfallweg funktioniert genau dann nicht, wenn er gebraucht wird.

**Lösungsvorschlag:**
1. **Jetzt** eine Probe-Wiederherstellung in einem zweiten (kostenlosen) Supabase-Projekt durchführen und die Dauer messen. Den Ablauf als Notfall-Anleitung dokumentieren.
2. Für `backup_wiederherstellen` und `bestand_csv_import` das Zeitlimit gezielt erhöhen: `alter function backup_wiederherstellen(jsonb) set statement_timeout = '300s';` (gilt nur innerhalb der Funktion).
3. Alternativ als Notfallweg die Wiederherstellung über den SQL-Editor oder `psql` dokumentieren. Dort gibt es kein 8-Sekunden-Limit.
4. Den Komplett-Import mengenbasiert umschreiben (ein `UPDATE … FROM` statt Schleife je Artikel).

---

### Fund 6 – „Palette sortieren“: schnelle Folge-Scans gehen still verloren · **Mittel**

**Fundstelle:** `index.html:1275-1340` (`erScan`). Das Scanfeld wird **erst am Ende** geleert (`:1305`, `:1336`), es gibt keine Sperre. Zum Vergleich: Der Scanner-Reiter leert das Feld sofort und sperrt (`:2085-2095`).

**Beschreibung:** Während der erste Scan noch auf die Datenbank wartet, steht der erste Barcode weiter im Feld. Scannt der Mitarbeiter schon den nächsten Artikel, wird dessen Code **angehängt** („40063813339314006381333931“). Dieser Code wird als „Nicht gefunden“ abgewiesen. Kurz danach meldet der erste Scan Erfolg, leert das Feld und **überschreibt die Fehlermeldung**.

**Auslöse-Szenario:** Langsames WLAN, Mitarbeiter scannt zügig zwei Artikel hintereinander. Auf dem Bildschirm steht nur „🟢 ONLINE → Karton P01-K03“, und die Sprachansage sagt „online“. Der zweite Artikel liegt physisch im Karton, ist aber nicht gebucht.

**Auswirkung:** Bestand auf der Quelle zu hoch, im Karton zu niedrig. Das Karton-Blatt ist unvollständig.

**Lösungsvorschlag:** Dasselbe Muster wie beim Scanner übernehmen: Code sofort aus dem Feld nehmen und leeren, und eine Sperrvariable setzen. Läuft noch ein Scan, Warnton und „bitte nochmal scannen“ ausgeben.

---

### Fund 7 – Karton-Vergabe im Browser; bestehende Kartons werden überschrieben · **Mittel**

**Fundstelle:** `index.html:1112-1116` (`erNaechsteNummer` aus der lokalen Platzliste), `:1150-1157` (`erNeuerKarton`), `:1144-1146` (Vorauswahl „leerer Karton wird weiterverwendet“), SQL `karton_setzen` `:484-499` (`on conflict (name) do update set palette=…, kanal=…`).

**Beschreibung:** Die nächste Kartonnummer (P01-K07 …) berechnet der Browser aus seiner zuletzt geladenen Platzliste. `karton_setzen` legt den Karton an oder **überschreibt** Palette und Kanal eines bestehenden Kartons ohne Rückfrage. Außerdem wählt die App beim Start einer Sortierung automatisch einen „leeren“ Karton der Palette vor. Das kann der Karton sein, den gerade ein *anderes* Gerät frisch angelegt hat und befüllen will.

**Auslöse-Szenario:** Zwei Mitarbeiter sortieren je eine Quelle auf Palette P03. Gerät A legt P03-K05 (online) an, hat aber noch nichts gescannt. Gerät B startet und bekommt P03-K05 als „leer“ vorausgewählt. Beide legen jetzt Ware in *ihren* physischen Karton „P03-K05“. In der Datenbank ist es ein Platz, und das Karton-Blatt listet den Inhalt beider Kisten. Variante: Klicken beide fast gleichzeitig auf „Karton voll → nächster“, erhalten beide dieselbe Nummer, und der Kanal des Online-Kartons wird auf „nicht online“ überschrieben.

**Auswirkung:** Vermischte Kartons, falsche Karton-Blätter, Online-Ware im Offline-Karton.

**Lösungsvorschlag:** Eine Datenbankfunktion `karton_neu(p_palette, p_kanal)` anlegen, die unter einer Sperre (`pg_advisory_xact_lock`) die höchste Nummer *in der Datenbank* ermittelt, den neuen Karton anlegt und den Namen zurückgibt. `karton_setzen` soll beim Anlegen nicht stillschweigend fremde Kartons umwidmen (eigener Parameter „überschreiben erlaubt“). Die Vorauswahl soll nur Kartons berücksichtigen, die keiner aktiven Sortierung gehören. Dafür die aktive Sortierung in der Datenbank statt nur im localStorage führen.

---

### Fund 8 – 1000-Zeilen-Grenze: Listen werden still abgeschnitten · **Mittel**

**Fundstelle:** Ungeblätterte Abfragen auf `v_lagerplaetze`: `index.html:657` (`ladeAllePlaetze` → Scanner-Knöpfe, Umlagern-Ziele, Kartonnummern), `:1066` (Quellen für Palette sortieren), `:1123-1124`, `:2173` (Reiter Lagerplätze, alle Auswahllisten), `:2813` (Inventur-Platzliste).

**Beschreibung:** Supabase liefert pro Anfrage höchstens 1000 Zeilen. An diesen Stellen fehlt das Blättern (`fetchAll`), und es gibt keine Sortierung. Die App bekommt dann eine **zufällige Teilmenge**, ohne Hinweis. Mit 40 Paletten × 25 Kartons plus Regalplätzen sind 1000 Plätze realistisch.

**Auslöse-Szenario:** Bei 1100 Plätzen fehlen ca. 100 in „Lagerplätze verwalten“, in der Inventur-Auswahl und in den Scanner-Knöpfen. Besonders heikel: Ein frisch angelegter, noch leerer Karton fehlt in `allePlaetze`. `erNaechsteNummer` sieht ihn nicht und vergibt seine Nummer erneut (siehe Fund 7).

**Auswirkung:** Plätze sind nicht auswählbar oder verwaltbar, und Kartonnummern werden doppelt vergeben.

**Lösungsvorschlag:** Überall `fetchAll(...)` verwenden, wie es an anderen Stellen bereits gemacht wird. Besser: eine Datenbankfunktion bzw. View, die genau das Benötigte liefert (z. B. nur die Namen, sortiert) oder serverseitig filtert (Plätze einer Palette, Plätze mit Bestand).

---

### Fund 9 – Rückgängig-Leiste ist global · **Mittel**

**Fundstelle:** `index.html:598-621` (`refreshUndo` lädt die neueste Buchung *aller* Nutzer), SQL `rueckgaengig` `:741-745` (jede neuere Buchung irgendeines Nutzers blockiert).

**Beschreibung:** Die Leiste zeigt die letzte Aktion **im gesamten Lager**, nicht die eigene. Sobald ein anderes Gerät irgendetwas bucht, ist die eigene Aktion nicht mehr rückgängig zu machen.

**Auslöse-Szenario A:** Mitarbeiter A bucht versehentlich 50 statt 5 ein und will es rückgängig machen. In der Zwischenzeit hat Mitarbeiter B einen Artikel gescannt. Ergebnis: „Rückgängig nicht mehr möglich“. **Szenario B:** Die Leiste bei A zeigt B's Buchung, A klickt auf „Rückgängig“ und nimmt **B's Buchung** zurück, ohne dass B davon weiß.

**Auswirkung:** Im Mehrgerätebetrieb ist die Funktion praktisch unbrauchbar oder sogar schädlich.

**Lösungsvorschlag:** Benutzer im Protokoll speichern (Fund 16). Rückgängig nur für eigene Aktionen anbieten und die Konfliktprüfung auf **betroffene Objekte** beschränken: Blockieren nur, wenn danach derselbe Artikel auf demselben Platz bzw. derselbe Lagerplatz geändert wurde.

---

### Fund 10 – Inventur: leere Plätze nicht zählbar, Zwischenbuchungen gehen verloren · **Mittel**

**Fundstelle:** `index.html:2811-2817` (Platzauswahl nur mit `stueck > 0`), `:2841-2843` („Artikel ergänzen“ verlangt einen gewählten Platz), `:2853-2858` (sendet nur Zeilen mit Ist ≠ dem *beim Laden* gemerkten Soll), SQL `inventur_anwenden` `:679-684` (setzt den absoluten Wert, ohne Sperre).

**Beschreibung:**
1. Ein Platz, der laut System leer ist, kann nicht inventiert werden. Gerade dort findet man aber oft Ware.
2. Zwischen Laden der Liste und „Inventur übernehmen“ können andere Geräte buchen. Die Inventur überschreibt diese Buchungen mit dem gezählten Wert. Dabei wird nicht unterschieden, ob die Buchung vor oder nach dem Zählen stattfand.

**Auslöse-Szenario:** Mitarbeiter A zählt Regal 7 (Artikel X: Soll 10, gezählt 10). Währenddessen bucht B 3 Stück X von Regal 7 aus und nimmt sie mit. A ändert X nicht, also wird X nicht gesendet, und das ist korrekt. Hätte A aber 9 gezählt, setzt die Inventur X auf 9. B's Ausgang ist damit „vergessen“, und der Bestand ist 3 zu hoch.

**Auswirkung:** Falsche Bestände nach der Inventur. Ware auf „leeren“ Plätzen wird als „Eingang“ statt als „Inventur“ gebucht, und das verfälscht die Kennzahlen.

**Lösungsvorschlag:** Alle Plätze in der Inventur-Auswahl anbieten (auch leere, auch frei eingebbare). Beim Übernehmen die beim Laden gesehenen Soll-Werte mitsenden. Hat sich ein Soll inzwischen geändert, die betroffenen Zeilen markieren und nachfragen („Seit dem Laden wurden 3 Stk ausgebucht – gezählt vor oder nach dieser Buchung?“). In der SQL-Funktion die Zeilen mit `FOR UPDATE` sperren.

---

### Fund 11 – Leermeldungs-Flut · **Mittel**

**Fundstelle:** SQL `einraeumen_scan` `:465-471`, `sammel_ausbuchen` `:649-652`, `umlagern` `:373-379`.

**Beschreibung:** Jeder Artikel, der durch eine Umlagerung oder das Sortieren von einem Platz verschwindet, erzeugt eine Leermeldung. Beim Sortieren einer Palette soll die Quelle aber absichtlich leer werden.

**Auslöse-Szenario:** Eine Quelle mit 150 Artikelsorten wird sortiert, und die Glocke zeigt 150 Meldungen „… leer“. Die Mitarbeiter gewöhnen sich an „Alle als gesehen markieren“, und echte Leermeldungen (z. B. ein Pickplatz ist leer gelaufen) gehen unter.

**Auswirkung:** Das Warnsystem verliert seinen Nutzen.

**Lösungsvorschlag:** Bei absichtlichem Leerräumen (`einraeumen_scan`, `sammel_ausbuchen`, Umlagerung mit voller Menge) keine Leermeldung erzeugen oder sie mit einem eigenen Typ versehen, der in der Glocke getrennt bzw. ausgeblendet wird. Leermeldungen nur für Plätze erzeugen, die als „Pickplatz“ gekennzeichnet sind.

---

### Fund 12 – Teil-Import schreibt sofort ohne Vorschau · **Mittel**

**Fundstelle:** `index.html:2346-2384`, entscheidend `:2383` (`await bestandImportieren()` direkt nach Dateiauswahl im Teil-Modus). Der Hinweis `:419` sagt selbst, dass der Import nicht rückgängig zu machen ist.

**Beschreibung:** Im Teil-Modus wird die Datei **beim Auswählen** sofort importiert, ohne Vorschau und ohne Rückfrage. Der Amazon-Import hat eine Vorschau, der Komplett-Import eine Rückfrage, der Teil-Import keines von beiden.

**Auslöse-Szenario:** Jemand wählt versehentlich eine alte Exportdatei vom Vormonat aus. Alle darin enthaltenen Plätze werden sofort auf die alten Werte zurückgesetzt.

**Auswirkung:** Großflächig falsche Bestände, die nur einzeln per Protokoll korrigiert werden können.

**Lösungsvorschlag:** Wie beim Amazon-Import eine Vorschau anzeigen („X Plätze ändern sich, Summe vorher/nachher, Y neue Artikel, Beispiele“) und danach einen Knopf „Import ausführen“. Optional die Vorschau serverseitig berechnen lassen (Probelauf der Funktion mit `p_nur_pruefen`).

---

### Fund 13 – Amazon-Import: unbekannte Statuswerte werden „online“ · **Mittel**

**Fundstelle:** `index.html:2259-2264` (`statusAusWert` kennt nur bestimmte Wörter), `:2275-2276` (`let st = 1; … if (erk !== null) st = erk;`).

**Beschreibung:** Wird ein Statuswert nicht erkannt, bleibt der Artikel auf **online** (1).

**Auslöse-Szenario:** Der Amazon-Bericht „Alle Angebote“ enthält Status „Unvollständig“ bzw. „Incomplete“ oder „Gesperrt“. Diese Wörter kennt die Funktion nicht, also werden die Artikel als online gesetzt. Beim Palette-Sortieren landen sie im Online-Karton.

**Auswirkung:** Falsche Kanalzuordnung, Ware wird ins falsche Lager bzw. in den falschen Karton sortiert.

**Lösungsvorschlag:** Unbekannte Werte nicht stillschweigend übernehmen. In der Vorschau auflisten („12 Zeilen mit unbekanntem Status: ‚Unvollständig‘ …“) und entweder abbrechen oder ausdrücklich zuordnen lassen. Die Standardannahme „online“ nur gelten lassen, wenn die Datei gar **keine** Status-Spalte hat.

---

### Fund 14 – Excel-Import verliert führende Nullen · **Mittel**

**Fundstelle:** `index.html:2242-2246` (`XLSX.utils.sheet_to_json(ws, { defval: '' })` liefert Zahlen als Zahlen), `:2309`, `:2322` (`String(row[colGtin])`), SQL `bestand_csv_import` `:1123-1129` (überschreibt die GTIN, wenn die Datei eine hat).

**Beschreibung:** Ist in Excel die EAN- oder Artikelnummer-Spalte als Zahl formatiert, gehen führende Nullen verloren (z. B. `0012345678905` → `12345678905`). Ist „Unbekannte Artikel neu anlegen“ aktiv (die Reset-Anleitung `:2510` empfiehlt genau das), **überschreibt** der Import die korrekte EAN bestehender Artikel mit dem verkürzten Wert.

**Auslöse-Szenario:** JTL-Export in Excel geöffnet und gespeichert, dann mit „neu anlegen“ importiert. Danach werden alle Artikel mit EAN-Präfix 0 (z. B. US-Ware/UPC) beim Scannen nicht mehr gefunden und als „unbekannt“ in den Klärfall-Karton gebucht.

**Auswirkung:** Scans schlagen fehl, und es entstehen Platzhalter-Artikel für eigentlich bekannte Ware.

**Lösungsvorschlag:** `sheet_to_json(ws, { defval: '', raw: false })` verwenden (formatierten Text lesen). EANs mit 11–13 Ziffern auf GTIN-Länge mit Nullen auffüllen und die Prüfziffer kontrollieren (`eanGueltig` existiert bereits). Bestehende EANs nur ändern, wenn die neue gültig ist. Änderungen im Protokoll vermerken (Fund 31).

---

### Fund 15 – Lagerplätze und Paletten sind Freitext ohne Fremdschlüssel · **Mittel**

**Fundstelle:** SQL `:30-45` (`bestaende.lagerplatz` ohne Verweis auf `lagerplaetze`; `lagerplaetze.palette` ohne Verweis auf `paletten`), `buchen` `:284-288` (bucht auf jeden beliebigen Namen), `karton_setzen` `:489-493` (kein `trim`, im Gegensatz zu `lagerplatz_neu` `:875`), `angelegt text` `:42` / `now()::text` `:492`. Frontend: `index.html:845` (Lagerplatz per `prompt` frei eingeben), `:2927` (Palette als Freitextfeld).

**Beschreibung:** Ein Lagerplatz „existiert“, sobald irgendwo ein Bestand mit diesem Namen steht. Die Tabelle `lagerplaetze` ist nur eine zweite, unvollständige Liste. Es gibt keine einheitliche Schreibweise (Leerzeichen, Groß-/Kleinschreibung). Paletten können in „Karton-Einstellungen“ frei getippt werden, ohne dass sie in der Palettenliste stehen.

**Auslöse-Szenario:** In der Suche bei einem Artikel ohne Platz auf „+ Ein“ klicken und „regal 3“ statt „Regal 3“ tippen. Es entsteht ein neuer, unsichtbar getrennter Platz. Oder in „Karton-Einstellungen“ die Palette „p01“ statt „P01“ eintragen: Der Karton erscheint nicht mehr unter Palette P01 und kann beim Sortieren nicht gewählt werden.

**Auswirkung:** Bestand „verschwindet“ auf Tippfehler-Plätzen, Exporte nach JTL enthalten Phantom-Lagerplätze, und Umbenennen und Zusammenlegen müssen mehrere Tabellen von Hand nachziehen.

**Lösungsvorschlag:** `lagerplaetze` zur einzigen Quelle machen: alle vorhandenen Namen übernehmen, dann `bestaende.lagerplatz references lagerplaetze(name) on update cascade` und `lagerplaetze.palette references paletten(name) on update cascade`. Neue Plätze nur über `lagerplatz_neu` bzw. `karton_neu`. In allen Funktionen Namen einheitlich mit `trim` behandeln und Groß-/Kleinschreibung über einen eindeutigen Index auf `lower(name)` abfangen. `angelegt` als `timestamptz` speichern.

---

### Fund 16 – Protokoll speichert nicht, wer gebucht hat · **Mittel**

**Fundstelle:** SQL `buchungen` `:50-65` (keine Benutzerspalte), alle Funktionen schreiben ohne `auth.uid()`.

**Beschreibung:** Bei mehreren Mitarbeitern ist nicht nachvollziehbar, wer eine Buchung, einen Import oder eine Löschung gemacht hat. Lagergeräte bleiben dauerhaft angemeldet (Sitzung im localStorage, `index.html:550-554`).

**Auslöse-Szenario:** Nach einem Komplett-Import mit falscher Datei weiß niemand, von welchem Gerät oder Konto er kam.

**Auswirkung:** Keine Revisionssicherheit, keine Rückfragen möglich. Außerdem ist ein „eigenes Rückgängig“ (Fund 9) unmöglich.

**Lösungsvorschlag:** Spalte `benutzer uuid default auth.uid()` (und optional `benutzer_email`) in `buchungen` und `leermeldungen` anlegen, in allen Funktionen befüllen und im Protokoll anzeigen. Jedem Mitarbeiter ein eigenes Konto geben. Optional eine automatische Abmeldung bei Inaktivität.

---

### Fund 17 – JTL-Lagerbestand-Export: verschwundene Plätze fehlen · **Mittel (Prüfen)**

**Fundstelle:** `index.html:2422-2433` (exportiert nur vorhandene `bestaende`-Zeilen). Zeilen werden gelöscht durch `lagerplatz_loeschen` SQL `:971`, `lagerplatz_zusammenlegen` `:939`, `lagerplatz_umbenennen` `:902` (alter Name verschwindet) und `artikel_loeschen` `:613`.

**Beschreibung:** Der Export enthält nur Plätze, die aktuell in LagerPal existieren. Wird ein Platz gelöscht, umbenannt oder zusammengelegt, erscheint der **alte** Platz nicht mehr, auch nicht mit Menge 0. Wenn JTL beim Import nur die genannten Plätze setzt (üblich bei absoluter Übernahme), bleibt dort der alte Bestand stehen. Außerdem ist zu prüfen, ob JTL die Spalte „Einzubuchende Menge“ als **absoluten Bestand** oder als **zu buchende Differenz** liest. Bei Differenz würde jeder Export den Bestand in JTL erhöhen. LagerPal liest dieselbe Spalte beim Re-Import als absoluten Bestand (`:2295`).

**Auslöse-Szenario:** „Regal 5“ wird in „R05“ umbenannt. Nach dem nächsten Export und JTL-Import hat JTL denselben Bestand doppelt: alt auf „Regal 5“, neu auf „R05“.

**Auswirkung:** Abweichende Bestände zwischen LagerPal und JTL, Überverkäufe oder Fehlmengen im Shop.

**Lösungsvorschlag:** Mit JTL klären, wie der Import konfiguriert ist (absolut/relativ, ob nicht genannte Plätze auf 0 gehen). Falls nötig: beim Löschen, Umbenennen und Zusammenlegen 0-Zeilen für den alten Platz behalten (statt die Zeilen zu löschen) oder die zuletzt exportierten Plätze merken und beim nächsten Export mit 0 ausgeben.

---

### Fund 18 – Nach jeder Buchung werden ganze Tabellen neu geladen · **Mittel**

**Fundstelle:** `index.html:655-663` (`ladeAllePlaetze` lädt **alle** `bestaende`-Zeilen, um Platznamen zu sammeln), aufgerufen nach jeder Scanner-Buchung `:2064`, nach jeder Suche-Buchung `:855`. `:696-711` (`ladeSucheDaten`: alle Artikel, alle Bestände, alle Plätze), aufgerufen nach jeder Buchung aus der Suche `:857`.

**Beschreibung:** Bei z. B. 30 000 Bestandszeilen löst jeder Scan 30 Anfragen zu je 1000 Zeilen aus, nur um die Platznamen neu zu bestimmen. Eine Buchung in der Suche lädt danach alle Artikel und Bestände neu.

**Auslöse-Szenario:** 3 Geräte scannen parallel bei langsamem WLAN. Jede Buchung zieht mehrere MB Daten, das Scannen wird spürbar träge, und die Wartezeit begünstigt Fund 3 und Fund 6.

**Auswirkung:** Lange Wartezeiten, hoher Datenverbrauch, mehr Fehlbedienungen. Das Problem wächst mit dem Datenbestand.

**Lösungsvorschlag:** Eine View `v_platznamen` (`select name from lagerplaetze union select distinct lagerplatz from bestaende`) einmal beim Start laden und nach Buchungen nur die betroffene Zeile lokal aktualisieren. Die Suche serverseitig filtern (Volltextsuche per RPC mit Limit) statt den gesamten Bestand im Browser zu halten.

---

### Fund 19 – Backup: Offset-Blättern, keine konsistente Momentaufnahme, unbegrenztes Wachstum · **Mittel**

**Fundstelle:** Edge Function `index.ts:56-72` (`range(from, from+999)`, Abbruch bei `< 1000` Zeilen), `:335-338` (Tabellen nacheinander, alles im Arbeitsspeicher), Frontend `index.html:2454-2465` und `:2660-2685` (dasselbe Muster). SQL-Kommentar `:1264-1270` bestätigt, dass inkonsistente Sicherungen schon vorkamen.

**Beschreibung:**
- Die Tabellen werden in einzelnen Anfragen nacheinander gelesen. Wird währenddessen gebucht, passen Artikel- und Bestandsliste nicht zusammen, und beim Blättern können Zeilen **doppelt oder gar nicht** in der Sicherung landen. Die Wiederherstellung überspringt solche Zeilen und meldet sie. Der Bestand ist dann aber verloren.
- Das Blättern per „Offset“ wird mit wachsendem Protokoll quadratisch langsamer. Alles liegt gleichzeitig im Speicher der Edge Function (Limit ca. 256 MB, Laufzeitlimit).
- Die Schleife bricht ab, sobald eine Seite weniger als 1000 Zeilen liefert. Ist im Projekt ein kleineres Zeilenlimit eingestellt (z. B. 500), wird **nur die erste Seite** gesichert, ohne Fehlermeldung (Prüfen: Einstellung „Max rows“ im Supabase-Dashboard).

**Auslöse-Szenario:** Manuelle Sicherung während laufender Scans: Ein neuer Artikel wird eingefügt, die Seitengrenzen verschieben sich, und ein Artikel fehlt in der Datei. Beim Einspielen werden seine Bestände als „ohne Artikel“ verworfen.

**Auswirkung:** Lückenhafte Sicherungen. In 1–2 Jahren kann die nächtliche Sicherung wegen Laufzeit oder Speicher scheitern (wird dann immerhin per Healthcheck gemeldet, falls `HEALTHCHECK_URL` gesetzt ist).

**Lösungsvorschlag:** Eine SQL-Funktion `backup_export()` (nur für `service_role`) bauen, die alle Tabellen **in einer Transaktion** als JSON liefert, oder pro Tabelle mit Schlüssel-Blättern (`where id > letzte_id order by id limit 1000`) in einer `REPEATABLE READ`-Transaktion arbeiten. Abbruchbedingung „leere Seite“ statt „< 1000“. Das Protokoll ab einer bestimmten Größe monatsweise in eigene Dateien schreiben. Die manuelle Sicherung im Browser über dieselbe Funktion laufen lassen.

---

### Fund 20 – Protokoll: nur die neuesten 200 Einträge durchsuchbar · **Mittel**

**Fundstelle:** `index.html:2761-2776` (`.limit(200)`), `:2782-2788` (Suchfeld filtert nur diese 200 im Browser; der Hinweis „max. 200 geladen“ erscheint nur, wenn es Treffer gibt).

**Beschreibung:** Die Suche nach Artikel, EAN oder Platz läuft nur über die letzten 200 Protokollzeilen. Findet sie nichts, steht dort „Keine Einträge.“, ohne Hinweis auf die Begrenzung.

**Auslöse-Szenario:** Es wird die Frage gestellt, wann Artikel X das letzte Mal ausgebucht wurde. Die Buchung war vor drei Tagen, inzwischen gab es 500 Scans. Die App meldet „Keine Einträge“, und der Nutzer schließt daraus fälschlich, dass es keine Buchung gab.

**Auswirkung:** Falsche Schlüsse bei Klärfällen und Reklamationen.

**Lösungsvorschlag:** Suchbegriff serverseitig filtern (`or(artikelnummer.ilike…,artikelname.ilike…,gtin.eq…,lagerplatz.ilike…)`), Index auf `buchungen(artikelnummer)` anlegen, „Mehr laden“ anbieten. Wenn ohne Treffer und 200 geladen: Hinweis „Suche nur in den letzten 200 – Zeitraum eingrenzen“ anzeigen.

---

### Fund 21 – Fremdbibliotheken ungepinnt, ohne Integritätsprüfung, mit bekannten Lücken · **Mittel**

**Fundstelle:** `index.html:7-9`.

**Beschreibung:**
- `@supabase/supabase-js@2` lädt **immer die neueste 2.x-Version** vom CDN. Eine neue Version mit geänderter Funktionsweise kann die App ohne Zutun über Nacht verändern oder lahmlegen.
- Keine der drei Bibliotheken hat ein `integrity`-Attribut (SRI). Wird das CDN manipuliert, läuft fremder Code mit der Sitzung des angemeldeten Nutzers (voller Datenzugriff).
- `xlsx@0.18.5` (SheetJS von npm) hat bekannte Sicherheitslücken (CVE-2023-30533 Prototype Pollution beim Lesen präparierter Dateien, CVE-2024-22363 ReDoS). SheetJS veröffentlicht neuere Versionen nur noch über sein eigenes CDN.

**Auslöse-Szenario:** Ein supabase-js-Update ändert ein Standardverhalten. Am nächsten Morgen funktioniert das Scannen nicht mehr, und niemand hat etwas geändert.

**Auswirkung:** Unvorhersehbare Ausfälle und ein Angriffsweg über die Lieferkette.

**Lösungsvorschlag:** Exakte Versionen festschreiben (z. B. `@supabase/supabase-js@2.45.4`) und `integrity="sha384-…" crossorigin="anonymous"` ergänzen. Alternativ die Dateien selbst mit ausliefern. xlsx auf eine aktuelle Version vom SheetJS-CDN (`https://cdn.sheetjs.com/`) umstellen. Optional eine Content-Security-Policy setzen.

---

### Fund 22 – Notfall-Wiederherstellung unvollständig · **Mittel**

**Fundstelle:** SQL `:1-12` (Cron-Zeitplan `06_cron_backup.sql` und JTL-Liste `21b_…` sind nicht im Repo), `:150-154` (`create policy` ohne vorheriges `drop policy if exists` – das Skript bricht bei einem zweiten Lauf ab), Edge `index.ts:16-27` (Secrets), `:41` (Backup enthält weder `jtl_artikelliste` noch die Benutzerkonten).

**Beschreibung:** Bei Verlust des Supabase-Projekts reicht das Backup allein nicht: Benutzerkonten (Supabase Auth), Cron-Zeitplan, Dropbox-Secrets, Healthcheck-URL und die JTL-Artikelliste sind nicht gesichert bzw. nicht im Repo. Das Setup-Skript läuft nur auf einer leeren Datenbank fehlerfrei. Wer es auf einer bestehenden Datenbank erneut ausführt, um Funktionen zu aktualisieren, bekommt „policy already exists“, und der Supabase-SQL-Editor rollt das gesamte Skript zurück.

**Auslöse-Szenario:** Das Projekt wird versehentlich gelöscht (oder wegen Inaktivität im Free-Plan pausiert und nicht mehr fortgesetzt). Der Neuaufbau dauert Stunden, weil der Zeitplan und die Secrets rekonstruiert werden müssen.

**Auswirkung:** Lange Ausfallzeit, und nach einer Wiederherstellung läuft die nächtliche Sicherung womöglich nicht.

**Lösungsvorschlag:** `06_cron_backup.sql` (ohne Schlüssel im Klartext, Schlüssel z. B. aus Supabase Vault) und eine Anleitung „Notfall-Neuaufbau“ ins Repo aufnehmen. `drop policy if exists …` vor jedes `create policy` setzen. Nutzerliste (E-Mails) und Liste der Secrets (nur Namen) dokumentieren. Die JTL-Liste ins Backup aufnehmen oder ihre Quelle dokumentieren. Einmal pro Quartal eine Probe-Wiederherstellung durchführen (siehe Fund 5).

---

### Fund 23 – Rückgängig von Zusammenlegung/Löschung stellt Palette/Kanal nicht wieder her · **Niedrig**

**Fundstelle:** SQL `lagerplatz_zusammenlegen` `:945` (löscht die Lagerplatz-Einträge der Quellen), `rueckgaengig` `:786-800` (stellt nur Bestände wieder her), `:774` (gelöschter Platz kommt mit Palette '' und Kanal 0 zurück), `:973` (Leermeldungen bleiben „gesehen“).

**Beschreibung und Szenario:** Die Kartons P02-K01 und P02-K02 (Kanal online) werden zusammengelegt und dann rückgängig gemacht. Die Bestände sind wieder da, aber die Kartons gehören keiner Palette mehr an und sind „gemischt“. Ein leerer Quell-Karton ohne Bestand verschwindet ganz.

**Auswirkung:** Kartons fehlen beim Palette-Sortieren, Karton-Blätter haben keinen Farbpunkt mehr.

**Lösungsvorschlag:** Im Snapshot (`MERGE|`, `DELETE|`) auch die Zeilen aus `lagerplaetze` (palette, kanal, angelegt) speichern und beim Rückgängigmachen wiederherstellen.

---

### Fund 24 – Rückgängig „Artikeländerung“ blockiert bei geteilter EAN · **Niedrig**

**Fundstelle:** SQL `:805-808` gegenüber `:537-539` und `:574` (doppelte EANs sind ausdrücklich erlaubt).

**Szenario:** Artikel A und sein Zweit-Artikel „A defekt“ haben dieselbe EAN (gewollt). Bei A wird der Name geändert, danach soll die Änderung rückgängig gemacht werden. Ergebnis: „die ursprüngliche GTIN ist inzwischen anderweitig vergeben“, obwohl sich die EAN gar nicht geändert hat.

**Lösungsvorschlag:** Die Prüfung entfernen (passend zum neuen Konzept) oder nur ausführen, wenn sich die EAN tatsächlich geändert hat.

---

### Fund 25 – „Palette sortieren“: Rückgängig nimmt nur die Hälfte eines Scans zurück · **Niedrig**

**Fundstelle:** SQL `einraeumen_scan` `:440-462` (ein Scan kann **zwei** Protokollzeilen erzeugen: Umlagerung + Eingang „Inventur-Zugang“).

**Szenario:** 5 Stück gescannt, 2 lagen auf der Quelle. Es entstehen eine Umlagerung (2) und ein Eingang (3). „Rückgängig“ nimmt nur den Eingang zurück, die Leiste zeigt danach die Umlagerung. Der Nutzer glaubt, der Scan sei komplett zurückgenommen.

**Lösungsvorschlag:** Beide Zeilen mit einer gemeinsamen Vorgangs-ID versehen (siehe Fund 3) und gemeinsam rückgängig machen, oder den Text der Leiste anpassen („Teil 2 von 2 – danach auch Umlagerung zurücknehmen“).

---

### Fund 26 – Sammel-Ausbuchen protokolliert ggf. eine veraltete Menge · **Niedrig**

**Fundstelle:** SQL `sammel_ausbuchen` `:639-648` (Liste wird ohne Zeilensperre gelesen, danach `set menge = 0`, protokolliert wird der zuvor gelesene Wert).

**Szenario:** Während des Sammel-Ausbuchens bucht ein anderes Gerät 5 Stück auf denselben Platz ein. Der Platz wird auf 0 gesetzt, protokolliert wird aber die alte Menge. Ein späteres Rückgängig stellt dann 5 zu wenig wieder her.

**Lösungsvorschlag:** `for r in select … for update` verwenden oder `update … set menge = 0 … returning` mit dem alten Wert (z. B. über eine CTE) und genau diesen Wert protokollieren.

---

### Fund 27 – Doppelte offene Leermeldungen möglich · **Niedrig**

**Fundstelle:** SQL `:69-80` (kein eindeutiger Index), Muster „wenn nicht vorhanden, dann einfügen“ z. B. `:314-318`.

**Szenario:** Zwei Geräte buchen gleichzeitig die letzten Stücke desselben Artikels von zwei Teilmengen desselben Platzes. Beide prüfen „keine offene Meldung“ und legen je eine an.

**Lösungsvorschlag:** `create unique index on leermeldungen(artikelnummer, lagerplatz) where gesehen = 0 and artikelnummer <> '—';` und `insert … on conflict do nothing`.

---

### Fund 28 – Suche: Mengenfeld kann vom falschen Feld gelesen werden · **Niedrig**

**Fundstelle:** `index.html:694` (`sucheUid` ersetzt alle Sonderzeichen inkl. Umlaute und Leerzeichen durch „_“), `:840`, `:955`, `:973`.

**Szenario:** Artikel X liegt auf „Lager Süd“ und „Lager Söd“ (oder „Regal-1“ und „Regal 1“). Beide Mengenfelder bekommen dieselbe HTML-ID. Der Nutzer trägt beim zweiten Platz 5 ein, die App liest das erste Feld (1) und bucht 1 Stück.

**Lösungsvorschlag:** Das Feld relativ zum Knopf ermitteln (`this.closest('td').querySelector('input')`) statt über eine konstruierte ID, oder eine laufende Nummer als ID verwenden.

---

### Fund 29 – Artikel-Export: falscher Gesamtbestand bei „:“ im Platznamen · **Niedrig**

**Fundstelle:** `index.html:2741`, `:2746` (`x.split(':')[1]`).

**Szenario:** Lagerplatz „A:1“ mit 5 Stück ergibt den Text „A:1:5“. Gelesen wird „1“, der Gesamtbestand ist also 1 statt 5.

**Lösungsvorschlag:** Die Summe direkt aus den Zahlen bilden (`best.filter(...).reduce(...)`) statt aus dem zusammengesetzten Text.

---

### Fund 30 – Falsche bzw. irreführende Beschriftungen · **Niedrig**

| Stelle | Problem | Vorschlag |
|---|---|---|
| `index.html:2403` | „**GTIN nicht übernommen** (gehört schon einem anderen Artikel)“. Laut SQL `:1096-1098`, `:1114-1121` wird die GTIN **trotzdem übernommen** und nur gemeldet. | „GTIN übernommen, ist aber auch bei einem anderen Artikel hinterlegt“ |
| `index.html:484` | „Einspielen der JSON **Backdatei**“ | „Backup-Datei“ |
| `index.html:461-465` | Text erweckt den Eindruck, es gebe *keine* automatische Sicherung. Es gibt aber die tägliche Dropbox-Sicherung. Paletten fehlen in der Aufzählung. | Auf die nächtliche Dropbox-Sicherung hinweisen, Paletten nennen |
| `index.html:470-475` | Reset „löscht … Lagerplätze/Kartons (inkl. Paletten-Zuordnung)“. Die **Palettenliste** selbst bleibt aber stehen (SQL `:1242-1246` löscht `paletten` nicht). | Klarstellen oder `paletten` mitlöschen |
| `index.html:393-400` | Protokoll-Filter kennt die Typen „Artikel angelegt“, „Palette angelegt“ und „Palette umbenannt“ nicht. | Typen ergänzen (oder Liste aus der DB laden) |
| `index.html:268` | Beispiel „WE-0-001“ als Artikelnummer, obwohl WE-0-… der Platzhalter-Nummernkreis ist | Echtes Nummernbeispiel verwenden |
| SQL `:1236-1239` | Kommentar beschreibt noch die alten Schreibrechte von „authenticated“ (vor Paket 3) | Kommentar aktualisieren |

---

### Fund 31 – Stammdatenänderung per Import ohne Protokoll; uneinheitliche Protokollspalten · **Niedrig**

**Fundstelle:**
- SQL `:1131-1133`: Das Set-Kennzeichen wird beim CSV-Import **auch ohne** „neu anlegen“ geändert. `:1123-1129`: Name und EAN werden überschrieben. Keines davon wird als „Artikeländerung“ protokolliert.
- `:974-976`: „Lagerplatz gelöscht“ schreibt die Artikelanzahl in die Spalte `menge` und die Stückzahl in `bestand_lp_vorher`.
- `:689`: Inventur schreibt `abs(diff)`, das Vorzeichen steht nur im Kommentar.
- `:458-461` und View `:232-239`: Der „Inventur-Zugang (Einräumen)“ wird als **Eingang** gezählt („Heute ein“), normale Inventur-Korrekturen dagegen nicht.

**Auswirkung:** Kennzahlen „Heute/Woche ein“ sind verfälscht, und Änderungen an EAN oder Set-Kennzeichen sind nicht nachvollziehbar.

**Lösungsvorschlag:** Stammdatenänderungen aus dem Import als „Artikeländerung (Import)“ protokollieren und das Set-Kennzeichen nur mit „neu anlegen“ bzw. eigener Option ändern. Mengen im Protokoll mit Vorzeichen speichern (oder eigene Spalte `delta`). Den Inventur-Zugang beim Einräumen als Typ „Inventur“ buchen.

---

### Fund 32 – Suche: veraltete Antwort überschreibt neuere; Auswahl bleibt über Filterwechsel · **Niedrig**

**Fundstelle:** `index.html:696-711` (`ladeSucheDaten` ohne Reihenfolgeschutz – anders als `refreshUndo` `:597-608`), `:684`, `:766-774` (die Auswahl wird bei Filter- oder Suchwechsel nicht geleert).

**Szenario A:** Zwei schnelle Buchungen in der Suche. Die Antwort der ersten Aktualisierung kommt nach der zweiten an, und die Tabelle zeigt den Stand nach Buchung 1. **Szenario B:** Der Nutzer wählt Artikel aus, wechselt den Filter auf Karton „P01-K03“, wählt dort weitere und klickt auf „Komplett ausbuchen“. Ausgebucht werden auch die nicht mehr sichtbaren Artikel aus der ersten Auswahl, und zwar **auf allen Plätzen** (steht im Bestätigungstext, wird aber leicht überlesen).

**Lösungsvorschlag:** Laufnummer wie bei `refreshUndo` einbauen. Die Auswahl beim Filterwechsel leeren oder die Anzahl der unsichtbar ausgewählten Artikel deutlich anzeigen. Bei aktivem Karton-Filter „nur auf diesem Karton ausbuchen“ anbieten.

---

### Fund 33 – Fehler werden still verschluckt · **Niedrig**

**Fundstelle:** `index.html:657-662` (`lpData.error` wird ignoriert), `:1060`, `:1066`, `:2813` (Fehler → leere Auswahlliste ohne Meldung), `:1385` (Fehler von `einraeumen_rest_melden` wird ignoriert, die Sortierung trotzdem beendet).

**Szenario:** Kurzer Netzaussetzer beim Öffnen der Inventur. Die Platzliste ist leer, und der Nutzer glaubt, es gebe keine Plätze mit Bestand.

**Lösungsvorschlag:** Bei jedem `error` eine sichtbare Meldung mit Knopf „Erneut laden“ anzeigen. Bei `erFertig` die Sitzung erst nach erfolgreicher Rest-Meldung beenden.

---

### Fund 34 – Backup-Funktion mit dem öffentlichen Schlüssel auslösbar · **Niedrig (Prüfen)**

**Fundstelle:** Edge `index.ts:326` (`Deno.serve` prüft weder ein Geheimnis noch einen Absender).

**Beschreibung:** Edge Functions verlangen standardmäßig nur irgendein gültiges JWT. Der anon-Key reicht dafür. Wurde die Funktion mit `--no-verify-jwt` veröffentlicht, ist sie sogar ohne Schlüssel aufrufbar.

**Szenario:** Wiederholte Aufrufe erzeugen viel Last, Dropbox-API-Kontingent wird verbraucht, und die JTL-Datei wird mitten am Tag neu geschrieben, während JTL sie womöglich gerade liest.

**Lösungsvorschlag:** Einen eigenen Secret-Header (z. B. `x-cron-secret`) verlangen, den nur der Cron-Job kennt, und andere Aufrufe mit 401 abweisen.

---

### Fund 35 – Härtung: `esc()` ohne Anführungszeichen, CSV-Formel-Injection · **Niedrig**

**Fundstelle:** `index.html:3090` (`esc` maskiert nur `& < >`), `:2702` und Edge `index.ts:208-212` (`csvZelle`).

**Beschreibung:** Aktuell wird `esc()` nirgends innerhalb von Attributen verwendet (geprüft). Für Attribute gibt es `escAttr` bzw. `jsAttr`, daher besteht **keine akute XSS-Lücke**. Eine spätere Änderung könnte `esc()` aber versehentlich in einem Attribut verwenden. In CSV-Exporten werden Werte wie `=HYPERLINK(...)` in Artikelnamen von Excel als Formel ausgeführt.

**Lösungsvorschlag:** `esc()` zusätzlich `"` und `'` maskieren lassen. In CSV-Exporten Zellen, die mit `= + - @` beginnen, ein `'` voranstellen. Das betrifft nicht die JTL-Dateien, falls JTL das stören würde, das dort vorher prüfen.

---

### Fund 36 – Platzhalter-Nummernkreis WE-0-… nicht gegen JTL abgesichert · **Niedrig (Prüfen)**

**Fundstelle:** SQL `unbekannt_einbuchen` `:1460-1468` (nächste Nummer = höchste WE-0-Nummer in LagerPal + 1), `artikel_aus_liste` `:1538-1543` (eine vorhandene Nummer wird ungeprüft als „der“ JTL-Artikel übernommen).

**Beschreibung:** Die Nummernvergabe berücksichtigt `jtl_artikelliste` nicht. Falls in JTL Artikelnummern im Schema „WE-0-…“ existieren oder künftig vergeben werden, kann ein Platzhalter dieselbe Nummer wie ein echter JTL-Artikel bekommen. `artikel_aus_liste` würde dann den Platzhalter als echten Artikel ausgeben.

**Lösungsvorschlag:** Prüfen, ob JTL diesen Nummernkreis nutzt. Falls ja, ein eindeutiges Präfix verwenden (z. B. „LP-UNB-…“) oder bei der Vergabe auch `jtl_artikelliste` berücksichtigen.

---

### Fund 37 – Gleichzeitiger Scan derselben neuen EAN: zweites Gerät erhält Fehler · **Niedrig**

**Fundstelle:** SQL `artikel_aus_liste` `:1531-1533` (gibt „gefunden = false“ zurück, wenn der Artikel inzwischen existiert), Frontend `index.html:2110-2117` (dann wird `unbekannt_einbuchen` versucht, das mit „EAN gehört zu einem bekannten Artikel“ abbricht).

**Szenario:** Zwei Mitarbeiter scannen gleichzeitig dieselbe neue EAN. Gerät A legt den Artikel an, Gerät B zeigt eine Fehlermeldung und muss erneut scannen. Das ist sicher (nichts wird falsch gebucht), aber verwirrend.

**Lösungsvorschlag:** In `artikel_aus_liste` statt „gefunden = false“ den nun vorhandenen Artikel zurückgeben (wie bei `:1540-1543`).

---

## 4. Ausdrücklich geprüft und in Ordnung

- **Bestandsrechnung in den SQL-Funktionen** (`buchen`, `umlagern`, `einraeumen_scan`, `inventur_anwenden`, `bestand_csv_import`, `rueckgaengig`): Vorher-/Nachher-Werte und Gesamtbestände sind korrekt berechnet. Ausbuchungen und Rückgängig ziehen nur bedingt ab. Negative Bestände sind durch CHECK und bedingte Updates ausgeschlossen.
- **Atomarität:** Jede Funktion ist eine Transaktion. Der frühere Zwei-Schritt-Ablauf beim Einräumen ist korrekt zu `einraeumen_scan` zusammengefasst.
- **Unbekannte Artikel:** Nummernvergabe und Kartonwahl laufen unter einer Sperre (`pg_advisory_xact_lock`) und sind damit race-sicher.
- **Rückgängig:** Sperrt die Zeile (`FOR UPDATE`), prüft die angezeigte ID gegen die aktuelle und hat eine Altersgrenze. Frontend und SQL sind konsistent (2 h).
- **RLS/Rechte:** Tabellen sind nur lesbar, `anon` hat keinen Zugriff, alle Funktionen haben `SECURITY DEFINER` mit festem `search_path = public, pg_temp`. Die Views laufen mit `security_invoker`, und `create` im Schema `public` ist entzogen.
- **XSS:** Alle geprüften `innerHTML`-Stellen und Druckfenster maskieren Nutzerdaten (`esc`, `escAttr`, `jsAttr`). `jsAttr` maskiert korrekt in der richtigen Reihenfolge (erst JS, dann HTML).
- **JTL-Lagerbestandskommentar:** Frontend (`index.html:2434-2452`) und Edge Function (`index.ts:216-231`) erzeugen identische Dateien: gleiche Sortierung der Artikel und Plätze, gleiche Spalten, `;`, CRLF, UTF-8-BOM (im Frontend als Byte-Folge EF BB BF verifiziert), gleiche Behandlung unbekannter Artikel und leerer Kommentare.
- **Zeitzonen:** Dashboard-Tagesgrenzen (`Europe/Berlin`), Protokoll-Datumsfilter (Ortszeit), Backup-Dateiname (`heuteBerlin`) und JTL-Archivdatum sind korrekt behandelt.
- **Aufbewahrung der Backups:** 30 Tage täglich plus das letzte Backup jedes Monats dauerhaft, korrekt umgesetzt. Dubletten „(1)“ werden mit erfasst.

---

## 5. Priorisierte Empfehlungen

**Sofort (diese Woche, geringer Aufwand, hoher Nutzen)**
1. Im Supabase-Dashboard die **Selbstregistrierung abschalten** und die Nutzerliste prüfen (Fund 1).
2. **Doppelklick-Sperren** in Scanner-Platzwahl, Suche, Umlagern und „Palette sortieren“ einbauen; im Einräum-Scan das Scanfeld sofort leeren (Funde 3, 6).
3. Die `confirm()`-Dialoge in den Scan-Abläufen durch einen eigenen Dialog ersetzen, der Scanner-Enter ignoriert (Fund 4).
4. Eine **Probe-Wiederherstellung** in einem Testprojekt durchführen und Dauer bzw. Zeitlimit messen; für `backup_wiederherstellen` ein höheres `statement_timeout` setzen (Fund 5).
5. Bibliotheksversionen **festschreiben** (supabase-js) und xlsx aktualisieren (Fund 21).

**Kurzfristig (nächste 2–4 Wochen)**
6. **Admin-Rolle** für Reset, Backup einspielen, Komplett-Import, Artikel löschen und Amazon-Vollabgleich (Fund 2).
7. **Benutzer im Protokoll** speichern (Fund 16) und darauf aufbauend ein **Rückgängig nur für eigene Aktionen** (Fund 9).
8. **Idempotenzschlüssel** (`vorgang_id`) für alle Buchungsfunktionen (Fund 3, auch Fund 25).
9. **Kartonvergabe in die Datenbank** verlagern (`karton_neu`) (Fund 7) und alle ungeblätterten Abfragen auf `fetchAll` bzw. serverseitige Filter umstellen (Fund 8).
10. **Vorschau für den Teil-Import** (Fund 12), strikte Statuserkennung beim Amazon-Import (Fund 13), Excel-Import als Text lesen und EAN prüfen (Fund 14).
11. Die falschen Texte korrigieren (Fund 30).

**Mittelfristig (1–3 Monate)**
12. **Datenmodell straffen:** Fremdschlüssel für Lagerplätze und Paletten, einheitliche Schreibweise (Fund 15).
13. **Inventur überarbeiten:** leere Plätze zählbar machen, Konfliktprüfung bei Zwischenbuchungen (Fund 10).
14. **Leermeldungen** nur für echte Leerläufe erzeugen (Fund 11).
15. Mit JTL klären, wie der Lagerbestand-Import arbeitet (absolut/relativ, nicht genannte Plätze), und den Export gegebenenfalls anpassen (Fund 17).
16. **Performance:** kein Komplettladen nach jeder Buchung, Suche und Protokollsuche serverseitig (Funde 18, 20).
17. **Backup** über eine konsistente Datenbank-Exportfunktion mit Schlüssel-Blättern; Notfall-Anleitung, Cron-Skript und wiederholbares Setup-Skript ins Repo (Funde 19, 22).

**Bei Gelegenheit**
18. Funde 23–37 (Rückgängig-Details, Unique-Index für Leermeldungen, ID-Kollision in der Suche, Export-Kleinigkeiten, Fehlermeldungen, Secret für die Edge Function, Härtung von `esc`/CSV, Nummernkreis-Prüfung).

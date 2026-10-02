# Prüfbericht Codequalität – LagerPal

Stand: 02.10.2026 · Geprüfter Commit: `77317bc` (Branch `claude/cloud-sessions-credits-9xe0tz`)

Geprüfte Dateien (vollständig gelesen):

| Datei | Zeilen | Inhalt |
|---|---|---|
| `index.html` | 3141 | Frontend (HTML/CSS/JS), spricht direkt mit Supabase |
| `supabase/00_KOMPLETT_neu_aufsetzen.sql` | 1630 | Schema, RLS, Views, 26 RPC-Funktionen (plpgsql) |
| `supabase/functions/lagerpal-backup/index.ts` | 378 | Edge Function: Backup nach Dropbox + JTL-CSV |

Vorgehen: alle drei Dateien vollständig gelesen. Jeder Fund „ungenutzt“ wurde mit grep über alle Dateien geprüft, auch auf dynamische Verwendung (`onclick`-Strings, Template-Strings, `rpc('…')`, `'tab-'+t`, `classList`). Am Code wurde nichts geändert.

---

## 1. Zusammenfassung und Gesamturteil

**Gesamturteil: solide, gepflegte Codebasis mit klaren Altlasten.** Insgesamt gibt es keine kritischen Fehler. Die Datenintegrität ist gut abgesichert:
- Alle Schreibzugriffe laufen über atomare `SECURITY DEFINER`-Funktionen.
- CHECK-Constraints verhindern negative Bestände.
- `REVOKE` entzieht direkte Schreibrechte.
- Das Paginieren ist stabil sortiert (`FETCH_PK`/`ORDER_COLS`).
- HTML-Ausgaben von Nutzerdaten werden durchgängig mit `esc()`, `escAttr()` bzw. `jsAttr()` maskiert. Einen konkreten XSS-Pfad habe ich nicht gefunden.
- Viele frühere Fehler sind in Kommentaren dokumentiert und behoben, z. B. Zeitzonen, Doppelscan im Scanner und das robuste Einspielen von Backups.

Die Probleme liegen vor allem in vier Bereichen:

1. **Rückgängig-Logik:** Sie passt nicht mehr ganz zum heutigen Datenmodell. Die GTIN-Prüfung blockiert ohne Grund. Palette, Kanal und leere Kartons gehen beim Zurücknehmen verloren.
2. **Doppelklick-/Nebenläufigkeitsschutz:** Er fehlt außerhalb des Scanners. Dadurch sind Doppelbuchungen möglich, und es gibt ein Race bei der Kartonnummer.
3. **Performance:** Nach praktisch jeder Buchung lädt die App die gesamte Tabelle `bestaende`, oft sogar zusätzlich Artikel und Lagerplätze komplett. Der Komplett-Import arbeitet zeilenweise (N+1).
4. **Altlasten:** Migrationsreste im „Neu-aufsetzen“-Skript, veraltete Kommentare und Texte, ein Übergangs-Fallback, ungenutzte CSS-Regeln. Dazu kommt viel kopierte Logik, v. a. der „Glocke pflegen“-Block (8× in SQL), Druckfenster (5×) und Sprachausgabe (4×).

Ungenutzte JS-Funktionen oder SQL-Funktionen gibt es nicht. Alle 26 RPC-Funktionen werden vom Frontend aufgerufen, und jede deklarierte JS-Funktion hat mindestens einen Aufrufer. Der tote Code beschränkt sich auf CSS, ein Fallback, Migrationsreste, überflüssige Guards und Kommentare.

### Anzahl der Funde

| Kategorie | Hoch | Mittel | Niedrig | Summe |
|---|---|---|---|---|
| Bug | – | 7 | 10 | 17 |
| Performance | 1 | 2 | 3 | 6 |
| Toter Code | – | – | 6 | 6 |
| Umständlich | – | 1 | 6 | 7 |
| Wartbarkeit | – | 2 | 7 | 9 |
| **Summe** | **1** | **12** | **32** | **45** |

---

## 2. Übersicht aller Funde

| Nr. | Kategorie | Schwere | Kurztitel |
|---|---|---|---|
| 1 | Bug | Mittel | Rückgängig „Artikeländerung“ scheitert an GTIN-Prüfung, obwohl Mehrfach-GTIN erlaubt ist |
| 2 | Bug | Mittel | Rückgängig „Zusammenlegung“/„Lagerplatz gelöscht“ verliert Palette/Kanal und leere Kartons |
| 3 | Bug | Mittel | Doppelbuchung durch Doppelklick/Doppel-Enter (Platzwahl, Suche, Palette sortieren) |
| 4 | Bug | Mittel | Karton-Blätter: `window.open` nach `await` → Popup-Blocker (v. a. 2. Blatt bei „Palette fertig“) |
| 5 | Bug | Mittel | Race bei Vergabe der Kartonnummer (zwei Geräte, gleiche Palette) |
| 6 | Bug | Mittel | Protokoll-Textsuche durchsucht nur die zuletzt geladenen 200 Einträge |
| 7 | Bug | Mittel | Supabase-`error` wird an vielen Lesestellen ignoriert (z. B. Karton-Blatt wird „(leer)“ gedruckt) |
| 8 | Bug | Niedrig | Leermeldungen aus „Sammel-Ausbuchen“ erscheinen als „Einräum-Hinweis“ ohne Artikel/Platz |
| 9 | Bug | Niedrig | Falsche Importmeldung „GTIN nicht übernommen“ (GTIN wird übernommen) |
| 10 | Bug | Niedrig | Ladefehler beim Start/Refresh unbehandelt (`ladeSucheDaten`, `ladeAllePlaetze`) |
| 11 | Bug | Niedrig | Artikel-Export: Gesamtbestand = `NaN`, wenn ein Lagerplatzname „:“ enthält |
| 12 | Bug | Niedrig | `verbinden()`: Fehlermeldung landet in unsichtbarem Element |
| 13 | Bug | Niedrig | `sucheUid()` kann kollidieren → falsches Mengenfeld wird gelesen |
| 14 | Bug | Niedrig | Lagerplatznamen werden in `buchen`/`umlagern`/`karton_setzen` nicht geprüft/getrimmt |
| 15 | Bug | Niedrig | `amazon_status_setzen`: Modus nicht validiert, „geändert“ zählt Treffer statt Änderungen |
| 16 | Bug | Niedrig | Nicht protokollierte Schreibfunktionen → Rückgängig „Umbenennung“ kann mit PK-Fehler scheitern |
| 17 | Bug | Niedrig | Excel-Import: führende Nullen von GTIN/Artikelnummer gehen verloren |
| 18 | Wartbarkeit | Mittel | Setup-Skript ist nicht wiederholbar (`create policy` ohne `drop policy if exists`) |
| 19 | Performance | **Hoch** | `ladeAllePlaetze()` lädt die gesamte Tabelle `bestaende`, bei jeder Buchung/jedem Scan |
| 20 | Performance | Mittel | `sucheRefresh()` lädt nach jeder Schnellbuchung Artikel + Bestände + Lagerplätze komplett |
| 21 | Performance | Mittel | Komplett-Import (N+1-Schleife) und Backup-Einspielen: Risiko `statement_timeout` |
| 22 | Performance | Niedrig | 15-s-Polling lädt 200 Leermeldungen auch bei geschlossenem Panel/verstecktem Tab |
| 23 | Performance | Niedrig | Index-Lage: redundanter Index `idx_bestaende_artnr`, fehlender Index für offene Leermeldungen |
| 24 | Performance | Niedrig | „Palette sortieren“: 6–8 Roundtrips pro Scan |
| 25 | Toter Code | Niedrig | Ungenutzte CSS-Regeln (`.buchung-box`, `.leer-item*`, `.hat-neue`, `#lager-grid` …) |
| 26 | Toter Code | Niedrig | Übergangs-Fallback in `leerGesehen()` (direktes UPDATE, durch REVOKE ohnehin wirkungslos) |
| 27 | Toter Code | Niedrig | Migrationsreste im „Neu-aufsetzen“-Skript |
| 28 | Toter Code | Niedrig | Veraltete Kommentare und UI-Texte |
| 29 | Toter Code | Niedrig | Überflüssige Guards/Zweige und Duplikate (`typeof … === 'function'`, `colLp ? :`, `heuteBerlin` …) |
| 30 | Toter Code | Niedrig | Kommentar-Payloads ohne Leser (`NEWLP|`, `PALETTE_NEU|`, `PALETTE_RENAME|`) |
| 31 | Umständlich | Mittel | „Glocke pflegen“ und `insert into buchungen(…12 Spalten…)` vielfach kopiert (SQL) |
| 32 | Umständlich | Niedrig | `einraeumen_scan` dupliziert `umlagern` + `buchen` |
| 33 | Umständlich | Niedrig | Druckfenster-Code 5× kopiert |
| 34 | Umständlich | Niedrig | Ton-/Sprachausgabe in 4 Varianten, 2 AudioContexts |
| 35 | Umständlich | Niedrig | `fetchAll` mit zwei Sortier-APIs (`order`/`orderBy`); Fehlerausgabe-Muster ~40× kopiert |
| 36 | Umständlich | Niedrig | Löschen mit doppelter Bestätigung (Vorab-Abfrage + `BESTAND_VORHANDEN`-Rundlauf) |
| 37 | Umständlich | Niedrig | `sucheRender`: Set-Neuaufbau im Filter-Callback; Edge-`gzip()` von Hand |
| 38 | Wartbarkeit | Mittel | Doppelte „Quellen der Wahrheit“: Undo-Typen/-Alter (JS+SQL), JTL-CSV (HTML+Edge) |
| 39 | Wartbarkeit | Niedrig | Palettenliste und `karton_setzen` laufen auseinander |
| 40 | Wartbarkeit | Niedrig | Protokoll: Typfilter/Farben kennen „Artikel angelegt“, „Palette angelegt/umbenannt“ nicht |
| 41 | Wartbarkeit | Niedrig | `buchungen`-Zeilen uneinheitlich befüllt (Gesamtbestand fehlt teils) |
| 42 | Wartbarkeit | Niedrig | Undo-Semantik widerspricht UI-Texten (Sammel-Ausbuchen, Einräumen-Scan) |
| 43 | Wartbarkeit | Niedrig | Backup/Reset inkonsistent (`paletten`, `erstellt` vs. `erstellt_am`, `angelegt` als Text) |
| 44 | Wartbarkeit | Niedrig | Edge Function: kein eigener Aufrufschutz, ungewartete Stream-Promises, Löschfehler nur geloggt |
| 45 | Wartbarkeit | Niedrig | Globaler Zustand über `window._artEdit` |

---

## 3. Funde im Detail

### Bugs

#### 1 – Rückgängig „Artikeländerung“ scheitert an GTIN-Prüfung (Bug, Mittel)
**Fundstelle:** `00_KOMPLETT_neu_aufsetzen.sql:805-808`. Zum Vergleich: `:537-539`, `:574`, `:1096-1098`.

**Beschreibung:** `artikel_neu`, `artikel_bearbeiten` und `bestand_csv_import` erlauben ausdrücklich, dass mehrere Artikel dieselbe GTIN haben (z. B. ein Defekt-Zweitartikel). `rueckgaengig()` bricht bei `Artikeländerung` aber ab, sobald die alte GTIN bei *irgendeinem* anderen Artikel steht. Das ist ein Rest aus der Zeit, als GTINs eindeutig sein mussten.

**Szenario:** Artikel A und Defekt-Artikel B haben beide die EAN 4006…. Jemand ändert bei A nur den Namen und klickt sofort „Rückgängig“. Die Meldung lautet „ursprüngliche GTIN ist inzwischen anderweitig vergeben“, und die Änderung lässt sich nicht zurücknehmen.

**Vorschlag:** Den Block `if coalesce(info->'alt'->>'gtin','') <> '' then … end if;` ersatzlos streichen. Die Variable `v_konflikt` wird dann nicht mehr gebraucht.

#### 2 – Rückgängig „Zusammenlegung“/„Lagerplatz gelöscht“ ist unvollständig (Bug, Mittel)
**Fundstelle:** SQL `:760-775` (Undo Löschen), `:786-800` (Undo Zusammenlegen), `:933-946` (Zusammenlegen), `:970-976` (Löschen).

**Beschreibung:**
- `lagerplatz_loeschen` sichert im Snapshot nur `{artnr: menge}`. Palette, Kanal und `angelegt` der Zeile in `lagerplaetze` fehlen. Das Undo legt den Platz mit `palette='' , kanal=0` neu an.
- `lagerplatz_zusammenlegen` löscht die `lagerplaetze`-Zeilen der Quellen (`:945`). Das Undo stellt nur `bestaende` wieder her, nicht die `lagerplaetze`-Zeilen. Ein Quell-Karton ganz ohne `bestaende`-Zeilen (nur Metadaten) verschwindet dauerhaft.
- Ein neu angelegter Zielplatz (`:946`) bleibt nach dem Undo als leere Hülle stehen.
- Leermeldungen, die per `:944` auf das Ziel umgehängt wurden, bleiben dort.

**Szenario:** Die Kartons P03-K01 (online) und P03-K02 (nicht online) werden zu „P03-K01“ zusammengelegt und dann rückgängig gemacht. Danach steht P03-K02 unter „Ohne Palette / gemischt“. In „Palette sortieren“ taucht er nicht mehr als Karton von P03 auf.

**Vorschlag:** Im Snapshot die `lagerplaetze`-Zeilen mitsichern und beim Undo wieder einfügen:
```sql
-- beim Zusammenlegen/Löschen
'lp', (select jsonb_agg(to_jsonb(l)) from lagerplaetze l where name = any(v_betroffen))
-- beim Undo
insert into lagerplaetze select * from jsonb_populate_recordset(null::lagerplaetze, info->'lp')
  on conflict (name) do update set palette = excluded.palette, kanal = excluded.kanal;
```
Den Zielplatz beim Undo entfernen, wenn er vorher nicht existierte (als Flag im Snapshot speichern).

#### 3 – Doppelbuchung durch Doppelklick/Doppel-Enter (Bug, Mittel)
**Fundstelle:** `index.html:2070-2081` (`ssBookPick`), `:838-858` (`sucheBuchen`), `:1275-1340` (`erScan`). Zum Vergleich mit Schutz: `:2085-2090` (`ssScan`/`ssLaeuft`).

**Beschreibung:** Nur `ssScan` hat eine Sperre gegen parallele Läufe. Die Platz-Buttons der offenen Platzwahl, die „+ Ein/− Aus“-Buttons in der Suche und „Buchen“/Enter in „Palette sortieren“ können während des laufenden RPC erneut ausgelöst werden.

**Szenario:** Im Scanner (Ausbuchen, Artikel auf drei Plätzen) wird der Platz-Button doppelt angetippt. Es wird zweimal `buchen(…,'aus',menge)` aufgerufen. `ssOffen` wird erst *nach* dem ersten `await` geleert. In „Palette sortieren“ schickt manche Scanner-Konfiguration CR+LF, oder jemand drückt Enter und klickt zusätzlich „Buchen“. Dann bucht `einraeumen_scan` doppelt, und der zweite Lauf erzeugt ggf. einen „Inventur-Zugang“.

**Vorschlag:** Eine gemeinsame Sperre einführen:
```js
async function exklusiv(key, fn) {
  if (exklusiv[key]) return; exklusiv[key] = true;
  try { return await fn(); } finally { exklusiv[key] = false; }
}
// onclick="exklusiv('ss', () => ssBookPick(…))"
```
Alternativ den Button während des Aufrufs auf `disabled` setzen.

#### 4 – Karton-Blätter werden vom Popup-Blocker gestoppt (Bug, Mittel)
**Fundstelle:** `index.html:1379-1385` (`erFertig`), `:1369-1371` (`erKartonVoll`), `:1920-1928` (`unbKartonVoll`), `:1619-1679` (`kartonBlattDrucken`: drei `await` vor `window.open`).

**Beschreibung:** `window.open` braucht eine frische Nutzeraktion. Vor dem Öffnen laufen mehrere Netzwerkabfragen. Chrome/Edge verbrauchen die Nutzeraktion beim ersten `window.open`. Safari blockiert Popups nach `await` meist ganz.

**Szenario:** Bei „✓ Palette fertig“ sind beide Kartons befüllt. Das erste Blatt öffnet sich, beim zweiten kommt „Bitte Pop-ups erlauben …“. Die Rest-Meldung wird trotzdem geschrieben, und die Sitzung ist beendet. Das fehlende Blatt muss man über „Nachdruck“ suchen.

**Vorschlag:** Die Fenster synchron im Klick-Handler öffnen (`const w = window.open('', '_blank')`) und erst danach die Daten laden und `w.document.write(...)` aufrufen. Alternativ beide Kartons in **einem** Druckdokument ausgeben, mit Seitenumbruch per `page-break-before`.

#### 5 – Race bei Vergabe der Kartonnummer (Bug, Mittel)
**Fundstelle:** `index.html:1112-1116`, `:1150-1157` (`erNaechsteNummer`/`erNeuerKarton`); SQL `:484-497` (`karton_setzen` mit `on conflict … do update`).

**Beschreibung:** Die nächste Nummer `P05-K<n+1>` berechnet der Browser aus `allePlaetze`. `karton_setzen` macht danach ein Upsert, ohne zu prüfen, ob der Karton gerade neu angelegt wurde.

**Szenario:** Zwei Personen sortieren gleichzeitig auf Palette P05. A legt den Online-Karton an, B fast zeitgleich den Nicht-online-Karton. Beide berechnen `P05-K07`. Das Upsert von B setzt `kanal = 2`, und A sortiert Online-Ware in einen Karton, der als „nicht online“ geführt und gedruckt wird.

**Vorschlag:** Eine Serverfunktion `palette_karton_naechster(p_palette, p_kanal)` nach dem Vorbild von `unbekannt_karton_naechster` einführen: `pg_advisory_xact_lock(hashtext('karton_'||p_palette))`, die höchste Nummer per SQL bestimmen und mit `insert … on conflict do nothing` anlegen. Gibt das Insert keine Zeile zurück, wird erneut versucht.

#### 6 – Protokoll-Textsuche nur über 200 Zeilen (Bug, Mittel)
**Fundstelle:** `index.html:2761-2776` (`.limit(200)`), `:2781-2787` (Filter `prot-suche` nur clientseitig).

**Beschreibung:** Das Suchfeld filtert nur die 200 zuletzt geladenen Zeilen. Der Hinweis „max. 200 geladen — Filter nutzen“ legt nahe, dass das Suchfeld die Datenbank durchsucht. Das tut es nicht.

**Szenario:** Ein Artikel wurde vor drei Wochen umgelagert, heute gab es schon 300 Buchungen. Die Suche nach der Artikelnummer zeigt „Keine Einträge“.

**Vorschlag:** Den Suchbegriff (entprellt) serverseitig anwenden:
```js
if (f) q = q.or(`artikelnummer.ilike.*${f}*,artikelname.ilike.*${f}*,gtin.ilike.*${f}*,lagerplatz.ilike.*${f}*`);
```
Dabei `,()` im Suchbegriff entfernen, wie in `sucheRender:887`. Alternativ den Hinweis korrigieren.

#### 7 – Ignorierte Supabase-Fehler beim Lesen (Bug, Mittel)
**Fundstelle (Auswahl):**
- `index.html:1620-1631` (`kartonBlattDrucken`)
- `:1832-1836` (`resolveArtikel`)
- `:666` (`artikelPlaetze`)
- `:1191` (`erInhaltLaden`)
- `:1060`, `:1066` (`initEinraeumen`)
- `:2813`, `:2822` (Inventur)
- `:2970`, `:2975` (`refreshLeer`)
- `:1385` (Ergebnis von `einraeumen_rest_melden` wird verworfen)

**Beschreibung:** Hier wird nur `{ data }` ausgewertet. Bei einem Fehler (Netz, abgelaufenes Token, Timeout) verhält sich die App so, als gäbe es keine Daten.

**Szenario:**
- Beim „Karton voll → drucken“ bricht kurz das WLAN weg. Es wird ein Karton-Blatt „(leer)“ gedruckt und auf den vollen Karton geklebt.
- `resolveArtikel` meldet bei einem DB-Fehler „Nicht gefunden“. Im Einbuchen-Modus versucht die App dann, einen Unbekannt-Platzhalter anzulegen. Der Server verhindert das zum Glück (`EAN … gehört zu einem bekannten Artikel`), die Meldung führt den Nutzer aber in die Irre.
- Bei `erFertig` geht eine fehlgeschlagene Rest-Meldung still verloren.

**Vorschlag:** Einen kleinen Wrapper verwenden, der `error` wirft, und an den Aufrufstellen eine Meldung anzeigen:
```js
async function q(p) { const { data, error } = await p; if (error) throw error; return data; }
```

#### 8 – Sammel-Ausbuchen-Leermeldungen erscheinen als „Einräum-Hinweis“ (Bug, Niedrig)
**Fundstelle:** SQL `:649-652` (`hinweis = 'Sammel-Ausbuchen'`), `index.html:2986`.

**Beschreibung:** `renderLeerPanel` behandelt *jede* Meldung mit `hinweis` als Einräum-Hinweis. Ausgegeben werden dann nur „📦 Einräum-Hinweis“, der Hinweistext und die Zeit, ohne Artikel und Lagerplatz.

**Szenario:** Nach dem Sammel-Ausbuchen von 20 Artikeln zeigt die Glocke 40× „📦 Einräum-Hinweis – Sammel-Ausbuchen“. Welcher Platz leer ist, sieht man nicht.

**Vorschlag:** Den Einräum-Hinweis an `artikelnummer === '—'` erkennen (so legt `einraeumen_rest_melden` ihn an). Alternativ in `sammel_ausbuchen` `hinweis = ''` setzen.

#### 9 – Falsche Meldung „GTIN nicht übernommen“ (Bug, Niedrig)
**Fundstelle:** `index.html:2403` gegenüber SQL `:1096-1128`.

**Beschreibung:** Seit Mehrfach-GTINs erlaubt sind, *übernimmt* `bestand_csv_import` die GTIN und meldet den Fall nur. Der Text im Frontend sagt das Gegenteil.

**Vorschlag:** Den Text ändern, z. B. in „GTIN übernommen, ist aber auch bei einem anderen Artikel eingetragen: …“.

#### 10 – Ladefehler beim Start/Refresh unbehandelt (Bug, Niedrig)
**Fundstelle:** `index.html:567-578` (`zeigeApp`), `:655-663` (`ladeAllePlaetze`), `:696-709` (`ladeSucheDaten`).

**Beschreibung:** `fetchAll` wirft bei Fehlern. Hier gibt es kein `try/catch`. `zeigeApp` bricht nach `await ladeAllePlaetze()` ab, und das Polling (Glocke/Undo) wird dann nie gestartet. In der Suche bleibt „Wird geladen…“ stehen, ohne Fehlermeldung (nur eine *unhandled rejection* in der Konsole).

**Vorschlag:** `try/catch` mit sichtbarer Fehlermeldung einbauen und das Polling vor dem ersten Laden starten.

#### 11 – Artikel-Export: `NaN` bei „:“ im Lagerplatznamen (Bug, Niedrig)
**Fundstelle:** `index.html:2741-2746`.

**Beschreibung:** Der Gesamtbestand wird aus dem zusammengebauten String `lagerplatz + ':' + menge` per `split(':')[1]` zurückgerechnet. Bei „Regal:3“ ist das Ergebnis `parseInt('3')` bzw. `NaN`.

**Vorschlag:** Die Summe direkt rechnen:
```js
const sum = {}; best.forEach(b => { if (b.menge > 0) sum[b.artikelnummer] = (sum[b.artikelnummer] || 0) + b.menge; });
```

#### 12 – `verbinden()`: Fehlermeldung unsichtbar (Bug, Niedrig)
**Fundstelle:** `index.html:535` (schreibt in `#login-status`), `:166-171` (`#login-status` liegt in `#login-block`, der zu diesem Zeitpunkt `display:none` ist).

**Szenario:** Jemand klickt „Verbinden“ mit leerem Schlüssel, und nichts passiert.

**Vorschlag:** `alert()` verwenden oder ein eigenes Status-Element im `#cfg-block` anlegen.

#### 13 – `sucheUid()` kann kollidieren (Bug, Niedrig)
**Fundstelle:** `index.html:694`, verwendet in `:840`, `:955`, `:973`.

**Beschreibung:** Alle Zeichen außer `[a-zA-Z0-9_]` werden zu `_`. „Regal-1“ und „Regal 1“, Umlaute („Süd“/„Säd“) oder `A-1`/`A_1` ergeben dieselbe ID. `el('bk-m-'+uid)` liefert dann das erste Feld, also wird die Menge aus der falschen Zeile gebucht.

**Vorschlag:** Den Zeilenindex als ID verwenden oder den Button das Eingabefeld über das DOM finden lassen (`this.parentElement.querySelector('input')`).

#### 14 – Lagerplatznamen in `buchen`/`umlagern`/`karton_setzen` nicht geprüft (Bug, Niedrig)
**Fundstelle:** SQL `:256-300` (`buchen`: `p_lagerplatz` ungeprüft), `:335-350` (`umlagern`: `p_nach` ungeprüft), `:489-493` (`karton_setzen`: prüft auf leer, speichert aber ungetrimmt). `lagerplatz_neu`/`_umbenennen` trimmen dagegen.

**Szenario:** Bei „Karton-Einstellungen“ wird über einen anderen Client „P01-K01 “ (mit Leerzeichen) gesetzt. Es entsteht ein zweiter, optisch gleicher Platz. `buchen(…, p_lagerplatz => NULL)` endet in einer technischen NOT-NULL-Meldung statt einer verständlichen.

**Vorschlag:** In allen Schreibfunktionen einheitlich `p_x := nullif(trim(p_x), '')` setzen und dann prüfen, idealerweise mit einer Hilfsfunktion `lp_name_pruefen(text)`.

#### 15 – `amazon_status_setzen`: Modus nicht validiert, „geändert“ zu hoch (Bug, Niedrig)
**Fundstelle:** SQL `:986-1007`.

**Beschreibung:**
- Jeder Wert außer `'voll'` wird als `'nur'` behandelt. Andere Import-Funktionen werfen dagegen einen Fehler (vgl. `:1038`).
- `row_count` zählt alle getroffenen Zeilen, auch unveränderte. Die Vorschau im Frontend (`:2609-2619`) zählt echte Änderungen, die Erfolgsmeldung meldet eine andere, höhere Zahl.
- `jsonb_array_length(NULL)` liefert NULL in `menge`.

**Vorschlag:** Den Modus prüfen und `… where a.artikelnummer = x.artikelnummer and a.online is distinct from x.online` ergänzen.

#### 16 – Nicht protokollierte Schreibfunktionen stören die Undo-Logik (Bug, Niedrig)
**Fundstelle:** SQL `:484-497` (`karton_setzen`), `:502-518` (`einraeumen_rest_melden`), `:1401-1408` (`leermeldungen_alle_gesehen`), `:1494-1509` (`unbekannt_karton_naechster`); Undo `:777-784`.

**Beschreibung:** `rueckgaengig()` erlaubt das Undo nur, wenn es keine neuere Buchung gibt. Diese Funktionen schreiben aber keine `buchungen`-Zeile.

**Szenario:** Platz „A“ wird in „B“ umbenannt. Danach legt `karton_setzen('A', …)` (z. B. über Karton-Einstellungen) wieder eine `lagerplaetze`-Zeile „A“ an. Das Undo der Umbenennung macht `update lagerplaetze set name='A' where name='B'` und scheitert mit einem technischen Unique-Violation-Fehler. Außerdem gibt es keinen Audit-Eintrag, wer Palette oder Kanal eines Kartons geändert hat.

**Vorschlag:** In `karton_setzen` und `unbekannt_karton_naechster` eine Buchung „Karton geändert/angelegt“ schreiben. Im Undo „Umbenennung“ zusätzlich `if exists (select 1 from lagerplaetze where name = m_von) then raise …` mit verständlicher Meldung prüfen.

#### 17 – Excel-Import verliert führende Nullen (Bug, Niedrig)
**Fundstelle:** `index.html:2242-2245` (`XLSX.utils.sheet_to_json(ws, { defval: '' })`), Weiterverarbeitung `:2309`, `:2322`.

**Beschreibung:** Numerisch formatierte Zellen kommen als `Number`. Aus „0012345678905“ (UPC-basierte EAN) wird „12345678905“. Mit „Unbekannte Artikel neu anlegen“ überschreibt `bestand_csv_import` (`:1123-1128`) dann die korrekte GTIN des Artikels.

**Vorschlag:** `sheet_to_json(ws, { defval: '', raw: false })` verwenden (liefert den formatierten Text) und GTINs zusätzlich mit `/^\d{8,14}$/` prüfen.

### Wartbarkeit (Teil 1)

#### 18 – Setup-Skript nicht wiederholbar (Wartbarkeit, Mittel)
**Fundstelle:** SQL `:150-154`.

**Beschreibung:** Die fünf `create policy "auth_read_…"` haben kein `drop policy if exists`. Das übrige Skript ist dagegen idempotent geschrieben: `create table if not exists`, `create or replace`, `drop constraint if exists`, und bei `paletten`/`jtl_artikelliste` (`:176`, `:1572-1574`) gibt es das `drop policy if exists` bereits. Ein zweiter Lauf, z. B. um eine geänderte Funktion einzuspielen, bricht mit „policy … already exists“ ab. Je nach Ausführungsmodus des SQL-Editors wird dann nichts oder nur ein Teil übernommen.

**Vorschlag:** Vor jedes `create policy` ein `drop policy if exists "<name>" on <tabelle>;` setzen.

### Performance

#### 19 – `ladeAllePlaetze()` lädt die gesamte Tabelle `bestaende` (Performance, Hoch)
**Fundstelle:** `index.html:655-663`. 18 Aufrufstellen, u. a. `:2064` (`ssBook`: nach **jedem** Scan), `:2120`, `:855`, `:1151`, `:1165`, `:2882`.

**Beschreibung:** Um nur die Platz*namen* zu bekommen, holt `fetchAll('bestaende','lagerplatz')` *alle* Bestandszeilen (inkl. 0-Mengen), in 1000er-Seiten nacheinander. Bei 20 000 Zeilen sind das 20 sequenzielle Requests pro Scan. Im Scanner ist das Nachladen nach einer Buchung zudem nutzlos:
- Beim Einbuchen auf `ssLp` und beim Ausbuchen entsteht nie ein neuer Platzname.
- Die Platz-Buttons werden ohnehin erst bei `ssSetMode` neu aufgebaut.

**Vorschlag:**
- Eine View bzw. RPC `lagerplatz_namen()` einführen, z. B. `select name from v_lagerplaetze`. Die View enthält bereits alle Namen aus `bestaende` (mit Menge > 0) und `lagerplaetze`. Für „historische“ 0-Plätze `union select distinct lagerplatz from bestaende` ergänzen.
- `ladeAllePlaetze()` nur noch dort aufrufen, wo Plätze entstehen oder verschwinden (Lagerplatz-Operationen, Umlagern auf neuen Platz, Import, Restore).

#### 20 – `sucheRefresh()` lädt nach jeder Schnellbuchung alles neu (Performance, Mittel)
**Fundstelle:** `index.html:711` sowie `:649`, `:834`, `:857`, `:3055`, `:3075`.

**Beschreibung:** Ein Klick auf „+ Ein“ in der Suche löst zwei Komplett-Ladevorgänge aus: erst `ladeAllePlaetze()` (Fund 19), dann `ladeSucheDaten()` (artikel, bestaende und v_lagerplaetze komplett). Dabei liefert `buchen()` mit `lp_bestand_neu` bereits den neuen Wert.

**Vorschlag:** Nach `buchen` den Cache lokal aktualisieren (`sucheBestandCache` für Artikel und Platz setzen) und nur `sucheRender(true)` aufrufen. Komplett neu laden nur nach Import, Restore oder Löschen.

#### 21 – Komplett-Import und Backup-Einspielen: N+1 und Timeout-Risiko (Performance, Mittel)
**Fundstelle:** SQL `:1084-1172` (Schleife je Dateizeile mit 3–6 Abfragen), `:1178-1200` (Schleife über **alle** Artikel, je Artikel 1 + n Abfragen); `index.html:2393`, `:2568`.

**Beschreibung:** Supabase setzt für die Rolle `authenticated` standardmäßig ein `statement_timeout` von wenigen Sekunden (Standard 8 s). Ein Komplett-Import mit einigen tausend Artikeln oder ein Restore mit großem `buchungen`-Array (ein einziger RPC-Request mit dem gesamten JSON) kann daran scheitern. Durch die Transaktion bleibt die Datenbank zwar konsistent, der Import ist aber nicht durchführbar.

**Vorschlag:** Den „auf 0 setzen“-Teil mengenbasiert schreiben:
```sql
with z as (
  update bestaende b set menge = 0
  from artikel a
  where a.artikelnummer = b.artikelnummer and a.unbekannt = 0 and b.menge <> 0
    and not exists (select 1 from pg_temp.tmp_csv_kombi k
                    where k.artikelnummer = b.artikelnummer and k.lagerplatz = b.lagerplatz)
  returning b.artikelnummer, b.lagerplatz, … )
insert into buchungen (…) select … from z;
```
Ebenso den Hauptteil per `insert … on conflict … returning` mit anschließendem Massen-Insert in `buchungen`. Für die Funktion `set statement_timeout = '120s'` (Funktionsattribut) setzen.

#### 22 – Polling lädt auch bei geschlossenem Panel (Performance, Niedrig)
**Fundstelle:** `index.html:576`, `:2967-2978`.

**Beschreibung:** Alle 15 s laufen drei Abfragen: Zählung, bis zu 200 Leermeldungen und die letzte Buchung. Das passiert auch, wenn das Glocken-Panel zu ist oder der Tab im Hintergrund liegt (Tablets im Lager laufen den ganzen Tag).

**Vorschlag:** Die Liste nur laden, wenn `#leer-panel` offen ist. Bei `document.hidden` das Polling aussetzen (`visibilitychange`).

#### 23 – Index-Lage (Performance, Niedrig)
**Fundstelle:** SQL `:36`, `:80`.

**Beschreibung:**
- `idx_bestaende_artnr (artikelnummer)` ist redundant, weil der Primärschlüssel `(artikelnummer, lagerplatz)` mit derselben Spalte beginnt. Der Index kostet Schreibzeit und bringt keinen Nutzen.
- Jede Buchung prüft bzw. löscht `leermeldungen where artikelnummer=? and lagerplatz=? and gesehen=0`. Dafür gibt es nur den Index auf `gesehen`, der bei wachsender Tabelle (gesehene Meldungen werden nie gelöscht) kaum selektiv ist.

**Vorschlag:** `drop index idx_bestaende_artnr;` und `create index on leermeldungen (artikelnummer, lagerplatz) where gesehen = 0;`. Optional gesehene Meldungen nach X Monaten aufräumen.

#### 24 – „Palette sortieren“: viele Roundtrips pro Scan (Performance, Niedrig)
**Fundstelle:** `index.html:1285-1338`, `:1187-1198`.

**Beschreibung:** Pro Scan laufen `resolveArtikel` (2 Abfragen), `erBestandAuf`, `einraeumen_scan`, dann `erInhaltLaden` (RPC `unbekannt_karton_aktuell` + Abfrage) und `refreshUndo`. Das sind 6–7 sequenzielle Requests. Bei schwachem WLAN in der Halle merkt man das.

**Vorschlag:** Mit `resolveArtikel` per `.or('artikelnummer.eq.X,gtin.eq.X')` eine Abfrage sparen. `einraeumen_scan` kann den neuen Karton-Inhalt bzw. die Menge zurückgeben, dann lässt sich `erSession.inhalt` lokal fortschreiben.

### Toter Code / Altlasten

#### 25 – Ungenutzte CSS-Regeln (Toter Code, Niedrig)
**Fundstelle:** `index.html`
- `:20-21`: `#glocke.hat-neue` + `@keyframes gp` (Klasse `hat-neue` wird nie gesetzt)
- `:27-29`: `.leer-item`, `.leer-item-art`, `.leer-item-meta` (Panel nutzt `.art`)
- `:50-53`: `.buchung-box` und Nachfahren
- `:57`: Selektor `#lager-grid` (es gibt nur die Klasse `.lager-grid`)
- `:97-98`: `.art-name`, `.art-meta` (`art-name` gibt es nur als *ID* des Eingabefelds)
- `:126`: `.er-flash.pulse` (die Animation wird per `style.animation` gesetzt, `:1270-1272`)
- `:134`: `.so-card.so-offen`

Geprüft per grep auf `class="…"`, `classList`, `className` und Template-Strings.

**Vorschlag:** Entfernen (siehe Abschnitt 4).

#### 26 – Übergangs-Fallback in `leerGesehen()` (Toter Code, Niedrig)
**Fundstelle:** `index.html:2998-3004`.

**Beschreibung:** Der direkte `update leermeldungen` war für „Schritt A fehlt noch“ gedacht. Das Komplett-Skript legt `leermeldungen_alle_gesehen` an (`SQL:1401`) und entzieht `authenticated` das UPDATE-Recht (`SQL:161`). Der Fallback kann nie mehr gelingen.

**Vorschlag:** Auf `const { error } = await client.rpc('leermeldungen_alle_gesehen');` reduzieren.

#### 27 – Migrationsreste im „Neu-aufsetzen“-Skript (Toter Code, Niedrig)
**Fundstelle:** SQL
- `:88-99`: `drop constraint if exists` + `add constraint` (bei Neuaufbau gehört das in `create table`)
- `:107-109`: `alter table artikel add column if not exists unbekannt` (gehört in `create table artikel`)
- `:714`: `drop function if exists rueckgaengig();` (alte Signatur ohne Parameter)
- `:1572`: `drop policy if exists "auth_all_paletten"` (alte Policy)
- `:1583-1585`: Befüllen von `paletten` aus `lagerplaetze.palette`; bei einem Neuaufbau ist `lagerplaetze` leer

**Beschreibung:** Das Skript heißt „KOMPLETT neu aufsetzen“, enthält aber eine Schichtung aus Migrationen. Bei einem bestehenden System schaden die Reste nicht, sie machen das Schema aber schwer lesbar: Die Spalte `unbekannt` steht z. B. 80 Zeilen unter der Tabelle.

**Vorschlag:** Das Schema als „Zielzustand“ konsolidieren und Migrationen getrennt in `supabase/migrations/` führen. Wenn das Skript bewusst auch als Update-Skript dienen soll, das im Kopf so dokumentieren.

#### 28 – Veraltete Kommentare und UI-Texte (Toter Code, Niedrig)
**Fundstelle:**
- SQL `:1236-1239`: Der Kommentar sagt, `authenticated` habe „SELECT/INSERT/UPDATE/DELETE via RLS“. Seit Paket 3 stimmt das nicht mehr (nur SELECT), und die Funktion läuft als `SECURITY DEFINER`.
- SQL `:1257`: „leert erst alle 5 Tabellen“. Es sind inzwischen 6 (mit `paletten`).
- SQL `:137`: „nachdem Schema + Daten (01, 02) geladen sind“; `:4-11` und `:14`, `:128`, `:183`, `:250`, `:1556`: Verweise auf Einzeldateien (`01_schema.sql` …, `21b_…`), die nicht im Repo liegen.
- SQL `:1557-1563`: „Einmalig … ausführen“ / „Ersetzt die bisher im Code fest hinterlegte Liste“ (Historie).
- `index.html:1829-1830`: `select('*')` „sobald die Spalte existiert (Migration 19)“. Die Spalte ist inzwischen Teil des Schemas.
- `index.html:2505`: Die Fehlermeldung verweist auf „alles_loeschen.sql“, das es nicht gibt.
- `index.html:463`: Die Sicherungsbeschreibung nennt die Paletten nicht, obwohl sie gesichert werden (`:2464`).
- `index.html:2654-2655`: Zwei Kopfkommentare stehen übereinander; der erste gehört zu `fetchAll`, der zweite zu `FETCH_PK`.

**Vorschlag:** Die Kommentare an den Ist-Zustand anpassen und die Historie in die Commit-Messages bzw. ein CHANGELOG verschieben.

#### 29 – Überflüssige Guards, Zweige und Duplikate (Toter Code, Niedrig)
**Fundstelle:**
- `index.html:2514-2515`, `:2581-2583`: `if (typeof loadDashboard === 'function')`. Die Funktionen sind immer definiert.
- `:2713-2715`: `el('prot-typ') ? … : ''`. Die Elemente existieren immer.
- `:2320`: `colLp ? … : ''`. `colLp` ist nach `:2304` garantiert gesetzt.
- `:2208-2213`: `palettenCache` ist global, wird aber nur lokal genutzt.
- SQL `:436-438`: `select coalesce(menge,0) into …` und direkt danach `coalesce(v_ziel_nachher,0)`. Das erste `coalesce` ist wirkungslos, weil bei „keine Zeile“ ohnehin NULL ankommt.
- `index.ts:183-185` gegenüber `:234-236`: `heuteBerlin()` ist identisch mit `datumBerlin(new Date())`.

**Vorschlag:** Vereinfachen bzw. entfernen.

#### 30 – Kommentar-Payloads ohne Leser (Toter Code, Niedrig)
**Fundstelle:** SQL `:882` (`'NEWLP|'||p_name`), `:1598` (`PALETTE_NEU|`), `:1624` (`PALETTE_RENAME|`), `:618` (`DELETE|…` bei „Artikel gelöscht“).

**Beschreibung:** Kein Code wertet diese Präfixe aus. `rueckgaengig` nutzt bei „Lagerplatz angelegt“ `b.lagerplatz`, und die anderen Typen sind nicht umkehrbar. Im Protokoll erscheint durch `renderProtokoll` (`index.html:2795`) als Kommentar nur „NEWLP“, „PALETTE_NEU“ usw.

**Vorschlag:** Lesbare Kommentare schreiben, z. B. „Palette angelegt“. Den `DELETE|`-Snapshot bei „Artikel gelöscht“ als bewusstes Audit-Format dokumentieren oder im Protokoll lesbar aufbereiten.

### Umständlicher Code

#### 31 – „Glocke pflegen“ und Buchungs-Insert vielfach kopiert (Umständlich, Mittel)
**Fundstelle:** SQL, Leermeldung anlegen/entfernen in: `:312-324`, `:372-382`, `:464-474`, `:649-652`, `:692-699`, `:832`, `:849-851`, `:1162-1169`, `:1192-1195`. Der 12-spaltige `insert into buchungen (…)` steht rund 20×.

**Beschreibung:** Jede neue Schreibfunktion muss die Glocken-Regeln korrekt nachbauen. Die Varianten unterscheiden sich bereits: `hinweis` ist mal `''`, mal `'Sammel-Ausbuchen'` (→ Fund 8), Gesamtbestände mal gesetzt, mal NULL (→ Fund 41).

**Vorschlag:**
```sql
create function glocke_pflegen(p_artnr text, p_lp text, p_vorher int, p_nachher int,
                               p_name text, p_gtin text) returns void language plpgsql as $$
begin
  if p_vorher > 0 and p_nachher = 0 then
    insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz)
      select now(), p_artnr, p_name, p_gtin, p_lp
      where not exists (select 1 from leermeldungen
                        where artikelnummer = p_artnr and lagerplatz = p_lp and gesehen = 0);
  elsif p_nachher > 0 then
    delete from leermeldungen where artikelnummer = p_artnr and lagerplatz = p_lp and gesehen = 0;
  end if;
end $$;
```
Analog dazu eine Funktion `buchung_schreiben(...)` mit benannten Parametern einführen.

#### 32 – `einraeumen_scan` dupliziert `umlagern` + `buchen` (Umständlich, Niedrig)
**Fundstelle:** SQL `:406-479` gegenüber `:256-393`.

**Beschreibung:** Die Funktion soll atomar sein. Das wäre auch mit Aufrufen von `umlagern()` und `buchen()` innerhalb derselben Funktion gegeben, genau so macht es `unbekannt_einbuchen` (`:1482`). Zurzeit existieren drei Kopien der Umlagerlogik.

**Vorschlag:**
```sql
if v_verf > 0 then perform umlagern(p_artikelnummer, p_quelle, p_ziel, v_verf); end if;
if v_surplus > 0 then perform buchen(p_artikelnummer, p_ziel, 'ein', v_surplus, 'Inventur-Zugang (Einräumen)'); end if;
```

#### 33 – Druckfenster-Code 5× kopiert (Umständlich, Niedrig)
**Fundstelle:** `index.html:821-823`, `:1591-1602`, `:1677-1679`, `:1712-1714`, `:1782-1784`.

**Vorschlag:** Eine Hilfsfunktion `druckFenster(html, popupText)` einführen. Sie kann auch Fund 4 lösen, wenn sie das Fenster vorab öffnet.

#### 34 – Ton-/Sprachausgabe in vier Varianten (Umständlich, Niedrig)
**Fundstelle:** `index.html:1253-1263` (`sprich`), `:1863-1872` (`ansageImmer`), `:1875-1899` (`unbAnsage`), `:1964-1987` (`ssWarnen`).

**Beschreibung:** Es gibt vier nahezu gleiche Blöcke für `SpeechSynthesisUtterance` und zwei Oszillator-Tonfolgen mit je eigenem `AudioContext` (`unbAnsage.ctx`, `ssWarnen.ctx`). Browser begrenzen die Zahl der AudioContexts.

**Vorschlag:** Zwei Funktionen `ansage(text, {immer})` und `ton(folge)` mit einem gemeinsamen Kontext.

#### 35 – `fetchAll` mit zwei Sortier-APIs; Fehlerausgabe-Muster kopiert (Umständlich, Niedrig)
**Fundstelle:** `index.html:2660-2685` (`opts.order` **und** `opts.orderBy`); das Muster `el(x).innerHTML = '<span class="err">' + esc(…) + '</span>'` kommt rund 40× vor.

**Vorschlag:** Nur `orderBy: [{col, asc}]` behalten und `zeigeFehler(elId, e)` / `zeigeOk(elId, html)` als Helfer einführen.

#### 36 – Löschen mit doppelter Bestätigung (Umständlich, Niedrig)
**Fundstelle:** `index.html:3038-3050` (`loescheArtikel`), `:2900-2910` (`lpLoeschen`).

**Beschreibung:** Das Frontend ermittelt den Bestand vorab und warnt im ersten `confirm`. Danach ruft es die RPC ohne `erzwingen` auf, bekommt `BESTAND_VORHANDEN` und fragt ein zweites Mal. Das sind zwei Dialoge und drei Requests für eine Entscheidung.

**Vorschlag:** Nach dem ersten (informierten) `confirm` direkt mit `p_erzwingen: stueck > 0` aufrufen. Die Serverprüfung bleibt als Schutz bestehen.

#### 37 – Kleinere Umständlichkeiten (Umständlich, Niedrig)
**Fundstelle:**
- `index.html:935-939`: Im Filter-Callback wird für jede Bestandszeile `new Set(sucheLagerplaetzeCache.filter(…).map(…))` neu gebaut, obwohl dieselbe Menge in `:876` bereits als `namenSet` existiert. Außerdem filtert jede der bis zu 60 Trefferzeilen den gesamten `sucheBestandCache`; besser einmal eine `Map artikelnummer → Zeilen` bauen.
- `index.ts:74-94`: `gzip()` sammelt die Chunks von Hand, und `writer.write()`/`writer.close()` werden nicht abgewartet.

**Vorschlag (gzip):**
```ts
const gz = new Uint8Array(await new Response(new Blob([bytes]).stream()
  .pipeThrough(new CompressionStream("gzip"))).arrayBuffer());
```

### Wartbarkeit (Teil 2)

#### 38 – Doppelte „Quellen der Wahrheit“ (Wartbarkeit, Mittel)
**Fundstelle:**
- Undo: `index.html:581` (`UNDO_TYPEN`), `:593` (`UNDO_MAX_MS`) gegenüber SQL `:720`, `:736-737`.
- JTL-Kommentar-CSV: `index.html:2434-2452` + `:2702` (`csvZelle`) gegenüber `index.ts:208-231`.

**Beschreibung:** Beide Stellen sind laut Kommentar „bei Änderungen beide anpassen“. Inhaltlich stimmen sie aktuell überein (geprüft: Filter `unbekannt`, nur `menge > 0`, Sortierung, BOM, CRLF, Escaping). Das ist aber fehleranfällig.

**Vorschlag:**
- Eine SQL-Funktion `jtl_kommentar_zeilen()` (bzw. View) einführen, die Frontend und Edge Function beide verwenden.
- Für Undo eine RPC `undo_kandidat()` anlegen, die `id`, `typ` und Beschreibung liefert (bzw. NULL). Damit entfallen `UNDO_TYPEN` und `UNDO_MAX_MS` im Frontend.

#### 39 – Palettenliste und `karton_setzen` laufen auseinander (Wartbarkeit, Niedrig)
**Fundstelle:** SQL `:484-497`; `index.html:357-361`, `:2924-2932` (freies Textfeld „Palette“), `:1060` (Auswahl in „Palette sortieren“ nur aus Tabelle `paletten`).

**Szenario:** In den Karton-Einstellungen wird Palette „P41“ eingetippt. In der Suche erscheint ein Button „P41“, in „Palette sortieren“ fehlt die Palette.

**Vorschlag:** `karton_setzen` legt eine unbekannte Palette in `paletten` an oder lehnt sie ab. Im Frontend wird das Textfeld zu einem `<select>` aus `palettenCache`.

#### 40 – Protokoll kennt neuere Buchungstypen nicht (Wartbarkeit, Niedrig)
**Fundstelle:** `index.html:393-400` (Typ-Filter), `:2755-2760` (`ptClass`). Typen aus SQL `:1546`, `:1597`, `:1622`.

**Beschreibung:** „Artikel angelegt“, „Palette angelegt“ und „Palette umbenannt“ lassen sich nicht filtern. Die Palettentypen werden als „CSV“ eingefärbt (`pt-csv` als Rückfallwert).

**Vorschlag:** Die Typen als eine Konstante führen, aus der Filter und Farben erzeugt werden.

#### 41 – `buchungen`-Zeilen uneinheitlich befüllt (Wartbarkeit, Niedrig)
**Fundstelle:** SQL `:458-461` (Eingang aus `einraeumen_scan` ohne `bestand_gesamt_*`), `:645-648` (`sammel_ausbuchen` ohne Gesamt), `:384-388` (Umlagerung: Gesamt `null`), `:1003-1005` (`lagerplatz` `null` statt `'—'`).

**Beschreibung:** Das Protokoll zeigt „—“ statt der Gesamtbestände. Auswertungen über `bestand_gesamt_nachher` sind lückenhaft.

**Vorschlag:** Mit der Hilfsfunktion aus Fund 31 vereinheitlichen.

#### 42 – Undo-Semantik widerspricht UI-Texten (Wartbarkeit, Niedrig)
**Fundstelle:** `index.html:828` gegenüber SQL `:625-629`; `einraeumen_scan` `:447-461`.

**Beschreibung:**
- Der Bestätigungsdialog beim Sammel-Ausbuchen sagt „nicht mit einem Klick rückgängig zu machen“. Die Rückgängig-Leiste bietet danach aber die *letzte Teil*-Ausbuchung an, ein Klick nimmt also genau einen von n Plätzen zurück.
- Ein atomarer Einräum-Scan mit Mehrmenge erzeugt zwei Buchungen (Umlagerung + Eingang). „Rückgängig“ nimmt zuerst nur den Eingang zurück.

**Vorschlag:** Entweder eine Sammel-Buchung mit eigenem Undo-Typ einführen oder Teil-Buchungen mit `rueckgaengig_gemacht`-unabhängiger Kennung als „nicht einzeln umkehrbar“ markieren. Den Text an das tatsächliche Verhalten anpassen.

#### 43 – Backup/Reset inkonsistent (Wartbarkeit, Niedrig)
**Fundstelle:** SQL `:1221-1251` (`alles_loeschen` lässt `paletten` stehen), `:1377-1385` (Restore ersetzt `paletten`); `index.html:2466` (`erstellt`, `quelle`) gegenüber `index.ts:335` (`erstellt_am`); SQL `:42` (`lagerplaetze.angelegt text`, befüllt mit `now()::text`).

**Vorschlag:** Ein einheitliches Backup-Format mit Versionsfeld (`format: 1`) einführen und das Verhalten von `alles_loeschen` bezüglich `paletten` bewusst festlegen und dokumentieren. `angelegt` als `timestamptz` führen.

#### 44 – Edge Function: Robustheit (Wartbarkeit, Niedrig)
**Fundstelle:** `index.ts:326` (kein eigener Aufrufschutz), `:76-78` (`writer.write/close` ohne `await`), `:162-171` (Löschfehler nur `console.error`, nicht im Healthcheck), `:31-35` (`!`-Assertions ohne Prüfung).

**Beschreibung:** Mit Standard-`verify_jwt` reicht der öffentliche Anon-Key (er steht im Browser-`localStorage`), um Läufe auszulösen. Jeder Lauf überschreibt die Tagesdatei und archiviert bzw. überschreibt die JTL-Datei. Der Schaden ist gering, aber unnötig. Scheitert die Aufbewahrung beim Löschen, bleibt das unbemerkt. Fehlen Secrets, kommt erst eine kryptische Dropbox-Fehlermeldung.

**Vorschlag:**
- Einen eigenen Header oder ein Secret prüfen (z. B. `x-cron-secret`), das nur der Cron-Job kennt.
- Fehlgeschlagene Löschungen in `ergebnis.retention.fehler` zählen.
- Beim Start prüfen, ob alle Pflicht-Secrets gesetzt sind.

#### 45 – Globaler Zustand über `window._artEdit` (Wartbarkeit, Niedrig)
**Fundstelle:** `index.html:3022`, `:3035`, `:3039`, `:3063`.

**Vorschlag:** `let artEditNr = null;` wie die übrigen Modulvariablen verwenden.

---

## 4. Kann gefahrlos entfernt werden

Jede Stelle ist per grep über alle drei Dateien geprüft, auch auf dynamische Verwendung.

**CSS (`index.html`):**
- `:20` `#glocke.hat-neue{…}` und `:21` `@keyframes gp{…}`
- `:27-29` `.leer-item`, `.leer-item-art`, `.leer-item-meta`
- `:50-53` `.buchung-box` samt `label`/`input`/`select`/`::placeholder`-Regeln
- `:57` den Teil `#lager-grid,` im Selektor (`.lager-grid` bleibt)
- `:97-98` `.art-name`, `.art-meta` (`.art` in `:96` bleibt, wird in `renderLeerPanel` genutzt)
- `:126` `.er-flash.pulse{…}` (`@keyframes erPulse` in `:125` **bleibt**, wird in `:1272` genutzt)
- `:134` `.so-card.so-offen{…}`

**JavaScript (`index.html`):**
- `:3001-3004` Fallback-Zweig in `leerGesehen()` (direktes UPDATE)
- `:2514`, `:2515`, `:2581`, `:2582`, `:2583` jeweils das `if (typeof … === 'function')` (Aufruf behalten)
- `:2713-2715` die `el('…') ? … : ''`-Guards
- `:2320` `colLp ? … : ''`, also nur noch `String(row[colLp] ?? '').trim()`
- `:2208` `let palettenCache` als globale Variable (in `palettenFuellen` lokal machen)

**SQL (`00_KOMPLETT_neu_aufsetzen.sql`)**, sofern das Skript nur noch zum Neuaufsetzen dient:
- `:714` `drop function if exists rueckgaengig();`
- `:1572` `drop policy if exists "auth_all_paletten" on paletten;`
- `:36` `create index … idx_bestaende_artnr …` (durch PK abgedeckt)
- `:436` das `coalesce(...)` in `select coalesce(menge,0) into v_ziel_nachher` (wirkungslos wegen `:438`)
- `:88-99`, `:107-109`: als `CHECK` bzw. Spalte direkt in die `create table`-Anweisungen verschieben (Konsolidierung, keine reine Löschung)

**Edge Function (`index.ts`):**
- `:183-185` `heuteBerlin()`: durch `datumBerlin(new Date())` ersetzen

**Kommentare/Texte:** die in Fund 28 genannten veralteten Kommentare bzw. Verweise (`alles_loeschen.sql`, „Migration 19“, „Schritt A“, „5 Tabellen“, RLS-Kommentar in `alles_loeschen`).

Nicht gefunden: ungenutzte JS-Funktionen, ungenutzte SQL-Funktionen (alle 26 RPCs werden aufgerufen), verwaiste HTML-IDs (alle IDs werden referenziert, `tab-*` dynamisch über `'tab-'+t`), auskommentierter Code.

---

## 5. Priorisierte Aufräum-Empfehlung

**Stufe 1 – kleine, risikoarme Korrekturen mit direktem Nutzen (je < 1 h):**
1. Fund 1: GTIN-Prüfung im Undo „Artikeländerung“ streichen.
2. Fund 3: Doppelklick-Sperre für `ssBookPick`, `sucheBuchen` und `erScan`.
3. Fund 8 und 9: Falsche Darstellung bzw. Meldung (Sammel-Ausbuchen-Glocke, GTIN-Importtext).
4. Fund 18: `drop policy if exists` ergänzen, damit das Skript wiederholbar ist.
5. Fund 12, 11, 17 (`raw:false`): kleine Einzeiler.
6. Abschnitt 4: tote CSS-, JS- und Kommentar-Stellen entfernen; `leerGesehen`-Fallback raus.

**Stufe 2 – Performance (größter spürbarer Effekt im Lageralltag):**
7. Fund 19: `ladeAllePlaetze()` auf eine schlanke Namensabfrage umstellen und aus `ssBook`/Scanner-Pfad entfernen.
8. Fund 20: Suche nach Schnellbuchung lokal aktualisieren statt Komplett-Reload.
9. Fund 22, 23: Polling nur bei sichtbarem Panel/Tab; Index-Korrekturen.

**Stufe 3 – Robustheit:**
10. Fund 4: Druckfenster synchron öffnen bzw. ein gemeinsames Druckdokument (zusammen mit Fund 33).
11. Fund 7, 10: Einheitlicher Fehler-Wrapper für Supabase-Aufrufe, Fehler sichtbar machen.
12. Fund 5: Kartonnummer serverseitig mit Advisory-Lock vergeben.
13. Fund 6: Serverseitige Protokollsuche.
14. Fund 21: `bestand_csv_import` mengenbasiert und mit Funktions-`statement_timeout`.

**Stufe 4 – Struktur und Wartbarkeit (bei der nächsten größeren Änderung):**
15. Fund 31, 32, 41: SQL-Hilfsfunktionen `glocke_pflegen` und `buchung_schreiben`; `einraeumen_scan` auf `umlagern` und `buchen` aufbauen.
16. Fund 2, 16, 42: Undo-Snapshots um `lagerplaetze`-Metadaten erweitern, fehlende Protokollzeilen ergänzen, Texte angleichen.
17. Fund 38: JTL-CSV-Logik und Undo-Kandidat in die Datenbank verlagern (eine Quelle der Wahrheit).
18. Fund 27: Schema in einen konsolidierten Zielzustand und getrennte Migrationen aufteilen.
19. Fund 33–35, 39, 40, 43–45: Helfer für Druck, Audio und Fehlerausgabe; Paletten-Auswahl; Typkonstante; Backup-Format; Edge-Function-Absicherung.

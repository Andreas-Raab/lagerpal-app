#!/usr/bin/env python3
# Erzeugt supabase/updates/2026-10_paket3a.sql aus 00_KOMPLETT_neu_aufsetzen.sql:
# die in Paket 3a geänderten Funktionen + die Sicht v_dashboard, eingerahmt von
# Kopf/Fuß. Prüfung danach: DB im Stand Paket 2 + Update muss denselben
# Fingerabdruck haben wie eine Neuinstallation (siehe tests/README.md).
import re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
s = (root / 'supabase/00_KOMPLETT_neu_aufsetzen.sql').read_text(encoding='utf-8')
ziel = root / 'supabase/updates/2026-10_paket3a.sql'
namen = ['einraeumen_scan', 'sammel_ausbuchen', 'inventur_anwenden', 'amazon_status_setzen', 'bestand_csv_import']
def block(name):
    a = re.search(r'create or replace function ' + name + r'\(', s).start()
    nxt = s.find('create or replace function', a + 10)
    ends = [x.end() for x in re.finditer(r'(revoke|grant)[^\n]*function ' + name + r'\([^\n]*\n', s)
            if x.start() > a and (nxt == -1 or x.start() < nxt)]
    return s[a:max(ends)]
a = s.index('create or replace view v_dashboard')
e = s.index('grant select on v_dashboard to authenticated;\n', a) + len('grant select on v_dashboard to authenticated;\n')
sicht = s[a:e]
kopf = '''-- ═══════════════════════════════════════════════════════════════════════
-- LagerPal – UPDATE Paket 3a (Stand 10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Für ein BESTEHENDES System im Stand Paket 2 (Daten bleiben erhalten). Im
-- Supabase SQL-Editor komplett einfügen und ausführen. Kann gefahrlos mehrfach
-- ausgeführt werden. ZUERST im Testsystem, dann im echten System - und zwar
-- BEVOR die neue index.html live geht (die alte App läuft damit unverändert weiter).
--
-- Ganz unten wird der Fingerabdruck angezeigt. Er muss dem Wert in der
-- Testanleitung entsprechen.
--
-- Inhalt:
--  • Bestandsimport: EAN, die sich nur durch fehlende führende Nullen
--    unterscheidet, überschreibt die vorhandene nicht mehr; Stammdaten-
--    Änderungen und neu angelegte Artikel werden protokolliert
--  • Inventur: prüft, ob seit dem Laden auf dem Platz gebucht wurde
--  • Amazon-Status: „nicht ändern" für unbekannte Werte; nur echte Änderungen zählen
--  • Protokoll: Gesamtbestand auch bei Palette sortieren und Sammel-Ausbuchen
--  • Übersicht: Inventur-Zugang beim Einräumen zählt nicht mehr als „Heute ein"
-- ═══════════════════════════════════════════════════════════════════════

begin;

'''
fuss = '\ncommit;\n\n-- Kontrolle: Fingerabdruck (muss dem Wert in der Testanleitung entsprechen)\n' \
       + (root / 'tests/sql/fingerabdruck.sql').read_text(encoding='utf-8')
ziel.write_text(kopf + '\n\n'.join(block(n) for n in namen) + '\n\n' + sicht + fuss, encoding='utf-8')
print('geschrieben:', ziel)

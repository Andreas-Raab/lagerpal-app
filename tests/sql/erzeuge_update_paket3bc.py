#!/usr/bin/env python3
# Erzeugt supabase/updates/2026-10_paket3bc.sql aus 00_KOMPLETT_neu_aufsetzen.sql:
# die in Paket 3b/3c geänderten Funktionen, eingerahmt von
# Kopf/Fuß. Prüfung danach: DB im Stand Paket 2 + Update muss denselben
# Fingerabdruck haben wie eine Neuinstallation (siehe tests/README.md).
import re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
s = (root / 'supabase/00_KOMPLETT_neu_aufsetzen.sql').read_text(encoding='utf-8')
ziel = root / 'supabase/updates/2026-10_paket3bc.sql'
namen = ['alles_loeschen', 'backup_wiederherstellen', 'jtl_kommentar_csv']
def block(name):
    a = re.search(r'create or replace function ' + name + r'\(', s).start()
    nxt = s.find('create or replace function', a + 10)
    ends = [x.end() for x in re.finditer(r'(revoke|grant)[^\n]*function ' + name + r'\([^\n]*\n', s)
            if x.start() > a and (nxt == -1 or x.start() < nxt)]
    return s[a:max(ends)]
kopf = '''-- ═══════════════════════════════════════════════════════════════════════
-- LagerPal – UPDATE Paket 3b/3c (Stand 10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Für ein BESTEHENDES System im Stand Paket 3a (Daten bleiben erhalten). Im
-- Supabase SQL-Editor komplett einfügen und ausführen. Kann gefahrlos mehrfach
-- ausgeführt werden. ZUERST im Testsystem, dann im echten System - und zwar
-- BEVOR die neue index.html live geht (die alte App läuft damit unverändert weiter).
--
-- Ganz unten wird der Fingerabdruck angezeigt. Er muss dem Wert in der
-- Testanleitung entsprechen.
--
-- Inhalt:
--  • „Alles löschen" löscht auch die Palettenliste; eine ältere Sicherung ohne
--    Palettenliste ergänzt beim Einspielen die Paletten der Lagerplätze
--  • jtl_kommentar_csv(): JTL-Lagerbestandskommentar aus der Datenbank, genutzt
--    von der App und von der nächtlichen Edge Function (vorher doppelt programmiert)
-- ═══════════════════════════════════════════════════════════════════════

begin;

'''
fuss = '\ncommit;\n\n-- Kontrolle: Fingerabdruck (muss dem Wert in der Testanleitung entsprechen)\n' \
       + (root / 'tests/sql/fingerabdruck.sql').read_text(encoding='utf-8')
ziel.write_text(kopf + '\n\n'.join(block(n) for n in namen) + '\n' + fuss, encoding='utf-8')
print('geschrieben:', ziel)

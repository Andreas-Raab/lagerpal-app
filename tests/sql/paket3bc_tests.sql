-- Datenbank-Tests für Paket 3b/3c. Erwartet frische Testdaten (01_testdaten.sql).
\set ON_ERROR_STOP 1
set client_min_messages = notice;
-- alles in einer Transaktion, die am Ende zurückgerollt wird: „Alles löschen" würde
-- sonst die Testdaten (u. a. Paletten) für nachfolgende Browser-Tests leeren
begin;

-- 50/43: „Alles löschen" löscht auch die Palettenliste
do $$ declare r jsonb; begin
  perform palette_neu('P-TEST');
  r := alles_loeschen('ALLES LOESCHEN');
  assert (r->'geloescht'->>'paletten')::int >= 1, r::text;
  assert not exists (select 1 from paletten), 'Paletten noch da';
  assert not exists (select 1 from artikel) and not exists (select 1 from lagerplaetze);
  raise notice 'OK: Alles löschen inkl. Palettenliste';
end $$;

-- 51: JTL-Kommentar aus der Datenbank
do $$ declare r jsonb; begin
  insert into artikel (artikelnummer, artikelname, gtin, ist_set, online, unbekannt) values
    ('B', 'x', '', 0, 0, 0), ('a', 'x', '', 0, 0, 0), ('K;1', 'x', '', 0, 0, 0), ('WE-0-9', 'x', '', 0, 0, 1);
  insert into bestaende values ('B', 'Regal 2', 3), ('B', 'Regal 1', 1), ('a', 'Regal 1', 0), ('WE-0-9', 'U-01', 4);
  r := jtl_kommentar_csv();
  assert r->>'csv' = E'Artikelnummer;Kommentar\r\nB;Regal 1 (1), Regal 2 (3)\r\n"K;1";\r\na;', 'CSV: ' || (r->>'csv');
  assert (r->>'artikel')::int = 3 and (r->>'mit_bestand')::int = 1, r::text;
  raise notice 'OK: JTL-Kommentar (Sortierung, leere Kommentare, unbekannte Artikel, Maskierung)';
end $$;

-- 43: ältere Sicherung ohne Palettenliste ergänzt die Paletten der Lagerplätze
do $$ declare r jsonb; begin
  r := backup_wiederherstellen('{"artikel":[{"artikelnummer":"X1","artikelname":"x"}],"bestaende":[],
    "lagerplaetze":[{"name":"P77-K01","palette":"P77","kanal":1}],"buchungen":[],"leermeldungen":[]}');
  assert exists (select 1 from paletten where name = 'P77'), 'P77 fehlt: ' || r::text;
  raise notice 'OK: Sicherung ohne Palettenliste ergänzt Paletten der Lagerplätze';
end $$;

rollback;

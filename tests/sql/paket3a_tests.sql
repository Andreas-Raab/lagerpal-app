-- Datenbank-Tests für Paket 3a. Erwartet frische Testdaten (01_testdaten.sql).
-- Jeder Test meldet „OK: …"; ein Fehler bricht mit Meldung ab.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.m(a text, l text) returns int language sql as
  $$ select coalesce((select menge from bestaende where artikelnummer=a and lagerplatz=l), 0) $$;

-- 25: EAN ohne führende Nullen (Excel) überschreibt die vorhandene nicht
do $$ declare r jsonb; begin
  update artikel set gtin = '0012345678905' where artikelnummer = 'A2';
  r := bestand_csv_import('[{"artikelnummer":"A2","lagerplatz":"QUELLE-1","bestand":10,"artikelname":"","gtin":"12345678905","set_flag":null}]', 'teil', true);
  assert (select gtin from artikel where artikelnummer = 'A2') = '0012345678905', 'EAN überschrieben';
  assert (r->>'stammdaten_geaendert')::int = 0, 'Stammdaten: ' || r::text;
  assert not exists (select 1 from buchungen where typ = 'Artikeländerung (Import)'), 'unnötiger Protokolleintrag';
  -- eine wirklich andere EAN wird weiter übernommen
  r := bestand_csv_import('[{"artikelnummer":"A2","lagerplatz":"QUELLE-1","bestand":10,"artikelname":"","gtin":"4000000000055","set_flag":null}]', 'teil', true);
  assert (select gtin from artikel where artikelnummer = 'A2') = '4000000000055';
  raise notice 'OK: EAN mit fehlenden führenden Nullen bleibt erhalten';
end $$;

-- 28: Stammdaten-Änderungen und neue Artikel werden protokolliert
do $$ declare r jsonb; b record; begin
  r := bestand_csv_import('[
    {"artikelnummer":"A1","lagerplatz":"Regal 3","bestand":12,"artikelname":"Neuer Name","gtin":"","set_flag":null},
    {"artikelnummer":"A1","lagerplatz":"Regal 4","bestand":5,"artikelname":"Neuer Name","gtin":"","set_flag":null},
    {"artikelnummer":"A3","lagerplatz":"Regal-1","bestand":7,"artikelname":"","gtin":"","set_flag":1},
    {"artikelnummer":"NEU1","lagerplatz":"Regal 9","bestand":2,"artikelname":"Ganz neu","gtin":"","set_flag":null}]', 'teil', true);
  assert (r->>'stammdaten_geaendert')::int = 2, 'Anzahl: ' || r::text;
  assert (r->>'neu_angelegt')::int = 1;
  select * into b from buchungen where typ = 'Artikeländerung (Import)' and artikelnummer = 'A1';
  assert b.kommentar = 'Name: „Testartikel Online" → „Neuer Name"', 'Kommentar: ' || b.kommentar;
  assert (select count(*) from buchungen where typ = 'Artikeländerung (Import)' and artikelnummer = 'A1') = 1, 'doppelt protokolliert';
  assert (select kommentar from buchungen where typ = 'Artikeländerung (Import)' and artikelnummer = 'A3') = 'Set: nein → ja';
  assert exists (select 1 from buchungen where typ = 'Artikel angelegt' and artikelnummer = 'NEU1');
  -- Set-Kennzeichen unverändert → kein Eintrag
  r := bestand_csv_import('[{"artikelnummer":"A3","lagerplatz":"Regal-1","bestand":7,"artikelname":"","gtin":"","set_flag":1}]', 'teil', false);
  assert (r->>'stammdaten_geaendert')::int = 0;
  raise notice 'OK: Stammdaten-Änderungen und neue Artikel im Protokoll';
end $$;

-- 16: Inventur prüft Zwischenbuchungen
do $$ declare r jsonb; begin
  -- gezählt wurde bei Soll 11, inzwischen sind es 12 → nichts übernehmen
  r := inventur_anwenden('Regal 3', '{"A1":{"ist":10,"soll":11},"SET1":{"ist":3,"soll":4}}');
  assert (r->>'ok')::boolean = false, 'Konflikt nicht erkannt: ' || r::text;
  assert jsonb_array_length(r->'konflikte') = 1 and r->'konflikte'->0->>'aktuell' = '12', r::text;
  assert pg_temp.m('A1','Regal 3') = 12 and pg_temp.m('SET1','Regal 3') = 4, 'trotz Konflikt geändert';
  -- mit aktuellem Soll → übernommen
  r := inventur_anwenden('Regal 3', '{"A1":{"ist":10,"soll":12},"SET1":{"ist":4,"soll":4}}');
  assert (r->>'anzahl_geaendert')::int = 1 and pg_temp.m('A1','Regal 3') = 10, r::text;
  -- auf einem leeren Platz zählen
  r := inventur_anwenden('Leerplatz', '{"A2":{"ist":3,"soll":0}}');
  assert pg_temp.m('A2','Leerplatz') = 3, r::text;
  -- alte App (nur Zahl) funktioniert weiter
  r := inventur_anwenden('Regal 3', '{"A1":9}');
  assert pg_temp.m('A1','Regal 3') = 9;
  raise notice 'OK: Inventur erkennt Zwischenbuchungen, leere Plätze, altes Format';
end $$;

-- 24: Amazon-Status: „nicht ändern" und nur echte Änderungen zählen
do $$ declare r jsonb; begin
  -- A1 online (unbekannter Status → nicht ändern), A2 offline → online, SET1 + A3 + NEU1 fehlen → nicht online
  r := amazon_status_setzen('[{"artikelnummer":"A1","online":null},{"artikelnummer":"A2","online":1}]', 'voll');
  assert (r->>'geaendert')::int = 4, 'geändert: ' || r::text;
  assert (select online from artikel where artikelnummer = 'A1') = 1, 'A1 geändert';
  assert (select online from artikel where artikelnummer = 'A2') = 1;
  assert (select online from artikel where artikelnummer = 'SET1') = 2;
  r := amazon_status_setzen('[{"artikelnummer":"A1","online":null},{"artikelnummer":"A2","online":1}]', 'voll');
  assert (r->>'geaendert')::int = 0, 'zweiter Lauf: ' || r::text;
  r := amazon_status_setzen('[{"artikelnummer":"A2","online":2}]', 'nur');
  assert (r->>'geaendert')::int = 1 and (select online from artikel where artikelnummer = 'A1') = 1;
  raise notice 'OK: Amazon-Status zählt nur echte Änderungen, „nicht ändern" bleibt';
end $$;

-- 28: Gesamtbestand im Protokoll, Inventur-Zugang zählt nicht als „Heute ein"
do $$ declare b record; begin
  perform einraeumen_scan('A1','QUELLE-1','P01-K01',5);     -- 2 umgelagert + 3 Inventur-Zugang
  for b in select * from buchungen where artikelnummer = 'A1' and typ in ('Umlagerung','Eingang') loop
    assert b.bestand_gesamt_vorher is not null and b.bestand_gesamt_nachher is not null, 'Gesamt fehlt: ' || b.typ;
  end loop;
  assert (select bestand_gesamt_nachher - bestand_gesamt_vorher from buchungen where typ = 'Eingang' and artikelnummer = 'A1') = 3;
  assert (select ein_heute from v_dashboard) = 0, 'Inventur-Zugang als Eingang gezählt';
  perform buchen('A2', 'Regal 3', 'ein', 2);
  assert (select ein_heute from v_dashboard) = 2;
  perform sammel_ausbuchen(array['A3']);
  assert not exists (select 1 from buchungen where typ = 'Ausgang' and artikelnummer = 'A3' and bestand_gesamt_vorher is null);
  assert (select min(bestand_gesamt_nachher) from buchungen where typ = 'Ausgang' and artikelnummer = 'A3') = 0;
  raise notice 'OK: Gesamtbestand im Protokoll, Kennzahl „Heute ein" ohne Inventur-Zugang';
end $$;

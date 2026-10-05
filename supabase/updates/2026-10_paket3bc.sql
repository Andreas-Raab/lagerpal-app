-- ═══════════════════════════════════════════════════════════════════════
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

create or replace function alles_loeschen(p_bestaetigung text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_artikel integer; v_bestaende integer; v_lagerplaetze integer;
    v_buchungen integer; v_leermeldungen integer; v_paletten integer;
begin
    if p_bestaetigung is distinct from 'ALLES LOESCHEN' then
        raise exception 'Bestätigung fehlt oder falsch. Bitte exakt "ALLES LOESCHEN" übergeben.';
    end if;
    select count(*) into v_artikel from artikel;
    select count(*) into v_bestaende from bestaende;
    select count(*) into v_lagerplaetze from lagerplaetze;
    select count(*) into v_buchungen from buchungen;
    select count(*) into v_leermeldungen from leermeldungen;
    select count(*) into v_paletten from paletten;

    -- DELETE statt TRUNCATE: TRUNCATE braucht ein eigenes TRUNCATE-Recht, das die
    -- App-Rolle "authenticated" nicht hat (nur SELECT/INSERT/UPDATE/DELETE via RLS),
    -- deshalb blieb bisher alles unverändert stehen. DELETE nutzt dieselben Rechte
    -- wie artikel_loeschen() & Co., die schon funktionieren.
    -- "where true" ist nötig, weil Supabase (pg-safeupdate) ein DELETE ganz ohne
    -- WHERE-Klausel grundsätzlich blockiert — auch wenn hier wirklich alles weg soll.
    delete from bestaende where true;
    delete from artikel where true;
    delete from buchungen where true;
    delete from leermeldungen where true;
    delete from lagerplaetze where true;
    delete from mengen_abweichungen where true;   -- Abgleich-Fälle gehören zum gelöschten Stand
    delete from paletten where true;              -- „wirklich alles" (Entscheidung 10/2026)

    return jsonb_build_object('ok', true, 'geloescht', jsonb_build_object(
        'artikel', v_artikel, 'bestaende', v_bestaende, 'lagerplaetze', v_lagerplaetze,
        'buchungen', v_buchungen, 'leermeldungen', v_leermeldungen, 'paletten', v_paletten));
end; $$;
revoke all on function alles_loeschen(text) from anon, public;
grant execute on function alles_loeschen(text) to authenticated;


create or replace function backup_wiederherstellen(p_daten jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
-- Robust gegen Unstimmigkeiten IN der Sicherungsdatei (Stand 27.09.2026):
-- Das Backup liest die Tabellen nacheinander. Wird genau in diesen Sekunden
-- gebucht/angelegt/gelöscht, kann die Datei (a) einen Bestand zu einem Artikel
-- enthalten, der in der Artikelliste fehlt, oder (b) eine Zeile doppelt
-- enthalten (Seitenwechsel beim Auslesen). Früher brach das Einspielen daran
-- komplett ab - ausgerechnet im Notfall. Jetzt werden solche Einzelzeilen
-- übersprungen und im Ergebnis gemeldet ('uebersprungen', 'beispiele_ohne_artikel').
declare
    v_artikel integer; v_bestaende integer; v_lagerplaetze integer;
    v_buchungen integer; v_leermeldungen integer; v_paletten integer;
    v_negativ integer; v_ohne_artikel integer; v_beispiele jsonb;
    v_ueber jsonb := '{}'::jsonb;
    v_n integer;
begin
    if p_daten is null or not (p_daten ? 'artikel') or not (p_daten ? 'bestaende') then
        raise exception 'Ungültige Sicherungsdatei: erwartete Felder (artikel, bestaende, …) fehlen.';
    end if;

    -- "where true": Supabase (pg-safeupdate) blockiert DELETE ohne WHERE-Klausel.
    delete from bestaende where true;
    delete from artikel where true;
    delete from lagerplaetze where true;
    delete from buchungen where true;
    delete from leermeldungen where true;
    -- Abgleich-Fälle passen nur zum Stand, aus dem sie stammen: immer leeren,
    -- und nur aus der Sicherung übernehmen, wenn sie dort enthalten sind (s. u.)
    delete from mengen_abweichungen where true;

    -- unbekannt: ältere Sicherungen haben die Spalte nicht → 0
    insert into artikel (artikelnummer, artikelname, gtin, ist_set, online, unbekannt)
        select artikelnummer, coalesce(artikelname,''), coalesce(gtin,''),
               case when ist_set = 1 then 1 else 0 end,
               case when online in (1,2) then online else 0 end,
               case when unbekannt = 1 then 1 else 0 end
        from jsonb_to_recordset(coalesce(p_daten->'artikel', '[]'::jsonb)) as x(
            artikelnummer text, artikelname text, gtin text, ist_set smallint, online smallint, unbekannt smallint)
        where artikelnummer is not null
        on conflict (artikelnummer) do nothing;
    get diagnostics v_artikel = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'artikel', '[]'::jsonb)) - v_artikel;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('artikel', v_n); end if;

    -- Ältere Sicherungen (vor Paket 2) können negative Bestände enthalten, die der
    -- CHECK (menge >= 0) nicht mehr zulässt. Statt die Wiederherstellung scheitern
    -- zu lassen: auf 0 setzen und im Ergebnis melden ('negativ_auf_null').
    select count(*) into v_negativ
        from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(menge integer)
        where menge < 0;
    -- Bestände zu Artikeln, die nicht in der Datei stehen, würde der Fremdschlüssel
    -- ablehnen (und damit das ganze Einspielen) → überspringen und melden.
    select count(*), jsonb_agg(b) filter (where rn <= 5)
        into v_ohne_artikel, v_beispiele
        from (select x.artikelnummer || ' @ ' || coalesce(x.lagerplatz,'?') || ' (' || coalesce(x.menge,0) || ')' as b,
                     row_number() over () as rn
              from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(
                  artikelnummer text, lagerplatz text, menge integer)
              where x.artikelnummer is not null
                and not exists (select 1 from artikel a where a.artikelnummer = x.artikelnummer)) t;
    insert into bestaende (artikelnummer, lagerplatz, menge)
        select artikelnummer, lagerplatz, greatest(coalesce(menge,0), 0)
        from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(
            artikelnummer text, lagerplatz text, menge integer)
        where artikelnummer is not null and lagerplatz is not null
          and exists (select 1 from artikel a where a.artikelnummer = x.artikelnummer)
        on conflict (artikelnummer, lagerplatz) do nothing;
    get diagnostics v_bestaende = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'bestaende', '[]'::jsonb)) - v_bestaende - v_ohne_artikel;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('bestaende', v_n); end if;

    insert into lagerplaetze (name, angelegt, palette, kanal)
        select name, coalesce(angelegt,''), coalesce(palette,''), case when kanal in (1,2) then kanal else 0 end
        from jsonb_to_recordset(coalesce(p_daten->'lagerplaetze', '[]'::jsonb)) as x(
            name text, angelegt text, palette text, kanal smallint)
        where name is not null
        on conflict (name) do nothing;
    get diagnostics v_lagerplaetze = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'lagerplaetze', '[]'::jsonb)) - v_lagerplaetze;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('lagerplaetze', v_n); end if;

    insert into buchungen (id, zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
        bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher,
        kommentar, rueckgaengig_gemacht, vorgang)
        select id, zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher,
            kommentar, case when rueckgaengig_gemacht = 1 then 1 else 0 end, vorgang
        from jsonb_to_recordset(coalesce(p_daten->'buchungen', '[]'::jsonb)) as x(
            id bigint, zeitstempel timestamptz, typ text, artikelnummer text, artikelname text, gtin text,
            lagerplatz text, menge integer, bestand_lp_vorher integer, bestand_lp_nachher integer,
            bestand_gesamt_vorher integer, bestand_gesamt_nachher integer, kommentar text,
            rueckgaengig_gemacht smallint, vorgang uuid)
        where id is not null
        on conflict (id) do nothing;
    get diagnostics v_buchungen = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'buchungen', '[]'::jsonb)) - v_buchungen;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('buchungen', v_n); end if;
    -- Identity-Sequenz nachziehen, sonst kollidiert der nächste normale INSERT
    -- (id wurde oben explizit mitgeliefert, "generated by default" erlaubt das).
    perform setval(pg_get_serial_sequence('buchungen','id'), coalesce((select max(id) from buchungen), 0) + 1, false);

    insert into leermeldungen (id, zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
        select id, zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, case when gesehen = 1 then 1 else 0 end, coalesce(hinweis,'')
        from jsonb_to_recordset(coalesce(p_daten->'leermeldungen', '[]'::jsonb)) as x(
            id bigint, zeitstempel timestamptz, artikelnummer text, artikelname text, gtin text,
            lagerplatz text, gesehen smallint, hinweis text)
        where id is not null
        on conflict do nothing;   -- doppelte id ODER doppelte offene Meldung (uq_leer_offen)
    get diagnostics v_leermeldungen = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'leermeldungen', '[]'::jsonb)) - v_leermeldungen;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('leermeldungen', v_n); end if;
    perform setval(pg_get_serial_sequence('leermeldungen','id'), coalesce((select max(id) from leermeldungen), 0) + 1, false);

    -- "paletten" gibt es erst seit später hinzugekommenen Backups. Nur anfassen,
    -- wenn der Schlüssel im JSON vorhanden ist - so lassen ältere Sicherungen
    -- (ohne diesen Schlüssel) die aktuell gepflegten Palettennamen unangetastet,
    -- statt sie versehentlich auf leer zurückzusetzen. Das Anlegedatum ("erstellt")
    -- wird mit übernommen (fehlt es in der Datei: jetzt).
    if p_daten ? 'mengen_abweichungen' then
        insert into mengen_abweichungen (id, zeitstempel, art, artikelnummer, menge, offen, quelle, karton, vorgang, alt)
            select id, coalesce(zeitstempel, now()), art, artikelnummer, menge, least(greatest(offen, 0), menge), quelle, karton, vorgang, coalesce(alt, false)
            from jsonb_to_recordset(p_daten->'mengen_abweichungen') as x(id bigint, zeitstempel timestamptz, art text,
                 artikelnummer text, menge integer, offen integer, quelle text, karton text, vorgang uuid, alt boolean)
            where id is not null and art in ('mehr','fehlt') and menge > 0
            on conflict do nothing;
        perform setval(pg_get_serial_sequence('mengen_abweichungen','id'), coalesce((select max(id) from mengen_abweichungen), 0) + 1, false);
    end if;

    if p_daten ? 'paletten' then
        delete from paletten where true;
        insert into paletten (name, erstellt)
            select name, coalesce(erstellt, now())
            from jsonb_to_recordset(coalesce(p_daten->'paletten', '[]'::jsonb)) as x(name text, erstellt timestamptz)
            where name is not null and trim(name) <> ''
            on conflict (name) do nothing;
        get diagnostics v_paletten = row_count;
    else
        -- ältere Sicherung ohne Palettenliste: bestehende Liste behalten und die
        -- Paletten ergänzen, die bei den Lagerplätzen vorkommen (sonst fehlen sie
        -- z. B. nach „Alles löschen" in „Palette sortieren")
        insert into paletten (name)
            select distinct palette from lagerplaetze where palette <> ''
            on conflict (name) do nothing;
    end if;

    return jsonb_build_object('ok', true, 'artikel', v_artikel, 'bestaende', v_bestaende,
        'lagerplaetze', v_lagerplaetze, 'buchungen', v_buchungen, 'leermeldungen', v_leermeldungen,
        'paletten', v_paletten, 'negativ_auf_null', v_negativ,
        'bestaende_ohne_artikel', v_ohne_artikel, 'beispiele_ohne_artikel', coalesce(v_beispiele, '[]'::jsonb),
        'uebersprungen', v_ueber);
end; $$;
revoke all on function backup_wiederherstellen(jsonb) from anon, public;
grant execute on function backup_wiederherstellen(jsonb) to authenticated;


create or replace function jtl_kommentar_csv()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
    with unb as (
        select artikelnummer from artikel where unbekannt = 1
    ), grp as (
        select b.artikelnummer, string_agg(b.lagerplatz || ' (' || b.menge || ')', ', ' order by b.lagerplatz) as kommentar
        from bestaende b
        where b.menge > 0 and b.artikelnummer not in (select artikelnummer from unb)
        group by b.artikelnummer
    ), alle as (
        select artikelnummer from artikel where artikelnummer not in (select artikelnummer from unb)
        union
        select artikelnummer from grp
    ), zeilen as (
        select a.artikelnummer, coalesce(g.kommentar, '') as kommentar
        from alle a left join grp g using (artikelnummer)
    )
    select jsonb_build_object(
        'csv', 'Artikelnummer;Kommentar' || coalesce(string_agg(
            E'\r\n' || case when z.artikelnummer ~ '[";\n]' then '"' || replace(z.artikelnummer, '"', '""') || '"' else z.artikelnummer end
            || ';' || case when z.kommentar ~ '[";\n]' then '"' || replace(z.kommentar, '"', '""') || '"' else z.kommentar end,
            '' order by z.artikelnummer collate "C"), ''),
        'artikel', count(*),
        'mit_bestand', count(*) filter (where z.kommentar <> ''))
    from zeilen z;
$$;
revoke all on function jtl_kommentar_csv() from anon, public;
grant execute on function jtl_kommentar_csv() to authenticated, service_role;


commit;

-- Kontrolle: Fingerabdruck (muss dem Wert in der Testanleitung entsprechen)
select
  (select md5(string_agg(x, '|' order by x)) from (
     select 'f:'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||'):'||md5(pg_get_functiondef(p.oid)) x
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f'
     union all
     select 't:'||table_name||'.'||column_name||':'||data_type
       from information_schema.columns where table_schema = 'public'
     union all
     select 'p:'||tablename||'.'||policyname from pg_policies where schemaname = 'public'
  ) s) as fingerabdruck;

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
--  • „Alles löschen" löscht auch die Palettenliste
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

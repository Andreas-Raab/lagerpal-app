-- Richtet den täglichen Backup-Job ein. Bitte im Supabase SQL-Editor
-- ausführen (Project → SQL Editor → neue Query → einfügen → Run).
--
-- Voraussetzung: die Edge Function "lagerpal-backup" wurde bereits deployt
-- (siehe ANLEITUNG_BACKUP.md) UND unter Edge Functions → lagerpal-backup →
-- Settings ist "Verify JWT with legacy secret" AUSGESCHALTET.
--
-- Stand 27.09.2026: Der Aufruf schickt KEINEN Schlüssel mehr mit. Vorher stand
-- hier ein sb_secret_…-Key im "apikey"-Header; den hat Supabase mit
-- "Invalid API key" (401) abgelehnt, noch bevor die Funktion lief - das
-- automatische Backup hat dadurch vom Einrichten (23.09.) bis zum 27.09. nie
-- funktioniert. Da die JWT-Prüfung der Funktion aus ist, braucht der Aufruf
-- keinen Schlüssel. Nebeneffekt: kein geheimer Schlüssel mehr im Klartext.
-- timeout_milliseconds: pg_net wartet standardmäßig nur 5 s auf die Antwort;
-- das Backup dauert länger. Die Funktion läuft zwar trotzdem zu Ende, aber mit
-- 60 s steht das Ergebnis danach auch in net._http_response (Fehlersuche).
--
-- Uhrzeit (seit 27.09.2026): 03:00 Uhr nachts deutscher Zeit statt 17:00 Uhr.
-- Grund: Das Backup liest die Tabellen nacheinander aus; wird währenddessen
-- gebucht, kann es in sich leicht unstimmig werden. Nachts bucht niemand.
-- Der JTL-Export läuft im selben Lauf mit und liegt damit morgens bereit.
-- Die Datei heißt nach dem Tag, an dem sie nachts entsteht: das Backup
-- "lagerpal_backup_2026-09-28" enthält also den Stand vom Abend des 27.09.
--
-- Zeitzone: pg_cron rechnet in UTC. 03:00 Uhr in Deutschland ist:
--   - während der Sommerzeit (MESZ, UTC+2, ca. Ende März bis Ende Oktober) = 01:00 UTC
--   - während der Winterzeit (MEZ, UTC+1, ca. Ende Oktober bis Ende März)  = 02:00 UTC
-- Damit das automatisch passt, sind unten ZWEI Cron-Jobs angelegt, die sich
-- an den Kalendermonaten orientieren (kleine Ungenauigkeit von ein paar
-- Tagen rund um die exakten Umstelltermine ist für ein tägliches Backup
-- unkritisch).

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Sommerzeit-Fenster (April–Oktober): 01:00 UTC = 03:00 Uhr MESZ
select cron.schedule(
  'lagerpal-daily-backup-sommer',
  '0 1 * 4-10 *',
  $$
  select net.http_post(
    url := 'https://csrjwhqhvkuvdnshazix.supabase.co/functions/v1/lagerpal-backup',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
  $$
);

-- Winterzeit-Fenster (November–März): 02:00 UTC = 03:00 Uhr MEZ
select cron.schedule(
  'lagerpal-daily-backup-winter',
  '0 2 * 11,12,1,2,3 *',
  $$
  select net.http_post(
    url := 'https://csrjwhqhvkuvdnshazix.supabase.co/functions/v1/lagerpal-backup',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
  $$
);

-- Zur Kontrolle: zeigt alle eingerichteten Cron-Jobs
select jobid, jobname, schedule, active from cron.job order by jobname;

-- Letzte Läufe und Antworten der Funktion (Fehlersuche):
-- select j.jobname, d.status, d.start_time from cron.job_run_details d join cron.job j using (jobid) order by d.start_time desc limit 5;
-- select id, status_code, left(coalesce(error_msg, content::text), 300), created from net._http_response order by id desc limit 5;

-- Bestehende Jobs nur umstellen (statt neu anlegen), z. B. auf eine andere Uhrzeit:
-- select cron.alter_job((select jobid from cron.job where jobname = 'lagerpal-daily-backup-sommer'), schedule := '0 1 * 4-10 *');
-- select cron.alter_job((select jobid from cron.job where jobname = 'lagerpal-daily-backup-winter'), schedule := '0 2 * 11,12,1,2,3 *');

-- Falls du einen Job später wieder entfernen willst:
-- select cron.unschedule('lagerpal-daily-backup-sommer');
-- select cron.unschedule('lagerpal-daily-backup-winter');

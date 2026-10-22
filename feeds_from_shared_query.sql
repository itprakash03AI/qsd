-- =============================================================================
--  QueryStudio: set up many feeds from ONE shared query, directly in PostgreSQL
-- =============================================================================
--  Run this on QueryStudio's own PostgreSQL database (psql, DBeaver, pgAdmin --
--  any client; no psql-only commands).  It creates ONE feed per row of your
--  entity list, all reading the same shared SQL file, through QueryStudio's own
--  checks (qs_feed_template_apply): name rules, file-name clashes, dependency
--  loops, passwords encrypted, version history.  Never INSERT into feed_configs.
--
--  HOW TO USE
--    1. Edit section 1 (names, not ids) and section 2 (your entity list).
--    2. Run the whole file with dry_run = true.  Read the result at the end:
--       how many feeds WOULD be created / changed / refused, and why.
--    3. Set dry_run = false and run it again.  The feeds are created within
--       about 10-60 seconds (QueryStudio picks the request up in the background).
--    4. Re-running later with a longer list adds only the new rows; existing
--       feeds come back "unchanged".  retire_missing = true switches off feeds
--       whose row left the list (kept in history, never deleted).
--
--  The shared query may use the entity values as tokens, e.g.
--      WHERE system_entity = '{SYSTEM_ENTITY}' AND event_code = '{EventCode}'
--  QueryStudio fills them per feed at run time (and refuses a value carrying a
--  quote, semicolon or comment marker).  {BUSINESSDATE} etc. come from the
--  feed's calendar.
--
--  Guide: docs/FEEDS_FROM_SQL_GUIDE_2026_10_14.html.  Proven on the Docker rig by
--  scripts/docker_proof/feeds_from_sql_script_proof.py.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. YOUR SETTINGS -- edit the values on the right
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS qs_feed_setup;
CREATE TEMP TABLE qs_feed_setup AS SELECT
    -- the template: one name for this family of feeds (re-use it to update them)
    'FACT_TETB_MONTH_END'::text                                  AS template_name,
    true                                                         AS dry_run,         -- true = preview only
    false                                                        AS retire_missing,  -- true = switch off feeds no longer listed

    -- the SHARED QUERY: the SQL file's name (Admin -> SQL files) and its connection
    'fact_tetb_join'::text                                       AS sql_file_name,
    NULL::text                                                   AS connection_name,        -- NULL = the SQL file's own connection
    -- optional second side (on-prem) running the same query, merged by column name
    NULL::text                                                   AS second_connection_name, -- NULL = one side only
    NULL::jsonb                                                  AS table_map,              -- e.g. '{"primary":{"icbg.fins.fact_tetb":"<cloud table>"},"secondary":{"icbg.fins":"hive.<schema>"}}'

    -- each feed's name and file name ({SYSTEM_ENTITY} / {EventCode} are filled per row)
    'FACT_TETB_{SYSTEM_ENTITY}_{EventCode}'::text                AS feed_name,
    'fact_tetb_{SYSTEM_ENTITY}_{EventCode}_{business_date:YYYYMMDD}.csv'::text AS file_name,
    'Month end, the shared fact_tetb query'::text                AS description,
    'csv'::text                                                  AS output_format,
    '|'::text                                                    AS delimiter,

    -- where the files go (SFTP).  The password is encrypted by QueryStudio.
    'sftp.example.com'::text                                     AS sftp_host,
    22                                                           AS sftp_port,
    '/inbox'::text                                               AS sftp_remote_dir,
    'feeduser'::text                                             AS sftp_username,
    'CHANGE_ME'::text                                            AS sftp_password,
    'AAAA...'::text                                              AS sftp_host_key_b64,       -- the server's public host key (base64)

    -- when (month_end | daily | ...) and the consumer SLA
    'month_end'::text                                            AS schedule_kind,
    NULL::text                                                   AS calendar_name,          -- NULL = the default calendar
    '18:00'::text                                                AS sla_to,
    'Europe/London'::text                                        AS sla_timezone,

    -- dependencies: what must arrive before a feed runs ([] = none).
    -- {SYSTEM_ENTITY} / {EventCode} are filled per row.
    '[]'::jsonb                                                  AS dependencies;
    -- example:
    -- '[{"dependency_type":"ORACLE_TABLE",
    --    "dependency_key":"finance_sl_balance_{SYSTEM_ENTITY}_{EventCode}_CLOUD",
    --    "arrival_sources":[{"kind":"kafka","topic":"qs.kafka.message"}],
    --    "require_mode":"any"}]'::jsonb


-- ---------------------------------------------------------------------------
-- 2. YOUR ENTITY LIST -- one feed per row
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS qs_feed_entities;
CREATE TEMP TABLE qs_feed_entities ("SYSTEM_ENTITY" text NOT NULL, "EventCode" text NOT NULL);
INSERT INTO qs_feed_entities VALUES
    ('SAP-2920-EMEA', 'EOD'),
    ('SAP-2920-EMEA', 'EOM');
-- or from a table you already have:
-- INSERT INTO qs_feed_entities SELECT code, event FROM my_entity_list;


-- ---------------------------------------------------------------------------
-- 3. CHECKS -- stops here, with the reason, when a name does not exist
-- ---------------------------------------------------------------------------
DO $$
DECLARE s qs_feed_setup%ROWTYPE; n int;
BEGIN
    SELECT * INTO s FROM qs_feed_setup;
    IF NOT EXISTS (SELECT 1 FROM sql_files WHERE name = s.sql_file_name AND is_active) THEN
        RAISE EXCEPTION 'SQL file "%" not found (Admin -> SQL files; the name must match exactly)', s.sql_file_name;
    END IF;
    IF s.connection_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM connections WHERE name = s.connection_name) THEN
        RAISE EXCEPTION 'connection "%" not found', s.connection_name;
    END IF;
    IF s.second_connection_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM connections WHERE name = s.second_connection_name) THEN
        RAISE EXCEPTION 'second connection "%" not found', s.second_connection_name;
    END IF;
    SELECT count(*) INTO n FROM qs_feed_entities;
    IF n = 0 AND NOT s.retire_missing THEN
        RAISE EXCEPTION 'the entity list is empty (section 2)';
    END IF;
    IF NOT s.dry_run AND s.sftp_password = 'CHANGE_ME' THEN
        RAISE EXCEPTION 'set sftp_password in section 1 before dry_run = false';
    END IF;
    RAISE NOTICE 'checks passed: % entity row(s), SQL file "%"', n, s.sql_file_name;
END $$;


-- ---------------------------------------------------------------------------
-- 4. APPLY (or preview) -- returns the request number
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS qs_feed_request;
CREATE TEMP TABLE qs_feed_request AS
SELECT qs_feed_template_apply(
    p_template        => s.template_name,
    p_parameters      => '["SYSTEM_ENTITY", "EventCode"]'::jsonb,
    p_feed            => jsonb_strip_nulls(jsonb_build_object(
        'name',                     s.feed_name,
        'description',              s.description,
        'source_type',              'sql_file',
        'source_id',                f.id,
        'connection_id',            COALESCE((SELECT c.id FROM connections c WHERE c.name = s.connection_name),
                                             f.connection_id),
        'secondary_connection_id',  (SELECT c.id FROM connections c WHERE c.name = s.second_connection_name),
        'combine_mode',             CASE WHEN s.second_connection_name IS NOT NULL THEN 'union' END,
        'query_params',             CASE WHEN s.table_map IS NOT NULL
                                         THEN jsonb_build_object('table_map', s.table_map) END,
        'output_format',            s.output_format,
        'output_options',           jsonb_build_object('delimiter', s.delimiter),
        'output_filename_template', s.file_name,
        'destination_type',         'sftp',
        'destination_config',       jsonb_build_object(
                                        'host', s.sftp_host, 'port', s.sftp_port,
                                        'remote_dir', s.sftp_remote_dir,
                                        'username', s.sftp_username, 'password', s.sftp_password,
                                        'host_key_b64', s.sftp_host_key_b64),
        'schedule_declaration',     jsonb_build_object('kind', s.schedule_kind),
        'calendar_name',            s.calendar_name,
        'sla_to',                   s.sla_to,
        'sla_timezone',             s.sla_timezone,
        'is_active',                true)),
    p_dependencies    => s.dependencies,
    p_matrix          => (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                 'SYSTEM_ENTITY', e."SYSTEM_ENTITY", 'EventCode', e."EventCode")), '[]'::jsonb)
                          FROM qs_feed_entities e),
    p_retire_missing  => s.retire_missing,
    p_dry_run         => s.dry_run,
    p_requested_by    => current_user) AS request_id
FROM qs_feed_setup s
JOIN sql_files f ON f.name = s.sql_file_name AND f.is_active;

SELECT request_id AS "request number" FROM qs_feed_request;


-- ---------------------------------------------------------------------------
-- 5. THE RESULT -- QueryStudio picks the request up within ~10 s.
--    Re-run these two SELECTs until state is done (or failed);
--    pending / running mean it is still being applied.
-- ---------------------------------------------------------------------------
SELECT pg_sleep(20);

SELECT s.request_id, s.state, s.dry_run, s.created, s.updated, s.unchanged,
       s.conflicts, s.refused, s.retired, s.error
  FROM qs_feed_template_apply_status s
  JOIN qs_feed_request r ON r.request_id = s.request_id;

-- why a row was refused (one line per refused feed)
SELECT r ->> 'name' AS feed, r ->> 'reason' AS reason
  FROM qs_feed_template_apply_status s
  JOIN qs_feed_request q ON q.request_id = s.request_id,
       json_array_elements(COALESCE(s.report::json -> 'refused', '[]'::json)) r;

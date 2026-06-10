-- analytics_test.refresh_engagement_views_all
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   analytics.  → analytics_test.
--   REFRESH MATERIALIZED VIEW CONCURRENTLY → REFRESH MATERIALIZED VIEW (not supported in CRDB)

CREATE OR REPLACE PROCEDURE analytics_test.refresh_engagement_views_all()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle TEXT;
BEGIN
    FOR handle IN
        SELECT LOWER(REPLACE(project_name, ' ', '_'))
        FROM mindshare_test.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        RAISE NOTICE 'Refreshing view for: %', handle;
        EXECUTE format('REFRESH MATERIALIZED VIEW analytics_test.%I', 'mv_engagement_' || handle);
    END LOOP;
END;
$procedure$;

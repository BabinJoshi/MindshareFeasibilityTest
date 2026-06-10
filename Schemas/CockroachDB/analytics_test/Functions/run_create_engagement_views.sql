-- analytics_test.run_create_engagement_views
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   analytics.  → analytics_test.

CREATE OR REPLACE PROCEDURE analytics_test.run_create_engagement_views()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle text;
BEGIN
    FOR handle IN
        SELECT project_name
        FROM mindshare_test.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        CALL analytics_test.create_engagement_view(handle);
        RAISE NOTICE 'Processed view for: %', handle;
    END LOOP;
END;
$procedure$;

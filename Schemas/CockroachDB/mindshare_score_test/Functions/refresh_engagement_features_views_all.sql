-- mindshare_score_test.refresh_engagement_features_views_all
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.
--   REFRESH MATERIALIZED VIEW CONCURRENTLY → REFRESH MATERIALIZED VIEW (CONCURRENTLY not supported in CRDB)
--   SET LOCAL statement_timeout removed (SET LOCAL not supported in procedures in CRDB)
--   pg_matviews → pg_catalog.pg_matviews (schemaname filter updated to mindshare_score_test)

CREATE OR REPLACE PROCEDURE mindshare_score_test.refresh_engagement_features_views_all()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle TEXT;
    base_view_name TEXT;
    features_view_name TEXT;
    features_exists BOOLEAN;
    start_time TIMESTAMP;
    end_time TIMESTAMP;
BEGIN
    FOR handle IN
        SELECT DISTINCT LOWER(REPLACE(project_name, ' ', '_'))
        FROM mindshare_test.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        base_view_name := 'mv_engagement_' || handle;
        features_view_name := 'mv_engagement_features_' || handle;

        SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_matviews
            WHERE schemaname = 'mindshare_score_test' AND matviewname = features_view_name
        ) INTO features_exists;

        BEGIN
            start_time := clock_timestamp();

            IF features_exists THEN
                RAISE NOTICE 'Refreshing features view: %', features_view_name;
                EXECUTE format('REFRESH MATERIALIZED VIEW mindshare_score_test.%I', features_view_name);
            ELSE
                RAISE NOTICE 'Provisioning missing features view for: %', handle;
                CALL mindshare_score_test.create_engagement_clustering_features_view(handle);
            END IF;

            end_time := clock_timestamp();
            RAISE NOTICE 'Finished processing % in %', features_view_name, (end_time - start_time);

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed refreshing/provisioning features view %: %', features_view_name, SQLERRM;
        END;

        COMMIT;
    END LOOP;
END;
$procedure$;

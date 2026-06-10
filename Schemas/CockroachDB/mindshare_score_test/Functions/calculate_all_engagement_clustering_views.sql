-- mindshare_score_test.create_all_engagement_clustering_views
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.

CREATE OR REPLACE PROCEDURE mindshare_score_test.create_all_engagement_clustering_views()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    keyword_record RECORD;
BEGIN
    FOR keyword_record IN
        SELECT MIN(project_keyword) AS project_keyword
        FROM mindshare_test.mindshare_post
        WHERE project_keyword IS NOT NULL AND project_keyword != ''
        GROUP BY LOWER(REPLACE(project_keyword, ' ', '_'))
    LOOP
        BEGIN
            CALL mindshare_score_test.create_engagement_clustering_features_view(keyword_record.project_keyword);
            RAISE NOTICE 'Features view created for: %', keyword_record.project_keyword;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed to create features view for %: %', keyword_record.project_keyword, SQLERRM;
        END;
    END LOOP;
END;
$procedure$;

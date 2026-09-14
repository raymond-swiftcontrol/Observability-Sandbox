DROP TABLE IF EXISTS research.dataset, research.label_definition,
  research.feature_build, research.feature_partition CASCADE;
DROP FUNCTION IF EXISTS research.features_as_of(uuid, timestamptz, text[]);
DROP TABLE IF EXISTS research.feature_value CASCADE;
DROP TABLE IF EXISTS research.feature_set, research.feature_dependency,
  research.feature_definition CASCADE;
DROP TYPE IF EXISTS research.feature_category;

-- GICS-shaped sector taxonomy, level 1 only. Deeper levels are loaded from a
-- vendor file when one is configured; the level-1 set is enough for the factor
-- models and the mobile sector filter to work out of the box.
INSERT INTO reference.sector (gics_code, level, name, parent_id) VALUES
  ('10', 1, 'Energy',                 NULL),
  ('15', 1, 'Materials',              NULL),
  ('20', 1, 'Industrials',            NULL),
  ('25', 1, 'Consumer Discretionary', NULL),
  ('30', 1, 'Consumer Staples',       NULL),
  ('35', 1, 'Health Care',            NULL),
  ('40', 1, 'Financials',             NULL),
  ('45', 1, 'Information Technology', NULL),
  ('50', 1, 'Communication Services', NULL),
  ('55', 1, 'Utilities',              NULL),
  ('60', 1, 'Real Estate',            NULL)
ON CONFLICT (gics_code) DO NOTHING;

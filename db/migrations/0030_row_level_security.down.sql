DO $$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relrowsecurity AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DISABLE ROW LEVEL SECURITY',
                   t.schema_name, t.table_name);
  END LOOP;
END $$;
DROP FUNCTION IF EXISTS platform.owns_portfolio(uuid);
DROP FUNCTION IF EXISTS platform.owns_account(uuid);

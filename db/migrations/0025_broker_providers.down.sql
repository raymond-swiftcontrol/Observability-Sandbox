DROP FUNCTION IF EXISTS broker.can_route_orders(uuid);
DROP TABLE IF EXISTS broker.connection, broker.provider CASCADE;
DROP TYPE IF EXISTS broker.connection_state, broker.resource,
  broker.integration_kind, broker.auth_kind;

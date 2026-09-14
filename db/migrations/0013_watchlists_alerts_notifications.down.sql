DROP TABLE IF EXISTS notify.quiet_hours, notify.preference, notify.delivery,
  notify.notification, notify.alert_trigger, notify.alert_rule,
  notify.watchlist_item, notify.watchlist CASCADE;
DROP TYPE IF EXISTS notify.delivery_status, notify.urgency, notify.channel,
  notify.alert_kind;

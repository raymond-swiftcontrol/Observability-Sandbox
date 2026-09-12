DROP VIEW IF EXISTS identity.effective_permission;
DROP TABLE IF EXISTS identity.auth_event, identity.user_consent, identity.disclosure,
  identity.api_key, identity.user_role, identity.role_permission, identity.permission,
  identity.role, identity.device, identity.session, identity.mfa_factor,
  identity.credential, identity.user CASCADE;
DROP FUNCTION IF EXISTS identity.revoke_session_family(uuid, text);
DROP TYPE IF EXISTS identity.platform, identity.mfa_method, identity.kyc_status,
  identity.user_status;

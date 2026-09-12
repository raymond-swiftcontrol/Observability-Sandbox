-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0002 · Identity, authentication, authorisation, devices                  ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Password hashes never leave identity.credential. Sessions are opaque
-- refresh-token families so that token theft is detectable by reuse.

CREATE TYPE identity.user_status AS ENUM (
  'pending_verification', 'active', 'suspended', 'closed', 'locked'
);

CREATE TYPE identity.kyc_status AS ENUM (
  'not_started', 'submitted', 'in_review', 'approved', 'rejected', 'expired'
);

CREATE TYPE identity.mfa_method AS ENUM ('totp', 'webauthn', 'sms', 'recovery_code');

CREATE TYPE identity.platform AS ENUM ('ios', 'android', 'web', 'cli');

-- ── Users ────────────────────────────────────────────────────────────────────
CREATE TABLE identity.user (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id         text UNIQUE NOT NULL DEFAULT platform.public_id('usr'),
  email             reference.email NOT NULL,
  email_verified_at timestamptz,
  phone_e164        varchar(20),
  display_name      varchar(80) NOT NULL,
  avatar_url        text,
  status            identity.user_status NOT NULL DEFAULT 'pending_verification',
  kyc_status        identity.kyc_status  NOT NULL DEFAULT 'not_started',
  kyc_reviewed_at   timestamptz,
  -- Regulatory profile. Drives which instruments and leverage the user can see.
  country_code      char(2) NOT NULL DEFAULT 'US',
  tax_residency     char(2),
  is_professional   boolean NOT NULL DEFAULT false,
  is_pattern_day_trader boolean NOT NULL DEFAULT false,
  base_currency     reference.currency_code NOT NULL DEFAULT 'USD',
  experience_years  smallint CHECK (experience_years BETWEEN 0 AND 80),
  risk_tolerance    smallint NOT NULL DEFAULT 3 CHECK (risk_tolerance BETWEEN 1 AND 5),
  locale            varchar(12) NOT NULL DEFAULT 'en-US',
  timezone          text NOT NULL DEFAULT 'UTC',
  -- Soft delete: we must retain trading records for 7y, so users are closed,
  -- never hard-deleted. PII is scrubbed by a separate redaction job.
  closed_at         timestamptz,
  last_seen_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_email_unique_when_open
    EXCLUDE (email WITH =) WHERE (closed_at IS NULL),
  CONSTRAINT user_closed_implies_status
    CHECK (closed_at IS NULL OR status = 'closed')
);

CREATE INDEX user_status_idx   ON identity.user (status) WHERE closed_at IS NULL;
CREATE INDEX user_kyc_idx      ON identity.user (kyc_status) WHERE kyc_status <> 'approved';
CREATE INDEX user_last_seen_idx ON identity.user (last_seen_at DESC NULLS LAST);

COMMENT ON COLUMN identity.user.is_pattern_day_trader IS
  'FINRA PDT flag; gates intraday round-trips on margin accounts under $25k equity.';

-- ── Credentials ──────────────────────────────────────────────────────────────
-- One row per user. Argon2id parameters are stored alongside the hash so that
-- we can raise cost factors over time and rehash on next successful login.
CREATE TABLE identity.credential (
  user_id             uuid PRIMARY KEY REFERENCES identity.user(id) ON DELETE CASCADE,
  password_hash       text NOT NULL,
  algorithm           varchar(24) NOT NULL DEFAULT 'argon2id',
  memory_cost_kib     integer NOT NULL DEFAULT 19456,
  time_cost           smallint NOT NULL DEFAULT 2,
  parallelism         smallint NOT NULL DEFAULT 1,
  must_rotate         boolean NOT NULL DEFAULT false,
  password_changed_at timestamptz NOT NULL DEFAULT now(),
  failed_attempts     smallint NOT NULL DEFAULT 0,
  locked_until        timestamptz,
  -- Last 5 hashes, newest first; blocks immediate reuse without storing plaintext.
  previous_hashes     text[] NOT NULL DEFAULT '{}',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT credential_history_bounded CHECK (cardinality(previous_hashes) <= 5)
);

-- ── Multi-factor ─────────────────────────────────────────────────────────────
CREATE TABLE identity.mfa_factor (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  method          identity.mfa_method NOT NULL,
  label           varchar(64),
  -- TOTP secrets and WebAuthn public keys are encrypted application-side with
  -- a KMS data key; the ciphertext and key reference are stored, never plaintext.
  secret_ciphertext bytea,
  kms_key_id      text,
  credential_id   bytea,            -- WebAuthn
  sign_count      bigint DEFAULT 0, -- WebAuthn replay detection
  confirmed_at    timestamptz,
  last_used_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mfa_one_confirmed_totp_per_user
    EXCLUDE (user_id WITH =) WHERE (method = 'totp' AND confirmed_at IS NOT NULL),
  CONSTRAINT mfa_webauthn_needs_credential
    CHECK (method <> 'webauthn' OR credential_id IS NOT NULL)
);

CREATE UNIQUE INDEX mfa_webauthn_credential_idx
  ON identity.mfa_factor (credential_id) WHERE credential_id IS NOT NULL;

-- ── Sessions / refresh token families ────────────────────────────────────────
-- A family is created at login. Each refresh rotates the token within the
-- family; presenting a rotated (already-used) token revokes the whole family,
-- which is how we detect replay after theft.
CREATE TABLE identity.session (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  device_id         uuid,
  refresh_token_hash bytea NOT NULL,        -- sha256 of the opaque token
  parent_session_id uuid REFERENCES identity.session(id) ON DELETE SET NULL,
  platform          identity.platform NOT NULL,
  app_version       varchar(24),
  os_version        varchar(40),
  ip_address        inet,
  user_agent        text,
  geo_country       char(2),
  mfa_satisfied_at  timestamptz,
  issued_at         timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL,
  rotated_at        timestamptz,
  revoked_at        timestamptz,
  revoked_reason    varchar(48),
  CONSTRAINT session_expiry_after_issue CHECK (expires_at > issued_at)
);

CREATE UNIQUE INDEX session_refresh_hash_idx ON identity.session (refresh_token_hash);
CREATE INDEX session_user_active_idx ON identity.session (user_id, expires_at DESC)
  WHERE revoked_at IS NULL AND rotated_at IS NULL;
CREATE INDEX session_family_idx ON identity.session (family_id);
-- Supports the reaper that prunes expired sessions nightly.
CREATE INDEX session_expired_idx ON identity.session (expires_at)
  WHERE revoked_at IS NULL;

-- Revoking a whole family is a single statement; called on reuse detection.
CREATE OR REPLACE FUNCTION identity.revoke_session_family(p_family_id uuid, p_reason text)
  RETURNS integer LANGUAGE plpgsql AS $$
DECLARE revoked integer;
BEGIN
  UPDATE identity.session
     SET revoked_at = now(), revoked_reason = p_reason
   WHERE family_id = p_family_id AND revoked_at IS NULL;
  GET DIAGNOSTICS revoked = ROW_COUNT;
  RETURN revoked;
END $$;

-- ── Devices (push targets, biometric binding, trust) ─────────────────────────
CREATE TABLE identity.device (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  install_id        text NOT NULL,          -- stable per app install
  platform          identity.platform NOT NULL,
  model             varchar(64),
  os_version        varchar(40),
  app_version       varchar(24),
  push_token        text,
  push_provider     varchar(16),            -- expo | apns | fcm
  push_token_invalid_at timestamptz,
  biometric_enrolled boolean NOT NULL DEFAULT false,
  -- Trusted devices can skip step-up MFA for low-risk reads for 30 days.
  trusted_until     timestamptz,
  last_seen_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, install_id)
);

CREATE INDEX device_push_token_idx ON identity.device (push_token)
  WHERE push_token IS NOT NULL AND push_token_invalid_at IS NULL;

ALTER TABLE identity.session
  ADD CONSTRAINT session_device_fk
  FOREIGN KEY (device_id) REFERENCES identity.device(id) ON DELETE SET NULL;

-- ── RBAC ─────────────────────────────────────────────────────────────────────
-- Small, explicit permission set. Checked in the gateway, mirrored by RLS for
-- defence in depth.
CREATE TABLE identity.role (
  id          smallserial PRIMARY KEY,
  key         varchar(40) UNIQUE NOT NULL,
  name        varchar(80) NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT false
);

CREATE TABLE identity.permission (
  id          smallserial PRIMARY KEY,
  key         varchar(64) UNIQUE NOT NULL,   -- e.g. 'order:submit'
  resource    varchar(32) NOT NULL,
  action      varchar(32) NOT NULL,
  description text,
  -- Permissions flagged sensitive require a fresh MFA assertion (step-up).
  requires_step_up boolean NOT NULL DEFAULT false,
  UNIQUE (resource, action)
);

CREATE TABLE identity.role_permission (
  role_id       smallint NOT NULL REFERENCES identity.role(id) ON DELETE CASCADE,
  permission_id smallint NOT NULL REFERENCES identity.permission(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE identity.user_role (
  user_id    uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  role_id    smallint NOT NULL REFERENCES identity.role(id) ON DELETE CASCADE,
  granted_by uuid REFERENCES identity.user(id),
  granted_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  PRIMARY KEY (user_id, role_id)
);

CREATE INDEX user_role_expiring_idx ON identity.user_role (expires_at)
  WHERE expires_at IS NOT NULL;

-- Flattened effective permissions; the gateway caches this per user in Redis.
CREATE OR REPLACE VIEW identity.effective_permission AS
SELECT ur.user_id,
       p.key              AS permission_key,
       p.requires_step_up,
       bool_or(r.is_system) AS via_system_role
  FROM identity.user_role ur
  JOIN identity.role r            ON r.id = ur.role_id
  JOIN identity.role_permission rp ON rp.role_id = r.id
  JOIN identity.permission p       ON p.id = rp.permission_id
 WHERE ur.expires_at IS NULL OR ur.expires_at > now()
 GROUP BY ur.user_id, p.key, p.requires_step_up;

-- ── API keys (programmatic access for the CLI and user-built bots) ───────────
CREATE TABLE identity.api_key (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  name          varchar(64) NOT NULL,
  key_prefix    char(8) NOT NULL,        -- shown in the UI for identification
  key_hash      bytea NOT NULL,
  scopes        text[] NOT NULL DEFAULT '{}',
  -- Keys may be pinned to source CIDRs; empty means unrestricted.
  allowed_cidrs inet[] NOT NULL DEFAULT '{}',
  rate_limit_rpm integer NOT NULL DEFAULT 120,
  last_used_at  timestamptz,
  last_used_ip  inet,
  expires_at    timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);

CREATE UNIQUE INDEX api_key_hash_idx ON identity.api_key (key_hash);
CREATE INDEX api_key_prefix_idx ON identity.api_key (key_prefix);

-- ── Consent & disclosures (regulatory paper trail) ───────────────────────────
CREATE TABLE identity.disclosure (
  id            smallserial PRIMARY KEY,
  key           varchar(64) UNIQUE NOT NULL,
  version       varchar(16) NOT NULL,
  title         text NOT NULL,
  body_url      text NOT NULL,
  required_for  text[] NOT NULL DEFAULT '{}',  -- e.g. {'live_trading','options'}
  effective_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (key, version)
);

CREATE TABLE identity.user_consent (
  user_id       uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  disclosure_id smallint NOT NULL REFERENCES identity.disclosure(id),
  accepted_at   timestamptz NOT NULL DEFAULT now(),
  ip_address    inet,
  user_agent    text,
  PRIMARY KEY (user_id, disclosure_id)
);

-- ── Login audit (separate from audit.event: high volume, security-owned) ─────
CREATE TABLE identity.auth_event (
  id          bigserial PRIMARY KEY,
  user_id     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  email_attempted reference.email,   -- set when the user lookup failed
  event        varchar(40) NOT NULL,  -- login_success, login_failed, mfa_failed…
  succeeded    boolean NOT NULL,
  failure_code varchar(40),
  ip_address   inet,
  user_agent   text,
  geo_country  char(2),
  risk_score   smallint CHECK (risk_score BETWEEN 0 AND 100),
  session_id   uuid,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX auth_event_user_time_idx ON identity.auth_event (user_id, occurred_at DESC);
CREATE INDEX auth_event_ip_time_idx   ON identity.auth_event (ip_address, occurred_at DESC)
  WHERE succeeded = false;
-- Brute-force detection window: count failures per email in the last 15 minutes.
CREATE INDEX auth_event_failed_email_idx ON identity.auth_event (email_attempted, occurred_at DESC)
  WHERE succeeded = false;

SELECT platform.attach_touch_triggers('identity');

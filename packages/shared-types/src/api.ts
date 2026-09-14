/**
 * Transport envelopes shared by the gateway, the SDK and every service.
 *
 * Pagination is cursor-based rather than offset-based throughout. Every listed
 * resource here is append-mostly and time-ordered, and an offset page over a
 * table that is being written to skips and repeats rows — which on an order
 * blotter looks exactly like a lost order.
 */
import { z } from 'zod';
import { AccountId, PortfolioId, Timestamp, UserId } from './primitives.js';

/**
 * Opaque to the client by construction: it is base64url over a server-side
 * keyset position, and a client that parses it will break when the sort changes.
 */
export const Cursor = z
  .string()
  .min(1)
  .max(512)
  .regex(/^[A-Za-z0-9_-]+$/, 'a cursor is opaque base64url')
  .brand<'Cursor'>();
export type Cursor = z.infer<typeof Cursor>;

export const PageRequest = z.object({
  cursor: Cursor.nullable().default(null),
  /** Capped server-side; the cap is stated here so the client does not guess. */
  limit: z.number().int().min(1).max(200).default(50),
});
export type PageRequest = z.infer<typeof PageRequest>;

export interface Page<T> {
  readonly items: readonly T[];
  readonly next_cursor: string | null;
  /** Null when the backend cannot count cheaply — most hot paths cannot. */
  readonly total: number | null;
}

/** Builds the paginated response schema for any item schema. */
export function pageOf<T extends z.ZodTypeAny>(item: T) {
  return z.object({
    items: z.array(item),
    next_cursor: Cursor.nullable().default(null),
    total: z.number().int().nonnegative().nullable().default(null),
  });
}

/**
 * Error codes are a closed set with a fixed HTTP mapping. A client switching on
 * a code must not have to parse a message, and a message must never be the only
 * place a condition is expressed.
 */
export const ERROR_CODES = [
  'bad_request',
  'validation_failed',
  'unauthenticated',
  'token_expired',
  'forbidden',
  'not_found',
  'conflict',
  'idempotency_conflict',
  'precondition_failed',
  'rate_limited',
  'payload_too_large',
  'unprocessable',
  'market_closed',
  'insufficient_buying_power',
  'risk_rejected',
  'kill_switch_engaged',
  'broker_unavailable',
  'broker_rate_limited',
  'connection_reauth_required',
  'read_only_connection',
  'data_unavailable',
  'internal_error',
  'service_unavailable',
  'timeout',
] as const;
export const ErrorCode = z.enum(ERROR_CODES);
export type ErrorCode = z.infer<typeof ErrorCode>;

/**
 * The mapping is a total record rather than a lookup with a fallback, so adding
 * a code without deciding its status is a compile error.
 *
 * Two choices worth stating: a blocked or blocking relationship answers
 * `not_found` (404) rather than `forbidden`, because the social-graph spec
 * requires that a block is not disclosed to the blocked user; and
 * `read_only_connection` is 409 rather than 403 because it describes the state
 * of the connection, not the caller's rights.
 */
export const ERROR_STATUS: Readonly<Record<ErrorCode, number>> = {
  bad_request: 400,
  validation_failed: 422,
  unauthenticated: 401,
  token_expired: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  idempotency_conflict: 409,
  precondition_failed: 412,
  rate_limited: 429,
  payload_too_large: 413,
  unprocessable: 422,
  market_closed: 409,
  insufficient_buying_power: 422,
  risk_rejected: 422,
  kill_switch_engaged: 423,
  broker_unavailable: 502,
  broker_rate_limited: 429,
  connection_reauth_required: 409,
  read_only_connection: 409,
  data_unavailable: 404,
  internal_error: 500,
  service_unavailable: 503,
  timeout: 504,
};

export function httpStatusFor(code: ErrorCode): number {
  return ERROR_STATUS[code];
}

/** 401 is the only family the SDK may answer by refreshing and retrying. */
export function isRetriableAfterRefresh(code: ErrorCode): boolean {
  return code === 'token_expired' || code === 'unauthenticated';
}

export function isTransient(code: ErrorCode): boolean {
  return (
    code === 'service_unavailable' ||
    code === 'timeout' ||
    code === 'broker_unavailable' ||
    code === 'rate_limited' ||
    code === 'broker_rate_limited'
  );
}

export const FieldError = z.object({
  /** Dotted path into the request body, matching Zod's issue path. */
  path: z.string(),
  message: z.string(),
});
export type FieldError = z.infer<typeof FieldError>;

export const ApiError = z.object({
  code: ErrorCode,
  message: z.string().min(1),
  /** Populated for validation_failed; empty otherwise. */
  fields: z.array(FieldError).default([]),
  /** Echoed so a user-reported failure can be found in Tempo directly. */
  request_id: z.string().min(1),
  trace_id: z.string().regex(/^[0-9a-f]{32}$/).nullable().default(null),
  /** Seconds; set on rate_limited and broker_rate_limited. */
  retry_after: z.number().int().nonnegative().nullable().default(null),
});
export type ApiError = z.infer<typeof ApiError>;

export const ErrorEnvelope = z.object({ error: ApiError });
export type ErrorEnvelope = z.infer<typeof ErrorEnvelope>;

/** Success responses carry the payload at `data`, never at the root. */
export function envelopeOf<T extends z.ZodTypeAny>(data: T) {
  return z.object({ data, meta: z.record(z.unknown()).optional() });
}

/**
 * Ambient context carried on every request. `account_id` is nullable because
 * auth and profile endpoints have no account, and making it required would
 * invite a placeholder value that later selects the wrong book.
 */
export const RequestContext = z.object({
  user_id: UserId.nullable().default(null),
  account_id: AccountId.nullable().default(null),
  portfolio_id: PortfolioId.nullable().default(null),
  request_id: z.string().min(1).max(64),
  trace_id: z.string().regex(/^[0-9a-f]{32}$/).nullable().default(null),
  span_id: z.string().regex(/^[0-9a-f]{16}$/).nullable().default(null),
  /** Present on mutating requests; the server stores it for replay protection. */
  idempotency_key: z.string().min(8).max(128).nullable().default(null),
  client_version: z.string().max(32).nullable().default(null),
  received_at: Timestamp.nullable().default(null),
});
export type RequestContext = z.infer<typeof RequestContext>;

/** Header names, in one place, because three services otherwise spell them three ways. */
export const HEADERS = {
  requestId: 'x-request-id',
  idempotencyKey: 'idempotency-key',
  clientVersion: 'x-helios-client',
  accountId: 'x-helios-account',
  traceparent: 'traceparent',
} as const;

/** Turns a Zod failure into the wire shape without losing the path. */
export function toFieldErrors(error: z.ZodError): FieldError[] {
  return error.issues.map((issue) => ({
    path: issue.path.join('.'),
    message: issue.message,
  }));
}

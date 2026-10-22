// Sends one notification to every device of the person it is for: iPhones
// through APNs, Android phones through Firebase Cloud Messaging. index.ts is
// the HTTP shell around it; the decisions are here, so the tests can make them
// without Apple or Google.
//
// APNs: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
// FCM:  https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;
export type Platform = "ios" | "android";

/** What the database posts: the notification row, already rendered. */
export interface PushRow {
  id: string;
  profile_id: string;
  kind: string;
  title: string;
  body: string;
  thread_id: string | null;
  recommendation_id: string | null;
  invoice_id: string | null;
  /** The recipient's unread count, this notification included. */
  badge?: number | null;
}

export interface DeviceResult {
  token: string;            // the first characters only, for the log
  platform: Platform;
  /** The HTTP status; 0 when the request never got an answer. */
  status: number;
  reason?: string;
  environment?: ApnsEnvironment;
  forgotten: boolean;
}

export function parsePushRow(input: unknown): PushRow | null {
  const row = (input as { record?: PushRow } | null)?.record;
  return row && typeof row.profile_id === "string" && typeof row.id === "string" ? row : null;
}

// ================================================================== APNs

export interface ApnsConfig {
  /** The ES256 provider token, minted from the .p8 key. */
  jwt: string;
  /** The app's bundle id. */
  topic: string;
  environment: ApnsEnvironment;
}

/** The APNs-only entry point: the recipient's iOS tokens, and the key. */
export interface PushDeps extends ApnsConfig {
  /** The recipient's iOS device tokens. */
  tokens(profileId: string): Promise<string[]>;
  /** Drops a token Apple says no longer reaches anyone. */
  forget(token: string): Promise<void>;
  fetch?: typeof fetch;
}

export function apnsPayload(row: PushRow): string {
  return JSON.stringify({
    aps: {
      alert: { title: row.title, body: row.body },
      sound: "default",
      // the icon says what the bell will say once the app is open
      ...(typeof row.badge === "number" ? { badge: row.badge } : {}),
      // one conversation, or one kind of news, stacks together on the lock screen
      "thread-id": row.thread_id ?? row.kind,
    },
    // so a tap can open the thing the notification is about (PushCenter.swift)
    kind: row.kind,
    thread_id: row.thread_id,
    recommendation_id: row.recommendation_id,
    invoice_id: row.invoice_id,
  });
}

const other = (env: ApnsEnvironment): ApnsEnvironment => env === "production" ? "sandbox" : "production";

async function sendApns(
  row: PushRow,
  tokens: string[],
  config: ApnsConfig,
  forget: (token: string) => Promise<void>,
  fetcher: typeof fetch,
): Promise<DeviceResult[]> {
  const payload = apnsPayload(row);

  const post = async (token: string, environment: ApnsEnvironment) => {
    const response = await fetcher(`${APNS_HOSTS[environment]}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${config.jwt}`,
        "apns-topic": config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        // APNs deduplicates on this, so a retry cannot notify twice
        "apns-collapse-id": row.id.slice(0, 64),
      },
      body: payload,
    });
    const reason = response.ok
      ? undefined
      : ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
    return { status: response.status, reason };
  };

  return await Promise.all(tokens.map(async (token): Promise<DeviceResult> => {
    let environment = config.environment;
    try {
      let outcome = await post(token, environment);

      // One .p8 key serves both of Apple's environments, but each token belongs
      // to one: an Xcode build's is a sandbox token, a TestFlight or App Store
      // build's a production one. Asked the wrong one, Apple answers
      // BadDeviceToken -- so the other is tried before the token is judged.
      if (outcome.status === 400 && outcome.reason === "BadDeviceToken") {
        environment = other(environment);
        outcome = await post(token, environment);
      }

      // Only what Apple says about the token itself loses it: 410, the app is
      // gone from that phone; BadDeviceToken in both environments, it was never
      // valid. Any other 400 (a wrong topic, a malformed request) is ours to
      // fix, and dropping tokens over it would empty the table on one typo.
      const gone = outcome.status === 410
        || (outcome.status === 400 && outcome.reason === "BadDeviceToken");
      if (gone) await forget(token);

      return { token: token.slice(0, 8), platform: "ios", status: outcome.status, reason: outcome.reason,
               environment, forgotten: gone };
    } catch (error) {
      // the network, not the token: kept, and reported
      return { token: token.slice(0, 8), platform: "ios", status: 0, reason: String(error),
               environment, forgotten: false };
    }
  }));
}

/** Every iOS device of the person, through APNs (the original entry point). */
export async function deliver(row: PushRow, deps: PushDeps): Promise<{ sent: number; results: DeviceResult[] }> {
  const tokens = await deps.tokens(row.profile_id);
  const results = await sendApns(row, tokens, deps, deps.forget, deps.fetch ?? fetch);
  return { sent: results.filter((r) => r.status === 200).length, results };
}

// =================================================================== FCM

export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
/** The channel the Android app creates (push/Push.kt). */
export const ANDROID_CHANNEL = "general";

/** The fields of a Google service-account key file that matter here. */
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

/** The key file as Firebase hands it over, or null if it is not one. */
export function parseServiceAccount(text: string | undefined | null): ServiceAccount | null {
  if (!text) return null;
  try {
    const sa = JSON.parse(text) as Partial<ServiceAccount>;
    if (typeof sa.project_id === "string" && sa.project_id
        && typeof sa.client_email === "string" && sa.client_email
        && typeof sa.private_key === "string" && sa.private_key.includes("PRIVATE KEY")) {
      return { project_id: sa.project_id, client_email: sa.client_email, private_key: sa.private_key,
               token_uri: typeof sa.token_uri === "string" && sa.token_uri ? sa.token_uri : undefined };
    }
  } catch { /* not JSON */ }
  return null;
}

/** The FCM v1 message: what the notification shade shows, and where a tap leads. */
export function fcmMessage(row: PushRow, token: string) {
  // FCM only carries strings in `data`, and a null would be refused
  const data: Record<string, string> = { kind: row.kind, notification_id: row.id };
  for (const key of ["thread_id", "recommendation_id", "invoice_id"] as const) {
    const value = row[key];
    if (value !== null && value !== undefined && value !== "") data[key] = String(value);
  }
  return {
    message: {
      token,
      notification: { title: row.title, body: row.body },
      android: {
        // a message or an invoice to sign is worth waking the phone for
        priority: "high",
        notification: {
          channel_id: ANDROID_CHANNEL,
          // a retried call replaces its own notification instead of adding one
          tag: `n-${row.id}`,
          ...(typeof row.badge === "number" ? { notification_count: row.badge } : {}),
        },
      },
      data,
    },
  };
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const base64urlText = (text: string) => base64url(new TextEncoder().encode(text));

/** The service account's RS256-signed assertion, to trade for an access token. */
export async function signServiceAccountJwt(sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const der = Uint8Array.from(
    atob(sa.private_key.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\\n|\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const header = base64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64urlText(JSON.stringify({
    iss: sa.client_email,
    scope: FCM_SCOPE,
    aud: sa.token_uri ?? GOOGLE_TOKEN_URL,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

export interface FcmAuth {
  /** A valid access token; `fresh` skips the cache (after FCM said 401). */
  token(fresh?: boolean): Promise<string>;
}

/** Google's access tokens last an hour; one is reused for 50 minutes. */
export const FCM_TOKEN_REUSE_MS = 50 * 60 * 1000;

export function fcmAuth(sa: ServiceAccount, opts: { fetch?: typeof fetch; now?: () => number } = {}): FcmAuth {
  const fetcher = opts.fetch ?? fetch;
  const now = opts.now ?? Date.now;
  let cached: { value: string; mintedAt: number } | null = null;
  // devices are sent to in parallel: they share one exchange, not one each
  let inFlight: Promise<string> | null = null;

  const mint = async (): Promise<string> => {
    const mintedAt = now();
    const assertion = await signServiceAccountJwt(sa, Math.floor(mintedAt / 1000));
    const response = await fetcher(sa.token_uri ?? GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
    });
    const body = await response.json().catch(() => ({})) as { access_token?: string; error?: string; error_description?: string };
    if (!response.ok || !body.access_token) {
      throw new Error(`google token exchange ${response.status}: ${body.error ?? ""} ${body.error_description ?? ""}`.trim());
    }
    cached = { value: body.access_token, mintedAt };
    return body.access_token;
  };

  return {
    token(fresh = false) {
      if (!fresh && cached && now() - cached.mintedAt < FCM_TOKEN_REUSE_MS) return Promise.resolve(cached.value);
      if (fresh) cached = null;
      inFlight ??= mint().finally(() => { inFlight = null; });
      return inFlight;
    },
  };
}

export interface FcmConfig {
  projectId: string;
  auth: FcmAuth;
}

interface FcmError {
  error?: {
    code?: number;
    status?: string;
    message?: string;
    details?: { "@type"?: string; errorCode?: string; fieldViolations?: { field?: string; description?: string }[] }[];
  };
}

/** Whether FCM's answer says the token itself is dead -- the only reason to drop it. */
export function fcmTokenGone(status: number, body: FcmError): boolean {
  const error = body.error ?? {};
  const details = error.details ?? [];
  const codes = details.map((d) => d.errorCode).filter(Boolean);
  // the app was uninstalled, or the token expired: FCM forgot it
  if (status === 404 && (codes.includes("UNREGISTERED") || error.status === "UNREGISTERED")) return true;
  // the token is not a token. Any other invalid argument (a payload of ours
  // FCM does not like) is ours to fix, and must not cost anyone their device.
  if (status === 400 && (error.status === "INVALID_ARGUMENT" || codes.includes("INVALID_ARGUMENT"))) {
    const aboutToken = details.some((d) => (d.fieldViolations ?? []).some((v) => v.field === "message.token"))
      || /registration token/i.test(error.message ?? "");
    return aboutToken;
  }
  return false;
}

function fcmReason(body: FcmError): string | undefined {
  const error = body.error;
  if (!error) return undefined;
  const code = error.details?.map((d) => d.errorCode).find(Boolean);
  return [code ?? error.status, error.message].filter(Boolean).join(": ") || undefined;
}

async function sendFcm(
  row: PushRow,
  tokens: string[],
  config: FcmConfig,
  forget: (token: string) => Promise<void>,
  fetcher: typeof fetch,
): Promise<DeviceResult[]> {
  const url = `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(config.projectId)}/messages:send`;

  const post = async (token: string, accessToken: string) => {
    const response = await fetcher(url, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify(fcmMessage(row, token)),
    });
    const body = response.ok ? {} : (await response.json().catch(() => ({}))) as FcmError;
    return { status: response.status, body };
  };

  let accessToken: string;
  try {
    accessToken = await config.auth.token();
  } catch (error) {
    // a key Google refuses is a configuration error: every token is kept
    return tokens.map((token) => ({ token: token.slice(0, 8), platform: "android" as const, status: 0,
                                    reason: `auth: ${String(error)}`, forgotten: false }));
  }

  return await Promise.all(tokens.map(async (token): Promise<DeviceResult> => {
    try {
      let outcome = await post(token, accessToken);
      // an access token revoked or expired early: one fresh one, one more try
      if (outcome.status === 401) {
        outcome = await post(token, await config.auth.token(true));
      }
      const gone = fcmTokenGone(outcome.status, outcome.body);
      if (gone) await forget(token);
      return { token: token.slice(0, 8), platform: "android", status: outcome.status,
               reason: fcmReason(outcome.body), forgotten: gone };
    } catch (error) {
      return { token: token.slice(0, 8), platform: "android", status: 0, reason: String(error), forgotten: false };
    }
  }));
}

// ============================================================ both of them

export interface Device {
  token: string;
  platform: string;
}

export interface DispatchDeps {
  /** Every device the recipient registered, on any platform. */
  devices(profileId: string): Promise<Device[]>;
  /** Drops a token Apple or Google says no longer reaches anyone. */
  forget(token: string): Promise<void>;
  /** null: no APNs key, iPhones are skipped. */
  apns: ApnsConfig | null;
  /** null: no service account, Android phones are skipped. */
  fcm: FcmConfig | null;
  fetch?: typeof fetch;
}

export interface Skipped {
  platform: string;
  count: number;
  reason: string;
}

export interface Outcome {
  sent: number;
  results: DeviceResult[];
  /** Devices nothing was sent to, and why: a missing key is said, not hidden. */
  skipped: Skipped[];
}

/** One notification row, to all of the person's devices, on both platforms. */
export async function dispatch(row: PushRow, deps: DispatchDeps): Promise<Outcome> {
  const devices = await deps.devices(row.profile_id);
  const fetcher = deps.fetch ?? fetch;
  const ios = devices.filter((d) => d.platform === "ios").map((d) => d.token);
  const android = devices.filter((d) => d.platform === "android").map((d) => d.token);
  const unknown = devices.filter((d) => d.platform !== "ios" && d.platform !== "android");

  const skipped: Skipped[] = [];
  if (ios.length && !deps.apns) {
    skipped.push({ platform: "ios", count: ios.length,
                   reason: "APNs is not configured (APNS_PRIVATE_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC)" });
  }
  if (android.length && !deps.fcm) {
    skipped.push({ platform: "android", count: android.length, reason: "FCM is not configured (FCM_SERVICE_ACCOUNT)" });
  }
  for (const platform of new Set(unknown.map((d) => d.platform))) {
    skipped.push({ platform, count: unknown.filter((d) => d.platform === platform).length,
                   reason: "no sender for this platform" });
  }

  const [iosResults, androidResults] = await Promise.all([
    ios.length && deps.apns ? sendApns(row, ios, deps.apns, deps.forget, fetcher) : Promise.resolve([]),
    android.length && deps.fcm ? sendFcm(row, android, deps.fcm, deps.forget, fetcher) : Promise.resolve([]),
  ]);
  const results = [...iosResults, ...androidResults];
  return { sent: results.filter((r) => r.status === 200).length, results, skipped };
}

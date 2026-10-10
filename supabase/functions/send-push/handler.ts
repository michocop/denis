// Sends one notification to every iOS device of the person it is for, through
// APNs. index.ts is the HTTP shell around it; the decisions are here, so the
// tests can make them without Apple.
//
// APNs: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;

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

export interface PushDeps {
  /** The recipient's iOS device tokens. */
  tokens(profileId: string): Promise<string[]>;
  /** Drops a token Apple says no longer reaches anyone. */
  forget(token: string): Promise<void>;
  /** The ES256 provider token, minted from the .p8 key. */
  jwt: string;
  /** The app's bundle id. */
  topic: string;
  environment: ApnsEnvironment;
  fetch?: typeof fetch;
}

export interface DeviceResult {
  token: string;            // the first characters only, for the log
  status: number;
  reason?: string;
  environment: ApnsEnvironment;
  forgotten: boolean;
}

export function parsePushRow(input: unknown): PushRow | null {
  const row = (input as { record?: PushRow } | null)?.record;
  return row && typeof row.profile_id === "string" && typeof row.id === "string" ? row : null;
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

export async function deliver(row: PushRow, deps: PushDeps): Promise<{ sent: number; results: DeviceResult[] }> {
  const tokens = await deps.tokens(row.profile_id);
  const payload = apnsPayload(row);
  const fetcher = deps.fetch ?? fetch;

  const post = async (token: string, environment: ApnsEnvironment) => {
    const response = await fetcher(`${APNS_HOSTS[environment]}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${deps.jwt}`,
        "apns-topic": deps.topic,
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

  const results = await Promise.all(tokens.map(async (token): Promise<DeviceResult> => {
    let environment = deps.environment;
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
    if (gone) await deps.forget(token);

    return { token: token.slice(0, 8), status: outcome.status, reason: outcome.reason,
             environment, forgotten: gone };
  }));

  return { sent: results.filter((r) => r.status === 200).length, results };
}

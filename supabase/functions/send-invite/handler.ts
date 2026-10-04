// Invites someone by email. The invitation row is created with the caller's
// own rights (create_invite refuses anyone but an admin), and only then does
// the service role ask Supabase Auth to send the invitation email -- so this
// function can never be used to send mail on behalf of a non-admin.

export interface Invite {
  code: string;
  email: string;
  role: string;
}

export interface Deps {
  /** create_invite, as the calling user. Throws with Postgres's message. */
  createInvite(email: string, role: string, autoActivate: boolean): Promise<Invite>;
  /** auth.admin.inviteUserByEmail, as the service role. */
  sendInvitation(email: string, redirectTo: string): Promise<void>;
}

export const REDIRECT = "trinityenergie://auth-callback";

export type Result =
  | { status: 200; body: { email: string; code: string } }
  | { status: 400 | 403 | 409 | 502; body: { error: string } };

export async function invite(
  input: { email?: unknown; role?: unknown; auto_activate?: unknown },
  deps: Deps,
): Promise<Result> {
  const email = typeof input.email === "string" ? input.email.trim().toLowerCase() : "";
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { status: 400, body: { error: "Adresse e-mail invalide." } };
  }
  const role = input.role === "admin" || input.role === "manager" ? input.role : "apporteur";
  const autoActivate = input.auto_activate !== false;

  let created: Invite;
  try {
    created = await deps.createInvite(email, role, autoActivate);
  } catch (error) {
    const message = String((error as { message?: string }).message ?? error);
    if (/only an admin/i.test(message)) return { status: 403, body: { error: "Réservé aux administrateurs." } };
    if (/already has an account/i.test(message)) {
      return { status: 409, body: { error: "Un compte existe déjà pour cette adresse." } };
    }
    return { status: 400, body: { error: message } };
  }

  try {
    await deps.sendInvitation(email, REDIRECT);
  } catch (error) {
    // The invitation exists; the code can still be read out to the person.
    console.error(`invitation email to ${email} not sent`, error);
    return { status: 502, body: { error: `L'invitation est créée (code ${created.code}) mais l'e-mail n'a pas pu partir.` } };
  }
  return { status: 200, body: { email, code: created.code } };
}

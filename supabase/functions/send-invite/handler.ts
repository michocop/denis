// Invites someone by email. The invitation row is created with the caller's
// own rights (create_invite refuses anyone but an admin), and only then does
// the service role open the account and send the invitation -- so this
// function can never be used to send mail on behalf of a non-admin.
//
// The account is opened with its address already confirmed. Signing in is by
// a code sent to that address, which proves it every time; and Auth will not
// send a sign-in code to an unconfirmed address while sign-up is closed, so
// an account left unconfirmed could never sign in at all.

export interface Invite {
  code: string;
  email: string;
  role: string;
}

export interface Deps {
  /** create_invite, as the calling user. Throws with Postgres's message. */
  createInvite(email: string, role: string, autoActivate: boolean): Promise<Invite>;
  /** Opens the account, confirmed, as the service role. Resolves for an
   *  address that already has one: inviting again only resends the email. */
  openAccount(email: string): Promise<void>;
  /** The invitation letter, through the project's mail provider. */
  sendInvitation(email: string): Promise<"sent" | "not_configured">;
}

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
    await deps.openAccount(email);
    if (await deps.sendInvitation(email) !== "sent") throw new Error("no mail provider configured");
  } catch (error) {
    // The invitation exists; the person can still be told to sign in.
    console.error(`invitation to ${email} not completed`, error);
    return { status: 502, body: { error: `L'invitation est créée (code ${created.code}) mais l'e-mail n'a pas pu partir.` } };
  }
  return { status: 200, body: { email, code: created.code } };
}

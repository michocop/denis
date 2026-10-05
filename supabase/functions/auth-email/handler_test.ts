import { assert, assertEquals } from "jsr:@std/assert@1";
import { authMail, verifyLink } from "./handler.ts";
import { brevoSender, parseFrom } from "../_shared/email.ts";

const base = { user: { email: "johann@example.test", user_metadata: { first_name: "Johann" } } };

Deno.test("an invitation is a branded letter whose button opens the app through Supabase", () => {
  const mail = authMail({ ...base, email_data: { token_hash: "abc", email_action_type: "invite",
    redirect_to: "trinityenergie://auth-callback" } }, "https://ref.supabase.co");
  assertEquals(mail.to, ["johann@example.test"]);
  assertEquals(mail.subject, "Votre invitation à rejoindre Trinity Énergie");
  const link = "https://ref.supabase.co/auth/v1/verify?token=abc&type=invite&redirect_to=trinityenergie%3A%2F%2Fauth-callback";
  assert(mail.html.includes(`href="${link.replace(/&/g, "&amp;")}"`), "the button is a real link");
  assert(mail.text.includes(link), "and the plain-text part carries it too");
  assert(mail.html.includes("Bonjour Johann,"));
  assert(!mail.html.includes("désactiver ces e-mails"), "account mail cannot be switched off");
});

Deno.test("a password reset says so and goes back to the app by default", () => {
  const mail = authMail({ user: { email: "a@b.test" }, email_data: { token_hash: "h", email_action_type: "recovery" } },
    "https://ref.supabase.co/");
  assertEquals(mail.subject, "Réinitialisez votre mot de passe");
  assert(mail.text.startsWith("Bonjour,"));
  assert(mail.text.includes(verifyLink("https://ref.supabase.co", "h", "recovery")));
  assert(mail.text.includes("redirect_to=trinityenergie"));
});

Deno.test("an email change is confirmed at the new address", () => {
  const mail = authMail({ user: { email: "old@b.test", new_email: "new@b.test" },
    email_data: { token_hash: "o", token_hash_new: "n", email_action_type: "email_change" } }, "https://r.supabase.co");
  assertEquals(mail.to, ["new@b.test"]);
  assert(mail.text.includes("token=n&type=email_change"));
});

Deno.test("Brevo sends from the verified sender, with the PDF attached", async () => {
  const calls: RequestInit[] = [];
  const send = brevoSender("xkeysib-test", "Trinity Énergie <factures@trinity-energie.fr>",
    ((_: string, init: RequestInit) => { calls.push(init); return Promise.resolve(new Response("{}", { status: 201 })); }) as typeof fetch);
  const status = await send({ to: ["a@b.test"], subject: "S", text: "t", html: "<p>t</p>",
    attachments: [{ filename: "FA-2026-0001.pdf", content: new Uint8Array([37, 80, 68, 70]) }] });
  assertEquals(status, "sent");
  const body = JSON.parse(calls[0].body as string);
  assertEquals(body.sender, { name: "Trinity Énergie", email: "factures@trinity-energie.fr" });
  assertEquals(body.to, [{ email: "a@b.test" }]);
  assertEquals(body.attachment, [{ name: "FA-2026-0001.pdf", content: "JVBERg==" }]);
  assertEquals((calls[0].headers as Record<string, string>)["api-key"], "xkeysib-test");
});

Deno.test("without a verified sender nothing is sent", async () => {
  assertEquals(await brevoSender("k", undefined)({ to: ["a@b.test"], subject: "", text: "", html: "" }), "not_configured");
  assertEquals(parseFrom("x@y.fr"), { email: "x@y.fr" });
});

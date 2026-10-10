import { assertEquals } from "jsr:@std/assert@1";
import { invite } from "./handler.ts";

const ok = (sent: string[]) => ({
  createInvite: (email: string, role: string) => Promise.resolve({ code: "ABCD2345", email, role }),
  openAccount: (email: string) => { sent.push(`open ${email}`); return Promise.resolve(); },
  sendInvitation: (email: string) => { sent.push(`mail ${email}`); return Promise.resolve("sent" as const); },
});

Deno.test("an admin's invitation opens the account, then emails the letter", async () => {
  const sent: string[] = [];
  const result = await invite({ email: " Nina@Example.test " }, ok(sent));
  assertEquals(result, { status: 200, body: { email: "nina@example.test", code: "ABCD2345" } });
  assertEquals(sent, ["open nina@example.test", "mail nina@example.test"]);
});

Deno.test("an invitation that could not be mailed says so, with its code", async () => {
  const result = await invite({ email: "nina@example.test" }, {
    ...ok([]), sendInvitation: () => Promise.resolve("not_configured" as const) });
  assertEquals(result.status, 502);
});

Deno.test("someone who is not an admin sends nothing", async () => {
  const sent: string[] = [];
  const result = await invite({ email: "x@example.test" }, {
    createInvite: () => Promise.reject({ message: "only an admin may invite" }),
    openAccount: (e: string) => { sent.push(e); return Promise.resolve(); },
    sendInvitation: (e: string) => { sent.push(e); return Promise.resolve("sent" as const); },
  });
  assertEquals(result.status, 403);
  assertEquals(sent, [], "the email is sent only after the database agreed");
});

Deno.test("an address that already has an account is refused plainly", async () => {
  const result = await invite({ email: "x@example.test" }, {
    createInvite: () => Promise.reject({ message: "this address already has an account" }),
    openAccount: () => Promise.resolve(),
    sendInvitation: () => Promise.resolve("sent" as const),
  });
  assertEquals(result.status, 409);
});

Deno.test("a malformed address never reaches the database", async () => {
  let called = false;
  const result = await invite({ email: "pas-une-adresse" }, {
    createInvite: () => { called = true; return Promise.resolve({ code: "", email: "", role: "" }); },
    openAccount: () => Promise.resolve(),
    sendInvitation: () => Promise.resolve("sent" as const),
  });
  assertEquals(result.status, 400);
  assertEquals(called, false);
});

import { assertEquals } from "jsr:@std/assert@1";
import { invite, REDIRECT } from "./handler.ts";

const ok = (sent: string[]) => ({
  createInvite: (email: string, role: string) => Promise.resolve({ code: "ABCD2345", email, role }),
  sendInvitation: (email: string, redirect: string) => {
    sent.push(`${email} -> ${redirect}`);
    return Promise.resolve();
  },
});

Deno.test("an admin's invitation is created, then emailed with a link back into the app", async () => {
  const sent: string[] = [];
  const result = await invite({ email: " Nina@Example.test " }, ok(sent));
  assertEquals(result, { status: 200, body: { email: "nina@example.test", code: "ABCD2345" } });
  assertEquals(sent, [`nina@example.test -> ${REDIRECT}`]);
});

Deno.test("someone who is not an admin sends nothing", async () => {
  const sent: string[] = [];
  const result = await invite({ email: "x@example.test" }, {
    createInvite: () => Promise.reject({ message: "only an admin may invite" }),
    sendInvitation: (e: string) => { sent.push(e); return Promise.resolve(); },
  });
  assertEquals(result.status, 403);
  assertEquals(sent, [], "the email is sent only after the database agreed");
});

Deno.test("an address that already has an account is refused plainly", async () => {
  const result = await invite({ email: "x@example.test" }, {
    createInvite: () => Promise.reject({ message: "this address already has an account" }),
    sendInvitation: () => Promise.resolve(),
  });
  assertEquals(result.status, 409);
});

Deno.test("a malformed address never reaches the database", async () => {
  let called = false;
  const result = await invite({ email: "pas-une-adresse" }, {
    createInvite: () => { called = true; return Promise.resolve({ code: "", email: "", role: "" }); },
    sendInvitation: () => Promise.resolve(),
  });
  assertEquals(result.status, 400);
  assertEquals(called, false);
});

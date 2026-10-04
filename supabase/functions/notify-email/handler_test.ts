import { assert, assertEquals } from "jsr:@std/assert@1";
import { sendNotificationEmail } from "./handler.ts";
import { Mail } from "../_shared/email.ts";

Deno.test("an invoice to sign is emailed with the same words as the push, and what to do next", async () => {
  const sent: Mail[] = [];
  const outcome = await sendNotificationEmail("n1", {
    load: () => Promise.resolve({
      to: "johann@example.test", first_name: "Johann", kind: "invoice_ready",
      title: "Facture à signer", body: "Facture FA-2026-0007 — 450.00 EUR",
    }),
    sendMail: (m) => { sent.push(m); return Promise.resolve("sent" as const); },
  });
  assertEquals(outcome.status, "sent");
  assertEquals(sent[0].to, ["johann@example.test"]);
  assertEquals(sent[0].subject, "Facture à signer — Facture FA-2026-0007 — 450.00 EUR");
  assert(sent[0].text.startsWith("Bonjour Johann,"));
  assert(sent[0].text.includes("signer"));
  assert(sent[0].html.includes("TRINITY ÉNERGIE"), "in the brand's own letterhead");
  assert(sent[0].html.includes("Facture à signer"));
});

Deno.test("nobody to send to means nothing is sent", async () => {
  let calls = 0;
  const outcome = await sendNotificationEmail("n2", {
    load: () => Promise.resolve(null),
    sendMail: () => { calls++; return Promise.resolve("sent" as const); },
  });
  assertEquals(outcome.status, "no_recipient");
  assertEquals(calls, 0);
});

Deno.test("text a sender could have typed is escaped in the HTML", async () => {
  const sent: Mail[] = [];
  await sendNotificationEmail("n3", {
    load: () => Promise.resolve({
      to: "a@b.test", first_name: "<b>x</b>", kind: "document_added",
      title: "Nouveau document", body: "<script>alert(1)</script>.pdf",
    }),
    sendMail: (m) => { sent.push(m); return Promise.resolve("sent" as const); },
  });
  assert(!sent[0].html.includes("<script>"));
  assert(sent[0].html.includes("&lt;script&gt;"));
});

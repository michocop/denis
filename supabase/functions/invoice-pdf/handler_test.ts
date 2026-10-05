// deno test supabase/functions
import { assert, assertEquals } from "jsr:@std/assert@1";
import { PDFDict, PDFDocument, PDFName } from "npm:pdf-lib@1.17.1";
import { Deps, retainInvoice } from "./handler.ts";
import { InvoiceDocument, renderInvoicePdf, sha256Hex, signatureLine } from "../_shared/invoice_pdf.ts";
import { Mail } from "../_shared/email.ts";

export const sample: InvoiceDocument & { pdf_path?: string | null } = {
  number: "FA-2026-0001",
  kind: "invoice",
  corrects_number: null,
  document_sha256: "a".repeat(64),
  issuer: { name: "Pierre-Louis Tettamanti", company: "Trinity Énergie", city: "AIX-EN-PEVELE" },
  customer: {
    legal_name: "Trinity Énergie", legal_form: "SAS", share_capital: "10 000 €",
    siren: "123456789", rcs_city: "Lille", vat_number: "FR12123456789",
    address: "1 rue de la Gare", postal_code: "59310", city: "Aix-en-Pévèle",
  },
  apporteur: {
    name: "Johann Lefeuvre", company: "Lefeuvre Conseil", siret: "12345678900011",
    legal_form: "Micro-entreprise", address: "12 rue des Lilas", postal_code: "59000", city: "Lille",
  },
  attestation: {
    soussigne: "Johann Lefeuvre", mis_en_relation: "Trinity Énergie", avec: "Thomas Dubois",
    prestation: "Apport d'affaires - mise en relation", intervenue_le: "17.09.2026",
  },
  amount: { ht: "300.00", vat_rate: 0, vat: "0.00", ttc: "300.00", currency: "EUR" },
  legal_mentions: "TVA non applicable – Régime d'exonération de TVA (Article 293B du Code général des impôts)",
  payment_method: "Virement bancaire",
  place: "AIX-EN-PEVELE",
  issued_on: "17.09.2026",
  due_on: "17.10.2026",
  self_billing_mention: "Autofacturation — facture établie par le client au nom et pour le compte du fournisseur (art. 289, I-2 du CGI).",
  late_payment_mention: "En cas de retard de paiement, pénalités au taux de trois fois le taux d'intérêt légal, exigibles sans rappel, et indemnité forfaitaire pour frais de recouvrement de 40 € (art. L441-10 du Code de commerce).",
  tax_notice: "N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.",
  status: "signed",
  pdf_path: null,
  signatures: [
    { role: "apporteur", name: "Johann Lefeuvre", signed: true, signed_at: "2026-09-18T10:00:00Z" },
    { role: "entreprise", name: "Pierre-Louis Tettamanti", signed: true, signed_at: "2026-09-18T11:00:00Z" },
  ],
};

const ID = "11111111-2222-3333-4444-555555555555";

function fakes(overrides: Partial<Deps> = {}, state: { stored?: Uint8Array; retained?: string } = {}) {
  const sent: Mail[] = [];
  const deps: Deps = {
    loadDocument: () => Promise.resolve({ ...sample }),
    loadRecipients: () => Promise.resolve({
      number: sample.number, kind: "invoice", apporteur_name: "Johann",
      apporteur_email: "johann@example.test", company_email: "compta@trinity-energie.fr",
    }),
    upload: (_path, bytes) => {
      if (state.stored) return Promise.resolve("exists" as const);
      state.stored = bytes;
      return Promise.resolve("created" as const);
    },
    download: () => Promise.resolve(state.stored!),
    retain: (_id, path, sha) => {
      state.retained ??= sha;
      return Promise.resolve(path);
    },
    sendMail: (mail) => {
      sent.push(mail);
      return Promise.resolve("sent" as const);
    },
    ...overrides,
  };
  return { deps, sent, state };
}

Deno.test("a sealed invoice is rendered, stored, recorded and mailed to both parties", async () => {
  const { deps, sent, state } = fakes();
  const outcome = await retainInvoice(ID, deps);

  assertEquals(outcome.status, "retained");
  assert(state.stored, "the PDF is stored");
  assertEquals(state.retained, await sha256Hex(state.stored!), "the digest recorded is of the stored bytes");

  assertEquals(sent.length, 1);
  assertEquals(sent[0].to, ["johann@example.test", "compta@trinity-energie.fr"]);
  assertEquals(sent[0].subject, "La facture FA-2026-0001 est signée");
  assertEquals(sent[0].attachments?.[0].filename, "FA-2026-0001.pdf");
  assertEquals(sent[0].attachments?.[0].content, state.stored, "and the attachment is the retained file");
});

Deno.test("an invoice that is not sealed is left alone", async () => {
  const { deps, state } = fakes({ loadDocument: () => Promise.resolve({ ...sample, status: "draft" }) });
  assertEquals((await retainInvoice(ID, deps)).status, "not_sealed");
  assertEquals(state.stored, undefined);
});

Deno.test("an invoice already retained is not rendered again", async () => {
  const { deps, state, sent } = fakes({
    loadDocument: () => Promise.resolve({ ...sample, pdf_path: `${ID}.pdf` }),
  });
  assertEquals((await retainInvoice(ID, deps)).status, "already_retained");
  assertEquals(state.stored, undefined);
  assertEquals(sent.length, 0, "and nobody is mailed twice");
});

Deno.test("after a crash between storing and recording, the stored file is the one recorded", async () => {
  const earlier = new TextEncoder().encode("%PDF-1.7 the file stored by the earlier run");
  const { deps, state } = fakes({}, { stored: earlier });
  const outcome = await retainInvoice(ID, deps);
  assertEquals(outcome.status, "retained");
  assertEquals(state.retained, await sha256Hex(earlier), "not a fresh rendering that merely looks the same");
});

Deno.test("without an email provider the document is still kept", async () => {
  const { deps } = fakes({ sendMail: () => Promise.resolve("not_configured" as const) });
  const outcome = await retainInvoice(ID, deps);
  assertEquals(outcome.status, "retained");
  assertEquals((outcome as { mailed: string }).mailed, "not_configured");
});

Deno.test("a mail that fails does not undo the retention", async () => {
  const { deps } = fakes({ sendMail: () => Promise.reject(new Error("provider down")) });
  const outcome = await retainInvoice(ID, deps);
  assertEquals(outcome.status, "retained");
  assertEquals((outcome as { mailed: string }).mailed, "failed");
});

Deno.test("the PDF is A4, embeds its fonts and names the invoice", async () => {
  const bytes = await renderInvoicePdf(sample, { creationDate: new Date("2026-09-18T12:00:00Z") });
  const pdf = await PDFDocument.load(bytes);
  assertEquals(pdf.getPageCount(), 1);
  const { width, height } = pdf.getPage(0).getSize();
  assertEquals([Math.round(width), Math.round(height)], [595, 842]);
  assertEquals(pdf.getTitle(), "Facture FA-2026-0001");
  // object streams hide the dictionaries from a text search; walk them instead
  const embedded = pdf.context.enumerateIndirectObjects()
    .filter(([, obj]) => obj instanceof PDFDict && obj.has(PDFName.of("FontFile2")));
  assertEquals(embedded.length, 3, "all three faces are embedded, as PDF/A requires");
});

Deno.test("a long label flows onto a second page instead of off the first", async () => {
  const long = { ...sample, attestation: { ...sample.attestation, prestation: "Apport d'affaires détaillé. ".repeat(160) } };
  const pdf = await PDFDocument.load(await renderInvoicePdf(long));
  assert(pdf.getPageCount() > 1);
});

Deno.test("a signature confirmed by SMS says so on the document, with the masked number", async () => {
  const line = signatureLine({ role: "apporteur", name: "Johann Lefeuvre", signed: true,
    signed_at: "2026-09-18T10:00:00Z", sms_verified: true, sms_phone: "+33 6 •• •• •• 78" });
  assert(line.startsWith("Signature de l'apporteur — Johann Lefeuvre — signé électroniquement le "));
  assert(line.endsWith(", code SMS vérifié (+33 6 •• •• •• 78)"));
  assertEquals(signatureLine({ role: "entreprise", name: "P", signed: false, sms_verified: false }),
    "Signature de l'entreprise — P — en attente");

  const doc = structuredClone(sample);
  doc.signatures[0] = { ...doc.signatures[0], sms_verified: true, sms_phone: "+33 6 •• •• •• 78" };
  const pdf = await renderInvoicePdf(doc);
  assert(pdf.length > 1000, "and the masked number renders in the embedded font");
});

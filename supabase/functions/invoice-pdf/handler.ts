// What the invoice-pdf function does, with everything it touches passed in,
// so the whole sequence can be tested without a Supabase project.

import { InvoiceDocument, renderInvoicePdf, sha256Hex } from "../_shared/invoice_pdf.ts";
import { html, Mail, SendMail } from "../_shared/email.ts";

export interface Recipients {
  number: string;
  kind: "invoice" | "credit_note";
  apporteur_name: string | null;
  apporteur_email: string | null;
  company_email: string | null;
}

export interface Deps {
  loadDocument(invoiceId: string): Promise<(InvoiceDocument & { pdf_path?: string | null }) | null>;
  loadRecipients(invoiceId: string): Promise<Recipients | null>;
  /** "exists" when an object is already at that path. */
  upload(path: string, bytes: Uint8Array): Promise<"created" | "exists">;
  download(path: string): Promise<Uint8Array>;
  /** Records the file; returns the path actually kept. */
  retain(invoiceId: string, path: string, sha256: string): Promise<string>;
  sendMail: SendMail;
  /** Makes the PDF; Factur-X wraps the plain render. */
  render?(doc: InvoiceDocument): Promise<Uint8Array>;
}

export type Outcome =
  | { invoice_id: string; status: "not_found" | "not_sealed" | "already_retained" }
  | { invoice_id: string; status: "retained"; sha256: string; mailed: "sent" | "not_configured" | "failed" | "no_recipient" };

export async function retainInvoice(invoiceId: string, deps: Deps): Promise<Outcome> {
  const doc = await deps.loadDocument(invoiceId);
  if (!doc) return { invoice_id: invoiceId, status: "not_found" };
  if (doc.status !== "signed" && doc.status !== "paid") {
    return { invoice_id: invoiceId, status: "not_sealed" };
  }
  if (doc.pdf_path) return { invoice_id: invoiceId, status: "already_retained" };

  const path = `${invoiceId}.pdf`;
  let bytes = await (deps.render ?? renderInvoicePdf)(doc);

  // A previous run may have stored the file and died before recording it.
  // The stored bytes are then the retained document, not a fresh rendering.
  if (await deps.upload(path, bytes) === "exists") {
    bytes = await deps.download(path);
  }
  const sha256 = await sha256Hex(bytes);
  const kept = await deps.retain(invoiceId, path, sha256);
  if (kept !== path) {
    // someone else recorded a different file first; theirs is the one kept
    return { invoice_id: invoiceId, status: "already_retained" };
  }

  return { invoice_id: invoiceId, status: "retained", sha256, mailed: await mail(invoiceId, bytes, deps) };
}

async function mail(invoiceId: string, pdf: Uint8Array, deps: Deps) {
  const r = await deps.loadRecipients(invoiceId);
  const to = [r?.apporteur_email, r?.company_email].filter((x): x is string => !!x);
  if (!r || to.length === 0) return "no_recipient" as const;
  try {
    return await deps.sendMail(signedMail(r, to, pdf));
  } catch (error) {
    // The document is kept; a mail that did not leave is not worth failing for.
    console.error(`invoice ${invoiceId}: mail not sent`, error);
    return "failed" as const;
  }
}

export function signedMail(r: Recipients, to: string[], pdf: Uint8Array): Mail {
  const what = r.kind === "credit_note" ? "L'avoir" : "La facture";
  const greeting = r.apporteur_name ? `Bonjour ${r.apporteur_name},` : "Bonjour,";
  const lines = [
    greeting,
    "",
    `${what} ${r.number} a été signé${r.kind === "credit_note" ? "" : "e"} par les deux parties. ` +
      "Vous la trouverez en pièce jointe.",
    "",
    "Conservez ce document : il est à garder dix ans, et c'est celui que vous déclarez.",
    "",
    "Trinity Énergie",
  ];
  return {
    to,
    subject: `${what} ${r.number} est signé${r.kind === "credit_note" ? "" : "e"}`,
    text: lines.join("\n"),
    html: lines.map((l) => (l ? `<p>${html(l)}</p>` : "")).join(""),
    attachments: [{ filename: `${r.number}.pdf`, content: pdf }],
  };
}

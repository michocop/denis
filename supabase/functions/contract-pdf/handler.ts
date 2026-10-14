// What the contract-pdf function does, with everything it touches passed in,
// so the whole sequence can be tested without a Supabase project.

import { ContractDocument, reference, renderContractPdf } from "../_shared/contract_pdf.ts";
import { sha256Hex } from "../_shared/invoice_pdf.ts";
import { Mail, SendMail } from "../_shared/email.ts";
import { renderLetter } from "../_shared/email_template.ts";

export interface Deps {
  loadDocument(contractId: string): Promise<ContractDocument | null>;
  /** The company's address for its copy, if it has one. */
  companyEmail(): Promise<string | null>;
  /** "exists" when an object is already at that path. */
  upload(path: string, bytes: Uint8Array): Promise<"created" | "exists">;
  download(path: string): Promise<Uint8Array>;
  /** Records the file; returns the path actually kept. */
  retain(contractId: string, path: string, sha256: string): Promise<string>;
  sendMail: SendMail;
  render?(doc: ContractDocument): Promise<Uint8Array>;
}

export type Outcome =
  | { contract_id: string; status: "not_found" | "already_retained" }
  | { contract_id: string; status: "retained"; sha256: string; mailed: "sent" | "not_configured" | "failed" };

export async function retainContract(contractId: string, deps: Deps): Promise<Outcome> {
  const doc = await deps.loadDocument(contractId);
  if (!doc) return { contract_id: contractId, status: "not_found" };
  if (doc.pdf_path) return { contract_id: contractId, status: "already_retained" };

  const path = `${contractId}.pdf`;
  let bytes = await (deps.render ?? renderContractPdf)(doc);
  // A previous run may have stored the file and died before recording it:
  // the stored bytes are then the filed contract, not a fresh rendering.
  if (await deps.upload(path, bytes) === "exists") {
    bytes = await deps.download(path);
  }
  const sha256 = await sha256Hex(bytes);
  if (await deps.retain(contractId, path, sha256) !== path) {
    return { contract_id: contractId, status: "already_retained" };
  }

  let mailed: "sent" | "not_configured" | "failed";
  try {
    const company = await deps.companyEmail();
    mailed = await deps.sendMail(contractMail(doc, [doc.signer.email, company].filter((x): x is string => !!x), bytes));
  } catch (error) {
    // The contract is filed; a copy that did not leave is not worth failing for.
    console.error(`contract ${contractId}: mail not sent`, error);
    mailed = "failed";
  }
  return { contract_id: contractId, status: "retained", sha256, mailed };
}

export function contractMail(doc: ContractDocument, to: string[], pdf: Uint8Array): Mail {
  const first = doc.signer.name.split(" ")[0];
  const letter = renderLetter({
    greeting: first ? `Bonjour ${first},` : "Bonjour,",
    heading: "Votre contrat d'apporteur d'affaires est signé",
    paragraphs: [
      "Vous trouverez en pièce jointe votre contrat d'apporteur d'affaires avec Trinity Énergie, le mandat de " +
        "facturation qui lui est annexé et le certificat de signature.",
      "Il reste disponible à tout moment dans l'application, onglet Profil. Bienvenue dans le réseau Trinity Énergie.",
    ],
    footerNote: "Cet e-mail accompagne la signature de votre contrat. Conservez-le avec vos documents.",
  });
  return {
    to,
    subject: "Votre contrat d'apporteur d'affaires est signé",
    text: letter.text,
    html: letter.html,
    attachments: [{ filename: `Contrat apporteur ${reference(doc.id)}.pdf`, content: pdf }],
  };
}

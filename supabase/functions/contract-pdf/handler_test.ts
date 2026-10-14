import { assert, assertEquals } from "jsr:@std/assert@1";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import { Deps, retainContract } from "./handler.ts";
import { ContractDocument, groupedSiret, parseLegalText, reference, renderContractPdf } from "../_shared/contract_pdf.ts";
import { Mail } from "../_shared/email.ts";

export const sample: ContractDocument = {
  id: "5f0c2a1e-8b7d-4c3a-9e21-0d6f4b8a7c11",
  signed_at: "2026-10-14T14:07:31Z",
  business_status: "societe",
  signer: {
    name: "Lina Laurent", email: "lina@example.test", company: "Laurent Conseil", legal_form: "SASU",
    siret: "12345678900012", address: "3 rue Nationale", postal_code: "59000", city: "Lille",
  },
  evidence: { sms_verified: true, sms_phone: "+33 6 •• •• •• 32", ip_address: "90.12.34.56", user_agent: "EnergyCourtage/1.0" },
  contract: {
    title: "Contrat d'apporteur d'affaires", version: "2026-10-1", sha256: "a".repeat(64),
    body: "**Entre les soussignés :**\n\n**TRINITY ENERGIE**, société par actions simplifiée,\nreprésentée par son Président,\n\n" +
      "## Article 1 — Objet\n\nLe présent contrat définit les conditions.\n\n## Article 2 — Mission\n\nL'Apporteur s'engage à :\n\n" +
      "- n'adresser que des personnes **informées** ;\n  dont il a l'accord ;\n- transmettre des informations exactes.\n\n" +
      Array.from({ length: 12 }, (_, i) => `## Article ${i + 3} — Clause\n\n${"Texte de la clause. ".repeat(30)}`).join("\n\n"),
  },
  mandate: { title: "Mandat de facturation", version: "2026-10-1", sha256: "b".repeat(64),
    body: "## Article 1 — Objet\n\nLe Mandant donne mandat au Mandataire d'établir les factures." },
  company: { legal_name: "TRINITY ENERGIE", legal_form: "SAS", share_capital: "1 000 €", siren: "102470705",
    rcs_city: "Lille Métropole", address: "945 rue du Général de Gaulle", postal_code: "59310", city: "Aix-en-Pévèle" },
  pdf_path: null,
};

Deno.test("the legal text is read back from its small Markdown, lines joined, bullets kept", () => {
  const blocks = parseLegalText(sample.contract.body);
  assertEquals(blocks[0], { kind: "paragraph", text: "Entre les soussignés :", strong: true });
  assertEquals(blocks[1].kind === "paragraph" && blocks[1].text,
    "TRINITY ENERGIE, société par actions simplifiée, représentée par son Président,");
  assertEquals(blocks[2], { kind: "heading", text: "Article 1 — Objet" });
  const bullets = blocks.find((b) => b.kind === "bullets");
  assertEquals(bullets, { kind: "bullets", items: [
    "n'adresser que des personnes informées ; dont il a l'accord ;", "transmettre des informations exactes."] });
});

Deno.test("the PDF holds the contract, its annex and the certificate, titled for its signer", async () => {
  const bytes = await renderContractPdf(sample, { creationDate: new Date("2026-10-14T14:07:31Z") });
  const pdf = await PDFDocument.load(bytes);
  assert(pdf.getPageCount() >= 3, "contract, annex and certificate each start a page");
  assertEquals(pdf.getTitle(), "Contrat d'apporteur d'affaires — Lina Laurent");
  assert(pdf.getSubject()?.includes("a".repeat(64)) && pdf.getSubject()?.includes("b".repeat(64)),
    "the digests of both texts travel in the metadata too");
  assertEquals(reference(sample.id), "CT-5F0C2A1E");
  assertEquals(groupedSiret("12345678900012"), "123 456 789 00012");
  await Deno.writeFile(Deno.env.get("CONTRACT_PDF_SAMPLE") ?? "/dev/null", bytes).catch(() => {});
});

function fakeDeps(over: Partial<Deps> = {}, log: string[] = [], mails: Mail[] = []): Deps {
  return {
    loadDocument: () => Promise.resolve(sample),
    companyEmail: () => Promise.resolve("pierrelouis@trinity-energie.fr"),
    upload: (path) => { log.push(`upload ${path}`); return Promise.resolve("created"); },
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    retain: (_id, path, sha) => { log.push(`retain ${path} ${sha.length}`); return Promise.resolve(path); },
    sendMail: (m) => { mails.push(m); return Promise.resolve("sent"); },
    render: () => Promise.resolve(new Uint8Array([37, 80, 68, 70])),
    ...over,
  };
}

Deno.test("signing files the PDF under the contract's id and mails both parties a copy", async () => {
  const log: string[] = [], mails: Mail[] = [];
  const outcome = await retainContract(sample.id, fakeDeps({}, log, mails));
  assertEquals(outcome.status, "retained");
  assertEquals(log, [`upload ${sample.id}.pdf`, `retain ${sample.id}.pdf 64`]);
  assertEquals(mails[0].to, ["lina@example.test", "pierrelouis@trinity-energie.fr"]);
  assertEquals(mails[0].attachments?.[0].filename, "Contrat apporteur CT-5F0C2A1E.pdf");
  assert(mails[0].html.includes("Bonjour Lina,"));
});

Deno.test("a file stored by a run that died is the one kept, not a fresh rendering", async () => {
  const shas: string[] = [];
  await retainContract(sample.id, fakeDeps({
    upload: () => Promise.resolve("exists"),
    retain: (_id, path, sha) => { shas.push(sha); return Promise.resolve(path); },
  }));
  // sha256 of [1, 2, 3], the stored bytes
  assertEquals(shas, ["039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"]);
});

Deno.test("a contract already filed, or unknown, is left alone; a mail failure does not undo the filing", async () => {
  assertEquals((await retainContract(sample.id, fakeDeps({
    loadDocument: () => Promise.resolve({ ...sample, pdf_path: `${sample.id}.pdf` }) }))).status, "already_retained");
  assertEquals((await retainContract(sample.id, fakeDeps({
    loadDocument: () => Promise.resolve(null) }))).status, "not_found");
  const outcome = await retainContract(sample.id, fakeDeps({ sendMail: () => Promise.reject(new Error("Brevo down")) }));
  assertEquals(outcome.status === "retained" && outcome.mailed, "failed");
});

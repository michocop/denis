// The invoice, or credit note, as the PDF that is kept for ten years.
//
// Rendered on the server from invoice_document() -- the same JSON the app
// shows -- the moment both signatures are in. It used to be drawn on a phone
// and uploaded by whichever company admin happened to open the invoice, so an
// invoice nobody opened was never retained at all.
//
// The layout mirrors ios/.../InvoicePDF.swift, so what a signer saw in the app
// and what is filed look the same. The legal binding is unaffected by layout:
// what both parties signed is document_sha256, the digest of the canonical
// text, and this page prints it.

import { PDFDocument, PDFFont, PDFPage, rgb } from "npm:pdf-lib@1.17.1";
import fontkit from "npm:@pdf-lib/fontkit@1.1.1";
import { fontBytes, manropeBold, manropeRegular, soraSemiBold } from "./fonts.ts";

export interface Party {
  name: string;
  company?: string | null;
  city?: string | null;
  siret?: string | null;
  legal_form?: string | null;
  address?: string | null;
  postal_code?: string | null;
  vat_number?: string | null;
}

export interface Customer {
  legal_name: string;
  legal_form?: string | null;
  share_capital?: string | null;
  siren: string;
  rcs_city?: string | null;
  vat_number?: string | null;
  address: string;
  postal_code: string;
  city: string;
}

export interface InvoiceDocument {
  number: string;
  kind?: "invoice" | "credit_note" | null;
  corrects_number?: string | null;
  document_sha256?: string | null;
  issuer: Party;
  customer?: Customer | null;
  apporteur: Party;
  attestation: {
    soussigne: string;
    mis_en_relation?: string | null;
    avec: string;
    prestation: string;
    intervenue_le: string;
  };
  amount: { ht: string; vat_rate: number; vat: string; ttc: string; currency: string };
  legal_mentions: string;
  payment_method: string;
  place: string;
  issued_on: string;
  due_on?: string | null;
  self_billing_mention?: string | null;
  late_payment_mention?: string | null;
  tax_notice?: string | null;
  status: string;
  signatures: { role: string; name: string; signed: boolean; signed_at?: string | null }[];
}

/** A4 at 72 dpi. */
const PAGE = { width: 595.28, height: 841.89 };
const MARGIN = 48;
const FOOTER = 28;
const INK = rgb(0, 0, 0);
const GREY = rgb(0.4, 0.4, 0.4);
const RULE = rgb(0.8, 0.8, 0.8);

export function title(doc: InvoiceDocument): string {
  return doc.kind === "credit_note" ? "AVOIR" : "FACTURE";
}

/** "300.00" from the database, "300,00 €" on the page. */
export function money(amount: string, currency: string): string {
  return `${amount.replace(".", ",")} ${currency === "EUR" ? "€" : currency}`;
}

function frenchDate(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getUTCDate())}.${pad(d.getUTCMonth() + 1)}.${d.getUTCFullYear()}`;
}

/** Breaks text into lines that fit `width`, keeping explicit newlines. */
export function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const lines: string[] = [];
  for (const paragraph of text.split("\n")) {
    let line = "";
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      const candidate = line ? `${line} ${word}` : word;
      if (font.widthOfTextAtSize(candidate, size) <= width) {
        line = candidate;
      } else {
        if (line) lines.push(line);
        line = word;
      }
    }
    lines.push(line);
  }
  return lines;
}

class Layout {
  page!: PDFPage;
  y = 0;
  pageNumber = 0;
  readonly width = PAGE.width - MARGIN * 2;

  constructor(
    private pdf: PDFDocument,
    private footer: string,
    private fonts: { body: PDFFont; bold: PDFFont; display: PDFFont },
  ) {
    this.newPage();
  }

  get bottom() {
    return MARGIN + FOOTER;
  }

  newPage() {
    this.page = this.pdf.addPage([PAGE.width, PAGE.height]);
    this.pageNumber += 1;
    this.y = PAGE.height - MARGIN;
    this.page.drawText(`${this.footer} — page ${this.pageNumber}`, {
      x: MARGIN, y: MARGIN - 4, size: 7, font: this.fonts.body, color: GREY,
    });
  }

  /** Starts a new page unless `height` still fits. */
  keep(height: number) {
    if (this.y - height < this.bottom) this.newPage();
  }

  space(points: number) {
    this.y -= points;
  }

  text(text: string, opts: { font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>; x?: number; width?: number } = {}) {
    const font = opts.font ?? this.fonts.body;
    const size = opts.size ?? 10;
    const x = opts.x ?? MARGIN;
    const width = opts.width ?? this.width;
    const leading = size * 1.35;
    for (const line of wrap(text, font, size, width)) {
      this.keep(leading);
      this.y -= leading;
      this.page.drawText(line, { x, y: this.y + size * 0.25, size, font, color: opts.color ?? INK });
    }
  }

  /** A label on the left, wrapped to its column, and a value flush right on
   *  its first line. A long label used to run straight off the page. */
  row(label: string, value: string, font: PDFFont, size = 10) {
    const leading = size * 1.5;
    const valueWidth = font.widthOfTextAtSize(value, size);
    const lines = wrap(label, font, size, this.width - valueWidth - 24);
    lines.forEach((line, i) => {
      this.keep(leading);
      this.y -= leading;
      this.page.drawText(line, { x: MARGIN, y: this.y + size * 0.3, size, font, color: INK });
      if (i === 0) {
        this.page.drawText(value, {
          x: PAGE.width - MARGIN - valueWidth, y: this.y + size * 0.3, size, font, color: INK,
        });
      }
    });
  }

  rule() {
    this.keep(12);
    this.y -= 6;
    this.page.drawLine({
      start: { x: MARGIN, y: this.y }, end: { x: PAGE.width - MARGIN, y: this.y },
      thickness: 0.5, color: RULE,
    });
    this.y -= 6;
  }

  /** Two blocks side by side, advancing by the taller one. The first line of
   *  each block is its small heading ("FOURNISSEUR", "CLIENT"). */
  columns(left: [string, PDFFont][], right: [string, PDFFont][], size = 10) {
    const gutter = 24;
    const columnWidth = (this.width - gutter) / 2;
    const leading = size * 1.4;
    const sizeAt = (index: number) => (index === 0 ? size - 1.5 : size);
    const measure = (lines: [string, PDFFont][]) =>
      lines.reduce((h, [t, f], i) => h + wrap(t, f, sizeAt(i), columnWidth).length * leading, 0);
    this.keep(Math.max(measure(left), measure(right)));
    const top = this.y;
    let lowest = top;
    for (const [lines, x] of [[left, MARGIN], [right, MARGIN + columnWidth + gutter]] as const) {
      let cursor = top;
      lines.forEach(([t, f], i) => {
        for (const line of wrap(t, f, sizeAt(i), columnWidth)) {
          cursor -= leading;
          this.page.drawText(line, { x, y: cursor + size * 0.25, size: sizeAt(i), font: f, color: INK });
        }
      });
      lowest = Math.min(lowest, cursor);
    }
    this.y = lowest;
  }
}

function supplierLines(doc: InvoiceDocument, f: { body: PDFFont; bold: PDFFont }): [string, PDFFont][] {
  const p = doc.apporteur;
  const lines: [string, PDFFont][] = [["FOURNISSEUR", f.bold], [p.name, f.bold]];
  if (p.company) lines.push([p.company, f.body]);
  if (p.legal_form) lines.push([p.legal_form, f.body]);
  if (p.address) lines.push([p.address, f.body]);
  const town = [p.postal_code, p.city].filter(Boolean).join(" ");
  if (town) lines.push([town, f.body]);
  if (p.siret) lines.push([`SIRET ${p.siret}`, f.body]);
  if (p.vat_number) lines.push([`TVA ${p.vat_number}`, f.body]);
  return lines;
}

function customerLines(doc: InvoiceDocument, f: { body: PDFFont; bold: PDFFont }): [string, PDFFont][] {
  const c = doc.customer;
  if (!c) {
    // issued before the company's legal identity was recorded
    const lines: [string, PDFFont][] = [["CLIENT", f.bold], [doc.issuer.company ?? doc.issuer.name, f.bold]];
    if (doc.issuer.city) lines.push([doc.issuer.city, f.body]);
    return lines;
  }
  const lines: [string, PDFFont][] = [["CLIENT", f.bold], [c.legal_name, f.bold]];
  const form = [c.legal_form, c.share_capital ? `au capital de ${c.share_capital}` : null]
    .filter(Boolean).join(" ");
  if (form) lines.push([form, f.body]);
  lines.push([c.address, f.body], [`${c.postal_code} ${c.city}`, f.body]);
  lines.push([`SIREN ${c.siren}${c.rcs_city ? ` — RCS ${c.rcs_city}` : ""}`, f.body]);
  if (c.vat_number) lines.push([`TVA ${c.vat_number}`, f.body]);
  return lines;
}

export interface RenderOptions {
  /** Fixed for reproducible output in tests; the issue date otherwise. */
  creationDate?: Date;
}

/** The PDF document, open for the caller to finish (Factur-X attaches to it). */
export async function buildInvoicePdf(doc: InvoiceDocument, options: RenderOptions = {}): Promise<PDFDocument> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const fonts = {
    body: await pdf.embedFont(fontBytes(manropeRegular), { subset: true }),
    bold: await pdf.embedFont(fontBytes(manropeBold), { subset: true }),
    display: await pdf.embedFont(fontBytes(soraSemiBold), { subset: true }),
  };

  const label = title(doc) === "AVOIR" ? "Avoir" : "Facture";
  const customerName = doc.customer?.legal_name ?? doc.issuer.company ?? doc.issuer.name;
  pdf.setTitle(`${label} ${doc.number}`);
  pdf.setAuthor(doc.apporteur.name);
  pdf.setCreator(customerName);
  pdf.setProducer("Trinity Énergie");
  pdf.setSubject(`Autofacturation — document ${doc.document_sha256 ?? "non scellé"}`);
  pdf.setLanguage("fr-FR");
  const created = options.creationDate ?? new Date();
  pdf.setCreationDate(created);
  pdf.setModificationDate(created);

  const footer = `${label} ${doc.number} — empreinte SHA-256 ${doc.document_sha256 ?? "non scellé"}`;
  const L = new Layout(pdf, footer, fonts);
  const cur = doc.amount.currency;

  L.text(`${title(doc)} N° ${doc.number}`, { font: fonts.display, size: 18 });
  L.space(4);
  L.text(`Date d'émission : ${doc.issued_on}${doc.due_on ? `     Échéance : ${doc.due_on}` : ""}`);
  if (doc.kind === "credit_note" && doc.corrects_number) {
    L.text(`Avoir sur la facture n° ${doc.corrects_number}`, { font: fonts.bold });
  }
  L.space(14);

  L.columns(supplierLines(doc, fonts), customerLines(doc, fonts));
  L.space(10);

  if (doc.self_billing_mention) {
    L.text(doc.self_billing_mention, { font: fonts.bold });
    L.space(10);
  }

  L.rule();
  L.row("DÉSIGNATION", "MONTANT HT", fonts.bold, 8.5);
  L.rule();
  L.row(doc.attestation.prestation, money(doc.amount.ht, cur), fonts.body);
  L.text(`Mise en relation avec ${doc.attestation.avec}, intervenue le ${doc.attestation.intervenue_le}.`,
    { size: 8.5, color: GREY });
  L.rule();

  L.keep(60);
  L.row("Total HT", money(doc.amount.ht, cur), fonts.body);
  L.row(`TVA (${doc.amount.vat_rate} %)`, money(doc.amount.vat, cur), fonts.body);
  L.row(doc.kind === "credit_note" ? "Total TTC à déduire" : "Total TTC", money(doc.amount.ttc, cur), fonts.bold);
  L.rule();
  L.space(8);

  L.text(doc.legal_mentions, { size: 8.5 });
  L.text(`Règlement : ${doc.payment_method}${doc.due_on ? `, au plus tard le ${doc.due_on}` : ""}.`, { size: 8.5 });
  if (doc.late_payment_mention) L.text(doc.late_payment_mention, { size: 8.5 });
  L.text(`Fait à ${doc.place}, le ${doc.issued_on}.`, { size: 8.5 });
  L.space(12);

  if (doc.kind !== "credit_note") {
    L.text(`Je soussigné(e) ${doc.attestation.soussigne} atteste avoir mis en relation ` +
      `${doc.attestation.mis_en_relation ?? "la société"} avec ${doc.attestation.avec} ` +
      `pour la prestation ci-dessus.`, { size: 8.5 });
    L.space(12);
  }

  if (doc.tax_notice) {
    L.text(doc.tax_notice, { size: 8.5, color: GREY });
    L.space(12);
  }

  L.keep(70);
  L.text("SIGNATURES", { font: fonts.bold, size: 8.5 });
  L.space(4);
  for (const s of doc.signatures) {
    const who = s.role === "apporteur" ? "Signature de l'apporteur" : "Signature de l'entreprise";
    const state = s.signed
      ? `signé électroniquement${s.signed_at ? ` le ${frenchDate(s.signed_at)}` : ""}`
      : "en attente";
    L.text(`${who} — ${s.name} — ${state}`);
  }

  return pdf;
}

export async function renderInvoicePdf(doc: InvoiceDocument, options: RenderOptions = {}): Promise<Uint8Array> {
  return await (await buildInvoicePdf(doc, options)).save();
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

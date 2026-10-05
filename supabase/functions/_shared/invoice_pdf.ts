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
// text, and every page prints it.

import { PDFDocument, PDFFont, PDFPage, rgb, RGB } from "npm:pdf-lib@1.17.1";
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

export interface Signature {
  role: string;
  name: string;
  signed: boolean;
  signed_at?: string | null;
  sms_verified?: boolean;
  sms_phone?: string | null;
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
  signatures: Signature[];
}

// ------------------------------------------------------------------ look
/** A4 at 72 dpi. */
const PAGE = { width: 595.28, height: 841.89 };
const MARGIN = 44;
const CONTENT = PAGE.width - MARGIN * 2;
const FOOTER_TOP = 58;          // the footer lives below this line

const hex = (h: number) => rgb(((h >> 16) & 255) / 255, ((h >> 8) & 255) / 255, (h & 255) / 255);
/**
 * One colour and greys, the way a document from an accountant looks: white
 * paper, navy for what matters, grey for the rest, hairlines for structure.
 * The mark's blue appears in the mark and nowhere else -- no tinted tiles, no
 * coloured pills -- so the page prints as well in black and white as it reads
 * on screen.
 */
const C = {
  navy: hex(0x0A1F4A),    // titles, figures, names, the rules that carry weight
  mark: hex(0x3C8BFF),    // the inner triangle of the mark
  ink: hex(0x1C2333),
  grey: hex(0x5B6478),
  label: hex(0x6B7385),   // small capitals: labels and section headings
  faint: hex(0x8A93A6),
  rule: hex(0xE3E7EF),
  pending: hex(0xD5DAE3), // the rule over a signature still awaited
};
/** The tracking of small capitals. Any wider and a search of the filed copy
 * misses words its text layer has split ("AT TESTATION"). */
const CAPS = 0.2;

type Fonts = { body: PDFFont; bold: PDFFont; display: PDFFont };

export function title(doc: InvoiceDocument): string {
  return doc.kind === "credit_note" ? "AVOIR" : "FACTURE";
}

/** "300.00" from the database, "300,00 €" on the page, thousands spaced. */
export function money(amount: string, currency: string): string {
  const [whole, cents = "00"] = amount.split(".");
  const sign = whole.startsWith("-") ? "-" : "";
  const digits = whole.replace("-", "").replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  return `${sign}${digits},${cents} ${currency === "EUR" ? "€" : currency}`;
}

function frenchDate(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getUTCDate())}.${pad(d.getUTCMonth() + 1)}.${d.getUTCFullYear()}`;
}

/** "18.09.2026 à 12:00", in Paris time, where the parties are. */
function parisDateTime(iso: string): string {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris", day: "2-digit", month: "2-digit", year: "numeric",
    hour: "2-digit", minute: "2-digit", hour12: false,
  }).formatToParts(new Date(iso)).map((p) => [p.type, p.value]));
  return `${parts.day}.${parts.month}.${parts.year} à ${parts.hour}:${parts.minute}`;
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

// --------------------------------------------------------------- drawing
/** A horizontal rule at height `y` (measured upward). */
function rule(page: PDFPage, y: number,
              o: { x?: number; length?: number; color?: RGB; thickness?: number } = {}) {
  const x = o.x ?? MARGIN;
  page.drawLine({ start: { x, y }, end: { x: x + (o.length ?? CONTENT), y },
    thickness: o.thickness ?? 0.5, color: o.color ?? C.rule });
}

/** A check mark drawn rather than typed: the brand faces have no ✓. */
function tick(page: PDFPage, x: number, top: number, color: RGB) {
  page.drawSvgPath("M 0 3.4 L 2.4 5.8 L 6.6 0.6", { x, y: top, borderColor: color, borderWidth: 1.1 });
}

/** An empty circle, 6 pt across: a signature still to come. */
function ring(page: PDFPage, x: number, top: number, color: RGB) {
  const r = 3, k = 0.5523 * r, c = 3.5, m = 3;   // centre (c, m) from the top-left
  page.drawSvgPath(
    `M ${c + r} ${m} C ${c + r} ${m + k} ${c + k} ${m + r} ${c} ${m + r} ` +
    `C ${c - k} ${m + r} ${c - r} ${m + k} ${c - r} ${m} ` +
    `C ${c - r} ${m - k} ${c - k} ${m - r} ${c} ${m - r} ` +
    `C ${c + k} ${m - r} ${c + r} ${m - k} ${c + r} ${m} Z`,
    { x, y: top, borderColor: color, borderWidth: 0.8 });
}

/** Letter-spaced capitals, as the brand's wordmark and small headings. */
function tracked(page: PDFPage, text: string, x: number, y: number, size: number,
                 font: PDFFont, color: RGB, tracking: number): number {
  let cursor = x;
  for (const ch of text) {
    page.drawText(ch, { x: cursor, y, size, font, color });
    cursor += font.widthOfTextAtSize(ch, size) + tracking;
  }
  return cursor - tracking - x;
}

function trackedWidth(text: string, size: number, font: PDFFont, tracking: number): number {
  return [...text].reduce((w, ch) => w + font.widthOfTextAtSize(ch, size) + tracking, 0) - tracking;
}

/** The mark: an open triangle and a solid one inside (the site's SVG, 24×22). */
function logo(page: PDFPage, x: number, top: number, size: number, line: RGB) {
  const s = size / 24;
  page.drawSvgPath("M 12 1.25 L 22.5 20.75 L 1.5 20.75 Z", {
    x, y: top, scale: s, borderColor: line, borderWidth: 1.8,
  });
  page.drawSvgPath("M 12 8.75 L 16.5 17 L 7.5 17 Z", { x, y: top, scale: s, color: C.mark });
}

// ---------------------------------------------------------------- layout
class Layout {
  page!: PDFPage;
  y = 0;
  readonly pages: PDFPage[] = [];

  constructor(private pdf: PDFDocument, readonly fonts: Fonts, private continuation: string) {}

  /** The first page draws its own header; later ones get a slim reminder. */
  newPage(first = false) {
    this.page = this.pdf.addPage([PAGE.width, PAGE.height]);
    this.pages.push(this.page);
    this.y = PAGE.height - MARGIN;
    if (!first) {
      tracked(this.page, this.continuation, MARGIN, this.y - 8, 7.5, this.fonts.bold, C.faint, 0.4);
      this.y -= 26;
    }
  }

  get bottom() {
    return FOOTER_TOP + 14;
  }

  keep(height: number) {
    if (this.y - height < this.bottom) this.newPage();
  }

  space(points: number) {
    this.y -= points;
  }

  text(text: string, o: { font?: PDFFont; size?: number; color?: RGB; x?: number; width?: number; leading?: number } = {}) {
    const font = o.font ?? this.fonts.body;
    const size = o.size ?? 9;
    const leading = o.leading ?? size * 1.45;
    for (const line of wrap(text, font, size, o.width ?? CONTENT)) {
      this.keep(leading);
      this.y -= leading;
      this.page.drawText(line, { x: o.x ?? MARGIN, y: this.y + size * 0.28, size, font, color: o.color ?? C.ink });
    }
  }

  /** A small-capitals section heading with a hairline after it. */
  heading(label: string) {
    this.keep(40);
    this.y -= 14;
    const w = tracked(this.page, label, MARGIN, this.y, 6.8, this.fonts.bold, C.label, CAPS);
    rule(this.page, this.y + 2.4, { x: MARGIN + w + 10, length: CONTENT - w - 10 });
    this.y -= 8;
  }
}

// ---------------------------------------------------------------- blocks
/**
 * The mark and the name on the left; on the right what the document is, its
 * number, and that it is self-billed -- a mention the law requires, so it sits
 * where the eye looks first.
 */
function header(L: Layout, doc: InvoiceDocument) {
  const { page, fonts } = L;
  const top = L.y, right = PAGE.width - MARGIN;
  logo(page, MARGIN, top - 1, 20, C.navy);
  tracked(page, "TRINITY ÉNERGIE", MARGIN + 29, top - 13, 10, fonts.display, C.navy, 2.4);
  if (doc.customer) {
    const c = doc.customer;
    page.drawText(`${c.address}, ${c.postal_code} ${c.city}`,
      { x: MARGIN, y: top - 35, size: 8, font: fonts.body, color: C.grey });
  }

  const kind = title(doc);
  tracked(page, kind, right - trackedWidth(kind, 20, fonts.display, 1.5), top - 15, 20, fonts.display, C.navy, 1.5);
  const number = `N° ${doc.number}`;
  page.drawText(number, { x: right - fonts.bold.widthOfTextAtSize(number, 10), y: top - 33,
    size: 10, font: fonts.bold, color: C.navy });
  const lines = [doc.kind === "credit_note" ? "Avoir en autofacturation" : "Autofacturation"];
  if (doc.kind === "credit_note" && doc.corrects_number) lines.push(`Avoir sur la facture n° ${doc.corrects_number}`);
  let y = top - 46;
  for (const line of lines) {
    page.drawText(line, { x: right - fonts.body.widthOfTextAtSize(line, 8), y, size: 8, font: fonts.body, color: C.grey });
    y -= 12;
  }
  L.y = y - 5;
  rule(page, L.y);
  L.y -= 14;
}

/**
 * When it was issued, when it is due, how it is paid, how much: four facts in
 * one row, all in the same voice. The amount is not singled out here; the
 * totals below are where it carries weight.
 */
function keyFacts(L: Layout, doc: InvoiceDocument) {
  const { page, fonts } = L;
  const facts: [string, string][] = [
    ["DATE D'ÉMISSION", doc.issued_on],
    ["ÉCHÉANCE", doc.due_on ?? "À réception"],
    ["RÈGLEMENT", doc.payment_method],
    [doc.kind === "credit_note" ? "MONTANT À DÉDUIRE" : "MONTANT TTC", money(doc.amount.ttc, doc.amount.currency)],
  ];
  const column = CONTENT / 4, right = MARGIN + CONTENT;
  facts.forEach(([label, value], i) => {
    const last = i === facts.length - 1;
    const labelX = last ? right - trackedWidth(label, 6.6, fonts.bold, CAPS) : MARGIN + i * column;
    const valueX = last ? right - fonts.bold.widthOfTextAtSize(value, 10.5) : MARGIN + i * column;
    tracked(page, label, labelX, L.y - 5.5, 6.6, fonts.bold, C.label, CAPS);
    page.drawText(value, { x: valueX, y: L.y - 21, size: 10.5, font: fonts.bold, color: C.navy });
  });
  L.y -= 34;
  rule(page, L.y);
  L.y -= 16;
}

function supplierLines(doc: InvoiceDocument): string[] {
  const p = doc.apporteur;
  const lines = [p.company, p.legal_form, p.address,
    [p.postal_code, p.city].filter(Boolean).join(" "),
    p.siret ? `SIRET ${p.siret}` : null, p.vat_number ? `TVA ${p.vat_number}` : null];
  return lines.filter((l): l is string => !!l && l.trim() !== "");
}

function customerLines(doc: InvoiceDocument): { name: string; lines: string[] } {
  const c = doc.customer;
  if (!c) {
    // issued before the company's legal identity was recorded
    return { name: doc.issuer.company ?? doc.issuer.name, lines: [doc.issuer.city].filter((l): l is string => !!l) };
  }
  const form = [c.legal_form, c.share_capital ? `au capital de ${c.share_capital}` : null].filter(Boolean).join(" ");
  return {
    name: c.legal_name,
    lines: [form, c.address, `${c.postal_code} ${c.city}`,
      `SIREN ${c.siren}${c.rcs_city ? ` · RCS ${c.rcs_city}` : ""}`,
      c.vat_number ? `TVA ${c.vat_number}` : ""].filter((l) => l.trim() !== ""),
  };
}

/** The two parties side by side, as columns of text rather than cards. */
function parties(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const gap = 28, w = (CONTENT - gap) / 2, size = 8.6, leading = 12.2;
  const customer = customerLines(doc);
  const columns = [
    { label: "FOURNISSEUR · APPORTEUR", name: doc.apporteur.name, lines: supplierLines(doc) },
    { label: "CLIENT", name: customer.name, lines: customer.lines },
  ];
  const measure = (c: typeof columns[number]) =>
    13 + wrap(c.name, fonts.bold, 10.5, w).length * 14 +
    c.lines.reduce((n, l) => n + wrap(l, fonts.body, size, w).length, 0) * leading;
  const h = Math.max(...columns.map(measure));
  L.keep(h);
  columns.forEach((c, i) => {
    const x = MARGIN + i * (w + gap);
    tracked(L.page, c.label, x, L.y - 5.5, 6.6, fonts.bold, C.label, CAPS);
    let y = L.y - 13;
    for (const line of wrap(c.name, fonts.bold, 10.5, w)) {
      y -= 14;
      L.page.drawText(line, { x, y: y + 3, size: 10.5, font: fonts.bold, color: C.navy });
    }
    for (const text of c.lines) {
      for (const line of wrap(text, fonts.body, size, w)) {
        y -= leading;
        L.page.drawText(line, { x, y: y + 3, size, font: fonts.body, color: C.grey });
      }
    }
  });
  L.y -= h + 24;
}

/** Désignation · Qté · Prix unitaire HT · Montant HT, under a navy rule. */
function lineItems(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const totalRight = MARGIN + CONTENT, unitRight = totalRight - 96, qtyRight = unitRight - 96;
  const designationWidth = qtyRight - MARGIN - 40;

  const headerRow = () => {
    L.keep(60);
    const y = L.y - 5.5;
    tracked(L.page, "DÉSIGNATION", MARGIN, y, 6.6, fonts.bold, C.label, CAPS);
    for (const [label, right] of [["QTÉ", qtyRight], ["PRIX UNIT. HT", unitRight], ["MONTANT HT", totalRight]] as const) {
      tracked(L.page, label, right - trackedWidth(label, 6.6, fonts.bold, CAPS), y, 6.6, fonts.bold, C.label, CAPS);
    }
    rule(L.page, L.y - 13, { color: C.navy, thickness: 0.9 });
    L.y -= 22;
  };
  headerRow();

  const amount = money(doc.amount.ht, doc.amount.currency);
  const size = 9.5, leading = 13.5;
  const flushRight = (text: string, right: number) => right - fonts.body.widthOfTextAtSize(text, size);
  wrap(doc.attestation.prestation, fonts.bold, size, designationWidth).forEach((line, i) => {
    if (L.y - leading < L.bottom) { L.newPage(); headerRow(); }
    L.y -= leading;
    L.page.drawText(line, { x: MARGIN, y: L.y + 3, size, font: fonts.bold, color: C.navy });
    if (i === 0) {
      L.page.drawText("1", { x: flushRight("1", qtyRight), y: L.y + 3, size, font: fonts.body, color: C.ink });
      L.page.drawText(amount, { x: flushRight(amount, unitRight), y: L.y + 3, size, font: fonts.body, color: C.ink });
      L.page.drawText(amount, { x: flushRight(amount, totalRight), y: L.y + 3, size, font: fonts.body, color: C.ink });
    }
  });
  L.text(`Mise en relation avec ${doc.attestation.avec}, intervenue le ${doc.attestation.intervenue_le}.`,
    { width: designationWidth, size: 8, color: C.grey });
  L.y -= 8;
  rule(L.page, L.y);
  L.y -= 14;
}

/** Totals flush right, the last under a navy rule; payment terms on the left. */
function totals(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const cur = doc.amount.currency;
  const w = 200, x = MARGIN + CONTENT - w, right = MARGIN + CONTENT;
  const rows: [string, string][] = [
    ["Total HT", money(doc.amount.ht, cur)],
    [`TVA (${String(doc.amount.vat_rate).replace(".", ",")} %)`, money(doc.amount.vat, cur)],
  ];
  const leftWidth = CONTENT - w - 40;
  const terms = [
    `Règlement : ${doc.payment_method}${doc.due_on ? `, au plus tard le ${doc.due_on}` : ""}.`,
    `Fait à ${doc.place}, le ${doc.issued_on}.`,
  ];
  const termLines = terms.flatMap((t) => wrap(t, fonts.body, 8, leftWidth));
  L.keep(Math.max(rows.length * 16 + 34, termLines.length * 11.5));
  const top = L.y;

  let ty = top;
  for (const line of termLines) {
    ty -= 11.5;
    L.page.drawText(line, { x: MARGIN, y: ty + 3, size: 8, font: fonts.body, color: C.grey });
  }

  let y = top;
  for (const [label, value] of rows) {
    y -= 16;
    L.page.drawText(label, { x, y: y + 4, size: 9, font: fonts.body, color: C.grey });
    L.page.drawText(value, { x: right - fonts.body.widthOfTextAtSize(value, 9), y: y + 4, size: 9,
      font: fonts.body, color: C.grey });
  }
  y -= 3;
  rule(L.page, y, { x, length: w, color: C.navy, thickness: 1.2 });
  y -= 7;
  const label = doc.kind === "credit_note" ? "Total TTC à déduire" : "Total TTC";
  const value = money(doc.amount.ttc, cur);
  L.page.drawText(label, { x, y: y - 11, size: 10.5, font: fonts.bold, color: C.navy });
  L.page.drawText(value, { x: right - fonts.display.widthOfTextAtSize(value, 13), y: y - 11.5, size: 13,
    font: fonts.display, color: C.navy });
  L.y = Math.min(y - 22, ty) - 14;
}

/**
 * The self-billing sentence with the article that allows it, the VAT regime
 * and the late-payment terms: plain text under one heading, as an accountant
 * would set them, rather than a highlighted box.
 */
function mentions(L: Layout, doc: InvoiceDocument) {
  L.heading("MENTIONS LÉGALES");
  if (doc.self_billing_mention) L.text(doc.self_billing_mention, { size: 8, color: C.grey });
  L.text(doc.legal_mentions, { size: 8, color: C.grey });
  if (doc.late_payment_mention) L.text(doc.late_payment_mention, { size: 8, color: C.grey });
  if (doc.kind !== "credit_note") {
    L.space(6);
    L.heading("ATTESTATION");
    L.text(`Je soussigné(e) ${doc.attestation.soussigne} atteste avoir mis en relation ` +
      `${doc.attestation.mis_en_relation ?? "la société"} avec ${doc.attestation.avec} ` +
      `pour la prestation ci-dessus.`, { size: 8.6 });
  }
  if (doc.tax_notice) {
    L.space(6);
    L.text(doc.tax_notice, { size: 7.8, color: C.faint });
  }
  L.space(4);
}

/**
 * One column per party under a rule -- navy once signed, pale while awaited --
 * with the state said in words rather than shown as a pill.
 */
function signatures(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const gap = 28, w = (CONTENT - gap) / 2, h = 74;
  L.keep(h + 24);   // the heading stays with its columns
  L.heading("SIGNATURES ÉLECTRONIQUES");
  L.y -= 2;
  doc.signatures.slice(0, 2).forEach((s, i) => {
    const x = MARGIN + i * (w + gap);
    rule(L.page, L.y, { x, length: w, color: s.signed ? C.navy : C.pending, thickness: 1.2 });
    tracked(L.page, s.role === "apporteur" ? "L'APPORTEUR" : "L'ENTREPRISE", x, L.y - 13.5, 6.6,
      fonts.bold, C.label, CAPS);
    L.page.drawText(s.name, { x, y: L.y - 29, size: 10.5, font: fonts.bold, color: C.navy });

    const statusTop = L.y - 38, baseline = L.y - 44.5;
    if (s.signed) {
      tick(L.page, x, statusTop - 1.5, C.navy);
      L.page.drawText(s.signed_at ? `Signé électroniquement le ${parisDateTime(s.signed_at)}` : "Signé électroniquement",
        { x: x + 11, y: baseline, size: 8, font: fonts.bold, color: C.navy });
      const evidence = [s.sms_verified ? `Code SMS vérifié · ${s.sms_phone ?? ""}`.trim() : "Session authentifiée",
        "Heure de Paris · art. 1367 du Code civil"];
      evidence.forEach((line, j) => {
        L.page.drawText(line, { x: x + 11, y: baseline - 12 - j * 11, size: 7.8, font: fonts.body, color: C.grey });
      });
    } else {
      ring(L.page, x, statusTop - 1.5, C.faint);
      L.page.drawText("En attente de signature", { x: x + 11, y: baseline, size: 8, font: fonts.body, color: C.grey });
    }
  });
  L.y -= h;
}

/** On every page, once their number is known. */
function footers(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const total = L.pages.length;
  const label = `${title(doc) === "AVOIR" ? "Avoir" : "Facture"} ${doc.number}`;
  const digest = doc.document_sha256
    ? (doc.document_sha256.match(/.{1,8}/g) ?? []).join(" ")
    : "document non scellé";
  const prefix = "Empreinte SHA-256 du document signé : ";
  L.pages.forEach((page, i) => {
    rule(page, FOOTER_TOP);
    page.drawText(`${label} · Trinity Énergie`, { x: MARGIN, y: FOOTER_TOP - 16, size: 7.2, font: fonts.body, color: C.grey });
    const pageLabel = `Page ${i + 1} / ${total}`;
    page.drawText(pageLabel, { x: PAGE.width - MARGIN - fonts.body.widthOfTextAtSize(pageLabel, 7.2),
      y: FOOTER_TOP - 16, size: 7.2, font: fonts.body, color: C.grey });
    // the digest apart from its label, in groups of eight that can be read out
    page.drawText(prefix, { x: MARGIN, y: FOOTER_TOP - 30, size: 6.6, font: fonts.body, color: C.faint });
    page.drawText(digest, { x: MARGIN + fonts.body.widthOfTextAtSize(prefix, 6.6), y: FOOTER_TOP - 30, size: 6.6,
      font: fonts.bold, color: C.grey });
  });
}

// ------------------------------------------------------------------ main
export interface RenderOptions {
  /** Fixed for reproducible output in tests; the issue date otherwise. */
  creationDate?: Date;
}

/** The PDF document, open for the caller to finish (Factur-X attaches to it). */
export async function buildInvoicePdf(doc: InvoiceDocument, options: RenderOptions = {}): Promise<PDFDocument> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const fonts: Fonts = {
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
  pdf.setKeywords([doc.number, "autofacturation", "apport d'affaires"]);
  pdf.setLanguage("fr-FR");
  const created = options.creationDate ?? new Date();
  pdf.setCreationDate(created);
  pdf.setModificationDate(created);

  const L = new Layout(pdf, fonts, `${title(doc)} N° ${doc.number} — SUITE`);
  L.newPage(true);
  header(L, doc);
  keyFacts(L, doc);
  parties(L, doc);
  lineItems(L, doc);
  totals(L, doc);
  mentions(L, doc);
  signatures(L, doc);
  footers(L, doc);
  return pdf;
}

/** One line per party: who, and how they signed -- with what proves it. */
export function signatureLine(s: Signature): string {
  const who = s.role === "apporteur" ? "Signature de l'apporteur" : "Signature de l'entreprise";
  const state = s.signed
    ? `signé électroniquement${s.signed_at ? ` le ${frenchDate(s.signed_at)}` : ""}`
      + (s.sms_verified ? `, code SMS vérifié${s.sms_phone ? ` (${s.sms_phone})` : ""}` : "")
    : "en attente";
  return `${who} — ${s.name} — ${state}`;
}

export async function renderInvoicePdf(doc: InvoiceDocument, options: RenderOptions = {}): Promise<Uint8Array> {
  return await (await buildInvoicePdf(doc, options)).save();
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

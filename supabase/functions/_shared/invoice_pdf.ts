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
const C = {
  navy: hex(0x0A1F4A),
  brand: hex(0x1F5FFF),
  mark: hex(0x3C8BFF),
  ice: hex(0xC3D7FF),
  ink: hex(0x0E1630),
  grey: hex(0x5B6478),
  faint: hex(0x8A93A6),
  tint: hex(0xF3F6FC),
  tintBlue: hex(0xEAF1FF),
  border: hex(0xDDE4F0),
  white: rgb(1, 1, 1),
  green: hex(0x0E9F6E),
  greenTint: hex(0xE3F6EE),
  amber: hex(0xB7791F),
  amberTint: hex(0xFBF1DE),
};

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
/** A rounded rectangle given by its top-left corner (y measured upward). */
function box(page: PDFPage, x: number, top: number, w: number, h: number,
             opts: { fill?: RGB; stroke?: RGB; radius?: number; strokeWidth?: number }) {
  const r = Math.min(opts.radius ?? 8, h / 2, w / 2);
  const path = `M ${r} 0 H ${w - r} Q ${w} 0 ${w} ${r} V ${h - r} Q ${w} ${h} ${w - r} ${h} ` +
    `H ${r} Q 0 ${h} 0 ${h - r} V ${r} Q 0 0 ${r} 0 Z`;
  page.drawSvgPath(path, {
    x, y: top, color: opts.fill, borderColor: opts.stroke,
    borderWidth: opts.stroke ? (opts.strokeWidth ?? 0.75) : undefined,
  });
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

  /** A small letter-spaced section heading with a hairline after it. */
  heading(label: string) {
    this.keep(40);
    this.y -= 14;
    const w = tracked(this.page, label, MARGIN, this.y, 7.5, this.fonts.bold, C.brand, 0.45);
    this.page.drawLine({
      start: { x: MARGIN + w + 10, y: this.y + 2.6 }, end: { x: PAGE.width - MARGIN, y: this.y + 2.6 },
      thickness: 0.5, color: C.border,
    });
    this.y -= 8;
  }
}

// ---------------------------------------------------------------- blocks
function header(L: Layout, doc: InvoiceDocument) {
  const { page, fonts } = L;
  const band = 100;
  page.drawRectangle({ x: 0, y: PAGE.height - band, width: PAGE.width, height: band, color: C.navy });
  // a quiet sweep of brand blue across the band's right side
  page.drawSvgPath(`M ${PAGE.width * 0.55} 0 L ${PAGE.width} 0 L ${PAGE.width} ${band} L ${PAGE.width * 0.72} ${band} Z`,
    { x: 0, y: PAGE.height, color: C.brand, opacity: 0.16 });
  page.drawRectangle({ x: 0, y: PAGE.height - band - 3, width: PAGE.width, height: 3, color: C.brand });

  const top = PAGE.height - 30;
  logo(page, MARGIN, top + 4, 26, C.white);
  tracked(page, "TRINITY ÉNERGIE", MARGIN + 36, top - 15, 10.5, fonts.display, C.white, 2.4);
  page.drawText(doc.kind === "credit_note"
    ? "Avoir en autofacturation"
    : "Autofacturation · établie au nom et pour le compte de l'apporteur", {
    x: MARGIN, y: top - 40, size: 8, font: fonts.body, color: C.ice,
  });

  const kind = title(doc);
  const kindWidth = trackedWidth(kind, 22, fonts.display, 1.5);
  tracked(page, kind, PAGE.width - MARGIN - kindWidth, top - 18, 22, fonts.display, C.white, 1.5);
  const number = `N° ${doc.number}`;
  page.drawText(number, {
    x: PAGE.width - MARGIN - fonts.bold.widthOfTextAtSize(number, 11), y: top - 40,
    size: 11, font: fonts.bold, color: C.ice,
  });
  if (doc.kind === "credit_note" && doc.corrects_number) {
    const ref = `sur la facture n° ${doc.corrects_number}`;
    page.drawText(ref, {
      x: PAGE.width - MARGIN - fonts.body.widthOfTextAtSize(ref, 8), y: top - 54,
      size: 8, font: fonts.body, color: C.ice,
    });
  }
  L.y = PAGE.height - band - 3 - 18;
}

/** Three tiles: when it was issued, when it is due, how much. */
function keyFacts(L: Layout, doc: InvoiceDocument) {
  const { page, fonts } = L;
  const gap = 10, h = 48, w = (CONTENT - gap * 2) / 3;
  const tiles: [string, string, boolean][] = [
    ["DATE D'ÉMISSION", doc.issued_on, false],
    ["ÉCHÉANCE", doc.due_on ?? "À réception", false],
    [doc.kind === "credit_note" ? "MONTANT À DÉDUIRE" : "MONTANT TTC", money(doc.amount.ttc, doc.amount.currency), true],
  ];
  tiles.forEach(([label, value, strong], i) => {
    const x = MARGIN + i * (w + gap);
    box(page, x, L.y, w, h, strong ? { fill: C.brand, radius: 10 } : { fill: C.tint, radius: 10 });
    tracked(page, label, x + 14, L.y - 17, 6.8, fonts.bold, strong ? C.ice : C.faint, 0.4);
    page.drawText(value, { x: x + 14, y: L.y - 35, size: strong ? 15 : 12.5, font: strong ? fonts.display : fonts.bold,
      color: strong ? C.white : C.ink });
  });
  L.y -= h + 14;
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

/** The two parties, as cards side by side. */
function parties(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const gap = 12, w = (CONTENT - gap) / 2, pad = 14, size = 8.6, leading = 12.4;
  const inner = w - pad * 2;
  const customer = customerLines(doc);
  const cards = [
    { label: "FOURNISSEUR · APPORTEUR", name: doc.apporteur.name, lines: supplierLines(doc) },
    { label: "CLIENT", name: customer.name, lines: customer.lines },
  ];
  const measure = (c: typeof cards[number]) =>
    pad + 14 + wrap(c.name, fonts.bold, 10.5, inner).length * 14 +
    c.lines.reduce((n, l) => n + wrap(l, fonts.body, size, inner).length, 0) * leading + pad;
  const h = Math.max(...cards.map(measure));
  L.keep(h);
  cards.forEach((c, i) => {
    const x = MARGIN + i * (w + gap);
    box(L.page, x, L.y, w, h, { fill: C.white, stroke: C.border, radius: 10 });
    tracked(L.page, c.label, x + pad, L.y - pad - 6, 6.8, fonts.bold, C.brand, 0.4);
    let y = L.y - pad - 14;
    for (const line of wrap(c.name, fonts.bold, 10.5, inner)) {
      y -= 14;
      L.page.drawText(line, { x: x + pad, y: y + 3, size: 10.5, font: fonts.bold, color: C.ink });
    }
    for (const text of c.lines) {
      for (const line of wrap(text, fonts.body, size, inner)) {
        y -= leading;
        L.page.drawText(line, { x: x + pad, y: y + 3, size, font: fonts.body, color: C.grey });
      }
    }
  });
  L.y -= h + 12;
}

/** A line of emphasis with a brand bar on its left. */
function callout(L: Layout, text: string) {
  const size = 8.4, leading = 11.8, pad = 10;
  const lines = wrap(text, L.fonts.bold, size, CONTENT - 28);
  const h = lines.length * leading + pad * 2 - 2;
  L.keep(h);
  box(L.page, MARGIN, L.y, CONTENT, h, { fill: C.tintBlue, radius: 6 });
  L.page.drawRectangle({ x: MARGIN, y: L.y - h, width: 3, height: h, color: C.brand });
  let y = L.y - pad + 1;
  for (const line of lines) {
    y -= leading;
    L.page.drawText(line, { x: MARGIN + 16, y: y + 3, size, font: L.fonts.bold, color: C.navy });
  }
  L.y -= h + 12;
}

/** Désignation · Qté · Prix unitaire HT · Montant HT. */
function lineItems(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const cur = doc.amount.currency;
  const col = { qty: MARGIN + CONTENT - 210, unit: MARGIN + CONTENT - 150, total: MARGIN + CONTENT - 12 };
  const designationWidth = col.qty - MARGIN - 24;

  const headerRow = () => {
    L.keep(60);
    box(L.page, MARGIN, L.y, CONTENT, 24, { fill: C.navy, radius: 6 });
    const y = L.y - 15.5;
    tracked(L.page, "DÉSIGNATION", MARGIN + 12, y, 7, fonts.bold, C.white, 0.4);
    tracked(L.page, "QTÉ", col.qty, y, 7, fonts.bold, C.white, 0.4);
    tracked(L.page, "PRIX UNIT. HT", col.unit, y, 7, fonts.bold, C.white, 0.4);
    const label = "MONTANT HT";
    tracked(L.page, label, col.total - trackedWidth(label, 7, fonts.bold, 0.4), y, 7, fonts.bold, C.white, 0.4);
    L.y -= 24;
  };
  headerRow();

  const amount = money(doc.amount.ht, cur);
  const size = 9.5, leading = 13.5;
  L.y -= 8;
  wrap(doc.attestation.prestation, fonts.bold, size, designationWidth).forEach((line, i) => {
    if (L.y - leading < L.bottom) { L.newPage(); headerRow(); L.y -= 8; }
    L.y -= leading;
    L.page.drawText(line, { x: MARGIN + 12, y: L.y + 3, size, font: fonts.bold, color: C.ink });
    if (i === 0) {
      L.page.drawText("1", { x: col.qty + 4, y: L.y + 3, size, font: fonts.body, color: C.ink });
      L.page.drawText(amount, { x: col.unit, y: L.y + 3, size, font: fonts.body, color: C.ink });
      L.page.drawText(amount, { x: col.total - fonts.bold.widthOfTextAtSize(amount, size), y: L.y + 3,
        size, font: fonts.bold, color: C.ink });
    }
  });
  L.text(`Mise en relation avec ${doc.attestation.avec}, intervenue le ${doc.attestation.intervenue_le}.`,
    { x: MARGIN + 12, width: designationWidth, size: 8, color: C.grey });
  L.y -= 10;
  L.page.drawLine({ start: { x: MARGIN, y: L.y }, end: { x: MARGIN + CONTENT, y: L.y }, thickness: 0.75, color: C.border });
  L.y -= 14;
}

/** Totals, flush right, ending on a navy band. Payment terms on the left. */
function totals(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const cur = doc.amount.currency;
  const w = 228, x = MARGIN + CONTENT - w;
  const rows: [string, string][] = [
    ["Total HT", money(doc.amount.ht, cur)],
    [`TVA (${String(doc.amount.vat_rate).replace(".", ",")} %)`, money(doc.amount.vat, cur)],
  ];
  const leftWidth = CONTENT - w - 24;
  const terms = [
    `Règlement : ${doc.payment_method}${doc.due_on ? `, au plus tard le ${doc.due_on}` : ""}.`,
    `Fait à ${doc.place}, le ${doc.issued_on}.`,
  ];
  const termLines = terms.flatMap((t) => wrap(t, fonts.body, 8, leftWidth));
  const h = rows.length * 20 + 34;
  L.keep(Math.max(h, termLines.length * 11.5 + 18));
  const top = L.y;

  tracked(L.page, "CONDITIONS", MARGIN, top - 8, 6.8, fonts.bold, C.brand, 0.4);
  let ty = top - 12;
  for (const line of termLines) {
    ty -= 11.5;
    L.page.drawText(line, { x: MARGIN, y: ty, size: 8, font: fonts.body, color: C.grey });
  }

  let y = top;
  for (const [label, value] of rows) {
    y -= 20;
    L.page.drawText(label, { x: x + 12, y: y + 6, size: 9.5, font: fonts.body, color: C.grey });
    L.page.drawText(value, { x: x + w - 12 - fonts.body.widthOfTextAtSize(value, 9.5), y: y + 6, size: 9.5,
      font: fonts.body, color: C.ink });
  }
  y -= 6;
  box(L.page, x, y, w, 30, { fill: C.navy, radius: 8 });
  const label = doc.kind === "credit_note" ? "Total TTC à déduire" : "Total TTC";
  const value = money(doc.amount.ttc, cur);
  L.page.drawText(label, { x: x + 12, y: y - 19.5, size: 10, font: fonts.bold, color: C.white });
  L.page.drawText(value, { x: x + w - 12 - fonts.display.widthOfTextAtSize(value, 13), y: y - 20.5, size: 13,
    font: fonts.display, color: C.white });
  L.y = Math.min(y - 30, ty) - 10;
}

function mentions(L: Layout, doc: InvoiceDocument) {
  L.heading("MENTIONS LÉGALES");
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

/** One panel per party: who signed, when, and what proves it. */
function signatures(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const gap = 12, w = (CONTENT - gap) / 2, pad = 14, h = 96;
  L.keep(h + 24);   // the heading stays with its panels
  L.heading("SIGNATURES ÉLECTRONIQUES");
  doc.signatures.slice(0, 2).forEach((s, i) => {
    const x = MARGIN + i * (w + gap);
    box(L.page, x, L.y, w, h, { fill: s.signed ? C.white : C.tint, stroke: C.border, radius: 10 });
    tracked(L.page, s.role === "apporteur" ? "L'APPORTEUR" : "L'ENTREPRISE", x + pad, L.y - pad - 6, 6.8,
      fonts.bold, C.faint, 0.4);

    // the state, as a pill on the right
    const pill = s.signed ? "Signé" : "En attente";
    const pw = fonts.bold.widthOfTextAtSize(pill, 7.5) + 22;
    box(L.page, x + w - pad - pw, L.y - pad + 3, pw, 16, { fill: s.signed ? C.greenTint : C.amberTint, radius: 8 });
    L.page.drawCircle({ x: x + w - pad - pw + 9, y: L.y - pad - 5, size: 2.4, color: s.signed ? C.green : C.amber });
    L.page.drawText(pill, { x: x + w - pad - pw + 15, y: L.y - pad - 7.6, size: 7.5, font: fonts.bold,
      color: s.signed ? C.green : C.amber });

    L.page.drawText(s.name, { x: x + pad, y: L.y - pad - 30, size: 11, font: fonts.bold, color: C.ink });
    const evidence = s.signed
      ? [s.signed_at ? `Le ${parisDateTime(s.signed_at)} (heure de Paris)` : "Signé électroniquement",
         s.sms_verified ? `Code SMS vérifié · ${s.sms_phone ?? ""}`.trim() : "Session authentifiée",
         "Signature électronique · art. 1367 C. civ."]
      : ["Signature attendue"];
    evidence.forEach((line, j) => {
      L.page.drawText(line, { x: x + pad, y: L.y - pad - 48 - j * 12.5, size: 8, font: fonts.body,
        color: j === 1 && s.sms_verified ? C.green : C.grey });
    });
  });
  L.y -= h + 10;
}

/** On every page, once their number is known. */
function footers(L: Layout, doc: InvoiceDocument) {
  const { fonts } = L;
  const total = L.pages.length;
  const label = `${title(doc) === "AVOIR" ? "Avoir" : "Facture"} ${doc.number}`;
  const digest = doc.document_sha256
    ? (doc.document_sha256.match(/.{1,8}/g) ?? []).join(" ")
    : "document non scellé";
  L.pages.forEach((page, i) => {
    page.drawLine({ start: { x: MARGIN, y: FOOTER_TOP }, end: { x: PAGE.width - MARGIN, y: FOOTER_TOP },
      thickness: 0.5, color: C.border });
    logo(page, MARGIN, FOOTER_TOP - 9, 9, C.navy);
    page.drawText(`${label} · Trinity Énergie`, { x: MARGIN + 14, y: FOOTER_TOP - 16, size: 7.2, font: fonts.bold, color: C.grey });
    const pageLabel = `Page ${i + 1} / ${total}`;
    page.drawText(pageLabel, { x: PAGE.width - MARGIN - fonts.bold.widthOfTextAtSize(pageLabel, 7.2),
      y: FOOTER_TOP - 16, size: 7.2, font: fonts.bold, color: C.grey });
    page.drawText(`Empreinte SHA-256 du document signé : ${digest}`, {
      x: MARGIN, y: FOOTER_TOP - 30, size: 6.4, font: fonts.body, color: C.faint,
    });
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
  if (doc.self_billing_mention) callout(L, doc.self_billing_mention);
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

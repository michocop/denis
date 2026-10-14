// The apporteur's signed contract, as the PDF the company files and both
// parties can open: the contract, the billing mandate as its annex, and a
// signature certificate saying who signed, as what, when, from which verified
// mobile, and the digest of each text -- which is what the signature binds.
//
// Same paper as the invoices (_shared/invoice_pdf.ts): white page, navy for
// what matters, grey for the rest, hairlines for structure.

import { PDFDocument, PDFFont, PDFPage, rgb, RGB } from "npm:pdf-lib@1.17.1";
import fontkit from "npm:@pdf-lib/fontkit@1.1.1";
import { fontBytes, manropeBold, manropeRegular, soraSemiBold } from "./fonts.ts";
import { wrap } from "./invoice_pdf.ts";

export interface ContractDocument {
  id: string;
  signed_at: string;
  business_status: "societe" | "independant";
  signer: {
    name: string;
    email: string;
    company?: string | null;
    legal_form?: string | null;
    siret: string;
    address: string;
    postal_code: string;
    city: string;
  };
  evidence: {
    sms_verified: boolean;
    sms_phone?: string | null;
    ip_address?: string | null;
    user_agent?: string | null;
  };
  contract: { title: string; version: string; sha256: string; body: string };
  mandate: { title: string; version: string; sha256: string; body: string };
  company?: {
    legal_name: string;
    legal_form?: string | null;
    share_capital?: string | null;
    siren: string;
    rcs_city?: string | null;
    address: string;
    postal_code: string;
    city: string;
  } | null;
  pdf_path?: string | null;
}

const PAGE = { width: 595.28, height: 841.89 };
const MARGIN = 50;
const CONTENT = PAGE.width - MARGIN * 2;
const FOOTER_TOP = 54;
const CAPS = 0.2;

const hex = (h: number) => rgb(((h >> 16) & 255) / 255, ((h >> 8) & 255) / 255, (h & 255) / 255);
const C = {
  navy: hex(0x0A1F4A),
  mark: hex(0x3C8BFF),
  ink: hex(0x1C2333),
  grey: hex(0x5B6478),
  label: hex(0x6B7385),
  faint: hex(0x8A93A6),
  rule: hex(0xE3E7EF),
};

type Fonts = { body: PDFFont; bold: PDFFont; display: PDFFont };

/** "14.10.2026 à 16:07", in Paris time, where the parties are. */
export function parisDateTime(iso: string): string {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris", day: "2-digit", month: "2-digit", year: "numeric",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(new Date(iso)).map((p) => [p.type, p.value]));
  return `${parts.day}.${parts.month}.${parts.year} à ${parts.hour}:${parts.minute}:${parts.second}`;
}

/** "123 456 789 00012": a SIRET as it is read out. */
export function groupedSiret(siret: string): string {
  const d = siret.replace(/\D/g, "");
  return d.length === 14 ? `${d.slice(0, 3)} ${d.slice(3, 6)} ${d.slice(6, 9)} ${d.slice(9)}` : siret;
}

export function statusLabel(status: ContractDocument["business_status"]): string {
  return status === "societe" ? "Société" : "Indépendant";
}

/** A short reference to quote on the phone: the first block of the id. */
export function reference(id: string): string {
  return `CT-${id.slice(0, 8).toUpperCase()}`;
}

// ------------------------------------------------------- legal text model
export type Block =
  | { kind: "heading"; text: string }
  | { kind: "paragraph"; text: string; strong: boolean }
  | { kind: "bullets"; items: string[] };

/**
 * The texts are written in the small Markdown the app renders (LegalText):
 * "## " headings, "- " bullets, **bold**. Lines inside a paragraph are wrapped
 * by hand in the source, so they are joined back before setting them anew.
 */
export function parseLegalText(body: string): Block[] {
  const blocks: Block[] = [];
  for (const raw of body.replace(/\r/g, "").split(/\n\s*\n/)) {
    const lines = raw.split("\n").filter((l) => l.trim() !== "");
    if (lines.length === 0) continue;
    if (lines[0].startsWith("## ")) {
      blocks.push({ kind: "heading", text: clean(lines[0].slice(3)) });
      if (lines.length > 1) blocks.push(...parseLegalText(lines.slice(1).join("\n")));
      continue;
    }
    if (lines[0].trimStart().startsWith("- ")) {
      const items: string[] = [];
      for (const line of lines) {
        if (line.trimStart().startsWith("- ")) items.push(line.trimStart().slice(2).trim());
        else if (items.length) items[items.length - 1] += " " + line.trim();
      }
      blocks.push({ kind: "bullets", items: items.map(clean) });
      continue;
    }
    const text = lines.map((l) => l.trim()).join(" ");
    const strong = /^\*\*[^*]+\*\*:?$/.test(text);
    blocks.push({ kind: "paragraph", text: clean(text), strong });
  }
  return blocks;
}

function clean(text: string): string {
  return text.replace(/\*\*/g, "").trim();
}

// ---------------------------------------------------------------- drawing
function rule(page: PDFPage, y: number, o: { x?: number; length?: number; color?: RGB; thickness?: number } = {}) {
  const x = o.x ?? MARGIN;
  page.drawLine({ start: { x, y }, end: { x: x + (o.length ?? CONTENT), y },
    thickness: o.thickness ?? 0.5, color: o.color ?? C.rule });
}

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

function logo(page: PDFPage, x: number, top: number, size: number) {
  const s = size / 24;
  page.drawSvgPath("M 12 1.25 L 22.5 20.75 L 1.5 20.75 Z", { x, y: top, scale: s, borderColor: C.navy, borderWidth: 1.8 });
  page.drawSvgPath("M 12 8.75 L 16.5 17 L 7.5 17 Z", { x, y: top, scale: s, color: C.mark });
}

function tick(page: PDFPage, x: number, top: number) {
  page.drawSvgPath("M 0 3.4 L 2.4 5.8 L 6.6 0.6", { x, y: top, borderColor: C.navy, borderWidth: 1.1 });
}

class Layout {
  page!: PDFPage;
  y = 0;
  readonly pages: PDFPage[] = [];
  continuation = "";

  constructor(private pdf: PDFDocument, readonly fonts: Fonts) {}

  newPage(first = false) {
    this.page = this.pdf.addPage([PAGE.width, PAGE.height]);
    this.pages.push(this.page);
    this.y = PAGE.height - MARGIN;
    if (!first && this.continuation) {
      tracked(this.page, this.continuation, MARGIN, this.y - 8, 7.2, this.fonts.bold, C.faint, 0.4);
      this.y -= 28;
    }
  }

  get bottom() { return FOOTER_TOP + 16; }

  keep(height: number) {
    if (this.y - height < this.bottom) this.newPage();
  }

  text(text: string, o: { font?: PDFFont; size?: number; color?: RGB; x?: number; width?: number; leading?: number } = {}) {
    const font = o.font ?? this.fonts.body;
    const size = o.size ?? 9;
    const leading = o.leading ?? size * 1.5;
    for (const line of wrap(text, font, size, o.width ?? CONTENT)) {
      this.keep(leading);
      this.y -= leading;
      this.page.drawText(line, { x: o.x ?? MARGIN, y: this.y + size * 0.28, size, font, color: o.color ?? C.ink });
    }
  }

  heading(label: string, o: { keep?: number } = {}) {
    this.keep(o.keep ?? 44);
    this.y -= 16;
    const w = tracked(this.page, label, MARGIN, this.y, 6.8, this.fonts.bold, C.label, CAPS);
    rule(this.page, this.y + 2.4, { x: MARGIN + w + 10, length: CONTENT - w - 10 });
    this.y -= 6;
  }
}

// ----------------------------------------------------------------- blocks
function header(L: Layout, doc: ContractDocument) {
  const { page, fonts } = L;
  const top = L.y, right = PAGE.width - MARGIN;
  logo(page, MARGIN, top - 1, 20);
  tracked(page, "TRINITY ÉNERGIE", MARGIN + 29, top - 13, 10, fonts.display, C.navy, 2.4);
  if (doc.company) {
    const c = doc.company;
    page.drawText(`${c.address}, ${c.postal_code} ${c.city}`, { x: MARGIN, y: top - 35, size: 8, font: fonts.body, color: C.grey });
  }
  const kind = "CONTRAT";
  tracked(page, kind, right - trackedWidth(kind, 20, fonts.display, 1.5), top - 15, 20, fonts.display, C.navy, 1.5);
  const sub = "d'apporteur d'affaires";
  page.drawText(sub, { x: right - fonts.bold.widthOfTextAtSize(sub, 10), y: top - 33, size: 10, font: fonts.bold, color: C.navy });
  const ref = `Réf. ${reference(doc.id)} · version ${doc.contract.version}`;
  page.drawText(ref, { x: right - fonts.body.widthOfTextAtSize(ref, 8), y: top - 46, size: 8, font: fonts.body, color: C.grey });
  L.y = top - 58;
  rule(page, L.y);
  L.y -= 14;
}

function keyFacts(L: Layout, doc: ContractDocument) {
  const { page, fonts } = L;
  const facts: [string, string][] = [
    ["SIGNÉ LE", parisDateTime(doc.signed_at).replace(/:\d\d$/, "")],
    ["STATUT", statusLabel(doc.business_status)],
    ["SIGNATURE", doc.evidence.sms_verified ? "Code SMS vérifié" : "Session authentifiée"],
  ];
  const column = CONTENT / facts.length;
  facts.forEach(([label, value], i) => {
    const x = MARGIN + i * column;
    tracked(page, label, x, L.y - 5.5, 6.6, fonts.bold, C.label, CAPS);
    page.drawText(value, { x, y: L.y - 21, size: 10.5, font: fonts.bold, color: C.navy });
  });
  L.y -= 34;
  rule(page, L.y);
  L.y -= 16;
}

function companyLines(doc: ContractDocument): { name: string; lines: string[] } {
  const c = doc.company;
  if (!c) return { name: "TRINITY ENERGIE", lines: [] };
  const form = [c.legal_form, c.share_capital ? `au capital de ${c.share_capital}` : null].filter(Boolean).join(" ");
  return {
    name: c.legal_name,
    lines: [form, c.address, `${c.postal_code} ${c.city}`,
      `SIREN ${c.siren}${c.rcs_city ? ` · RCS ${c.rcs_city}` : ""}`].filter((l) => l.trim() !== ""),
  };
}

function signerLines(doc: ContractDocument): { name: string; lines: string[] } {
  const s = doc.signer;
  const company = doc.business_status === "societe"
    ? [s.company, s.legal_form].filter(Boolean).join(", ")
    : ["Indépendant", s.legal_form].filter(Boolean).join(" · ");
  return {
    name: s.name,
    lines: [company, s.address, `${s.postal_code} ${s.city}`, `SIRET ${groupedSiret(s.siret)}`, s.email]
      .filter((l): l is string => !!l && l.trim() !== ""),
  };
}

function parties(L: Layout, doc: ContractDocument) {
  const { fonts } = L;
  const gap = 28, w = (CONTENT - gap) / 2, size = 8.6, leading = 12.2;
  const columns = [
    { label: "LA SOCIÉTÉ", ...companyLines(doc) },
    { label: "L'APPORTEUR", ...signerLines(doc) },
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
  L.y -= h + 20;
}

/** A legal text, set as an accountant would: small-capital article headings. */
function legalText(L: Layout, body: string) {
  const { fonts } = L;
  for (const block of parseLegalText(body)) {
    if (block.kind === "heading") {
      L.keep(48);
      L.y -= 10;
      L.text(block.text, { font: fonts.bold, size: 9.6, color: C.navy, leading: 14 });
      L.y -= 2;
    } else if (block.kind === "paragraph") {
      L.text(block.text, { font: block.strong ? fonts.bold : fonts.body, size: 8.8,
        color: block.strong ? C.navy : C.ink });
      L.y -= 5;
    } else {
      for (const item of block.items) {
        const lines = wrap(item, fonts.body, 8.8, CONTENT - 14);
        lines.forEach((line, i) => {
          L.keep(13.2);
          L.y -= 13.2;
          if (i === 0) L.page.drawText("—", { x: MARGIN, y: L.y + 2.5, size: 8.8, font: fonts.body, color: C.faint });
          L.page.drawText(line, { x: MARGIN + 14, y: L.y + 2.5, size: 8.8, font: fonts.body, color: C.ink });
        });
        L.y -= 2;
      }
      L.y -= 4;
    }
  }
}

function certificate(L: Layout, doc: ContractDocument) {
  const { fonts } = L;
  // after the annex on the same page when it fits whole, on its own otherwise
  if (L.y - 470 < L.bottom) L.newPage(); else { L.y -= 30; rule(L.page, L.y, { color: C.navy, thickness: 1.2 }); L.y -= 22; }
  L.y -= 4;
  // drawn whole, not letter-spaced: a search of the filed copy must find it
  L.page.drawText("Certificat de signature électronique", { x: MARGIN, y: L.y - 12, size: 15,
    font: fonts.display, color: C.navy });
  L.y -= 22;
  L.text("Le présent certificat fait partie intégrante du contrat. Il atteste de la signature, par l'Apporteur " +
    "désigné ci-dessous, du contrat d'apporteur d'affaires et du mandat de facturation qui lui est annexé, " +
    "dans les termes dont l'empreinte figure ci-après (articles 1366 et 1367 du Code civil).",
    { size: 8.6, color: C.grey });
  L.y -= 10;

  const s = doc.signer;
  const rows: [string, string][] = [
    ["Signataire", s.name],
    ["Statut", doc.business_status === "societe"
      ? `Société${s.company ? ` — ${s.company}` : ""}${s.legal_form ? ` (${s.legal_form})` : ""}`
      : `Indépendant${s.legal_form ? ` — ${s.legal_form}` : ""}`],
    ["SIRET", groupedSiret(s.siret)],
    ["Adresse", `${s.address}, ${s.postal_code} ${s.city}`],
    ["E-mail du compte", s.email],
    ["Date et heure", `${parisDateTime(doc.signed_at)} (heure de Paris)`],
    ["Méthode", doc.evidence.sms_verified
      ? `Code à usage unique envoyé par SMS${doc.evidence.sms_phone ? ` au ${doc.evidence.sms_phone}` : ""}, saisi et vérifié`
      : "Signature depuis le compte authentifié de l'Apporteur"],
    ["Adresse IP", doc.evidence.ip_address ?? "non transmise"],
    ["Référence", `${reference(doc.id)} — ${doc.id}`],
  ];
  const labelWidth = 118;
  for (const [label, value] of rows) {
    const lines = wrap(value, fonts.body, 8.8, CONTENT - labelWidth);
    L.keep(lines.length * 13 + 6);
    const top = L.y;
    tracked(L.page, label.toUpperCase(), MARGIN, top - 11, 6.4, fonts.bold, C.label, CAPS);
    lines.forEach((line, i) => {
      L.page.drawText(line, { x: MARGIN + labelWidth, y: top - 11 - i * 13, size: 8.8,
        font: i === 0 && label === "Signataire" ? fonts.bold : fonts.body, color: C.ink });
    });
    L.y = top - lines.length * 13 - 6;
    rule(L.page, L.y + 2);
  }

  L.heading("DOCUMENTS SIGNÉS — EMPREINTES SHA-256");
  for (const d of [doc.contract, doc.mandate]) {
    L.keep(40);
    L.text(`${d.title} — version ${d.version}`, { font: fonts.bold, size: 9, color: C.navy });
    L.text((d.sha256.match(/.{1,8}/g) ?? []).join(" "), { size: 8.2, color: C.grey });
    L.y -= 6;
  }

  L.keep(80);
  L.y -= 14;
  const gap = 28, w = (CONTENT - gap) / 2;
  const cols: [string, string, string][] = [
    ["L'APPORTEUR", s.name, `Signé électroniquement le ${parisDateTime(doc.signed_at).replace(/:\d\d$/, "")}`],
    ["LA SOCIÉTÉ", doc.company?.legal_name ?? "TRINITY ENERGIE",
     "Contrat proposé et publié par la Société dans l'application"],
  ];
  cols.forEach(([label, name, state], i) => {
    const x = MARGIN + i * (w + gap);
    rule(L.page, L.y, { x, length: w, color: C.navy, thickness: 1.2 });
    tracked(L.page, label, x, L.y - 13.5, 6.6, fonts.bold, C.label, CAPS);
    L.page.drawText(name, { x, y: L.y - 29, size: 10.5, font: fonts.bold, color: C.navy });
    tick(L.page, x, L.y - 39.5);
    wrap(state, fonts.body, 8, w - 11).forEach((line, j) => {
      L.page.drawText(line, { x: x + 11, y: L.y - 44.5 - j * 11, size: 8, font: fonts.body, color: C.grey });
    });
  });
  L.y -= 70;
}

function footers(L: Layout, doc: ContractDocument) {
  const { fonts } = L;
  const total = L.pages.length;
  const label = `Contrat d'apporteur d'affaires · ${doc.signer.name} · ${reference(doc.id)}`;
  L.pages.forEach((page, i) => {
    rule(page, FOOTER_TOP);
    page.drawText(label, { x: MARGIN, y: FOOTER_TOP - 16, size: 7.2, font: fonts.body, color: C.grey });
    const pageLabel = `Page ${i + 1} / ${total}`;
    page.drawText(pageLabel, { x: PAGE.width - MARGIN - fonts.body.widthOfTextAtSize(pageLabel, 7.2),
      y: FOOTER_TOP - 16, size: 7.2, font: fonts.body, color: C.grey });
    const sealed = `Signé électroniquement le ${parisDateTime(doc.signed_at).replace(/:\d\d$/, "")} · ` +
      (doc.evidence.sms_verified ? "code SMS vérifié" : "session authentifiée");
    page.drawText(sealed, { x: MARGIN, y: FOOTER_TOP - 28, size: 6.6, font: fonts.body, color: C.faint });
  });
}

export interface RenderOptions {
  creationDate?: Date;
}

export async function renderContractPdf(doc: ContractDocument, options: RenderOptions = {}): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const fonts: Fonts = {
    body: await pdf.embedFont(fontBytes(manropeRegular), { subset: true }),
    bold: await pdf.embedFont(fontBytes(manropeBold), { subset: true }),
    display: await pdf.embedFont(fontBytes(soraSemiBold), { subset: true }),
  };
  pdf.setTitle(`Contrat d'apporteur d'affaires — ${doc.signer.name}`);
  pdf.setAuthor(doc.signer.name);
  pdf.setCreator(doc.company?.legal_name ?? "TRINITY ENERGIE");
  pdf.setProducer("Trinity Énergie");
  pdf.setSubject(`Contrat ${doc.contract.version} (${doc.contract.sha256}), mandat ${doc.mandate.version} (${doc.mandate.sha256})`);
  pdf.setKeywords([reference(doc.id), "contrat d'apporteur d'affaires", "mandat de facturation"]);
  pdf.setLanguage("fr-FR");
  const created = options.creationDate ?? new Date(doc.signed_at);
  pdf.setCreationDate(created);
  pdf.setModificationDate(created);

  const L = new Layout(pdf, fonts);
  L.continuation = `CONTRAT D'APPORTEUR D'AFFAIRES — ${reference(doc.id)} — SUITE`;
  L.newPage(true);
  header(L, doc);
  keyFacts(L, doc);
  parties(L, doc);
  legalText(L, doc.contract.body);

  L.continuation = `ANNEXE — MANDAT DE FACTURATION — ${reference(doc.id)}`;
  L.newPage();
  tracked(L.page, "ANNEXE", MARGIN, L.y - 8, 7.2, fonts.bold, C.label, CAPS);
  L.y -= 14;
  L.text(doc.mandate.title, { font: fonts.display, size: 16, color: C.navy, leading: 22 });
  L.y -= 6;
  rule(L.page, L.y);
  L.y -= 6;
  legalText(L, doc.mandate.body);

  L.continuation = `CERTIFICAT DE SIGNATURE — ${reference(doc.id)}`;
  certificate(L, doc);
  footers(L, doc);
  return await pdf.save();
}

// Energy Courtage — renders, keeps and sends the signed invoice.
//
// Called by the database (call_edge_hook) when an invoice is sealed, and by
// the fifteen-minute sweep for any it missed. See handler.ts for the sequence
// and the migration 20261004000001_server_pdf.sql for the trigger.
//
// Deploy:
//   supabase functions deploy invoice-pdf --no-verify-jwt
//   supabase secrets set INVOICE_PDF_HOOK_SECRET=... RESEND_API_KEY=... \
//                        MAIL_FROM="Trinity Énergie <factures@trinity-energie.fr>"
//   then, in SQL:
//   insert into edge_hooks (name, url, secret) values
//     ('invoice-pdf', 'https://<ref>.supabase.co/functions/v1/invoice-pdf', '<same secret>');
//
// --no-verify-jwt because the caller is the database, not a user; the shared
// secret below is what keeps a stranger who finds the URL out.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { resendSender } from "../_shared/email.ts";
import { Deps, retainInvoice } from "./handler.ts";

const BUCKET = "invoices";

function deps(): Deps {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  return {
    async loadDocument(id) {
      const { data, error } = await db.rpc("invoice_document", { p_invoice_id: id });
      if (error) throw error;
      return data;
    },
    async loadRecipients(id) {
      const { data, error } = await db.rpc("invoice_mail_recipients", { p_invoice_id: id });
      if (error) throw error;
      return data;
    },
    async upload(path, bytes) {
      const { error } = await db.storage.from(BUCKET).upload(path, bytes, {
        contentType: "application/pdf",
        upsert: false,
      });
      if (!error) return "created";
      if (/exists|duplicate|409/i.test(`${error.message} ${(error as { statusCode?: string }).statusCode ?? ""}`)) {
        return "exists";
      }
      throw error;
    },
    async download(path) {
      const { data, error } = await db.storage.from(BUCKET).download(path);
      if (error) throw error;
      return new Uint8Array(await data.arrayBuffer());
    },
    async retain(id, path, sha256) {
      const { data, error } = await db.rpc("retain_invoice_pdf", {
        p_invoice_id: id, p_path: path, p_sha256: sha256,
      });
      if (error) throw error;
      return data;
    },
    sendMail: resendSender(),
  };
}

Deno.serve(async (request) => {
  const secret = Deno.env.get("INVOICE_PDF_HOOK_SECRET");
  if (!secret || request.headers.get("x-hook-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let body: { invoice_id?: string };
  try {
    body = await request.json();
  } catch {
    return new Response("expected a JSON body", { status: 400 });
  }
  if (!body.invoice_id || !/^[0-9a-f-]{36}$/i.test(body.invoice_id)) {
    return new Response("invoice_id is required", { status: 400 });
  }

  try {
    const outcome = await retainInvoice(body.invoice_id, deps());
    return Response.json(outcome);
  } catch (error) {
    // The sweep will ask again; say what went wrong for the logs.
    console.error(`invoice ${body.invoice_id}:`, error);
    return Response.json({ invoice_id: body.invoice_id, status: "error", error: String(error) }, { status: 500 });
  }
});

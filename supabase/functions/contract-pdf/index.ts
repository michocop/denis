// Energy Courtage — files the apporteur's signed contract as a PDF.
//
// Called by the database (call_edge_hook 'contract-pdf') the moment an
// apporteur signs, and by the sweep for any it missed. Renders the contract,
// its annex and the signature certificate, stores them in the private
// "contracts" bucket, records the digest, and mails a copy to both parties.
//
//   supabase functions deploy contract-pdf --no-verify-jwt
// (scripts/deploy.sh does it, and registers the hook with its secret.)

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { mailSender } from "../_shared/email.ts";
import { Deps, retainContract } from "./handler.ts";

const BUCKET = "contracts";

function deps(): Deps {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  return {
    async loadDocument(id) {
      const { data, error } = await db.rpc("contract_document", { p_contract_id: id });
      if (error) throw error;
      return data;
    },
    async companyEmail() {
      const { data } = await db.from("billing_settings").select("email").limit(1).maybeSingle();
      return (data?.email as string | undefined) ?? null;
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
      const { data, error } = await db.rpc("retain_contract_pdf", {
        p_contract_id: id, p_path: path, p_sha256: sha256,
      });
      if (error) throw error;
      return data;
    },
    sendMail: mailSender(),
  };
}

Deno.serve(async (request) => {
  const secret = Deno.env.get("CONTRACT_PDF_HOOK_SECRET");
  if (!secret || request.headers.get("x-hook-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let body: { contract_id?: string };
  try {
    body = await request.json();
  } catch {
    return new Response("expected a JSON body", { status: 400 });
  }
  if (!body.contract_id || !/^[0-9a-f-]{36}$/i.test(body.contract_id)) {
    return new Response("contract_id is required", { status: 400 });
  }

  try {
    return Response.json(await retainContract(body.contract_id, deps()));
  } catch (error) {
    // The sweep will ask again; say what went wrong for the logs.
    console.error(`contract ${body.contract_id}:`, error);
    return Response.json({ contract_id: body.contract_id, status: "error", error: String(error) }, { status: 500 });
  }
});

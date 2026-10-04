import { assertEquals } from "jsr:@std/assert@1";
import { purge } from "./handler.ts";

Deno.test("the files of anonymised leads are deleted from storage, in batches", async () => {
  const batches: string[][] = [];
  const paths = Array.from({ length: 230 }, (_, i) => `lead/${i}.pdf`);
  const result = await purge({
    purge: () => Promise.resolve({ anonymised: 12, retention_months: 36, document_paths: paths }),
    removeFiles: (p) => { batches.push(p); return Promise.resolve(); },
  });
  assertEquals(result, { anonymised: 12, retention_months: 36, files_removed: 230 });
  assertEquals(batches.map((b) => b.length), [100, 100, 30]);
});

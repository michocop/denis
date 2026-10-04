// The monthly retention sweep: purge_stale_leads anonymises what has been
// kept too long and hands back the documents' storage paths, which are
// deleted here through the Storage API -- deleting their rows in SQL would
// leave the bytes in the bucket.

export interface Deps {
  purge(): Promise<{ anonymised: number; retention_months: number; document_paths: string[] }>;
  removeFiles(paths: string[]): Promise<void>;
}

export async function purge(deps: Deps) {
  const result = await deps.purge();
  const paths = result.document_paths ?? [];
  for (let i = 0; i < paths.length; i += 100) {
    await deps.removeFiles(paths.slice(i, i + 100));
  }
  return { anonymised: result.anonymised, retention_months: result.retention_months, files_removed: paths.length };
}

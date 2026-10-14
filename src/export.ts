import { createWriteStream } from "node:fs";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { to as copyTo } from "pg-copy-streams";
import { pool, projectRoot } from "./db.js";

// Each export is a plain query streamed straight to a CSV with COPY, so the
// files always match what is in the firms table. The columns follow the brief.
// The linked list also carries link_id and firm_role so a vendor and its
// manufacturers can be told apart and grouped back together.
const exports: { file: string; query: string }[] = [
  {
    file: "linked_vendor_manufacturers.csv",
    query: `
      select company_name, cage, email, phone, contact_name, link_id, firm_role
      from public.firms where firm_list = 'linked' order by id`,
  },
  {
    file: "orphan_vendors.csv",
    query: `
      select company_name, cage, email, phone, contact_name
      from public.firms where firm_list = 'orphan_vendor' order by id`,
  },
  {
    file: "orphan_manufacturers.csv",
    query: `
      select company_name, cage, email, phone, contact_name
      from public.firms where firm_list = 'orphan_manufacturer' order by id`,
  },
  {
    file: "needs_review.csv",
    query: `
      select reason, company_name, detail, source
      from public.firms_review order by reason, company_name`,
  },
];

async function main(): Promise<void> {
  const outputDir = path.join(projectRoot, "output");
  await mkdir(outputDir, { recursive: true });

  const client = await pool.connect();
  try {
    for (const { file, query } of exports) {
      const copy = client.query(copyTo(`copy (${query}) to stdout with (format csv, header)`));
      await pipeline(copy, createWriteStream(path.join(outputDir, file)));
      console.log(`Wrote output/${file}`);
    }
  } finally {
    client.release();
  }
}

main()
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => pool.end());

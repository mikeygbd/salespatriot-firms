import { createReadStream } from "node:fs";
import path from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { parse, type Info } from "csv-parse";
import { from as copyFrom } from "pg-copy-streams";
import { pool, projectRoot, runSqlFile } from "./db.js";

// Maps each CSV header we keep to its staging column. Anything not listed here
// is never read into the database, which is how the bank and tax fields stay out.
interface Source {
  file: string;
  table: string;
  columns: Record<string, string>;
}

const sources: Source[] = [
  {
    file: "Sales Patriot Project Vendor File_ANONYMIZED.csv",
    table: "staging.vendors",
    columns: {
      VendorId: "vendor_id",
      VendorName: "vendor_name",
      SortName: "sort_name",
      Sts: "status",
      VendType: "vendor_type",
      PayToVendId: "pay_to_vendor_id",
      AddressOne: "address_one",
      AddressTwo: "address_two",
      City: "city",
      St: "state",
      ZipCode: "zip_code",
      Country: "country",
      Phone: "phone",
      PhoneExt: "phone_ext",
      OtherPhone: "other_phone",
      Fax: "fax",
      Contact: "contact",
      EmailAddress: "email_address",
      WebsiteAddress: "website_address",
      SRepName: "srep_name",
      SRepEmailAddr: "srep_email",
      SRepPhone: "srep_phone",
      PurchName: "purch_name",
      PurchPhone: "purch_phone",
      PurchContEmail: "purch_contact_email",
      PurchEmail: "purch_email",
      Notes: "notes",
      LastUpdDate: "last_updated",
    },
  },
  {
    file: "Cage Maintenance_ANONYMIZED.csv",
    table: "staging.cage_maintenance",
    columns: {
      CageCode: "cage_code",
      Description: "description",
      VendorCode: "vendor_code",
      PreludeKey: "prelude_key",
      ExportDate: "export_date",
    },
  },
  {
    file: "cages_ANONYMIZED.csv",
    table: "staging.cages",
    columns: {
      id: "cage_code",
      status: "status",
      type: "cage_kind",
      company: "company",
      city: "city",
      state_providence: "state",
      zip_postal: "zip",
      country: "country",
      cage_type: "cage_type",
    },
  },
];

const rawDataDir = path.resolve(projectRoot, process.env.RAW_DATA_DIR ?? "data");

// COPY in csv mode reads an unquoted empty field as null and a quoted field as
// a literal value. So empty cells become null and every real value gets quoted,
// which keeps commas and quotes inside company names from breaking the row.
function toCopyField(value: string | undefined): string {
  if (value === undefined || value === "") return "";
  return `"${value.replaceAll('"', '""')}"`;
}

// Streams one CSV into its staging table with COPY. The file is never fully in
// memory, which matters for the cages file at almost 600 MB.
async function loadSource(source: Source): Promise<number> {
  const csvHeaders = Object.keys(source.columns);
  const tableColumns = ["source_row", ...Object.values(source.columns)];
  let rowsSent = 0;

  const parser = parse({
    bom: true,
    info: true,
    // Fail fast if the client sends a file with renamed or missing columns,
    // instead of quietly loading nulls.
    columns: (header: string[]) => {
      const missing = csvHeaders.filter((name) => !header.includes(name));
      if (missing.length > 0) {
        throw new Error(`${source.file} is missing columns: ${missing.join(", ")}`);
      }
      return header;
    },
  });

  const toCopyRows = new Transform({
    writableObjectMode: true,
    transform(chunk: { record: Record<string, string>; info: Info }, _encoding, done) {
      rowsSent++;
      if (rowsSent % 500_000 === 0) console.log(`  ${rowsSent.toLocaleString()} rows sent`);
      // info.lines is the line the record ends on, which is its line number in the file.
      const fields = [String(chunk.info.lines), ...csvHeaders.map((name) => toCopyField(chunk.record[name]))];
      done(null, fields.join(",") + "\n");
    },
  });

  const client = await pool.connect();
  try {
    const copy = client.query(
      copyFrom(`copy ${source.table} (${tableColumns.join(", ")}) from stdin with (format csv)`),
    );
    await pipeline(createReadStream(path.join(rawDataDir, source.file)), parser, toCopyRows, copy);

    // Make sure every row we parsed actually landed before moving on.
    const result = await client.query<{ count: number }>(`select count(*)::int as count from ${source.table}`);
    const rowsInTable = result.rows[0]?.count ?? 0;
    if (rowsInTable !== rowsSent) {
      throw new Error(`${source.table}: sent ${rowsSent} rows but table has ${rowsInTable}`);
    }
    return rowsInTable;
  } finally {
    client.release();
  }
}

async function main(): Promise<void> {
  console.log(`Reading raw files from ${rawDataDir}`);
  await runSqlFile("sql/001_staging.sql");

  const summary: { table: string; rows: number; seconds: number }[] = [];
  for (const source of sources) {
    console.log(`Loading ${source.file}`);
    const started = Date.now();
    const rows = await loadSource(source);
    summary.push({ table: source.table, rows, seconds: Math.round((Date.now() - started) / 1000) });
  }
  console.table(summary);
}

main()
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => pool.end());

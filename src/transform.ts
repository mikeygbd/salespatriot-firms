import { readdir } from "node:fs/promises";
import path from "node:path";
import { pool, projectRoot, runSqlFile } from "./db.js";

// Runs every SQL step after the staging load, in file name order. Each file
// rebuilds its own schema, so this can be run as many times as needed without
// reloading the raw CSVs.
async function main(): Promise<void> {
  const files = (await readdir(path.join(projectRoot, "sql")))
    .filter((name) => name.endsWith(".sql") && name !== "001_staging.sql")
    .sort();

  for (const file of files) {
    const started = Date.now();
    await runSqlFile(path.join("sql", file));
    console.log(`${file} done in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  }
}

main()
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => pool.end());

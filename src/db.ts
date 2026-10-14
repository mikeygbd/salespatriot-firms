import "dotenv/config";
import { readFile } from "node:fs/promises";
import path from "node:path";
import pg from "pg";

// Every script reads the connection string from .env, so the same code runs
// against Railway, a local Postgres, or whatever database a reviewer points it at.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error("DATABASE_URL is not set. Copy .env.example to .env and fill it in.");
}

export const pool = new pg.Pool({ connectionString });

export const projectRoot = path.resolve(import.meta.dirname, "..");

// Runs a whole .sql file in one round trip. Paths are relative to the project root
// so scripts work no matter which folder they are started from.
export async function runSqlFile(relativePath: string): Promise<void> {
  const sql = await readFile(path.join(projectRoot, relativePath), "utf8");
  await pool.query(sql);
}

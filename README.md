# SalesPatriot firms ingest

Takes the client's vendor file, their Cage Maintenance file and the internal CAGE registry, and turns them into one clean `firms` table split into three lists: linked vendors with their manufacturers, orphan vendors and orphan manufacturers.

Everything after the CSV load is plain SQL in Postgres, run in order by a small TypeScript runner.

## Running it

You need Node 20+ and any Postgres 14+ database.

```bash
npm install
cp .env.example .env
```

Set `DATABASE_URL` in `.env`, and point `RAW_DATA_DIR` at the folder with the three CSVs from the task zip. The CSVs aren't in the repo since the registry file alone is almost 600 MB.

```bash
npm run pipeline
```

That loads the raw files, runs every SQL step, checks the result and writes the CSVs to `output/`. The load takes a few minutes because of the registry. After that, `npm run transform` and `npm run export` can be rerun on their own without reloading anything.

## Output

| File | What's in it |
| --- | --- |
| `linked_vendor_manufacturers.csv` | Each vendor followed by the manufacturers it represents, grouped by `link_id` |
| `orphan_vendors.csv` | Vendors with no manufacturers, representing themselves |
| `orphan_manufacturers.csv` | Manufacturers with no vendor |
| `needs_review.csv` | Everything left out of the lists, with the reason |

All three lists have the columns from the brief: `company_name, cage, email, phone, contact_name`. The linked list adds `link_id` and `firm_role`.

The same data lives in the `firms` table, which also has `email_repaired`, `cage_match` (how the CAGE was found) and `source` (the vendor ID or file row it came from).

## How it works

| Step | File | What it does |
| --- | --- | --- |
| Load | `src/load.ts`, `sql/001_staging.sql` | Streams each CSV into a staging table with COPY, all columns as text, and checks the row counts |
| Clean | `sql/002_clean.sql` | Normalizes keys, emails, phones and contacts, and labels bad rows with an issue instead of deleting them |
| Link | `sql/003_relationships.sql` | Merges duplicate vendors by name and decides which manufacturers are linked or orphaned |
| Match | `sql/004_vendor_cages.sql` | Finds each vendor's own CAGE code by name |
| Build | `sql/005_firms.sql` | Removes duplicates by CAGE across the lists and builds `firms` and `firms_review` |
| Check | `sql/006_checks.sql` | Fails the run if the output breaks any of the rules below |

## Decisions

**Quality over volume.** The brief says finished high quality data beats a lot of data with errors, so anything uncertain is left empty and sent to review rather than guessed.

**Nothing gets silently dropped.** Bad rows are labeled during cleaning and end up in `needs_review.csv` with a reason, so the client can fix them at the source.

**Bank and tax fields never enter the database.** The loader only reads the columns it needs.

**Contact cleanup.**
- Phones are stored in E.164. Numbers without an area code are dropped.
- Fax numbers mixed into the Cage Maintenance description are kept out of the phone column.
- Contacts that are a department instead of a person are dropped.

**Truncated emails.** Some fields were capped at 30 characters, which cut off the end of longer emails. When the cut was in the domain ending, I checked the complete emails in the data and almost all of them were .com, so I put that back and flagged the email as repaired. When the cut is in the middle of the domain name it can't be recovered, so those go to review.

**Placeholder vendors.** A couple of blank vendor records had thousands of manufacturers pointed at them. They're catch all codes, not real vendors, so those manufacturers are treated as orphans.

**Replaced vendors.** Some old vendor records say which vendor ID replaced them in the name. They're left out, and any manufacturers linked to them move to the replacement.

**Matching vendors to CAGE codes.** The vendor file has no CAGE column, so this goes by name, in order of how much I trust each source:
1. The vendor is listed as one of its own manufacturers in Cage Maintenance.
2. The vendor's name matches a CAGE the client already uses somewhere in Cage Maintenance.
3. The name matches exactly one CAGE in the registry. Registry names with a DBA are matched on either side.

If the name hits several codes and nothing breaks the tie, the vendor gets no CAGE and goes to review. I didn't use the registry's city and state as a tie breaker because in this copy of the data they don't line up with the vendor addresses.

**Duplicates.** Within the vendor file, duplicates are merged by a normalized company name. Across the lists they're found by CAGE, since that's the real identity of a firm. Linked firms always win over orphans, as the brief asks. When a duplicate is dropped, its contact info fills any gaps on the record that's kept.

A vendor whose only manufacturer is itself ends up as an orphan vendor. A firm can still show up as a vendor in its own group and as a manufacturer under another vendor, since that's a real relationship and not a duplicate.

**Checks.** `006_checks.sql` makes sure no CAGE appears twice across the orphan lists, no orphan shares a CAGE with a linked firm, every linked group has one vendor and at least one manufacturer, nobody is listed under themselves, and every CAGE, email and phone is well formed.

`pay_to_vendor_id` looked like a parent relationship at first, but it points at who gets paid, not who represents whom, so it isn't used for linking.

## Results

| List | Firms | With CAGE | Email | Phone | Contact |
| --- | --- | --- | --- | --- | --- |
| Linked vendors | 3,013 | 1,383 | 2,041 | 2,875 | 2,838 |
| Their manufacturers | 5,914 | 5,914 | 3,420 | 363 | 322 |
| Orphan vendors | 14,276 | 6,846 | 6,642 | 12,564 | 9,711 |
| Orphan manufacturers | 10,451 | 10,451 | 6,964 | 22 | 0 |

33,654 firms in total, and 462 have a repaired email.

About 48% of vendors got a CAGE. A lot of the rest were never going to have one, since the vendor file includes utilities, shipping companies, software vendors and individual people, none of whom would be registered as contractors.

## What I'd do next

- Fuzzy name matching for the vendors that didn't match, as suggestions for someone to confirm rather than automatic matches.
- Use location as a tie breaker on real data, which should clear up a lot of the ambiguous matches.
- Use the pay to relationships to group vendors that belong to the same parent company.
- Turn the review file into a small screen where someone can confirm or reject each item.

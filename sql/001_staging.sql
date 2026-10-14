-- Raw landing tables for the three CSVs.
--
-- Every column is text because the source data is too messy to cast on the way
-- in (CAGE codes with leading spaces, vendor codes exported as floats like
-- 2538.0). Loading it as is means nothing fails or gets lost, and all of the
-- cleaning happens in later SQL steps where each rule is easy to see.
--
-- source_row is the line number in the original file so any output record can
-- be traced back to its source. The tables are unlogged because they are just
-- copies of files on disk, which makes the big cages load faster.
--
-- The schema is dropped and recreated each run so the pipeline can always be
-- rerun from scratch.

drop schema if exists staging cascade;
create schema staging;

-- The vendor export has 139 columns. I only keep identity, contact and
-- relationship fields. The contact fields include the sales rep and purchasing
-- columns as fallbacks since the main phone and email are often empty.
-- Bank accounts, routing numbers and tax IDs are left out on purpose so they
-- never reach the database.
create unlogged table staging.vendors (
  source_row          integer primary key,
  vendor_id           text,
  vendor_name         text,
  sort_name           text,
  status              text,
  vendor_type         text,
  pay_to_vendor_id    text,
  address_one         text,
  address_two         text,
  city                text,
  state               text,
  zip_code            text,
  country             text,
  phone               text,
  phone_ext           text,
  other_phone         text,
  fax                 text,
  contact             text,
  email_address       text,
  website_address     text,
  srep_name           text,
  srep_email          text,
  srep_phone          text,
  purch_name          text,
  purch_phone         text,
  purch_contact_email text,
  purch_email         text,
  notes               text,
  last_updated        text
);

-- Each row is a manufacturer CAGE code. When vendor_code is filled in, it
-- points to the vendor that represents that manufacturer. description is free
-- text that usually holds an email but sometimes a fax number or a note, so it
-- gets sorted out during cleaning.
create unlogged table staging.cage_maintenance (
  source_row   integer primary key,
  cage_code    text,
  description  text,
  vendor_code  text,
  prelude_key  text,
  export_date  text
);

-- Internal CAGE registry, about 4 million rows. The source id column is the
-- CAGE code, so it is renamed here to make joins read clearly. Columns like
-- award_history, tracked_nsns and ai_description are skipped since they are
-- almost always empty and aren't needed to identify a firm.
create unlogged table staging.cages (
  source_row  integer primary key,
  cage_code   text,
  status      text,
  cage_kind   text,
  company     text,
  city        text,
  state       text,
  zip         text,
  country     text,
  cage_type   text
);

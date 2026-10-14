-- Raw landing tables for the three CSVs.
--
-- Every column is text since the source data is too messy to cast on the way
-- in. Loading it as is means nothing fails or gets lost, and the cleaning
-- happens in later SQL steps where each rule is easy to see.
--
-- source_row is the line number in the original file, for tracing records
-- back. Tables are unlogged since they can always be reloaded from the CSVs,
-- and the schema is rebuilt on every run.

drop schema if exists staging cascade;
create schema staging;

-- Only identity, contact and relationship fields are kept. The sales rep and
-- purchasing columns are fallbacks for when the main phone or email is empty.
-- Bank and tax fields are left out on purpose so they never reach the database.
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

-- vendor_code links a manufacturer to the vendor that represents it.
-- description is free text that gets sorted out during cleaning.
create unlogged table staging.cage_maintenance (
  source_row   integer primary key,
  cage_code    text,
  description  text,
  vendor_code  text,
  prelude_key  text,
  export_date  text
);

-- Internal CAGE registry. id is renamed to cage_code so joins read clearly.
-- Only the columns needed to identify a firm are kept.
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

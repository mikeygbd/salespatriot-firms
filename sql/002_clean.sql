-- Cleans the staging data into the clean schema.
--
-- Nothing gets deleted here. Rows that don't look usable get an issue label
-- instead, so later steps can leave them out of the firms list while still
-- being able to report exactly what was dropped and why.

drop schema if exists clean cascade;
create schema clean;

-- Helper functions
-- These keep the cleaning rules in one place so vendors and manufacturers
-- get treated exactly the same way.

-- Trims, collapses repeated spaces and strips control characters (the
-- export has a few stray \x7F bytes). Returns null for empty strings.
create function clean.squish(raw text) returns text
language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(trim(raw), '[[:cntrl:]]', '', 'g'), '\s+', ' ', 'g'), '')
$$;

-- Several source fields were capped at 30 characters, which cut off the end
-- of longer emails. When the cut lands in the ending, this puts ".com" back:
--   ".co" ending: shows up about 250 times more often at exactly 30
--     characters than at any other length, so these were cut off ".com".
--     Real .co addresses of any other length are left alone.
--   ".c" ending: 99.7% of complete emails with a domain starting in "c"
--     are ".com" (the rest are .ca, .cn, .ch and so on).
--   Ends in a dot: ".com" is 92% of all complete emails, next is .net at 4%.
-- Returns null when no repair applies. A cut inside the domain name itself
-- can't be repaired because there is no way to know the rest of the name.
create function clean.repair_truncated_email(raw text) returns text
language sql immutable as $$
  select case
    when length(trim(raw)) <> 30 then null
    when trim(raw) ~* '@[^@\s]+\.co$' then trim(raw) || 'm'
    when trim(raw) ~* '@[^@\s]+\.c$' then trim(raw) || 'om'
    when trim(raw) ~* '@[^@\s]+\.$' then trim(raw) || 'com'
  end
$$;

create function clean.email_was_repaired(raw text) returns boolean
language sql immutable as $$
  select clean.repair_truncated_email(raw) is not null
$$;

-- Pulls the first email address out of a messy field, since many hold two
-- addresses or extra text around them. Truncated endings are repaired first.
-- Any other value that is exactly 30 long and doesn't end in a common full
-- domain is dropped, since fixing it would be a guess.
create function clean.extract_email(raw text) returns text
language sql immutable as $$
  select case
    when email is null then null
    when repaired is null and length(trim(raw)) = 30
      and email !~ '\.(com|net|org|gov|mil|edu|us|biz|info)$' then null
    else email
  end
  from (select clean.repair_truncated_email(raw) as repaired) r,
  lateral (
    select lower(substring(coalesce(r.repaired, raw) from '[A-Za-z0-9._%+''-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')) as email
  ) found
$$;

-- Normalizes a phone number to E.164 (+15551234567) so every phone has one
-- format. US numbers need a full 10 digits with a valid area code, and
-- international numbers are recognized by the 011 dialing prefix. Anything
-- else, like 7 digit numbers with no area code, is dropped since it can't
-- be dialed reliably. An extension is kept on the end when there is one.
create function clean.normalize_phone(raw text, ext text default null) returns text
language sql immutable as $$
  select case
    when number is null then null
    when nullif(regexp_replace(ext, '\D', '', 'g'), '') is not null
      then number || ' x' || regexp_replace(ext, '\D', '', 'g')
    else number
  end
  from (
    select case
      when digits ~ '^1?[2-9]\d{9}$' then '+1' || right(digits, 10)
      when digits ~ '^011\d{8,15}$' then '+' || substr(digits, 4)
    end as number
    from (select regexp_replace(raw, '\D', '', 'g') as digits) d
  ) n
$$;

-- Returns the contact only if it looks like a person. A lot of contacts are
-- departments like SALES or CUSTOMER SERVICE, which aren't useful as a
-- contact name.
create function clean.person_name(raw text) returns text
language sql immutable as $$
  select case
    when name !~ '[A-Za-z]' then null
    when upper(name) ~ '\m(SALES|SERVICES?|DEPT|DEPARTMENT|ORDERS?|ACCOUNTS?|ACCOUNTING|RECEIVABLES?|PAYABLES?|PARTS|QUOTES?|RFQS?|PURCHASING|OFFICE|SUPPORT|INFO|COUNTER|DESK|TEAM|WAREHOUSE|SHIPPING|GOV''?T)\M' then null
    else name
  end
  from (select clean.squish(raw) as name) n
$$;

-- Vendor and CAGE codes show up as '008224', '8224' and '8224.0' depending
-- on the file, so every key is reduced to the bare number before joining.
create function clean.vendor_key(raw text) returns text
language sql immutable as $$
  select nullif(ltrim(regexp_replace(trim(raw), '\.0+$', ''), '0'), '')
$$;

-- CAGE registry
-- One row per valid CAGE code. Codes are always 5 letters or digits, so
-- anything else is a bad record and gets skipped.
create table clean.cage_registry as
select distinct on (upper(trim(cage_code)))
  upper(trim(cage_code))  as cage_code,
  clean.squish(company)   as company_name,
  case upper(trim(status)) when 'ACTIVE' then 'A' else upper(trim(status)) end as status,
  clean.squish(city)      as city,
  clean.squish(state)     as state,
  clean.squish(country)   as country,
  source_row
from staging.cages
where upper(trim(cage_code)) ~ '^[A-Z0-9]{5}$'
order by upper(trim(cage_code)), source_row;

alter table clean.cage_registry add primary key (cage_code);

-- Vendors
create table clean.vendors as
with base as (
  select
    source_row,
    trim(vendor_id) as vendor_id,
    clean.vendor_key(vendor_id) as vendor_key,
    coalesce(clean.squish(vendor_name), clean.squish(sort_name)) as company_name,
    upper(trim(status)) as status,
    clean.vendor_key(pay_to_vendor_id) as pay_to_vendor_key,
    clean.extract_email(best_email.raw) as email,
    coalesce(clean.email_was_repaired(best_email.raw), false) as email_repaired,
    coalesce(
      clean.normalize_phone(phone, phone_ext),
      clean.normalize_phone(srep_phone),
      clean.normalize_phone(purch_phone),
      clean.normalize_phone(other_phone)
    ) as phone,
    -- purch_name is skipped here because it is sometimes a company name, not a person.
    coalesce(clean.person_name(contact), clean.person_name(srep_name)) as contact_name
  from staging.vendors v
  -- Main email field first, then the purchasing and sales rep fields as
  -- fallbacks. Picking the raw value here (instead of a coalesce) keeps track
  -- of which field the email came from, so the repaired flag matches it.
  left join lateral (
    select f.raw
    from unnest(array[v.email_address, v.purch_contact_email, v.purch_email, v.srep_email])
      with ordinality as f(raw, priority)
    where clean.extract_email(f.raw) is not null
    order by f.priority
    limit 1
  ) best_email on true
)
select
  *,
  case
    when vendor_id !~ '^\d+$' then 'test_record'
    when company_name is null then 'missing_name'
    when company_name ~* '(DO NOT USE|DONT USE|DON''T USE)' then 'do_not_use'
    when company_name ~* '(^INACTIVE\M|\(INACTIVE\))' or status = 'I' then 'inactive'
  end as issue
from base;

alter table clean.vendors add primary key (source_row);
create index on clean.vendors (vendor_key);

-- Manufacturers from Cage Maintenance
create table clean.manufacturers as
with base as (
  select
    source_row,
    upper(trim(cage_code)) as cage_code,
    clean.vendor_key(vendor_code) as vendor_key,
    clean.squish(description) as description
  from staging.cage_maintenance
),
-- Grab the first phone shaped number in the description and the text on
-- either side of it. That text is what tells us whether the number is a fax.
numbers as (
  select
    *,
    substring(description from '\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}') as first_number,
    substring(description from '^(.*?)\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}') as text_before_number,
    substring(description from '\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(.*)$') as text_after_number
  from base
),
-- description is one free text field, so I sort each value into what it
-- actually holds before pulling anything out of it.
classified as (
  select
    *,
    case
      when description is null then null
      when clean.extract_email(description) is not null then 'email'
      when description like '%@%' then 'truncated_email'
      -- A number is a fax when a marker like (F), F), F#, FAX or FX sits right
      -- before it, or the word FAX right after it. Something like F7740 after
      -- the number is a fax extension, so the main number is still a phone.
      when text_before_number ~* '(\(F\)|\mFA?X\d?|\mF#''?S?|\mF\)?)[\s.:#*-]*\(?$' then 'fax'
      when text_after_number ~* '^\s*(FAX|FX)\M' then 'fax'
      when clean.normalize_phone(first_number) is not null then 'phone'
      else 'note'
    end as description_kind
  from numbers
),
ranked as (
  select
    c.*,
    r.company_name,
    r.status as registry_status,
    -- A few CAGE codes appear twice. Keep the copy that is linked to a vendor,
    -- then the one with an email, so the more useful record wins.
    row_number() over (
      partition by c.cage_code
      order by (c.vendor_key is not null) desc, (c.description_kind = 'email') desc, c.source_row
    ) as copy_number
  from classified c
  left join clean.cage_registry r on r.cage_code = c.cage_code
)
select
  source_row,
  cage_code,
  vendor_key,
  company_name,
  registry_status,
  case when description_kind = 'email' then clean.extract_email(description) end as email,
  coalesce(description_kind = 'email' and clean.email_was_repaired(description), false) as email_repaired,
  case when description_kind = 'phone'
    then clean.normalize_phone(first_number)
  end as phone,
  description,
  description_kind,
  case
    when cage_code !~ '^[A-Z0-9]{5}$' then 'invalid_cage'
    when copy_number > 1 then 'duplicate_cage'
    when company_name is null then 'not_in_registry'
    when description ~* '(DO NOT USE|NO LONGER IN BUSINESS|OUT OF BUSINESS)' then 'do_not_use'
  end as issue
from ranked;

alter table clean.manufacturers add primary key (source_row);
create index on clean.manufacturers (vendor_key);
create index on clean.manufacturers (cage_code);

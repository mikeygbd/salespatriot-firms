-- Works out which firms are linked vendors, which manufacturers sit under
-- them, and which firms are orphans.
--
-- A manufacturer is linked when its vendor_code points at a real, clean
-- vendor. Everything else is an orphan manufacturer, and the reason is kept
-- so it is clear why it didn't link. A vendor with no manufacturers under it
-- is an orphan vendor, which the brief treats as representing itself.

drop schema if exists link cascade;
create schema link;

-- Vendor duplicates
-- The vendor file has the same company under several vendor IDs, like
-- PARKER HANNIFIN CORP and PARKER HANNIFIN CORPORATION. Each group of
-- duplicates gets one parent record. The brief says to prioritize linked
-- firms, so the record with the most manufacturers under it wins, then the
-- one with the most complete contact info.
create table link.vendors as
with child_counts as (
  select vendor_key, count(*) as manufacturer_count
  from clean.manufacturers
  where issue is null and vendor_key is not null
  group by vendor_key
),
keyed as (
  select
    v.*,
    -- A name made only of words like THE or COMPANY has no key, so it falls
    -- back to its own vendor ID and never gets merged with anything.
    coalesce(clean.name_key(v.company_name), 'vendor ' || v.vendor_key) as name_key,
    coalesce(c.manufacturer_count, 0) as manufacturer_count,
    (v.email is not null)::int + (v.phone is not null)::int + (v.contact_name is not null)::int as contact_fields
  from clean.vendors v
  left join child_counts c using (vendor_key)
  where v.issue is null
)
select
  *,
  first_value(vendor_key) over (
    partition by name_key
    order by manufacturer_count desc, contact_fields desc, vendor_key::bigint
  ) as parent_vendor_key
from keyed;

alter table link.vendors add primary key (vendor_key);
create index on link.vendors (parent_vendor_key);

-- One row per parent vendor. Contact details are filled in from the
-- duplicates when the parent record is missing them, starting with the
-- parent itself and then the other records in the same order as above.
create table link.parent_vendors as
select
  parent_vendor_key as vendor_key,
  name_key,
  (array_agg(company_name order by vendor_key = parent_vendor_key desc))[1] as company_name,
  (array_agg(email order by vendor_key = parent_vendor_key desc, contact_fields desc) filter (where email is not null))[1] as email,
  coalesce((array_agg(email_repaired order by vendor_key = parent_vendor_key desc, contact_fields desc) filter (where email is not null))[1], false) as email_repaired,
  (array_agg(phone order by vendor_key = parent_vendor_key desc, contact_fields desc) filter (where phone is not null))[1] as phone,
  (array_agg(contact_name order by vendor_key = parent_vendor_key desc, contact_fields desc) filter (where contact_name is not null))[1] as contact_name,
  array_agg(vendor_key order by vendor_key::bigint) as merged_vendor_keys
from link.vendors
group by parent_vendor_key, name_key;

alter table link.parent_vendors add primary key (vendor_key);

-- Manufacturers
-- Vendors 2 and 5 are blank records with thousands of manufacturers pointed
-- at them. They look like placeholder codes in the client's system rather
-- than real vendors, so those manufacturers are treated as orphans instead of
-- being grouped under a vendor with no name.
create table link.manufacturers as
select
  m.*,
  lv.parent_vendor_key,
  case
    when lv.parent_vendor_key is not null then null
    when m.vendor_key is null then 'no_vendor_code'
    when v.vendor_key is null then 'vendor_not_in_file'
    when v.issue = 'missing_name' then 'placeholder_vendor'
    else 'vendor_' || v.issue
  end as orphan_reason
from clean.manufacturers m
left join link.vendors lv on lv.vendor_key = m.vendor_key
left join clean.vendors v on v.vendor_key = m.vendor_key
where m.issue is null;

alter table link.manufacturers add primary key (source_row);
create index on link.manufacturers (parent_vendor_key);
create index on link.manufacturers (cage_code);

-- Parent vendors with at least one manufacturer under them are linked, the
-- rest are orphan vendors.
alter table link.parent_vendors add column is_linked boolean;

update link.parent_vendors p
set is_linked = exists (
  select 1 from link.manufacturers m where m.parent_vendor_key = p.vendor_key
);

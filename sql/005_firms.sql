-- Builds the final firms table and the review table.
--
-- Up to this point duplicates were found by name. Here they are found by
-- CAGE code, since a CAGE identifies one registered business. The brief says
-- to remove duplicates at the parent level and to prioritize linked firms, so
-- every rule below keeps the linked copy and drops the orphan one:
--
--   1. Vendors that share a CAGE are one company under its legal name and its
--      trade name, so they merge.
--   2. A vendor listed as one of its own manufacturers is just itself, so it
--      comes out of its own child list. A vendor whose only manufacturer was
--      itself ends up as an orphan vendor, which is the self representing case.
--   3. An orphan vendor that is also a linked manufacturer under another
--      vendor stays in the linked list only.
--   4. An orphan manufacturer that is also a vendor stays as the vendor only.
--
-- When a duplicate is dropped its contact details aren't lost. Any missing
-- email, phone or contact on the firm that's kept gets filled in from the
-- other records with the same CAGE.

drop schema if exists final cascade;
create schema final;

-- Rule 1: one vendor per CAGE
create table final.vendors as
with child_counts as (
  select parent_vendor_key as vendor_key, count(*) as manufacturer_count
  from link.manufacturers
  where parent_vendor_key is not null
  group by parent_vendor_key
)
select
  p.*,
  vc.cage_code,
  vc.match_method,
  vc.candidate_count,
  coalesce(c.manufacturer_count, 0) as manufacturer_count,
  -- Vendors without a CAGE can't be compared this way, so each one stays as is.
  first_value(p.vendor_key) over (
    partition by coalesce(vc.cage_code, 'no cage ' || p.vendor_key)
    order by p.is_linked desc, (vc.match_method = 'own_manufacturer') desc,
      coalesce(c.manufacturer_count, 0) desc, p.vendor_key::bigint
  ) as keep_vendor_key
from link.parent_vendors p
join match.vendor_cages vc using (vendor_key)
left join child_counts c using (vendor_key);

alter table final.vendors add primary key (vendor_key);

-- Rule 2: manufacturers under each kept vendor, minus the vendor itself
create table final.linked_manufacturers as
select m.*, keep.vendor_key as link_vendor_key
from link.manufacturers m
join final.vendors v on v.vendor_key = m.parent_vendor_key
join final.vendors keep on keep.vendor_key = v.keep_vendor_key
where keep.cage_code is null or m.cage_code <> keep.cage_code;

create index on final.linked_manufacturers (link_vendor_key);
create index on final.linked_manufacturers (cage_code);

create table final.kept_vendors as
select
  v.*,
  exists (
    select 1 from final.linked_manufacturers lm where lm.link_vendor_key = v.vendor_key
  ) as has_manufacturers
from final.vendors v
where v.vendor_key = v.keep_vendor_key;

-- Rule 3: orphan vendors that already appear as a linked manufacturer
delete from final.kept_vendors k
where not k.has_manufacturers
  and k.cage_code in (select cage_code from final.linked_manufacturers);

-- Rule 4: orphan manufacturers that are already in the list as a vendor
create table final.orphan_manufacturers as
select m.*
from link.manufacturers m
where m.parent_vendor_key is null
  and m.cage_code not in (select cage_code from final.kept_vendors where cage_code is not null);

-- Contact details from every record, keyed by CAGE, so gaps on the kept firm
-- can be filled from the duplicates. Vendor records come first since they
-- usually have more to offer than a manufacturer's description field.
create table final.contact_pool as
select v.cage_code, 1 as priority, p.email, p.email_repaired, p.phone, p.contact_name
from link.parent_vendors p
join final.vendors v using (vendor_key)
where v.cage_code is not null
union all
select cage_code, 2, email, email_repaired, phone, null
from link.manufacturers;

create index on final.contact_pool (cage_code);

-- One row per firm before the gaps are filled
create table final.firm_rows as
select
  company_name, cage_code, email, email_repaired, phone, contact_name,
  vendor_key as link_id,
  'linked' as firm_list, 'vendor' as firm_role,
  match_method as cage_match,
  'vendor file ' || array_to_string(merged_vendor_keys, ', ') as source
from final.kept_vendors
where has_manufacturers
union all
select
  company_name, cage_code, email, email_repaired, phone, null,
  link_vendor_key,
  'linked', 'manufacturer',
  'cage_maintenance',
  'cage maintenance row ' || source_row
from final.linked_manufacturers
union all
select
  company_name, cage_code, email, email_repaired, phone, contact_name,
  null,
  'orphan_vendor', 'vendor',
  match_method,
  'vendor file ' || array_to_string(merged_vendor_keys, ', ')
from final.kept_vendors
where not has_manufacturers
union all
select
  company_name, cage_code, email, email_repaired, phone, null,
  null,
  'orphan_manufacturer', 'manufacturer',
  'cage_maintenance',
  'cage maintenance row ' || source_row
from final.orphan_manufacturers;

-- Final table
drop table if exists public.firms;

create table public.firms (
  id             bigint generated always as identity primary key,
  company_name   text,
  cage           text,
  email          text,
  phone          text,
  contact_name   text,
  link_id        text,
  firm_list      text not null check (firm_list in ('linked', 'orphan_vendor', 'orphan_manufacturer')),
  firm_role      text not null check (firm_role in ('vendor', 'manufacturer')),
  email_repaired boolean not null default false,
  cage_match     text,
  source         text not null
);

comment on column public.firms.link_id is 'Vendor ID of the parent vendor. Shared by a linked vendor and its manufacturers.';
comment on column public.firms.email_repaired is 'True when the email was cut off in the source and the .com ending was put back.';
comment on column public.firms.cage_match is 'How the CAGE was found. Manufacturers come straight from Cage Maintenance.';
comment on column public.firms.source is 'Where the record came from, for tracing it back to the raw files.';

-- Inserted in list order with each vendor followed by its manufacturers, so
-- the ids read naturally when browsing the table.
insert into public.firms (
  company_name, cage, email, email_repaired, phone, contact_name,
  link_id, firm_list, firm_role, cage_match, source
)
select
  f.company_name,
  f.cage_code,
  coalesce(f.email, e.email),
  case when f.email is not null then f.email_repaired else coalesce(e.email_repaired, false) end,
  coalesce(f.phone, ph.phone),
  coalesce(f.contact_name, c.contact_name),
  f.link_id, f.firm_list, f.firm_role, f.cage_match, f.source
from final.firm_rows f
left join lateral (
  select email, email_repaired from final.contact_pool p
  where p.cage_code = f.cage_code and p.email is not null
  order by p.priority limit 1
) e on f.email is null
left join lateral (
  select phone from final.contact_pool p
  where p.cage_code = f.cage_code and p.phone is not null
  order by p.priority limit 1
) ph on f.phone is null
left join lateral (
  select contact_name from final.contact_pool p
  where p.cage_code = f.cage_code and p.contact_name is not null
  order by p.priority limit 1
) c on f.contact_name is null
order by
  case f.firm_list when 'linked' then 1 when 'orphan_vendor' then 2 else 3 end,
  f.link_id::bigint,
  f.firm_role desc,
  f.company_name;

create index on public.firms (cage);
create index on public.firms (link_id);

-- Review table
-- Everything that didn't make it into firms cleanly, with the reason, so the
-- client can fix it at the source or confirm it by hand.
drop table if exists public.firms_review;

create table public.firms_review as
select 'vendor_cage_ambiguous' as reason, company_name,
  'Name matches ' || candidate_count || ' CAGE codes in the registry' as detail,
  'vendor file ' || array_to_string(merged_vendor_keys, ', ') as source
from final.kept_vendors
where match_method = 'ambiguous'
union all
select 'email_truncated', company_name,
  'Email cut off in the source: ' || description,
  'cage maintenance row ' || source_row
from clean.manufacturers
where description_kind = 'truncated_email' and issue is null
union all
select 'vendor_' || issue, company_name, null,
  'vendor file ' || vendor_id
from clean.vendors
where issue is not null
union all
select 'manufacturer_' || issue, company_name, description,
  'cage maintenance row ' || source_row
from clean.manufacturers
where issue is not null;

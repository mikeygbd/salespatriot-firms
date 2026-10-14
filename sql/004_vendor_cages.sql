-- Matches each parent vendor to its own CAGE code.
--
-- The vendor file has no CAGE column, so the only way in is the company name.
-- A wrong CAGE is worse than a missing one, so a vendor only gets a code when
-- the match is clear. Everything else is left empty and kept for review with
-- the number of candidates that were found.
--
-- The registry's city and state looked like a good tie breaker, but in this
-- copy of the data they don't line up with the vendor addresses at all, so
-- location isn't used.

drop schema if exists match cascade;
create schema match;

-- Registry names
-- Registry names are often "LEGAL NAME DBA TRADE NAME", and a vendor could be
-- listed under either one. Each CAGE gets a row for its full name, plus one
-- for each side of a DBA when there is one.
create table match.registry_names as
select cage_code, status, clean.name_key(company_name) as name_key, 'full' as name_part
from clean.cage_registry
union all
select cage_code, status, clean.name_key(split_part(company_name, ' DBA ', 1)), 'legal_name'
from clean.cage_registry
where company_name like '% DBA %'
union all
select cage_code, status, clean.name_key(split_part(company_name, ' DBA ', 2)), 'dba_name'
from clean.cage_registry
where company_name like '% DBA %';

delete from match.registry_names where name_key is null;
create index on match.registry_names (name_key);
create index on match.registry_names (cage_code);
analyze match.registry_names;

-- Method 1: the vendor's own manufacturer
-- Some vendors show up in Cage Maintenance as one of their own manufacturers,
-- like MACGREGOR USA linked to MACGREGOR USA INC. When a vendor's name matches
-- one of its own linked manufacturers, that CAGE is the strongest match there
-- is, since the client already tied the two together.
create table match.own_manufacturer as
with hits as (
  select distinct p.vendor_key, m.cage_code, m.registry_status
  from link.parent_vendors p
  join link.manufacturers m on m.parent_vendor_key = p.vendor_key
  join match.registry_names rn on rn.cage_code = m.cage_code and rn.name_key = p.name_key
)
select distinct on (vendor_key)
  vendor_key,
  cage_code,
  count(*) over (partition by vendor_key) as candidate_count
from hits
order by vendor_key, (registry_status = 'A') desc, cage_code;

-- Method 2: a CAGE the client already uses
-- If a vendor's name matches a manufacturer anywhere in Cage Maintenance, even
-- one linked to a different vendor or not linked at all, the client's own
-- file is telling us which CAGE they use for that company. That beats picking
-- from the full registry, where one name can hit dozens of division codes.
-- Only used when it points to a single code.
create table match.client_file as
with hits as (
  select distinct p.vendor_key, m.cage_code, m.registry_status
  from link.parent_vendors p
  join match.registry_names rn on rn.name_key = p.name_key
  join link.manufacturers m on m.cage_code = rn.cage_code
  where not exists (select 1 from match.own_manufacturer o where o.vendor_key = p.vendor_key)
),
ranked as (
  select *, rank() over (partition by vendor_key order by (registry_status = 'A') desc) as candidate_rank
  from hits
)
select vendor_key, min(cage_code) as cage_code
from ranked
where candidate_rank = 1
group by vendor_key
having count(*) = 1;

-- Method 3: exact name match against the whole registry
-- Big companies have a CAGE for every division, so one name can hit many
-- codes. Candidates are narrowed down in order: a match on the full registry
-- name beats a match on one side of a DBA, and an active CAGE beats an
-- inactive one. If exactly one code is left at the top, it's used. If there's
-- still a tie, the vendor is marked ambiguous and gets no code.
create table match.exact_name as
with candidates as (
  select
    p.vendor_key,
    rn.cage_code,
    bool_or(rn.name_part = 'full') as full_name_match,
    bool_or(rn.status = 'A') as is_active
  from link.parent_vendors p
  join match.registry_names rn on rn.name_key = p.name_key
  where not exists (select 1 from match.own_manufacturer o where o.vendor_key = p.vendor_key)
    and not exists (select 1 from match.client_file c where c.vendor_key = p.vendor_key)
  group by p.vendor_key, rn.cage_code
),
ranked as (
  select
    *,
    rank() over (partition by vendor_key order by full_name_match desc, is_active desc) as candidate_rank,
    count(*) over (partition by vendor_key) as candidate_count
  from candidates
)
select
  vendor_key,
  case when count(*) = 1 then min(cage_code) end as cage_code,
  case when count(*) = 1 then 'exact_name' else 'ambiguous' end as method,
  max(candidate_count) as candidate_count
from ranked
where candidate_rank = 1
group by vendor_key;

-- Final result, one row per parent vendor
create table match.vendor_cages as
select
  p.vendor_key,
  coalesce(o.cage_code, c.cage_code, e.cage_code) as cage_code,
  case
    when o.vendor_key is not null then 'own_manufacturer'
    when c.vendor_key is not null then 'client_file'
    when e.vendor_key is not null then e.method
    else 'no_match'
  end as match_method,
  coalesce(o.candidate_count, case when c.vendor_key is not null then 1 end, e.candidate_count, 0) as candidate_count
from link.parent_vendors p
left join match.own_manufacturer o on o.vendor_key = p.vendor_key
left join match.client_file c on c.vendor_key = p.vendor_key
left join match.exact_name e on e.vendor_key = p.vendor_key;

alter table match.vendor_cages add primary key (vendor_key);

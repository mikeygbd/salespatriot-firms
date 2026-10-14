-- Suggested CAGE codes for vendors that didn't get one.
--
-- Vendors with no exact name match are compared against the registry by
-- trigram similarity, which scores how many three letter chunks two names
-- share. This catches typos and abbreviations. These are only suggestions.
-- They go to the review file for someone to confirm and never fill in a CAGE
-- on their own.
--
-- A suggestion needs a high score and has to be clearly ahead of the next
-- closest name, otherwise it's too close to call. I picked the cutoffs after
-- going through a sample by hand. Very short names are skipped since they
-- look similar to too many things.

create extension if not exists pg_trgm;

create index on match.registry_names using gin (name_key gin_trgm_ops);

-- Only pull names that are reasonably close, which keeps the index search
-- fast and still leaves room to see the runner up.
set pg_trgm.similarity_threshold = 0.65;

create table match.cage_suggestions as
with candidates as (
  -- One row per distinct registry name. Several CAGE codes can share a name,
  -- in which case the active one is suggested.
  select
    p.vendor_key,
    rn.name_key as registry_key,
    similarity(rn.name_key, p.name_key) as score,
    count(distinct rn.cage_code) as cage_count,
    (array_agg(rn.cage_code order by (rn.status = 'A') desc, rn.cage_code))[1] as cage_code
  from link.parent_vendors p
  join match.vendor_cages vc using (vendor_key)
  join match.registry_names rn on rn.name_key % p.name_key
  where vc.match_method = 'no_match'
    and length(p.name_key) >= 5
  group by p.vendor_key, rn.name_key, p.name_key
),
ranked as (
  select
    *,
    row_number() over (partition by vendor_key order by score desc, registry_key) as place,
    lead(score) over (partition by vendor_key order by score desc, registry_key) as next_score
  from candidates
)
select vendor_key, cage_code, registry_key, score, next_score, cage_count
from ranked
where place = 1
  and score >= 0.75
  and (next_score is null or score - next_score >= 0.1);

alter table match.cage_suggestions add primary key (vendor_key);

reset pg_trgm.similarity_threshold;

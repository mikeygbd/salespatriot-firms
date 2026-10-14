-- Sanity checks on the final firms table. Each one is a rule from the brief
-- or from the cleaning steps. If any of them fail the whole run fails, so a
-- bad change can't quietly produce a broken list.

do $$
declare
  bad bigint;
begin
  -- A CAGE can only be in one orphan list, once.
  select count(*) into bad from (
    select cage from public.firms
    where firm_list <> 'linked' and cage is not null
    group by cage having count(*) > 1
  ) dupes;
  if bad > 0 then raise exception '% CAGE codes appear more than once across the orphan lists', bad; end if;

  -- Linked firms win, so no orphan can share a CAGE with a linked firm.
  select count(*) into bad
  from public.firms o
  where o.firm_list <> 'linked'
    and o.cage in (select cage from public.firms where firm_list = 'linked');
  if bad > 0 then raise exception '% orphans share a CAGE with a linked firm', bad; end if;

  -- Every linked group has exactly one vendor and at least one manufacturer.
  select count(*) into bad from (
    select link_id from public.firms
    where firm_list = 'linked'
    group by link_id
    having count(*) filter (where firm_role = 'vendor') <> 1
        or count(*) filter (where firm_role = 'manufacturer') = 0
  ) groups;
  if bad > 0 then raise exception '% linked groups are missing a vendor or have no manufacturers', bad; end if;

  -- A manufacturer should never be listed under itself.
  select count(*) into bad
  from public.firms m
  join public.firms v on v.link_id = m.link_id and v.firm_role = 'vendor'
  where m.firm_role = 'manufacturer' and m.cage = v.cage;
  if bad > 0 then raise exception '% manufacturers are listed under their own vendor', bad; end if;

  -- Orphans never carry a link_id.
  select count(*) into bad from public.firms where firm_list <> 'linked' and link_id is not null;
  if bad > 0 then raise exception '% orphan rows have a link_id', bad; end if;

  -- Format checks on what made it through cleaning.
  select count(*) into bad from public.firms where cage !~ '^[A-Z0-9]{5}$';
  if bad > 0 then raise exception '% rows have a malformed CAGE', bad; end if;

  select count(*) into bad from public.firms where email !~ '^[a-z0-9._%+''-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$';
  if bad > 0 then raise exception '% rows have a malformed email', bad; end if;

  select count(*) into bad from public.firms where phone !~ '^\+\d{8,15}( x\d+)?$';
  if bad > 0 then raise exception '% rows have a malformed phone', bad; end if;

  select count(*) into bad from public.firms where company_name is null;
  if bad > 0 then raise exception '% rows have no company name', bad; end if;
end
$$;

-- Donate links now go to Bill's Starlight page (tied to the LAGB team), since he runs LAGB's fundraising.
create or replace function public.dc_donate_button() returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('type', 1, 'components', jsonb_build_array(
    jsonb_build_object('type', 2, 'style', 5, 'label', 'Donate to Starlight', 'emoji', jsonb_build_object('name', '❤️'),
      'url', 'https://donate.starlight.org/fundraiser/7718546'))));
$$;

update public.crews
set donate_codes = jsonb_set(donate_codes, '{1,url}', '"https://donate.starlight.org/fundraiser/7718546"')
where slug = 'lagb' and donate_codes->1->>'url' = 'https://donate.starlight.org/fundraiser/3526698';

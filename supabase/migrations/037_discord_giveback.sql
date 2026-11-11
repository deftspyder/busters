-- Ghostbusters Give Back in Discord:
--  * /giveback: top 10 chapters with this crew in bold and its progress to goal. Posts publicly at most once an
--    hour; anyone asking again within the hour gets it privately, with a link to the last public one.
--  * Milestone posts: when the crew passes each $5,000, or 25 / 50 / 75 / 100% of its goal.

alter table public.crew_discord
  add column if not exists guild_id text,
  add column if not exists post_milestones boolean not null default true,
  add column if not exists giveback_milestone numeric,          -- highest milestone already announced
  add column if not exists giveback_last_at timestamptz,        -- last public /giveback
  add column if not exists giveback_last_url text;

create or replace function public.dc_money(n numeric) returns text
language sql immutable set search_path = '' as $$ select '$' || to_char(round(n), 'FM999,999,990'); $$;

create or replace function public.dc_bar(pct numeric) returns text
language sql immutable set search_path = '' as $$
  select repeat('▰', least(10, greatest(0, round(pct / 10)::int))) || repeat('▱', 10 - least(10, greatest(0, round(pct / 10)::int)));
$$;

create or replace function public.dc_donate_button() returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('type', 1, 'components', jsonb_build_array(
    jsonb_build_object('type', 2, 'style', 5, 'label', 'Donate to Starlight', 'emoji', jsonb_build_object('name', '❤️'),
      'url', 'https://donate.starlight.org/fundraiser/3526698'))));
$$;

-- The standings card.
create or replace function public.dc_giveback_embed(p_crew uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s record; me record; c public.crews; top text; pct numeric; line text;
begin
  select * into c from public.crews where id = p_crew;
  select * into s from public.giveback_snapshots order by taken_at desc limit 1;
  if s.id is null then return null; end if;
  with r as (select e->>'name' as name, (e->>'amount')::numeric as amount, rank() over (order by (e->>'amount')::numeric desc) as rnk
             from jsonb_array_elements(s.groups) e)
  select string_agg(case when lower(name) = lower(c.give_back_name) then '**' || rnk || '. ' || name || '  ' || public.dc_money(amount) || '**'
                         else rnk || '. ' || name || '  ' || public.dc_money(amount) end, E'\n' order by rnk, name)
    into top from r where rnk <= 10;
  with r as (select e->>'name' as name, (e->>'amount')::numeric as amount, rank() over (order by (e->>'amount')::numeric desc) as rnk
             from jsonb_array_elements(s.groups) e)
  select * into me from r where lower(name) = lower(c.give_back_name);
  if me.rnk > 10 then top := top || E'\n…\n**' || me.rnk || '. ' || me.name || '  ' || public.dc_money(me.amount) || '**'; end if;
  pct := case when coalesce(c.give_back_goal, 0) > 0 and me.amount is not null then 100 * me.amount / c.give_back_goal end;
  line := case when me.amount is null then 'Standings for this drive:'
    else '**' || coalesce(c.short_name, c.name) || ': ' || public.dc_money(me.amount) || '**, #' || me.rnk || ' of ' || jsonb_array_length(s.groups) || ' chapters'
      || case when pct is not null then E'\n' || public.dc_bar(pct) || '  ' || round(pct) || '% of our ' || public.dc_money(c.give_back_goal) || ' goal' else '' end end;
  return jsonb_strip_nulls(jsonb_build_object('color', 16729190,
    'author', jsonb_build_object('name', '❤️ Ghostbusters Give Back', 'icon_url', 'https://deftspyder.github.io/busters/icons/icon-192.png'),
    'title', 'Top 10 chapters', 'description', line,
    'fields', jsonb_build_array(jsonb_build_object('name', 'Standings', 'value', left(top, 1024))),
    'footer', jsonb_build_object('text', 'Campaign total ' || public.dc_money(s.total) || ' for Starlight Children''s Foundation · Official numbers lag while Sony approves donations'),
    'timestamp', to_char(s.taken_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
end $$;
revoke all on function public.dc_giveback_embed(uuid) from public, anon, authenticated;

-- Called by the interactions function for /giveback. Decides public (claims the hour) or private.
create or replace function public.discord_giveback(p_app text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.crew_discord; pub boolean;
begin
  select * into d from public.crew_discord where app_id = p_app;
  if d.crew_id is null then return null; end if;
  pub := d.giveback_last_at is null or d.giveback_last_at < now() - interval '1 hour';
  if pub then update public.crew_discord set giveback_last_at = now(), giveback_last_url = null where crew_id = d.crew_id; end if;
  return jsonb_build_object('public', pub, 'embed', public.dc_giveback_embed(d.crew_id), 'components', public.dc_donate_button(),
    'last_url', d.giveback_last_url, 'mins', round(extract(epoch from now() - d.giveback_last_at) / 60));
end $$;
revoke all on function public.discord_giveback(text) from public, anon, authenticated;

create or replace function public.discord_giveback_saved(p_app text, p_url text) returns void
language sql security definer set search_path = '' as $$
  update public.crew_discord set giveback_last_url = p_url where app_id = p_app;
$$;
revoke all on function public.discord_giveback_saved(text, text) from public, anon, authenticated;

-- Milestone posts, checked by the runner (outside quiet hours).
create or replace function public.dc_giveback_milestones() returns int
language plpgsql security definer set search_path = '' as $$
declare d record; amt numeric; rnk int; n_groups int; m numeric; goal numeric; st int; n int := 0; descr text; ttl text; s record;
begin
  select * into s from public.giveback_snapshots order by taken_at desc limit 1;
  if s.id is null then return 0; end if;
  for d in select cd.*, c.give_back_name, c.give_back_goal, coalesce(c.short_name, c.name) as crew_name
           from public.crew_discord cd join public.crews c on c.id = cd.crew_id
           where cd.bot_token is not null and cd.channel_id is not null and cd.post_milestones and c.give_back_name is not null loop
    continue when public.dc_quiet(d.quiet_from, d.quiet_to);
    select x.amount, x.rnk into amt, rnk from (
      select (e->>'amount')::numeric as amount, rank() over (order by (e->>'amount')::numeric desc) as rnk, e->>'name' as name
      from jsonb_array_elements(s.groups) e) x where lower(x.name) = lower(d.give_back_name);
    continue when amt is null;
    n_groups := jsonb_array_length(s.groups); goal := nullif(d.give_back_goal, 0);
    select max(t) into m from (
      select generate_series(5000, 1000000, 5000)::numeric as t
      union select goal * f from unnest(array[.25, .5, .75, 1]) f where goal is not null) th where t <= amt;
    continue when m is null or m <= coalesce(d.giveback_milestone, 0);
    ttl := case when goal is not null and m = goal then d.crew_name || ' hit its ' || public.dc_money(goal) || ' goal!'
                else d.crew_name || ' passed ' || public.dc_money(m) || '!' end;
    descr := public.dc_money(amt) || ' raised for Starlight Children''s Foundation so far, #' || rnk || ' of ' || n_groups || ' chapters.'
      || case when goal is not null then E'\n' || public.dc_bar(100 * amt / goal) || '  ' || round(100 * amt / goal) || '% of our ' || public.dc_money(goal) || ' goal' else '' end
      || E'\n\nThank you to everyone who has given and everyone who has busted for it. Every dollar goes to the kids.';
    st := public.discord_send_payload(d.crew_id, jsonb_build_object(
      'embeds', jsonb_build_array(jsonb_build_object('color', 16729190,
        'author', jsonb_build_object('name', '🎉 Give Back milestone', 'icon_url', 'https://deftspyder.github.io/busters/icons/icon-192.png'),
        'title', ttl, 'description', descr, 'footer', jsonb_build_object('text', 'Ghostbusters Give Back · Busters'))),
      'components', public.dc_donate_button()), ttl);
    insert into public.discord_log (crew_id, kind, status) values (d.crew_id, 'milestone', st);
    if st between 200 and 299 then update public.crew_discord set giveback_milestone = m where crew_id = d.crew_id; n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke all on function public.dc_giveback_milestones() from public, anon, authenticated;

-- Don't announce milestones already passed before this existed.
update public.crew_discord cd set giveback_milestone = x.m from (
  select cd2.crew_id, (select max(t) from (select generate_series(5000, 1000000, 5000)::numeric t
     union select c.give_back_goal * f from unnest(array[.25, .5, .75, 1]) f where c.give_back_goal > 0) th
     where t <= (select (e->>'amount')::numeric from public.giveback_snapshots s, jsonb_array_elements(s.groups) e
                 where lower(e->>'name') = lower(c.give_back_name) order by s.taken_at desc limit 1)) m
  from public.crew_discord cd2 join public.crews c on c.id = cd2.crew_id) x
where cd.crew_id = x.crew_id and cd.giveback_milestone is null;

-- Register the /giveback command in the crew's Discord server (guild commands show up straight away).
create or replace function public.dc_register_commands(p_crew uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record; g text;
begin
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.bot_token is null or d.app_id is null or d.channel_id is null then return 'not connected'; end if;
  select status, content into r from extensions.http(('GET', 'https://discord.com/api/v10/channels/' || d.channel_id,
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token), extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
    null, null)::extensions.http_request);
  if r.status <> 200 then return 'channel lookup failed: ' || r.status; end if;
  g := r.content::jsonb->>'guild_id';
  update public.crew_discord set guild_id = g where crew_id = p_crew;
  select status, content into r from extensions.http(('PUT', 'https://discord.com/api/v10/applications/' || d.app_id || '/guilds/' || g || '/commands',
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token), extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
    'application/json', jsonb_build_array(jsonb_build_object('name', 'giveback', 'type', 1,
      'description', 'Ghostbusters Give Back: top 10 chapters and our progress'))::text)::extensions.http_request);
  return r.status || ' ' || left(r.content, 300);
end $$;
revoke all on function public.dc_register_commands(uuid) from public, anon, authenticated;

-- The runner also checks milestones (applied live by patching discord_run to call it after discord_post_changes).
do $$ declare d text; begin
  d := pg_get_functiondef('public.discord_run()'::regprocedure);
  if position('dc_giveback_milestones' in d) = 0 then
    d := replace(d, 'n := public.discord_post_changes();', 'n := public.discord_post_changes();
  n := n + public.dc_giveback_milestones();');
    execute d;
  end if;
end $$;

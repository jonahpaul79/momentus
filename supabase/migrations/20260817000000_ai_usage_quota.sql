create table if not exists public.ai_usage_daily (
    user_id uuid not null,
    usage_date date not null default current_date,
    units integer not null default 0 check (units >= 0),
    updated_at timestamptz not null default now(),
    primary key (user_id, usage_date)
);

alter table public.ai_usage_daily enable row level security;

create or replace function public.consume_ai_quota(
    p_user_id uuid,
    p_units integer,
    p_daily_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    accepted boolean;
begin
    if p_units < 1 or p_daily_limit < p_units then
        return false;
    end if;

    insert into public.ai_usage_daily (user_id, usage_date, units)
    values (p_user_id, current_date, p_units)
    on conflict (user_id, usage_date) do update
        set units = public.ai_usage_daily.units + excluded.units,
            updated_at = now()
        where public.ai_usage_daily.units + excluded.units <= p_daily_limit
    returning true into accepted;

    return coalesce(accepted, false);
end;
$$;

revoke all on table public.ai_usage_daily from anon, authenticated;
revoke all on function public.consume_ai_quota(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, integer, integer) to service_role;

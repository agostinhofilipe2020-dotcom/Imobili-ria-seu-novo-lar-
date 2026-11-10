-- =====================================================================
-- SEU NOVO LAR — FASE 2: preparação para as apps (só adiciona)
-- Não altera nada do que o site usa hoje.
--  2.1  Tabela "dispositivos" (tokens de notificações push) + função
--       para registar o dispositivo.
--  2.2  Coluna "atualizado_em" nos anúncios (as apps sincronizam só o
--       que mudou).
-- Para desfazer: fase2-reverter.sql
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 2.1  Dispositivos (push)
-- ---------------------------------------------------------------------
create table if not exists public.dispositivos (
  id            uuid primary key default gen_random_uuid(),
  utilizador_id uuid not null references public.perfis(id) on delete cascade,
  token         text not null unique,
  plataforma    text not null check (plataforma in ('android','ios')),
  criado        timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists idx_dispositivos_utilizador
  on public.dispositivos (utilizador_id);

alter table public.dispositivos enable row level security;

drop policy if exists disp_ler    on public.dispositivos;
drop policy if exists disp_apagar on public.dispositivos;
create policy disp_ler    on public.dispositivos for select to authenticated
  using (utilizador_id = auth.uid());
create policy disp_apagar on public.dispositivos for delete to authenticated
  using (utilizador_id = auth.uid());

-- A app só lê e apaga os seus; registar passa pela função abaixo.
revoke all on public.dispositivos from anon, authenticated;
grant select, delete on public.dispositivos to authenticated;

create or replace function public.registar_dispositivo(p_token text, p_plataforma text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then raise exception 'Sem sessão'; end if;
  if p_plataforma not in ('android','ios') then raise exception 'Plataforma inválida'; end if;
  if coalesce(trim(p_token),'') = '' or length(p_token) > 500 then
    raise exception 'Token inválido';
  end if;
  -- Se o telemóvel mudar de conta, o token passa para a conta atual.
  insert into dispositivos(utilizador_id, token, plataforma)
    values (auth.uid(), trim(p_token), p_plataforma)
  on conflict (token) do update
    set utilizador_id = auth.uid(),
        plataforma    = excluded.plataforma,
        atualizado_em = now();
end $$;

revoke all on function public.registar_dispositivo(text, text) from public, anon;
grant execute on function public.registar_dispositivo(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2.2  anuncios.atualizado_em
--      Primeiro preenche com a data de criação, depois liga o gatilho
--      (para o preenchimento não ser sobrescrito).
-- ---------------------------------------------------------------------
alter table public.anuncios
  add column if not exists atualizado_em timestamptz not null default now();

update public.anuncios set atualizado_em = criado
where atualizado_em is distinct from criado;

create or replace function public.set_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists anuncios_atualizado on public.anuncios;
create trigger anuncios_atualizado
  before update on public.anuncios
  for each row execute function public.set_atualizado_em();

create index if not exists idx_anuncios_atualizado
  on public.anuncios (estado, atualizado_em desc);

commit;

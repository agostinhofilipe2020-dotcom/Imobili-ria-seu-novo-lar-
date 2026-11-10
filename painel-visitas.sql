-- =====================================================================
-- SEU NOVO LAR: painel de visitas no Admin  (RASCUNHO PARA REVISÃO)
--
-- NÃO APAGA NADA: só ACRESCENTA uma tabela de visitas, uma tabela com
-- um "sal" secreto e duas funções. Não guarda IP, nome nem e-mail:
-- cada visitante é só um código anónimo que muda todos os dias.
-- Os detalhes das visitas ficam guardados 90 dias.
-- Não usa cookies.
--
-- ORDEM: 1) PARTE 0 (só leitura)  2) PARTE 1  3) PARTE 2 (verificar)
--        4) publicar o index.html.
-- Supabase > SQL Editor > New query > colar > Run.
-- NÃO guardes este ficheiro no repositório do site.
-- =====================================================================

-- ------------------------- PARTE 0: só leitura -----------------------
-- Confirma que as colunas que o painel usa existem.
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'perfis'   and column_name in ('id','papel','criado'))
    or (table_name = 'anuncios' and column_name in ('id','titulo')))
order by table_name, column_name;
-- Devem aparecer 5 linhas: anuncios.id, anuncios.titulo, perfis.criado, perfis.id, perfis.papel.

-- ----------------------------- PARTE 1 -------------------------------

-- 1.1 Sal secreto (só as funções lhe acedem; sem políticas públicas)
create table if not exists public.visitas_sal (
  id  int primary key default 1 check (id = 1),
  sal text not null
);
alter table public.visitas_sal enable row level security;
insert into public.visitas_sal (id, sal)
select 1, md5(random()::text || clock_timestamp()::text)
where not exists (select 1 from public.visitas_sal);

-- 1.2 Visitas (só as funções lhe acedem; sem políticas públicas)
create table if not exists public.visitas (
  id          bigint generated always as identity primary key,
  criado      timestamptz not null default now(),
  dia         date not null,
  visitante   text not null,            -- código anónimo, muda todos os dias
  pagina      text not null,
  anuncio_id  uuid,
  origem      text not null default 'direto',
  dispositivo text not null default 'outro',
  nova_sessao boolean not null default false
);
alter table public.visitas enable row level security;
create index if not exists idx_visitas_dia       on public.visitas (dia);
create index if not exists idx_visitas_anuncio   on public.visitas (anuncio_id, dia) where anuncio_id is not null;
create index if not exists idx_visitas_visitante on public.visitas (visitante, criado desc);

-- 1.3 Registar uma visita (chamada pelo site, em segundo plano)
create or replace function public.registar_visita(
  p_pagina text, p_anuncio uuid default null, p_origem text default 'direto',
  p_dispositivo text default 'outro', p_nova boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  h json; ip text; ua text; v text; sal text; pg text; org text; dev text;
  hoje date := (now() at time zone 'Africa/Luanda')::date;
begin
  begin
    h := (current_setting('request.headers', true))::json;
  exception when others then
    h := null;
  end;
  ua := coalesce(h ->> 'user-agent', '');
  -- ignora robôs e ferramentas automáticas
  if ua = '' or ua ~* '(bot|crawl|spider|slurp|headless|lighthouse|pagespeed|preview|curl|python|wget)' then
    return;
  end if;
  -- ignora os próprios administradores
  if auth.uid() is not null
     and exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin') then
    return;
  end if;
  ip := split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1);
  select s.sal into sal from public.visitas_sal s where s.id = 1;
  v := md5(coalesce(sal, '') || '|' || trim(ip) || '|' || ua || '|' || hoje::text);
  -- limite contra abuso: 120 registos por 10 minutos por visitante
  if (select count(*) from public.visitas where visitante = v and criado > now() - interval '10 minutes') >= 120 then
    return;
  end if;
  pg  := case when p_pagina = any (array['/','/imoveis','/anuncio','/pedidos','/pedido','/novo','/publicar',
              '/novo-pedido','/favoritos','/conta','/entrar','/subscricao','/meus','/meus-pedidos',
              '/notificacoes','/termos','/privacidade','/eliminar-dados','/destacar','/combinam','/editar'])
         then p_pagina else '/outra' end;
  org := case when p_origem = any (array['direto','google','whatsapp','facebook','instagram','outro'])
         then p_origem else 'outro' end;
  dev := case when p_dispositivo = any (array['telemovel','tablet','computador'])
         then p_dispositivo else 'outro' end;
  insert into public.visitas (dia, visitante, pagina, anuncio_id, origem, dispositivo, nova_sessao)
  values (hoje, v, pg, case when pg = '/anuncio' then p_anuncio else null end, org, dev, coalesce(p_nova, false));
  -- limpeza: apaga visitas com mais de 90 dias (1 vez em cada 100)
  if random() < 0.01 then
    delete from public.visitas where criado < now() - interval '90 days';
  end if;
end $$;

-- 1.4 Resumo para o painel (SÓ ADMINISTRADORES)
create or replace function public.painel_visitas(p_dias int default 30)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  dn   int  := least(greatest(coalesce(p_dias, 30), 1), 180);
  hoje date := (now() at time zone 'Africa/Luanda')::date;
  d0   date;
  res  jsonb;
begin
  if not exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin') then
    raise exception 'Sem permissão.';
  end if;
  d0 := hoje - (dn - 1);
  select jsonb_build_object(
    'dias', dn,
    'totais', jsonb_build_object(
      'hoje',    (select jsonb_build_object('visualizacoes', count(*), 'visitas', count(*) filter (where nova_sessao),
                         'visitantes', count(distinct visitante)) from public.visitas where dia = hoje),
      'ult7',    (select jsonb_build_object('visualizacoes', count(*), 'visitas', count(*) filter (where nova_sessao),
                         'visitantes', count(distinct (dia, visitante))) from public.visitas where dia >= hoje - 6),
      'periodo', (select jsonb_build_object('visualizacoes', count(*), 'visitas', count(*) filter (where nova_sessao),
                         'visitantes', count(distinct (dia, visitante))) from public.visitas where dia >= d0)),
    'serie', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'dia', g.dia, 'visualizacoes', coalesce(v.vz, 0), 'visitas', coalesce(v.vs, 0),
               'visitantes', coalesce(v.un, 0), 'contas', coalesce(c.n, 0), 'logins', coalesce(l.n, 0))
             order by g.dia), '[]'::jsonb)
      from (select gs::date as dia from generate_series(d0::timestamp, hoje::timestamp, interval '1 day') gs) g
      left join (select dia, count(*) as vz, count(*) filter (where nova_sessao) as vs, count(distinct visitante) as un
                 from public.visitas where dia >= d0 group by dia) v on v.dia = g.dia
      left join (select (criado at time zone 'Africa/Luanda')::date as dia, count(*) as n
                 from public.perfis where criado >= d0 group by 1) c on c.dia = g.dia
      left join (select (last_sign_in_at at time zone 'Africa/Luanda')::date as dia, count(*) as n
                 from auth.users where last_sign_in_at >= d0 group by 1) l on l.dia = g.dia),
    'paginas', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
        select pagina, count(*) as visualizacoes from public.visitas
        where dia >= d0 group by pagina order by 2 desc limit 10) x),
    'anuncios', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
        select v.anuncio_id as id, coalesce(a.titulo, '(anúncio apagado)') as titulo,
               count(*) as visualizacoes, count(distinct (v.dia, v.visitante)) as visitantes
        from public.visitas v left join public.anuncios a on a.id = v.anuncio_id
        where v.dia >= d0 and v.anuncio_id is not null
        group by v.anuncio_id, a.titulo order by 3 desc limit 10) x),
    'origens', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
        select origem, count(*) as visitas from public.visitas
        where dia >= d0 and nova_sessao group by origem order by 2 desc) x),
    'dispositivos', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
        select dispositivo, count(*) as visitas from public.visitas
        where dia >= d0 and nova_sessao group by dispositivo order by 2 desc) x),
    'contas', jsonb_build_object(
      'total', (select count(*) from public.perfis),
      'novas', (select count(*) from public.perfis where criado >= d0)),
    'logins', (select count(*) from auth.users where last_sign_in_at >= d0)
  ) into res;
  return res;
end $$;

-- 1.5 Permissões
revoke all on function public.registar_visita(text, uuid, text, text, boolean) from public;
revoke all on function public.painel_visitas(int) from public;
grant execute on function public.registar_visita(text, uuid, text, text, boolean) to anon, authenticated;
grant execute on function public.painel_visitas(int) to authenticated;

notify pgrst, 'reload schema';

-- ------------------- PARTE 2: verificar (só leitura) -----------------
select 'tabela ' || x.nome as peca,
       case when exists (select 1 from information_schema.tables
                         where table_schema = 'public' and table_name = x.nome)
            then 'sim' else 'NÃO EXISTE' end as estado
from (values ('visitas'), ('visitas_sal')) as x(nome)
union all
select 'funcao ' || y.nome,
       case when exists (select 1 from pg_proc
                         where pronamespace = 'public'::regnamespace and proname = y.nome)
            then 'sim' else 'NÃO EXISTE' end
from (values ('registar_visita'), ('painel_visitas')) as y(nome);

-- ------------------------------ ROLLBACK -----------------------------
-- Remover tudo o que este ficheiro acrescentou (só se for mesmo preciso):
--   drop function if exists public.painel_visitas(int);
--   drop function if exists public.registar_visita(text, uuid, text, text, boolean);
--   drop table if exists public.visitas;
--   drop table if exists public.visitas_sal;

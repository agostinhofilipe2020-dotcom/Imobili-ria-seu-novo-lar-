-- SEU NOVO LAR · esquema inicial (Supabase / PostgreSQL)
-- Cola no SQL Editor e toca em Run. Podes correr uma vez só.
-- Nada aqui inventa preços: valores e duração da subscrição ficam em "config".

create extension if not exists pgcrypto;

-- ============ CONFIGURAÇÃO EDITÁVEL ============
create table public.config (
  chave text primary key,
  valor text,
  nota text
);
insert into public.config(chave, valor, nota) values
  ('dias_subscricao', null, 'POR DEFINIR: duração da subscrição em dias'),
  ('preco_subscricao', null, 'POR DEFINIR'),
  ('preco_destaque', null, 'POR DEFINIR');

-- ============ PERFIS ============
create table public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text,
  telefone text,
  tipo_conta text not null default 'particular' check (tipo_conta in ('particular','profissional')),
  verificacao text not null default 'nao_verificado' check (verificacao in ('nao_verificado','em_analise','verificado','recusada')),
  papel text not null default 'utilizador' check (papel in ('utilizador','admin')),
  criado timestamptz not null default now()
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis(id, nome) values (new.id, coalesce(new.raw_user_meta_data->>'name', new.raw_user_meta_data->>'full_name'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from perfis where id = auth.uid() and papel = 'admin');
$$;

-- ============ ANÚNCIOS ============
create table public.anuncios (
  id uuid primary key default gen_random_uuid(),
  anunciante_id uuid not null references public.perfis(id) on delete cascade,
  finalidade text not null check (finalidade in ('venda','arrendamento')),
  tipo text not null check (tipo in ('apartamento','moradia','terreno','comercial','escritorio')),
  titulo text not null check (char_length(titulo) between 10 and 100),
  descricao_publica text not null check (char_length(descricao_publica) <= 2000),
  preco numeric check (preco is null or preco >= 0),
  provincia text not null,
  municipio text not null,
  zona text,
  quartos int check (quartos >= 0),
  casas_banho int check (casas_banho >= 0),
  area_m2 numeric check (area_m2 > 0),
  mobilado boolean,
  estado text not null default 'publicado' check (estado in ('rascunho','publicado','denunciado','correcao_solicitada','suspenso','removido','encerrado')),
  criado timestamptz not null default now()
);
create index on public.anuncios (estado, municipio, tipo);

-- Campos reservados a subscritores (protegidos no servidor, não só escondidos)
create table public.anuncios_reservado (
  anuncio_id uuid primary key references public.anuncios(id) on delete cascade,
  descricao_completa text,
  telefone_contacto text,
  localizacao_detalhada text
);

create table public.fotografias (
  id uuid primary key default gen_random_uuid(),
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  caminho text not null,
  ordem int not null default 0
);

create table public.favoritos (
  utilizador_id uuid not null references public.perfis(id) on delete cascade,
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  criado timestamptz not null default now(),
  primary key (utilizador_id, anuncio_id)
);

-- ============ PAGAMENTOS, SUBSCRIÇÕES, DESTAQUES ============
create table public.pagamentos (
  id uuid primary key default gen_random_uuid(),
  utilizador_id uuid not null references public.perfis(id) on delete cascade,
  produto text not null check (produto in ('subscricao','destaque')),
  anuncio_id uuid references public.anuncios(id) on delete set null,
  valor numeric,
  metodo text not null check (metodo in ('transferencia','referencia')),
  estado text not null default 'pendente' check (estado in ('pendente','em_analise','confirmado','rejeitado')),
  comprovativo text,
  motivo text,
  decidido_por uuid references public.perfis(id),
  decidido_em timestamptz,
  criado timestamptz not null default now(),
  check (produto <> 'destaque' or anuncio_id is not null)
);

create table public.subscricoes (
  id uuid primary key default gen_random_uuid(),
  utilizador_id uuid not null references public.perfis(id) on delete cascade,
  pagamento_id uuid not null unique references public.pagamentos(id),  -- um pagamento ativa só uma vez
  estado text not null default 'ativa' check (estado in ('pendente','ativa','expirada','cancelada')),
  inicio timestamptz not null,
  fim timestamptz not null
);

create table public.destaques (
  id uuid primary key default gen_random_uuid(),
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  pagamento_id uuid not null unique references public.pagamentos(id),
  estado text not null default 'ativo' check (estado in ('pendente','ativo','terminado')),
  inicio timestamptz not null,
  fim timestamptz not null
);

create table public.denuncias (
  id uuid primary key default gen_random_uuid(),
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  denunciante_id uuid references public.perfis(id) on delete set null,
  motivo text not null,
  estado text not null default 'aberta' check (estado in ('aberta','em_revisao','mantido','correcao','suspenso','removido')),
  decisao text,
  decidido_por uuid references public.perfis(id),
  decidido_em timestamptz,
  criado timestamptz not null default now()
);

create table public.auditoria (
  id bigint generated always as identity primary key,
  autor uuid,
  acao text not null,
  entidade text,
  entidade_id uuid,
  motivo text,
  criado timestamptz not null default now()
);

-- ============ FUNÇÕES ============
create function public.tem_subscricao_ativa() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from subscricoes
    where utilizador_id = auth.uid() and estado = 'ativa' and fim > now());
$$;

create function public.aprovar_pagamento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p pagamentos; dias int;
begin
  if not is_admin() then raise exception 'Sem permissão'; end if;
  select * into p from pagamentos where id = p_id for update;
  if not found or p.estado not in ('pendente','em_analise') then
    raise exception 'Pedido inexistente ou já decidido';
  end if;
  if p.produto = 'subscricao' then
    select valor::int into dias from config where chave = 'dias_subscricao';
    if dias is null then raise exception 'Define config.dias_subscricao antes de aprovar'; end if;
    insert into subscricoes(utilizador_id, pagamento_id, estado, inicio, fim)
      values (p.utilizador_id, p.id, 'ativa', now(), now() + make_interval(days => dias));
  else
    insert into destaques(anuncio_id, pagamento_id, estado, inicio, fim)
      values (p.anuncio_id, p.id, 'ativo', now(), now() + interval '7 days');
  end if;
  update pagamentos set estado = 'confirmado', decidido_por = auth.uid(), decidido_em = now() where id = p.id;
  insert into auditoria(autor, acao, entidade, entidade_id) values (auth.uid(), 'aprovar_pagamento', 'pagamentos', p.id);
end $$;

create function public.rejeitar_pagamento(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Sem permissão'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Motivo obrigatório'; end if;
  update pagamentos set estado = 'rejeitado', motivo = p_motivo, decidido_por = auth.uid(), decidido_em = now()
    where id = p_id and estado in ('pendente','em_analise');
  if not found then raise exception 'Pedido inexistente ou já decidido'; end if;
  insert into auditoria(autor, acao, entidade, entidade_id, motivo) values (auth.uid(), 'rejeitar_pagamento', 'pagamentos', p_id, p_motivo);
end $$;

-- ============ SEGURANÇA (RLS) ============
alter table public.config enable row level security;
alter table public.perfis enable row level security;
alter table public.anuncios enable row level security;
alter table public.anuncios_reservado enable row level security;
alter table public.fotografias enable row level security;
alter table public.favoritos enable row level security;
alter table public.pagamentos enable row level security;
alter table public.subscricoes enable row level security;
alter table public.destaques enable row level security;
alter table public.denuncias enable row level security;
alter table public.auditoria enable row level security;

-- config: só admin
create policy config_admin on public.config for all using (is_admin()) with check (is_admin());

-- perfis: cada um vê/edita o seu; admin vê todos. Papel e verificação nunca editáveis pelo utilizador.
create policy perfis_ler on public.perfis for select using (id = auth.uid() or is_admin());
create policy perfis_editar on public.perfis for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.perfis from authenticated, anon;
grant update (nome, telefone, tipo_conta) on public.perfis to authenticated;

-- anúncios: públicos se publicados; dono gere os seus; admin tudo
create policy anuncios_publicos on public.anuncios for select
  using (estado = 'publicado' or anunciante_id = auth.uid() or is_admin());
create policy anuncios_criar on public.anuncios for insert to authenticated
  with check (anunciante_id = auth.uid() and estado in ('rascunho','publicado'));
create policy anuncios_editar on public.anuncios for update to authenticated
  using (anunciante_id = auth.uid() or is_admin())
  with check ((anunciante_id = auth.uid() and estado in ('rascunho','publicado','encerrado')) or is_admin());

-- campos reservados: dono, admin ou subscritor ativo
create policy reservado_ler on public.anuncios_reservado for select to authenticated
  using (is_admin() or tem_subscricao_ativa()
    or exists(select 1 from anuncios a where a.id = anuncio_id and a.anunciante_id = auth.uid()));
create policy reservado_escrever on public.anuncios_reservado for all to authenticated
  using (exists(select 1 from anuncios a where a.id = anuncio_id and a.anunciante_id = auth.uid()))
  with check (exists(select 1 from anuncios a where a.id = anuncio_id and a.anunciante_id = auth.uid()));

-- fotografias: leitura pública de anúncios publicados; dono gere
create policy fotos_ler on public.fotografias for select
  using (exists(select 1 from anuncios a where a.id = anuncio_id and (a.estado = 'publicado' or a.anunciante_id = auth.uid() or is_admin())));
create policy fotos_escrever on public.fotografias for all to authenticated
  using (exists(select 1 from anuncios a where a.id = anuncio_id and a.anunciante_id = auth.uid()))
  with check (exists(select 1 from anuncios a where a.id = anuncio_id and a.anunciante_id = auth.uid()));

-- favoritos: só os próprios
create policy fav_proprios on public.favoritos for all to authenticated
  using (utilizador_id = auth.uid()) with check (utilizador_id = auth.uid());

-- pagamentos: utilizador cria (sempre pendente) e vê os seus; decisões só pelas funções
create policy pag_ler on public.pagamentos for select to authenticated using (utilizador_id = auth.uid() or is_admin());
create policy pag_criar on public.pagamentos for insert to authenticated
  with check (utilizador_id = auth.uid() and estado = 'pendente' and decidido_por is null and valor is null);

-- subscrições e destaques: leitura; escrita só pela função aprovar_pagamento
create policy sub_ler on public.subscricoes for select to authenticated using (utilizador_id = auth.uid() or is_admin());
create policy dest_ler on public.destaques for select using (true);

-- denúncias: qualquer sessão cria; admin gere
create policy den_criar on public.denuncias for insert to authenticated with check (denunciante_id = auth.uid());
create policy den_admin on public.denuncias for all using (is_admin()) with check (is_admin());

-- auditoria: só admin lê
create policy aud_ler on public.auditoria for select using (is_admin());

-- ============ ARMAZENAMENTO DE FOTOS ============
insert into storage.buckets(id, name, public) values ('fotos-anuncios', 'fotos-anuncios', true) on conflict do nothing;
create policy fotos_ver on storage.objects for select using (bucket_id = 'fotos-anuncios');
create policy fotos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos-anuncios' and (storage.foldername(name))[1] = auth.uid()::text);
create policy fotos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'fotos-anuncios' and (storage.foldername(name))[1] = auth.uid()::text);

-- DEPOIS DE CORRER: torna-te administrador (troca o e-mail pelo teu):
-- update public.perfis set papel = 'admin' where id = (select id from auth.users where email = 'o-teu-email@exemplo.com');

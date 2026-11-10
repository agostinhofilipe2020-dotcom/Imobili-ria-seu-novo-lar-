-- =====================================================================
-- SEU NOVO LAR: acesso gratuito + destaques pagos  (RASCUNHO PARA REVISÃO)
--
-- NÃO APAGA NADA: nenhuma tabela, registo, pagamento ou subscrição.
-- Só ACRESCENTA: uma configuração, uma tabela de controlo, funções e
-- um gatilho. As regras de segurança atuais ficam INTACTAS.
-- Desfaz-se com os comandos da secção ROLLBACK, no fim.
--
-- ORDEM: 1) PARTE 0 (só leitura)  2) PARTE 1  3) depois publicar o index.html.
-- Supabase > SQL Editor > New query > colar > Run.
-- NÃO guardes este ficheiro no repositório do site.
-- =====================================================================

-- ------------------------- PARTE 0: só leitura -----------------------
-- Confirma tipos de colunas (assumi que os ids são "uuid") e mostra
-- os números atuais. Envia-me o resultado antes de correr a PARTE 1.
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public' and (
     (table_name = 'anuncios'              and column_name in ('id','anunciante_id','estado'))
  or (table_name = 'anuncios_reservado'    and column_name in ('anuncio_id','telefone_contacto','descricao_completa','localizacao_detalhada','latitude','longitude'))
  or (table_name = 'pedidos_casa'          and column_name in ('id','estado','expira','autor_id'))
  or (table_name = 'pedidos_casa_contacto' and column_name in ('pedido_id','telefone'))
  or (table_name = 'perfis'                and column_name in ('id','nome','papel'))
  or (table_name = 'config'                and column_name in ('chave','valor'))
  or (table_name = 'pagamentos'            and column_name in ('produto','estado'))
  or (table_name = 'subscricoes'           and column_name in ('utilizador_id','estado','fim')))
order by table_name, column_name;

-- Subscrições existentes (só números)
select count(*) filter (where estado = 'ativa' and fim > now()) as subscricoes_ativas,
       count(*) as total_subscricoes
from public.subscricoes;

-- Pagamentos por produto e estado (só números)
select produto, estado, count(*) as n from public.pagamentos group by 1, 2 order by 1, 2;

-- Configurações (os dados de IBAN/Express NÃO são mostrados, só se estão preenchidos)
select chave,
       case when chave like 'instrucoes%' then 'preenchido=' || (coalesce(valor,'') <> '')::text
            else valor end as valor
from public.config order by chave;

-- ----------------------------- PARTE 1 -------------------------------

-- 1.1 Interruptor do modelo de acesso: 'livre' (agora) ou 'subscricao' (futuro)
insert into public.config (chave, valor)
select 'modo_acesso', 'livre'
where not exists (select 1 from public.config where chave = 'modo_acesso');

-- 1.2 Registo de consultas de contactos (para travar recolhas em massa).
--     Só as funções abaixo lhe acedem (RLS ligado e sem políticas públicas).
create table if not exists public.contacto_acessos (
  id     bigint generated always as identity primary key,
  chave  text not null,
  criado timestamptz not null default now()
);
alter table public.contacto_acessos enable row level security;
create index if not exists idx_contacto_acessos on public.contacto_acessos (chave, criado desc);

-- 1.3 Funções auxiliares
create or replace function public.modo_acesso()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select valor from public.config where chave = 'modo_acesso' limit 1), 'subscricao')
$$;

create or replace function public._chave_acesso()
returns text language plpgsql stable as $$
declare h text;
begin
  if auth.uid() is not null then return 'u:' || auth.uid()::text; end if;
  begin
    h := split_part(coalesce((current_setting('request.headers', true))::json ->> 'x-forwarded-for', ''), ',', 1);
  exception when others then h := '';
  end;
  return 'ip:' || coalesce(nullif(trim(h), ''), 'desconhecido');
end $$;

-- Limite: 300 consultas por 10 minutos por utilizador (ou por IP, se for visitante).
-- Ajustável: muitos telemóveis em Angola partilham o mesmo IP, por isso é folgado.
create or replace function public._limite_contactos(p_max int)
returns void language plpgsql security definer set search_path = public as $$
declare k text := public._chave_acesso(); n int;
begin
  select count(*) into n from public.contacto_acessos where chave = k and criado > now() - interval '10 minutes';
  if n >= p_max then
    raise exception 'Demasiados pedidos. Tenta de novo dentro de alguns minutos.';
  end if;
  insert into public.contacto_acessos (chave) values (k);
  if random() < 0.02 then
    delete from public.contacto_acessos where criado < now() - interval '1 day';
  end if;
end $$;

create or replace function public._pode_ver_contactos(p_dono uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.modo_acesso() = 'livre'
      or auth.uid() = p_dono
      or exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin')
      or exists (select 1 from public.subscricoes
                 where utilizador_id = auth.uid() and estado = 'ativa' and fim > now())
$$;

-- 1.4 Contacto de UM anúncio (nunca devolve a lista completa)
create or replace function public.obter_contacto(p_anuncio uuid)
returns table (telefone_contacto text, descricao_completa text, localizacao_detalhada text,
               latitude double precision, longitude double precision, nome text, modo text)
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select an.id, an.anunciante_id, an.estado into a from public.anuncios an where an.id = p_anuncio;
  if not found then return; end if;
  if a.estado <> 'publicado'
     and not (auth.uid() = a.anunciante_id
              or exists (select 1 from public.perfis x where x.id = auth.uid() and x.papel = 'admin')) then
    return;
  end if;
  if not public._pode_ver_contactos(a.anunciante_id) then return; end if;
  perform public._limite_contactos(300);
  return query
    select r.telefone_contacto::text, r.descricao_completa::text, r.localizacao_detalhada::text,
           r.latitude::double precision, r.longitude::double precision,
           (select pf.nome::text from public.perfis pf where pf.id = a.anunciante_id),
           public.modo_acesso()
    from public.anuncios_reservado r where r.anuncio_id = p_anuncio;
end $$;

-- 1.5 Contactos dos pedidos de casa (só dos pedidos pedidos, no máximo 60 de cada vez)
create or replace function public.contactos_pedidos(p_ids uuid[])
returns table (pedido_id uuid, telefone text)
language plpgsql security definer set search_path = public as $$
begin
  if p_ids is null or array_length(p_ids, 1) is null then return; end if;
  if array_length(p_ids, 1) > 60 then raise exception 'Máximo de 60 pedidos por consulta.'; end if;
  perform public._limite_contactos(300);
  return query
    select c.pedido_id, c.telefone::text
    from public.pedidos_casa_contacto c
    join public.pedidos_casa p on p.id = c.pedido_id
    where c.pedido_id = any (p_ids)
      and ( (p.estado = 'ativo' and p.expira > now() and public._pode_ver_contactos(p.autor_id))
            or p.autor_id = auth.uid()
            or exists (select 1 from public.perfis x where x.id = auth.uid() and x.papel = 'admin') );
end $$;

-- 1.6 Permissões de execução (visitantes e utilizadores)
revoke all on function public.modo_acesso()            from public;
revoke all on function public.obter_contacto(uuid)     from public;
revoke all on function public.contactos_pedidos(uuid[]) from public;
revoke all on function public._limite_contactos(int)   from public;
revoke all on function public._pode_ver_contactos(uuid) from public;
revoke all on function public._chave_acesso()          from public;
grant execute on function public.modo_acesso()            to anon, authenticated;
grant execute on function public.obter_contacto(uuid)     to anon, authenticated;
grant execute on function public.contactos_pedidos(uuid[]) to anon, authenticated;

-- 1.7 Enquanto o acesso for livre, ninguém consegue criar NOVOS pedidos de
--     subscrição (evita que alguém pague por algo que já não é preciso).
--     Pagamentos e subscrições existentes não são tocados.
create or replace function public.bloquear_subscricao_gratis()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.produto = 'subscricao' and public.modo_acesso() = 'livre' then
    raise exception 'As subscrições não estão disponíveis nesta fase: o acesso é gratuito.';
  end if;
  return new;
end $$;
drop trigger if exists aaa_bloquear_subscricao_gratis on public.pagamentos;
create trigger aaa_bloquear_subscricao_gratis
  before insert on public.pagamentos
  for each row execute function public.bloquear_subscricao_gratis();

-- ------------------------------ ROLLBACK -----------------------------
-- Voltar ao modelo anterior (acesso por subscrição) sem apagar nada:
--   update public.config set valor = 'subscricao' where chave = 'modo_acesso';
-- Remover tudo o que esta parte acrescentou (só se for mesmo preciso):
--   drop trigger if exists aaa_bloquear_subscricao_gratis on public.pagamentos;
--   drop function if exists public.bloquear_subscricao_gratis();
--   drop function if exists public.contactos_pedidos(uuid[]);
--   drop function if exists public.obter_contacto(uuid);
--   drop function if exists public._pode_ver_contactos(uuid);
--   drop function if exists public._limite_contactos(int);
--   drop function if exists public._chave_acesso();
--   drop function if exists public.modo_acesso();
--   drop table if exists public.contacto_acessos;
--   delete from public.config where chave = 'modo_acesso';

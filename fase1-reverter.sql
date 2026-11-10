-- =====================================================================
-- SEU NOVO LAR — REVERTER A FASE 1
-- Só correr se algo falhar depois de fase1-seguranca.sql.
-- Repõe as políticas, o bucket e as permissões como estavam.
-- =====================================================================

begin;

-- 1.1 Denúncias: política original
alter policy den_criar on public.denuncias
  with check (denunciante_id = auth.uid());

-- 1.2 Contactos reservados: política original
alter policy reservado_ler on public.anuncios_reservado
  using (
    is_admin()
    or tem_subscricao_ativa()
    or exists (
      select 1 from public.anuncios a
      where a.id = anuncios_reservado.anuncio_id
        and a.anunciante_id = auth.uid()
    )
  );

-- 1.3 Bucket de fotografias: sem limites (como antes)
update storage.buckets
set file_size_limit = null,
    allowed_mime_types = null
where id = 'fotos-anuncios';

-- 1.4 Permissões: repor exatamente as que existiam
grant truncate, references, trigger
  on all tables in schema public to anon, authenticated;

-- anon: INSERT/UPDATE/DELETE em todas, menos UPDATE em perfis e notificacoes
grant insert, update, delete
  on public.anuncios, public.anuncios_reservado, public.auditoria, public.config,
     public.denuncias, public.destaques, public.favoritos, public.fotografias,
     public.pagamentos, public.pedidos_casa, public.pedidos_casa_contacto,
     public.pedidos_denuncias, public.subscricoes
  to anon;
grant insert, delete on public.perfis, public.notificacoes to anon;

-- authenticated
grant insert, update, delete
  on public.auditoria, public.config, public.destaques, public.subscricoes
  to authenticated;
grant update, delete
  on public.pagamentos, public.denuncias, public.pedidos_denuncias,
     public.pedidos_casa_contacto
  to authenticated;
grant insert, delete on public.notificacoes, public.perfis to authenticated;

-- 1.5 Índices criados pela Fase 1 (os que já existiam antes não são tocados)
drop index if exists public.idx_anuncios_estado_criado;
drop index if exists public.idx_anuncios_estado_tipo;
drop index if exists public.idx_anuncios_estado_finalid;
drop index if exists public.idx_anuncios_estado_preco;
drop index if exists public.idx_anuncios_anunciante;
drop index if exists public.idx_anuncios_municipio_trgm;
drop index if exists public.idx_fotografias_anuncio_ordem;
drop index if exists public.idx_destaques_estado_fim;
drop index if exists public.idx_destaques_anuncio;
drop index if exists public.idx_favoritos_utilizador;
drop index if exists public.idx_favoritos_anuncio;
drop index if exists public.idx_subs_utilizador;
drop index if exists public.idx_pedidos_estado_expira;
drop index if exists public.idx_pedidos_autor;
drop index if exists public.idx_pagamentos_estado;
drop index if exists public.idx_pagamentos_utilizador;

commit;

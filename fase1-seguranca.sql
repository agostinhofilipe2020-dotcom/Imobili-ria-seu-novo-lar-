-- =====================================================================
-- SEU NOVO LAR — FASE 1: segurança e desempenho
-- Não apaga nem altera dados. Só aperta permissões, define limites
-- de ficheiros e cria índices (atalhos de pesquisa).
-- Para desfazer: correr o ficheiro fase1-reverter.sql
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run
-- Recomendado: correr primeiro num projeto de teste.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1.1  Denúncias: o denunciante só pode criar denúncias "abertas".
--      Antes, podia inserir uma denúncia já com decisão preenchida.
-- ---------------------------------------------------------------------
alter policy den_criar on public.denuncias
  with check (
    denunciante_id = auth.uid()
    and estado = 'aberta'
    and decisao is null
    and decidido_por is null
    and decidido_em is null
  );

-- ---------------------------------------------------------------------
-- 1.2  Contactos reservados: quem tem subscrição só vê contactos de
--      anúncios PUBLICADOS. Dono do anúncio e admin mantêm o acesso.
--      Antes, um subscritor podia ler contactos de rascunhos, suspensos
--      e removidos.
-- ---------------------------------------------------------------------
alter policy reservado_ler on public.anuncios_reservado
  using (
    is_admin()
    or exists (
      select 1 from public.anuncios a
      where a.id = anuncios_reservado.anuncio_id
        and a.anunciante_id = auth.uid()
    )
    or (
      tem_subscricao_ativa()
      and exists (
        select 1 from public.anuncios a
        where a.id = anuncios_reservado.anuncio_id
          and a.estado = 'publicado'
      )
    )
  );

-- ---------------------------------------------------------------------
-- 1.3  Fotografias: limite de tamanho e tipos aceites.
--      O site já comprime para JPEG antes de enviar; 10 MB é o mesmo
--      limite que o site aplica ao escolher a foto.
--      Não afeta as fotografias que já existem.
-- ---------------------------------------------------------------------
update storage.buckets
set file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'fotos-anuncios';

-- ---------------------------------------------------------------------
-- 1.4  Permissões das tabelas (camada extra por baixo do RLS).
--      Só se retira o que o site NÃO usa. Leitura e as escritas que o
--      site faz ficam como estão. As regras RLS continuam a valer.
--      (Verificado contra o código do site: ver lista abaixo.)
-- ---------------------------------------------------------------------

-- Nunca necessários através da API
revoke truncate, references, trigger
  on all tables in schema public from anon, authenticated;

-- Visitantes sem sessão (anon) nunca escrevem
revoke insert, update, delete
  on all tables in schema public from anon;

-- Utilizadores com sessão: tabelas que só mudam por funções do servidor
revoke insert, update, delete
  on public.auditoria, public.config, public.destaques, public.subscricoes
  from authenticated;

-- Só criam registos (nunca editam nem apagam diretamente)
revoke update, delete
  on public.pagamentos, public.denuncias, public.pedidos_denuncias,
     public.pedidos_casa_contacto
  from authenticated;

-- Notificações: só marcar como lida (UPDATE por coluna fica como está).
-- Perfis: o perfil é criado pelo servidor; edição por coluna fica como está.
revoke insert, delete
  on public.notificacoes, public.perfis
  from authenticated;

-- ---------------------------------------------------------------------
-- 1.5  Índices (listagens, filtros, favoritos, notificações, pedidos).
--      "if not exists": se já existir, é ignorado.
-- ---------------------------------------------------------------------
create index if not exists idx_anuncios_estado_criado  on public.anuncios (estado, criado desc);
create index if not exists idx_anuncios_estado_tipo    on public.anuncios (estado, tipo);
create index if not exists idx_anuncios_estado_finalid on public.anuncios (estado, finalidade);
create index if not exists idx_anuncios_estado_preco   on public.anuncios (estado, preco);
create index if not exists idx_anuncios_anunciante     on public.anuncios (anunciante_id);

create extension if not exists pg_trgm with schema extensions;
create index if not exists idx_anuncios_municipio_trgm
  on public.anuncios using gin (municipio extensions.gin_trgm_ops);

create index if not exists idx_fotografias_anuncio_ordem on public.fotografias (anuncio_id, ordem);

create index if not exists idx_destaques_estado_fim on public.destaques (estado, fim);
create index if not exists idx_destaques_anuncio    on public.destaques (anuncio_id);

create index if not exists idx_favoritos_utilizador on public.favoritos (utilizador_id);
create index if not exists idx_favoritos_anuncio    on public.favoritos (anuncio_id);

create index if not exists idx_subs_utilizador on public.subscricoes (utilizador_id, estado, fim desc);

create index if not exists idx_pedidos_estado_expira on public.pedidos_casa (estado, expira, criado desc);
create index if not exists idx_pedidos_autor         on public.pedidos_casa (autor_id);

create index if not exists idx_pagamentos_estado     on public.pagamentos (estado);
create index if not exists idx_pagamentos_utilizador on public.pagamentos (utilizador_id, criado desc);

commit;

analyze public.anuncios;
analyze public.fotografias;
analyze public.destaques;

-- =====================================================================
-- TESTES DEPOIS DE CORRER (no site, com conta normal e com a admin):
--  1. Entrar e sair (e-mail e Google).
--  2. Ver a lista de imóveis e abrir um anúncio.
--  3. Com subscrição: abrir um anúncio e ver o contacto.
--  4. Publicar um anúncio com 2 fotografias; editar e apagar.
--  5. Denunciar um anúncio; criar um pedido de casa.
--  6. Pedir um destaque e anexar comprovativo.
--  7. Marcar uma notificação como lida; adicionar/remover favorito.
--  8. Admin: aprovar/rejeitar pagamento, decidir denúncia, guardar preços.
-- Se algo falhar: correr fase1-reverter.sql e dizer-me qual passo falhou.
-- =====================================================================

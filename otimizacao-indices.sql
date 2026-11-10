-- =====================================================================
-- SEU NOVO LAR: otimização da base de dados (Fase C)
-- Estes comandos NÃO apagam nem alteram nenhum dado.
-- Só criam "índices" (atalhos de pesquisa). Se um índice já existir,
-- o comando é ignorado (IF NOT EXISTS). Se alguma coluna não existir
-- com este nome, o Supabase mostra um erro e não muda nada.
-- Como usar: Supabase > SQL Editor > New query > colar > Run.
-- Corre PRIMEIRO a PARTE 1 (só lê) e envia-me o resultado.
-- =====================================================================

-- ---------------------- PARTE 1: só leitura ---------------------------
-- Lista os índices que já existem nas tabelas do site.
select tablename, indexname
from pg_indexes
where schemaname = 'public'
  and tablename in ('anuncios','fotografias','destaques','favoritos','notificacoes',
                    'subscricoes','pedidos_casa','pagamentos')
order by tablename, indexname;

-- ---------------------- PARTE 2: criar índices ------------------------
-- Só corre depois de eu confirmar a PARTE 1.

-- Listagens e filtros de anúncios publicados
create index if not exists idx_anuncios_estado_criado   on public.anuncios (estado, criado desc);
create index if not exists idx_anuncios_estado_tipo     on public.anuncios (estado, tipo);
create index if not exists idx_anuncios_estado_finalid  on public.anuncios (estado, finalidade);
create index if not exists idx_anuncios_estado_preco    on public.anuncios (estado, preco);
create index if not exists idx_anuncios_anunciante      on public.anuncios (anunciante_id);

-- Pesquisa por município (aceita pesquisa parcial, ex.: "tala")
create extension if not exists pg_trgm with schema extensions;
create index if not exists idx_anuncios_municipio_trgm
  on public.anuncios using gin (municipio extensions.gin_trgm_ops);

-- Fotografias de cada anúncio, já por ordem
create index if not exists idx_fotografias_anuncio_ordem on public.fotografias (anuncio_id, ordem);

-- Destaques ativos
create index if not exists idx_destaques_estado_fim on public.destaques (estado, fim);
create index if not exists idx_destaques_anuncio    on public.destaques (anuncio_id);

-- Favoritos
create index if not exists idx_favoritos_utilizador on public.favoritos (utilizador_id);
create index if not exists idx_favoritos_anuncio    on public.favoritos (anuncio_id);

-- Notificações e subscrições (consultadas por cada utilizador com sessão)
create index if not exists idx_notif_utilizador   on public.notificacoes (utilizador_id, lida, criado desc);
create index if not exists idx_subs_utilizador    on public.subscricoes (utilizador_id, estado, fim desc);

-- Pedidos de casa
create index if not exists idx_pedidos_estado_expira on public.pedidos_casa (estado, expira, criado desc);
create index if not exists idx_pedidos_autor         on public.pedidos_casa (autor_id);

-- Pagamentos (painel de administração e "os meus pedidos")
create index if not exists idx_pagamentos_estado     on public.pagamentos (estado);
create index if not exists idx_pagamentos_utilizador on public.pagamentos (utilizador_id, criado desc);

-- Atualiza as estatísticas para o Supabase usar os índices de imediato
analyze public.anuncios;
analyze public.fotografias;
analyze public.destaques;

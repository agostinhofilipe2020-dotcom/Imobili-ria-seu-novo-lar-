-- =====================================================================
-- SEU NOVO LAR — REVERTER A FASE 2
-- Remove o que a Fase 2 acrescentou. Não toca em dados do site.
-- ATENÇÃO: apaga a tabela "dispositivos" (tokens de push guardados).
-- =====================================================================

begin;

drop trigger  if exists anuncios_atualizado on public.anuncios;
drop function if exists public.set_atualizado_em();
drop index    if exists public.idx_anuncios_atualizado;
alter table public.anuncios drop column if exists atualizado_em;

drop function if exists public.registar_dispositivo(text, text);
drop table    if exists public.dispositivos;

commit;

// =====================================================================
// SEU NOVO LAR — Edge Function: apagar-conta
// Permite ao utilizador apagar a própria conta (exigido pelas lojas de
// apps e útil também no site). Apaga os ficheiros dele no Storage e a
// conta; os dados ligados (perfil, anúncios, favoritos, notificações,
// pedidos, pagamentos, subscrições) apagam-se em cascata.
//
// COMO PUBLICAR (Supabase > Edge Functions > Deploy a new function):
//   nome: apagar-conta      (deixar "Verify JWT" LIGADO)
//   colar este código e publicar.
// As chaves SUPABASE_URL, SUPABASE_ANON_KEY e SUPABASE_SERVICE_ROLE_KEY
// já existem automaticamente nas Edge Functions. Não as copies para
// nenhum ficheiro nem para a app.
//
// COMO A APP/SITE CHAMA:
//   supabase.functions.invoke("apagar-conta", { body: { confirmar: "APAGAR" } })
//
// DECISÃO TUA (legal): os registos de pagamento também são apagados.
// Se a lei exigir guardá-los, diz-me e mudo para anonimizar em vez de apagar.
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// Lista todos os ficheiros de uma pasta (incluindo subpastas).
async function listarFicheiros(admin: any, bucket: string, prefixo: string): Promise<string[]> {
  const out: string[] = [];
  const { data, error } = await admin.storage.from(bucket).list(prefixo, { limit: 1000 });
  if (error || !data) return out;
  for (const item of data) {
    const caminho = `${prefixo}/${item.name}`;
    if (item.id === null) out.push(...await listarFicheiros(admin, bucket, caminho)); // subpasta
    else out.push(caminho);
  }
  return out;
}

async function apagarPasta(admin: any, bucket: string, prefixo: string) {
  const ficheiros = await listarFicheiros(admin, bucket, prefixo);
  for (let i = 0; i < ficheiros.length; i += 100) {
    await admin.storage.from(bucket).remove(ficheiros.slice(i, i + 100));
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ erro: "Método não permitido" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1) Quem está a pedir? (valida a sessão enviada pela app/site)
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: erroUser } = await userClient.auth.getUser();
  if (erroUser || !user) return json({ erro: "Sem sessão válida" }, 401);

  // 2) Confirmação explícita (evita apagar por engano)
  const corpo = await req.json().catch(() => ({}));
  if (corpo?.confirmar !== "APAGAR") return json({ erro: "Confirmação em falta" }, 400);

  const admin = createClient(url, service);

  // 3) Contas de administração não se apagam por aqui
  const { data: perfil } = await admin.from("perfis").select("papel").eq("id", user.id).maybeSingle();
  if (perfil?.papel === "admin") return json({ erro: "Contas de administrador não podem ser apagadas aqui" }, 403);

  // 4) Registo na auditoria (sem dados pessoais)
  await admin.from("auditoria").insert({ autor: null, acao: "conta_apagada", entidade: "perfis", entidade_id: user.id });

  // 5) Ficheiros do utilizador (fotos, miniaturas e comprovativos)
  await apagarPasta(admin, "fotos-anuncios", user.id);
  await apagarPasta(admin, "comprovativos", user.id);

  // 6) Conta (apaga o perfil e o resto em cascata)
  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) return json({ erro: "Não foi possível apagar a conta. Tenta de novo ou contacta o suporte." }, 500);

  return json({ ok: true });
});

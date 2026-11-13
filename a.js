// Pré-visualização de um anúncio ao partilhar (WhatsApp, Facebook, etc.).
// Chega como /a/<id> (ver vercel.json). Os robôs leem as etiquetas Open Graph;
// as pessoas são redirecionadas de imediato para /#/anuncio/<id>.
const SB_URL = process.env.SUPABASE_URL || 'https://sfwqxhisfjyxuhoacofg.supabase.co';
const SB_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_9JyxvxunfLy_uopgTDFGZA_l67zPGPE';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIPOS = { apartamento: 'Apartamento', comercial: 'Espaço comercial', salao_festas: 'Salão de festas', escritorio: 'Escritório', moradia: 'Moradia', vivenda: 'Vivenda', terreno: 'Terreno' };
const ORIGENS = ['whatsapp', 'facebook', 'instagram', 'google'];

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const kz = (n) => (n == null ? 'Preço sob consulta' : Number(n).toLocaleString('pt-PT') + ' Kz');
const cut = (s, n) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);

async function get(url, ms) {
  const c = new AbortController(); const t = setTimeout(() => c.abort(), ms);
  try { return await fetch(url, { headers: { apikey: SB_KEY }, signal: c.signal }); } finally { clearTimeout(t); }
}

module.exports = async (req, res) => {
  const host = req.headers['x-forwarded-host'] || req.headers.host || 'seu-novo-lar.vercel.app';
  const origin = 'https://' + host;
  const q = req.query || {};
  const id = String(q.id || '');
  const org = ORIGENS.includes(String(q.origem || '')) ? '?origem=' + q.origem : '';
  const dest = UUID.test(id) ? origin + '/' + org + '#/anuncio/' + id : origin + '/';
  let titulo = 'Seu Novo Lar', desc = 'Descobre. Conecta. Encontra o teu lugar. Casas e apartamentos em Angola.', img = origin + '/og-image.jpg';

  if (UUID.test(id)) {
    try {
      const r = await get(SB_URL + '/rest/v1/anuncios?id=eq.' + id +
        '&select=titulo,preco,tipo,finalidade,provincia,municipio,quartos,casas_banho,area_m,descricao_publica,fotografias(caminho,ordem)&limit=1', 3500);
      const a = r.ok ? (await r.json())[0] : null;
      if (a) {
        titulo = cut((a.titulo || 'Imóvel') + ' · ' + kz(a.preco), 90);
        const onde = [a.municipio, a.provincia].filter(Boolean).join(', ');
        const partes = [(TIPOS[a.tipo] || 'Imóvel') + (a.finalidade === 'venda' ? ' à venda' : ' para arrendar') + (onde ? ' em ' + onde : '')];
        const ex = [];
        if (a.quartos) ex.push(a.quartos + (Number(a.quartos) === 1 ? ' quarto' : ' quartos'));
        if (a.casas_banho) ex.push(a.casas_banho + (Number(a.casas_banho) === 1 ? ' casa de banho' : ' casas de banho'));
        if (a.area_m) ex.push(a.area_m + ' m²');
        if (ex.length) partes.push(ex.join(' · '));
        desc = cut(partes.join('. ') + '. ' + (a.descricao_publica ? String(a.descricao_publica).replace(/\s+/g, ' ') : 'Vê as fotografias e contacta o anunciante no Seu Novo Lar.'), 200);
        const f = (a.fotografias || []).slice().sort((x, y) => x.ordem - y.ordem)[0];
        if (f && f.caminho) {
          const base = SB_URL + '/storage/v1/object/public/fotos-anuncios/';
          const orig = base + f.caminho.split('/').map(encodeURIComponent).join('/');
          const thumb = orig.replace(/\.jpg$/i, '-m.jpg');
          img = orig;
          if (thumb !== orig) { try { const h = await fetch(thumb, { method: 'HEAD', signal: AbortSignal.timeout(1500) }); if (h.ok) img = thumb; } catch (e) {} }
        }
      }
    } catch (e) { /* mantém a pré-visualização genérica */ }
  }

  const url = origin + '/a/' + (UUID.test(id) ? id : '');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=3600');
  res.status(200).send('<!doctype html><html lang="pt-AO"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>' + esc(titulo) + '</title><meta name="description" content="' + esc(desc) + '">' +
    '<link rel="canonical" href="' + esc(url) + '"><meta name="robots" content="noindex">' +
    '<meta property="og:type" content="website"><meta property="og:site_name" content="Seu Novo Lar"><meta property="og:locale" content="pt_PT">' +
    '<meta property="og:title" content="' + esc(titulo) + '"><meta property="og:description" content="' + esc(desc) + '">' +
    '<meta property="og:image" content="' + esc(img) + '"><meta property="og:url" content="' + esc(url) + '">' +
    '<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="' + esc(titulo) + '">' +
    '<meta name="twitter:description" content="' + esc(desc) + '"><meta name="twitter:image" content="' + esc(img) + '">' +
    '<script>location.replace(' + JSON.stringify(dest).replace(/</g, '\\u003c') + ')</script></head>' +
    '<body style="font-family:system-ui,sans-serif;padding:24px"><p>A abrir o anúncio… <a href="' + esc(dest) + '">Clica aqui se não abrir.</a></p></body></html>');
};

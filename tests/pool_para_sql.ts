// "Há conta no pool desta campanha?" — a tela e o banco respondem igual?
//
// A prévia de inscrição pergunta a `privado.pool_da_campanha` (SQL). O Início,
// o Painel e o fim do setup perguntam a `poolDaCampanha` (`app/src/assistente.ts`),
// que lê o que a tela já tem. São a mesma regra escrita duas vezes, em
// linguagens diferentes (D77b) — e divergir não dá erro: dá uma tela dizendo
// "pronto" para uma campanha que a prévia diz não ter conta, ou o contrário. É
// o D55 com o pool no lugar do template.
//
// Os cenários são todas as combinações de sete contas-modelo, nos dois canais
// que têm escolha diferente (WhatsApp e e-mail, onde a campanha pode escolher
// a conta), nos dois tipos de campanha. Cada cenário é um cliente próprio, para
// as contas de um não entrarem no pool do outro.
//
// O catálogo de provedores é declarado AQUI e aplicado no banco, para os dois
// lados lerem o mesmo — o catálogo contra o registro de adapters é outra
// ponte (`registro_para_sql.ts`).
//
// Escreve SQL em stdout; quem roda é `tests/run.sh`, que o joga no psql.

import { poolDaCampanha } from '../app/src/assistente.ts';
import type { Foto } from '../app/src/assistente.ts';

type Pool = 'morna' | 'fria';
type Estado = 'ativo' | 'circuito_aberto' | 'desativado';

const linhas: string[] = [];
const p = (s: string) => linhas.push(s);
const q = (s: string) => `'${s.replace(/'/g, "''")}'`;

// O catálogo dos dois lados. `gupshup` desligado e `smtp` sem adapter são as
// duas formas de um provedor não entregar.
const CATALOGO = [
  { slug: 'evolution', canal: 'whatsapp', tem_adapter: true, ativo: true },
  { slug: 'gupshup', canal: 'whatsapp', tem_adapter: true, ativo: false },
  { slug: 'resend', canal: 'email', tem_adapter: true, ativo: true },
  { slug: 'smtp', canal: 'email', tem_adapter: false, ativo: true },
  { slug: 'comtele', canal: 'sms', tem_adapter: true, ativo: true },
];

interface Modelo {
  rotulo: string;
  canal: (c: string) => string;
  provedor: (c: string) => string;
  tipo: (t: Pool) => Pool;
  estado: Estado;
  removida: boolean;
}
const outro = (t: Pool): Pool => (t === 'morna' ? 'fria' : 'morna');
const entrega = (c: string) => (c === 'whatsapp' ? 'evolution' : 'resend');
const naoEntrega = (c: string) => (c === 'whatsapp' ? 'gupshup' : 'smtp');
const MODELOS: Modelo[] = [
  { rotulo: 'ativa', canal: (c) => c, provedor: entrega, tipo: (t) => t, estado: 'ativo', removida: false },
  { rotulo: 'circuito', canal: (c) => c, provedor: entrega, tipo: (t) => t, estado: 'circuito_aberto', removida: false },
  { rotulo: 'desligada', canal: (c) => c, provedor: entrega, tipo: (t) => t, estado: 'desativado', removida: false },
  { rotulo: 'outro_pool', canal: (c) => c, provedor: entrega, tipo: outro, estado: 'ativo', removida: false },
  { rotulo: 'sem_entrega', canal: (c) => c, provedor: naoEntrega, tipo: (t) => t, estado: 'ativo', removida: false },
  { rotulo: 'arquivada', canal: (c) => c, provedor: entrega, tipo: (t) => t, estado: 'desativado', removida: true },
  { rotulo: 'outro_canal', canal: () => 'sms', provedor: () => 'comtele', tipo: (t) => t, estado: 'ativo', removida: false },
];

const uuid = (grupo: number, n: number) =>
  `ee${grupo.toString(16).padStart(6, '0')}-0000-0000-0000-${n.toString(16).padStart(12, '0')}`;

p(`\\set ON_ERROR_STOP on`);
p(`SET client_min_messages = warning;`);
p(`CREATE SCHEMA pp;`);
p(`CREATE TABLE pp.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);`);
p(`CREATE FUNCTION pp.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO pp.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $f$;`);
p(`\\o /dev/null`);
p(`CREATE TABLE pp.esperado (
  tenant uuid, campanha uuid, canal canal, cenario text, ts text
);`);

const OPERADOR = 'ee000000-0000-0000-0000-0000000000d1';
let grupo = 0;
const esperados: string[] = [];

for (const canal of ['whatsapp', 'email']) {
  for (const tipo of ['morna', 'fria'] as Pool[]) {
    for (let mascara = 0; mascara < 1 << MODELOS.length; mascara++) {
      grupo += 1;
      const tenant = uuid(grupo, 0);
      const usadas = MODELOS.filter((_, i) => mascara & (1 << i));
      const contas = usadas.map((m, i) => ({
        id: uuid(grupo, i + 1), rotulo: m.rotulo, canal: m.canal(canal), provedor: m.provedor(canal),
        tipo_permitido: m.tipo(tipo), estado: m.estado, removida: m.removida,
      }));

      p(`INSERT INTO tenants (id, nome, slug) VALUES (${q(tenant)}, 'ponte ${grupo}', 'ponte-pool-${grupo}');`);
      p(`INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (${q(tenant)}, ${q(OPERADOR)}, 'operador');`);
      for (const [i, c] of contas.entries()) {
        const ident = c.canal === 'email' ? `conta${i}@ponte.exemplo.com` : `55159900${String(i).padStart(5, '0')}`;
        p(`INSERT INTO sender_accounts (id, tenant_id, canal, identificador, provedor, tipo_permitido, quota_diaria, estado, `
          + `circuito_aberto_ate, removido_em) VALUES (${q(c.id)}, ${q(tenant)}, ${q(c.canal)}, ${q(ident)}, ${q(c.provedor)}, `
          + `${q(c.tipo_permitido)}, 50, ${q(c.estado)}, `
          + `${c.estado === 'circuito_aberto' ? `now() + interval '30 minutes'` : 'NULL'}, ${c.removida ? 'now()' : 'NULL'});`);
      }

      // No e-mail a campanha pode escolher a conta: sem escolha, e cada conta
      // que o banco deixa escolher (de e-mail, do mesmo pool, não arquivada).
      const escolhas: (string | null)[] = [null];
      if (canal === 'email') {
        escolhas.push(...contas.filter((c) => c.canal === 'email' && c.tipo_permitido === tipo && !c.removida)
          .map((c) => c.id));
      }

      // O que a tela lê: `lerRemetentes` filtra `removido_em`, e o catálogo.
      const foto: Pick<Foto, 'provedores' | 'remetentes'> = {
        provedores: CATALOGO.map((x) => ({ ...x, nome: x.slug, descricao: '', oficial: false, campos: [] })),
        remetentes: contas.filter((c) => !c.removida).map((c) => ({
          id: c.id, canal: c.canal, provedor: c.provedor, tipo_permitido: c.tipo_permitido,
          quota_diaria: 50, estado: c.estado, apelido: null, identificador: c.id,
        })),
      };

      for (const [k, escolhida] of escolhas.entries()) {
        const campanha = uuid(grupo, 100 + k);
        p(`INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados, remetente_email_id) `
          + `VALUES (${q(campanha)}, ${q(tenant)}, 'ponte', ${q(tipo)}, 'teste', ARRAY[${q(canal)}]::canal[], `
          + `${escolhida ? q(escolhida) : 'NULL'});`);
        const ts = poolDaCampanha(foto, { tipo, remetente_email_id: escolhida }, canal);
        const cenario = `${canal} ${tipo} [${usadas.map((m) => m.rotulo).join(', ')}]`
          + (escolhida ? ` escolhida=${contas.find((c) => c.id === escolhida)!.rotulo}` : '');
        esperados.push(`(${q(tenant)}, ${q(campanha)}, ${q(canal)}, ${q(cenario)}, ${q(ts)})`);
      }
    }
  }
}

p(`INSERT INTO pp.esperado VALUES\n  ${esperados.join(',\n  ')};`);

// O catálogo dos dois lados, aplicado DEPOIS das contas: o gatilho de
// `sender_accounts` recusa cadastrar em provedor desligado, e a conta que
// existia antes de o provedor ser desligado é justamente o caso.
p(`UPDATE channel_provider_catalog c SET tem_adapter = v.tem_adapter, ativo = v.ativo
  FROM (VALUES ${CATALOGO.map((x) => `(${q(x.slug)}, ${x.tem_adapter}, ${x.ativo})`).join(', ')})
       AS v(slug, tem_adapter, ativo)
 WHERE c.slug = v.slug;`);

// Quem pergunta é um operador, como na prévia (D41).
p(`SELECT set_config('request.jwt.claims', '{"sub":"${OPERADOR}"}', false);`);
p(`CREATE TABLE pp.obtido AS
  SELECT e.*, privado.pool_da_campanha(e.tenant, e.campanha, e.canal) AS sql FROM pp.esperado e;`);
p(`SELECT set_config('request.jwt.claims', '', false);`);

// Cenário que consegue falhar (D36): as três respostas aparecem dos dois
// lados, senão uma regra que respondesse sempre "ok" passaria.
p(`SELECT pp.confere('os cenários produzem as três respostas no TypeScript',
  (SELECT count(DISTINCT ts) = 3 FROM pp.obtido), (SELECT string_agg(DISTINCT ts, ', ') FROM pp.obtido));`);
p(`SELECT pp.confere('os cenários produzem as três respostas no SQL',
  (SELECT count(DISTINCT sql) = 3 FROM pp.obtido), (SELECT string_agg(DISTINCT coalesce(sql, '(nulo)'), ', ') FROM pp.obtido));`);
p(`SELECT pp.confere('a escolha da conta de e-mail entra nos cenários',
  (SELECT count(*) > 0 FROM pp.obtido WHERE cenario LIKE '%escolhida=%'));`);

p(`SELECT pp.confere('poolDaCampanha (tela) e privado.pool_da_campanha (banco) respondem igual',
  NOT EXISTS (SELECT 1 FROM pp.obtido WHERE sql IS DISTINCT FROM ts),
  (SELECT count(*) FROM pp.obtido WHERE sql IS DISTINCT FROM ts) || ' divergências de '
    || (SELECT count(*) FROM pp.obtido) || '; ex.: '
    || (SELECT string_agg(cenario || ' → tela ' || ts || ', banco ' || coalesce(sql, '(nulo)'), ' | ')
          FROM (SELECT * FROM pp.obtido WHERE sql IS DISTINCT FROM ts ORDER BY cenario LIMIT 3) d));`);

p(`\\o`);
p(`SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS resultado, nome, detalhe FROM pp.resultado ORDER BY id;`);
p(`DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pp.resultado WHERE NOT ok) THEN RAISE EXCEPTION 'pool: tela e banco divergem'; END IF;
END $$;`);

console.log(linhas.join('\n'));

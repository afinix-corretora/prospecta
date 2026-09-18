import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  criarCampanhaDeModelo, lerAgentes, lerCampanhas, lerCredenciaisIA, lerModelos,
  lerProvedoresCanal, lerProvedoresIA, lerRemetentes, salvarCredencialIA,
} from '../dados';
import type { Agente, Campanha, CredencialIA, Modelo, ProvedorCanal, ProvedorIA } from '../dados';
import {
  Aviso, Campo, Kpi, LinhaIndice, NOME_CANAL, Secao, corCanal,
} from '../componentes/base';
import { familiaDe, familiasDoCanal } from '../componentes/Rail';

/** Carrega uma vez e devolve estado de tela — erro visível, não engolido. */
function useDados<T>(carregar: () => Promise<T>, deps: unknown[] = []) {
  const [dados, setDados] = useState<T | null>(null);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);
  async function recarregar() {
    setCarregando(true);
    try { setDados(await carregar()); setErro(''); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }
  useEffect(() => { void recarregar(); /* eslint-disable-next-line */ }, deps);
  return { dados, erro, carregando, recarregar };
}

function Moldura({ titulo, sub, voltar, children }: {
  titulo: string; sub: string; voltar?: () => void; children: React.ReactNode;
}) {
  return (
    <div className="wrap">
      <div className="cabeca"><div>
        {voltar && <button className="voltar" onClick={voltar}>← Configurações</button>}
        <h1>{titulo}</h1><p>{sub}</p>
      </div></div>
      {children}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Hub de campanhas
// ---------------------------------------------------------------------------

export function Hub() {
  const { tenant, opera } = useSessao();
  const { dados, erro, carregando, recarregar } = useDados(
    async () => ({
      campanhas: await lerCampanhas(),
      modelos: await lerModelos(),
    }), [tenant?.tenant_id],
  );
  const [criando, setCriando] = useState<Modelo | null>(null);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const campanhas: Campanha[] = dados?.campanhas ?? [];
  const modelos: Modelo[] = dados?.modelos ?? [];
  const ativas = campanhas.filter((c) => c.ativa).length;

  return (
    <div className="wrap">
      <div className="cabeca">
        <div>
          <h1>Hub de campanhas</h1>
          <p>Escolha um modelo pronto ou monte a sua. Cada campanha carrega base legal,
             canais habilitados e pool de remetentes próprios.</p>
        </div>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Campanhas ativas" valor={ativas} sub={`${campanhas.length - ativas} pausada(s)`} />
        <Kpi rotulo="Modelos prontos" valor={modelos.length} sub="cadência e base legal já definidas" />
        <Kpi rotulo="Cliente" valor={tenant?.nome ?? '—'} sub={tenant?.papel ?? ''} />
      </section>

      <Secao titulo="Campanhas" nota={campanhas.length ? `${campanhas.length} no total` : 'nenhuma ainda'} />
      <section className="indice">
        {campanhas.length ? campanhas.map((c) => (
          <LinhaIndice
            key={c.id} icone="campanha" cor={corCanal(c.canais_habilitados[0] ?? '')}
            titulo={c.nome}
            descricao={`${c.objetivo ?? '—'} · pool ${c.tipo} · ${c.canais_habilitados.map((x) => NOME_CANAL[x] ?? x).join(', ')}`}
            contagem={c.ativa ? 'ativa' : 'pausada'}
          />
        )) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma campanha ainda</b>
            <p>Escolha um modelo abaixo — ele já vem com cadência, base legal e canais.</p>
          </span></div>
        )}
      </section>

      <Secao titulo="Modelos prontos" nota="cadência, base legal e canais já definidos — é só escolher" />
      <section className="indice">
        {modelos.map((m) => (
          <LinhaIndice
            key={m.slug} icone="modelo" titulo={m.nome}
            descricao={`${m.descricao} · ${m.passos.length} passos · ${m.canais.map((x) => NOME_CANAL[x] ?? x).join(', ')}`}
            contagem={m.tipo}
            aoClicar={opera ? () => setCriando(m) : undefined}
          />
        ))}
      </section>

      {criando && (
        <CriarCampanha modelo={criando} tenant={tenant?.tenant_id ?? ''}
                       aoFechar={() => setCriando(null)} aoCriar={recarregar} />
      )}
    </div>
  );
}

function CriarCampanha({ modelo, tenant, aoFechar, aoCriar }: {
  modelo: Modelo; tenant: string; aoFechar(): void; aoCriar(): Promise<void>;
}) {
  const [nome, setNome] = useState(modelo.nome);
  const [canais, setCanais] = useState<string[]>(modelo.canais);
  const [estado, setEstado] = useState<'parado' | 'criando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  async function criar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('criando');
    try {
      const r = await criarCampanhaDeModelo({ tenant, slug: modelo.slug, nome, canais });
      setMsg({ tipo: 'ok', texto: `Campanha criada com ${r.passos_criados} passos.` });
      await aoCriar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
    finally { setEstado('parado'); }
  }

  return (
    <>
      <Secao titulo={`Criar a partir de "${modelo.nome}"`} nota={modelo.objetivo} />
      <form className="painel" onSubmit={criar}>
        <Campo id="camp-nome" rotulo="Nome da campanha" valor={nome} aoMudar={setNome} />
        <div className="campo">
          <label>Canais</label>
          <div className="chips">
            {modelo.canais.map((c) => {
              const on = canais.includes(c);
              return (
                <button key={c} type="button" className="chip" aria-pressed={on}
                        style={on ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}
                        onClick={() => setCanais(on ? canais.filter((x) => x !== c) : [...canais, c])}>
                  {NOME_CANAL[c] ?? c}
                </button>
              );
            })}
          </div>
          <span className="ajuda">
            Passo de canal não escolhido não entra na cadência. O modelo sem nenhum passo nos canais
            escolhidos é recusado na criação, não em produção.
          </span>
        </div>
        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
        <div style={{ display: 'flex', gap: 9 }}>
          <button className="btn prim" disabled={estado === 'criando' || !nome || !canais.length}>
            {estado === 'criando' ? 'Criando…' : 'Criar campanha'}
          </button>
          <button type="button" className="btn" onClick={aoFechar}>Cancelar</button>
        </div>
      </form>
    </>
  );
}

// ---------------------------------------------------------------------------
// Canais — índice
// ---------------------------------------------------------------------------

export function Canais() {
  const nav = useNavigate();
  const { tenant } = useSessao();
  const { dados, erro, carregando } = useDados(
    async () => ({ provedores: await lerProvedoresCanal(), remetentes: await lerRemetentes() }),
    [tenant?.tenant_id],
  );

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  const provedores: ProvedorCanal[] = dados?.provedores ?? [];
  const remetentes = dados?.remetentes ?? [];

  const canais = ['whatsapp', 'email', 'sms', 'instagram'].filter((c) => provedores.some((p) => p.canal === c));

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <h1>Canais</h1>
        <p>Cada canal tem as suas contas. O que não tem adapter não vira opção na criação
           de campanha — o motor recusa antes de prometer.</p>
      </div></div>
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      <section className="indice">
        {canais.map((c) => {
          const ps = provedores.filter((p) => p.canal === c);
          const n = remetentes.filter((r) => r.canal === c).length;
          const temAdapter = ps.some((p) => p.tem_adapter);
          return (
            <LinhaIndice
              key={c} icone={c} cor={corCanal(c)} titulo={NOME_CANAL[c] ?? c}
              descricao={`${ps.map((p) => p.nome).join(', ')}`}
              contagem={temAdapter ? `${n} conta${n === 1 ? '' : 's'}` : 'sem adapter'}
              aoClicar={() => nav(`/canais/${c}`)}
            />
          );
        })}
      </section>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Configurações
// ---------------------------------------------------------------------------

export function Config() {
  const nav = useNavigate();
  const { tenant } = useSessao();
  const { dados } = useDados(async () => ({
    ia: await lerProvedoresIA(), agentes: await lerAgentes(), modelos: await lerModelos(),
    canal: await lerProvedoresCanal(),
  }), [tenant?.tenant_id]);

  const itens: [string, string, string, string, string][] = [
    ['/config/ia', 'ia', 'Provedores de IA',
     'Anthropic, OpenAI, Gemini, Perplexity, DeepSeek e compatíveis. A chave mora no Vault.',
     `${dados?.ia.length ?? 0} provedores`],
    ['/config/agentes', 'agente', 'Agentes',
     'A persona que responde em cada canal quando a pessoa reage à cadência.',
     `${dados?.agentes.length ?? 0} agentes`],
    ['/config/modelos', 'modelo', 'Modelos de conversa',
     'As receitas de cadência: canais, atrasos e texto de cada passo.',
     `${dados?.modelos.length ?? 0} modelos`],
    ['/config/plataformas', 'plataforma', 'Plataformas de contato',
     'Catálogo de provedores por canal — WhatsApp, e-mail, SMS e Instagram.',
     `${dados?.canal.length ?? 0} provedores`],
  ];

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <h1>Configurações</h1><p>Cada assunto na sua própria tela. Nada abre junto.</p>
      </div></div>
      <section className="indice">
        {itens.map(([rota, ic, titulo, desc, cont]) => (
          <LinhaIndice key={rota} icone={ic} titulo={titulo} descricao={desc}
                       contagem={cont} aoClicar={() => nav(rota)} />
        ))}
      </section>
    </div>
  );
}

export function ConfigIA() {
  const nav = useNavigate();
  const { tenant, administra } = useSessao();
  const { dados, erro, carregando, recarregar } = useDados(
    async () => ({
      provedores: await lerProvedoresIA(),
      credenciais: await lerCredenciaisIA(),
    }), [tenant?.tenant_id],
  );

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const provs: ProvedorIA[] = dados?.provedores ?? [];
  const creds: CredencialIA[] = dados?.credenciais ?? [];

  return (
    <Moldura titulo="Provedores de IA" voltar={() => nav('/config')}
             sub="Escolha o provedor e os campos certos aparecem. A chave vai para o Vault — o banco recusa gravá-la em qualquer outro lugar.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <Secao titulo="Credenciais" nota="é o que os agentes usam para responder" />
      <section className="indice" style={{ marginBottom: 14 }}>
        {creds.length ? creds.map((c) => (
          <div key={c.id} className="item" style={{ cursor: 'default' }}>
            <span className="txt">
              <b>{c.nome}</b>
              <p>
                {provs.find((x) => x.slug === c.provedor)?.nome ?? c.provedor}
                {' · '}<span className="mono">{c.modelo}</span>
              </p>
              <span className="chips" style={{ marginTop: 6 }}>
                <span className="chip">{c.chave_secret_id ? 'chave no Vault' : 'sem chave'}</span>
                {Object.keys(c.config).map((k) => <span key={k} className="chip">{k}</span>)}
              </span>
            </span>
            <span className={`delta ${c.ativo && c.chave_secret_id ? '' : 'neutra'}`}>
              {c.ativo ? (c.chave_secret_id ? 'pronta' : 'falta chave') : 'desligada'}
            </span>
          </div>
        )) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma credencial cadastrada</b>
            <p>Sem credencial, agente nenhum responde. O motor segue tocando a cadência — só não conversa.</p>
          </span></div>
        )}
      </section>

      {administra && tenant
        ? <FormularioIA provedores={provs} credenciais={creds} tenant={tenant.tenant_id} aoSalvar={recarregar} />
        : <Aviso tipo="neutro">Só quem administra o cliente configura provedor de IA.</Aviso>}
    </Moldura>
  );
}

/** O formulário não conhece provedor nenhum: desenha o que o catálogo declara.
 *
 * Também não decide o que é segredo. Manda tudo o que foi preenchido para
 * `salvar_credencial_ia` e é o banco, lendo o catálogo, que separa Vault de
 * config — a mesma razão por que a tela sobrevive a um provedor novo.
 */
function FormularioIA(props: {
  provedores: ProvedorIA[]; credenciais: CredencialIA[]; tenant: string;
  aoSalvar(): Promise<void>;
}) {
  const [slug, setSlug] = useState('');
  const [nome, setNome] = useState('');
  const [modelo, setModelo] = useState('');
  const [valores, setValores] = useState<Record<string, string>>({});
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const escolhido = props.provedores.find((x) => x.slug === slug) ?? props.provedores[0];
  if (!escolhido) return null;
  // A anotação não é decorativa: sem ela o narrowing do guard acima não chega
  // dentro de `salvar`, que é uma closure.
  const provedor: ProvedorIA = escolhido;

  // Reenviar o mesmo nome edita, como em `salvar_servidor_provedor`. Dizer isso
  // antes de salvar evita a descoberta pelo caminho ruim: duas credenciais
  // quase iguais e nenhuma pista de qual o agente está usando.
  const existente = props.credenciais.find((c) => c.nome === nome.trim());

  function trocarProvedor(novo: string) {
    setSlug(novo);
    // Campo de provedor anterior não sobrevive à troca: o banco recusaria a
    // chave que o provedor novo não declara, e o erro sairia sem explicação.
    setValores({});
    setMsg(null);
  }

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('salvando');
    try {
      await salvarCredencialIA({
        tenant: props.tenant, nome: nome.trim(), provedor: provedor.slug,
        modelo, campos: valores,
      });
      setMsg({
        tipo: 'ok',
        texto: existente ? 'Credencial atualizada.' : 'Credencial salva. A chave foi para o Vault.',
      });
      // Só o segredo é limpo: o resto continua à vista para uma segunda edição.
      setValores(Object.fromEntries(
        Object.entries(valores).filter(([k]) => !provedor.campos.find((c) => c.chave === k)?.segredo),
      ));
      await props.aoSalvar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
    finally { setEstado('parado'); }
  }

  return (
    <form className="painel" onSubmit={salvar}>
      <div className="opts" style={{ marginBottom: 16 }}>
        {props.provedores.map((x) => (
          <button key={x.slug} type="button" className="opt" aria-pressed={x.slug === provedor.slug}
                  onClick={() => trocarProvedor(x.slug)}>
            <b>{x.nome}</b><p>{x.descricao}</p>
          </button>
        ))}
      </div>

      {provedor.docs_url && (
        <p style={{ marginTop: 0 }}>
          <a href={provedor.docs_url} target="_blank" rel="noopener">documentação do {provedor.nome}</a>
        </p>
      )}

      <Campo id="ia-nome" rotulo="Nome da credencial" valor={nome} aoMudar={setNome}
             placeholder="Claude de produção"
             ajuda={existente
               ? `Já existe: salvar edita a credencial ${existente.provedor} em vez de criar outra.`
               : 'É por ele que o agente escolhe. Reenviar o mesmo nome edita em vez de duplicar.'} />

      {provedor.campos.map((c) => (
        <Campo key={c.chave} id={`ia-${c.chave}`} rotulo={c.rotulo} tipo={c.tipo}
               valor={valores[c.chave] ?? ''} obrigatorio={c.obrigatorio}
               aoMudar={(v) => setValores({ ...valores, [c.chave]: v })} ajuda={c.ajuda}
               vault={c.segredo
                 ? 'Vai para o Vault. Em branco na edição, a chave guardada fica como está.'
                 : undefined} />
      ))}

      <div className="campo">
        <label htmlFor="ia-modelo">Modelo</label>
        <input id="ia-modelo" list="modelos-ia" value={modelo}
               onChange={(e) => setModelo(e.target.value)}
               placeholder={provedor.modelos_sugeridos[0] ?? 'nome do modelo'} />
        <datalist id="modelos-ia">
          {provedor.modelos_sugeridos.map((m) => <option key={m} value={m} />)}
        </datalist>
        <span className="ajuda">
          {provedor.modelos_sugeridos.length
            ? 'Sugestões verificadas; aceita qualquer nome.'
            : 'Catálogo de modelo muda toda semana — o campo é livre de propósito.'}
        </span>
      </div>

      {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      <button className="btn prim" disabled={estado === 'salvando' || !nome.trim() || !modelo.trim()}>
        {estado === 'salvando' ? 'Salvando…' : existente ? 'Atualizar credencial' : 'Salvar credencial'}
      </button>
    </form>
  );
}

export function ConfigAgentes() {
  const nav = useNavigate();
  const { tenant } = useSessao();
  const { dados, erro, carregando } = useDados(lerAgentes, [tenant?.tenant_id]);
  const [aberto, setAberto] = useState<Agente | null>(null);

  // Usar um agente do catálogo copia a linha para o tenant; sem deduplicar, o
  // original e a cópia apareceriam como dois agentes.
  //
  // O useMemo vem ANTES do return de carregamento: hook depois de return
  // condicional muda a ordem entre renders e o React quebra.
  const agentes = useMemo(() => {
    const m = new Map<string, Agente>();
    for (const a of (dados ?? [])) {
      const atual = m.get(a.nome);
      if (!atual || (atual.tenant_id === null && a.tenant_id !== null)) m.set(a.nome, a);
    }
    return [...m.values()].sort((a, b) => a.canal.localeCompare(b.canal) || a.nome.localeCompare(b.nome));
  }, [dados]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  return (
    <Moldura titulo="Agentes" voltar={() => nav('/config')}
             sub="Uma persona por canal, escolhida na criação da campanha. O agente é dono da conversa; o motor é dono da cadência.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      <section className="indice">
        {agentes.map((a) => (
          <LinhaIndice key={a.id} icone={a.canal} cor={corCanal(a.canal)} titulo={a.nome}
                       descricao={`${a.descricao} · ${a.papel} · até ${a.limite_trocas} trocas`}
                       contagem={a.tenant_id ? 'seu' : 'catálogo'}
                       aoClicar={() => setAberto(aberto?.id === a.id ? null : a)} />
        ))}
      </section>
      {aberto && (
        <>
          <Secao titulo={aberto.nome} nota={`${NOME_CANAL[aberto.canal]} · ${aberto.papel}`} />
          <div className="painel">
            <p style={{ whiteSpace: 'pre-wrap', marginTop: 0 }}>{aberto.instrucoes}</p>
            <Secao titulo="Passa para uma pessoa quando" />
            <p style={{ marginBottom: 0 }}>{aberto.escalar_quando}</p>
          </div>
        </>
      )}
    </Moldura>
  );
}

export function ConfigModelos() {
  const nav = useNavigate();
  const { dados, erro, carregando } = useDados(lerModelos);
  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  return (
    <Moldura titulo="Modelos de conversa" voltar={() => nav('/config')}
             sub="A receita da cadência: canais, atrasos e texto de cada passo. Instanciar cria uma versão nova — editar o modelo depois não mexe em campanha já criada.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      <section className="indice">
        {(dados ?? []).map((m) => (
          <LinhaIndice key={m.slug} icone="modelo" titulo={m.nome}
                       descricao={`${m.descricao} · ${m.passos.length} passos · ${m.canais.map((x) => NOME_CANAL[x] ?? x).join(', ')}`}
                       contagem={m.tipo} />
        ))}
      </section>
    </Moldura>
  );
}

export function ConfigPlataformas() {
  const nav = useNavigate();
  const { dados, erro, carregando } = useDados(lerProvedoresCanal);
  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  const provs: ProvedorCanal[] = dados ?? [];
  const canais = ['whatsapp', 'email', 'sms', 'instagram'].filter((c) => provs.some((p) => p.canal === c));

  return (
    <Moldura titulo="Plataformas de contato" voltar={() => nav('/config')}
             sub="O catálogo de provedores por canal. Provedor novo é uma linha aqui mais uma classe em adapters/ — nada muda no motor.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {canais.map((c) => {
        const ps = provs.filter((p) => p.canal === c);
        const familias = familiasDoCanal(ps);
        return (
          <div key={c}>
            <Secao titulo={NOME_CANAL[c] ?? c}
                   nota={familias.length ? 'oficial e não oficial' : `${ps.length} provedor(es)`} />
            <section className="indice">
              {ps.map((p) => (
                <div key={p.slug} className="item" style={{ cursor: 'default' }}>
                  <span className="ico" style={{ background: corCanal(c), color: '#fff' }}>
                    <svg viewBox="0 0 24 24" strokeLinejoin="round" strokeLinecap="round" />
                  </span>
                  <span className="txt">
                    <b>{p.nome}</b><p>{p.descricao}</p>
                    <span className="chips" style={{ marginTop: 6 }}>
                      <span className="chip">{familiaDe(p) === 'oficial' ? 'oficial' : 'não oficial'}</span>
                      <span className="chip">{p.tem_adapter ? 'adapter pronto' : 'sem adapter'}</span>
                      <span className="chip">{p.campos.length} campos</span>
                    </span>
                  </span>
                  <span className={`delta ${p.tem_adapter ? '' : 'neutra'}`}>
                    {p.tem_adapter ? 'ativo' : 'em breve'}
                  </span>
                </div>
              ))}
            </section>
          </div>
        );
      })}
    </Moldura>
  );
}

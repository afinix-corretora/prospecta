import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  alternarConexaoCRM, alternarCredencialIA, criarCampanha, criarCampanhaDeModelo, lerAgentes, lerCampanhas,
  lerCanaisEntregaveis, lerConexoesCRM, lerCredenciaisIA, lerModelos, lerProvedoresCRM,
  lerProvedoresCanal, lerProvedoresIA, lerRemetentes, lerVersoesDeFlow, salvarAgente, salvarCredencialCRM,
  salvarCredencialIA,
} from '../dados';
import type {
  Agente, CanalEntregavel, Campanha, ConexaoCRM, CredencialIA, Modelo, MotivoDoCanal,
  ProvedorCRM, ProvedorCanal, ProvedorIA, VersaoDeFlow,
} from '../dados';
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

export function Moldura({ titulo, sub, voltar, children }: {
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
  const nav = useNavigate();
  const { tenant, opera } = useSessao();
  const { dados, erro, carregando, recarregar } = useDados(
    async () => ({
      campanhas: await lerCampanhas(),
      modelos: await lerModelos(),
      // O que este cliente consegue entregar hoje. Oferecer um modelo cujo
      // canal nenhum provedor sabe enviar é prometer um envio que o
      // despachante não tem como fazer (D31) — e o efeito seria o silêncio de
      // sempre: campanha criada, ninguém recebe, nada dá erro.
      entregaveis: await lerCanaisEntregaveis(),
      versoes: await lerVersoesDeFlow(),
    }), [tenant?.tenant_id],
  );
  const [criando, setCriando] = useState<Modelo | null>(null);
  const [emBranco, setEmBranco] = useState(false);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const campanhas: Campanha[] = dados?.campanhas ?? [];
  const modelos: Modelo[] = dados?.modelos ?? [];
  const entregaveis: CanalEntregavel[] = dados?.entregaveis ?? [];
  const versoes: VersaoDeFlow[] = dados?.versoes ?? [];
  const ativas = campanhas.filter((c) => c.ativa).length;

  const motivoDe = (canal: string): MotivoDoCanal =>
    entregaveis.find((e) => e.canal === canal)?.motivo ?? 'sem_adapter';

  // Sem adapter em TODOS os canais é "não dá", e nenhuma tela resolve.
  // Sem remetente é "ainda não", e cadastrar um chip resolve. A diferença
  // decide se o modelo é bloqueado ou só avisado.
  const impossivel = (m: Modelo) => m.canais.every((c) => motivoDe(c) === 'sem_adapter');
  const semChip = (m: Modelo) =>
    !impossivel(m) && m.canais.every((c) => motivoDe(c) !== 'entrega');

  const bloqueados = modelos.filter(impossivel);

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
            aoClicar={() => nav(`/campanhas/${c.id}`)}
          />
        )) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma campanha ainda</b>
            <p>Escolha um modelo abaixo — ele já vem com cadência, base legal e canais.</p>
          </span></div>
        )}
      </section>

      <Secao titulo="Modelos prontos" nota="cadência, base legal e canais já definidos — é só escolher" />

      {bloqueados.length > 0 && (
        <Aviso tipo="neutro">
          {bloqueados.length === 1
            ? <><b>{bloqueados[0]!.nome}</b> está </>
            : <><b>{bloqueados.length} modelos</b> estão </>}
          sem como enviar: nenhum provedor de{' '}
          {[...new Set(bloqueados.flatMap((m) => m.canais))]
            .map((c) => NOME_CANAL[c] ?? c).join(', ')}{' '}
          tem adapter no catálogo. Não é configuração que falta — é código que
          ainda não existe, e por isso o modelo aparece marcado em vez de
          desaparecer: some da lista seria um mistério, marcado é uma resposta.
        </Aviso>
      )}

      <section className="indice">
        {modelos.map((m) => {
          const nao = impossivel(m);
          const talvez = semChip(m);
          return (
            <LinhaIndice
              key={m.slug} icone="modelo" titulo={m.nome}
              descricao={
                `${m.descricao} · ${m.passos.length} passos · `
                + `${m.canais.map((x) => NOME_CANAL[x] ?? x).join(', ')}`
                + (nao ? ' · sem adapter para este canal'
                   : talvez ? ' · nenhum remetente cadastrado ainda' : '')
              }
              contagem={nao ? 'não dá' : talvez ? 'falta chip' : m.tipo}
              // Bloqueado só o que nenhuma tela resolve. "Falta chip" abre:
              // criar a campanha antes de cadastrar o remetente é ordem
              // legítima de trabalho, e a campanha nasce desligada de efeito
              // de qualquer forma — o passo é adiado, não queimado (D31).
              aoClicar={opera && !nao ? () => setCriando(m) : undefined}
            />
          );
        })}
      </section>

      {/* O outro caminho, e ele só existe desde que dá para escrever cadência
          (D55): campanha em branco. Sem isto, quem escreveu a sua cadência
          precisava instanciar um modelo qualquer e repontar — ficando com o
          `template_slug` e a base legal de um modelo que não é o dela. */}
      {opera && !criando && (
        <section className="indice">
          <LinhaIndice
            icone="campanha" titulo="Campanha em branco"
            descricao="para rodar uma cadência escrita por você, com a sua base legal"
            contagem="nova" aoClicar={() => setEmBranco(true)}
          />
        </section>
      )}

      {criando && (
        <CriarCampanha modelo={criando} tenant={tenant?.tenant_id ?? ''}
                       aoFechar={() => setCriando(null)} aoCriar={recarregar} />
      )}

      {emBranco && !criando && (
        <CampanhaEmBranco tenant={tenant?.tenant_id ?? ''} versoes={versoes}
                          entregaveis={entregaveis}
                          aoFechar={() => setEmBranco(false)} aoCriar={recarregar} />
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

/**
 * Campanha em branco (D55).
 *
 * O modelo traz tipo, base legal, canais e cadência num pacote só. Quem
 * escreveu a própria cadência precisa do avesso disso — e precisava,
 * literalmente, instanciar um modelo qualquer e repontar, ficando com o
 * `template_slug` e a base legal de um modelo que não é o dela.
 *
 * A base legal é campo de texto e é obrigatória, na função e aqui. Não é
 * burocracia: é o que autoriza falar com a pessoa, e o D4 a guarda na campanha
 * para que a resposta exista por escrito quando alguém perguntar. Um `NOT NULL`
 * preenchido com espaço seria a decoração do D46.
 */
function CampanhaEmBranco({ tenant, versoes, entregaveis, aoFechar, aoCriar }: {
  tenant: string; versoes: VersaoDeFlow[]; entregaveis: CanalEntregavel[];
  aoFechar(): void; aoCriar(): Promise<void>;
}) {
  const [f, setF] = useState({
    nome: '', objetivo: '', tipo: 'morna' as 'morna' | 'fria',
    baseLegal: 'Opt-in registrado na base própria', versao: '',
  });
  const [canais, setCanais] = useState<string[]>(['whatsapp']);
  const [estado, setEstado] = useState<'parado' | 'criando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const alvo = versoes.find((v) => v.id === f.versao) ?? null;
  const cruzam = alvo ? alvo.canais.filter((c) => canais.includes(c)) : null;
  const motivoDe = (c: string) => entregaveis.find((e) => e.canal === c)?.motivo ?? 'sem_adapter';

  async function criar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('criando');
    try {
      await criarCampanha({
        tenant, nome: f.nome, tipo: f.tipo, baseLegal: f.baseLegal,
        canais, objetivo: f.objetivo, versao: f.versao || null,
      });
      setMsg({ tipo: 'ok', texto: 'Campanha criada.' });
      await aoCriar();
      aoFechar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
    finally { setEstado('parado'); }
  }

  return (
    <>
      <Secao titulo="Campanha em branco"
             nota="tipo, base legal e canais escritos por você; a cadência é uma das suas" />
      <form className="painel" onSubmit={criar}>
        <Campo id="cb-nome" rotulo="Nome da campanha" valor={f.nome}
               aoMudar={(v) => setF({ ...f, nome: v })} />
        <Campo id="cb-obj" rotulo="Objetivo (opcional)" valor={f.objetivo}
               aoMudar={(v) => setF({ ...f, objetivo: v })}
               ajuda="Uma linha para você reconhecer a campanha na lista." />

        <div className="campo">
          <label htmlFor="cb-tipo">Tipo</label>
          <select id="cb-tipo" value={f.tipo}
                  onChange={(e) => setF({
                    ...f,
                    tipo: e.target.value as 'morna' | 'fria',
                    // A base legal padrão acompanha o tipo, porque são a mesma
                    // decisão: morna é base própria com opt-in, fria não tem
                    // relação prévia. Quem quiser outra, escreve por cima.
                    baseLegal: e.target.value === 'morna'
                      ? 'Opt-in registrado na base própria'
                      : 'Interesse legítimo (LGPD art. 7º, IX)',
                  })}>
            <option value="morna">Morna — base própria, com opt-in</option>
            <option value="fria">Fria — lista sem relação prévia</option>
          </select>
          <span className="ajuda">
            O tipo não é rótulo: ele restringe o pool de remetentes (D4). Campanha
            fria não usa o número nem o domínio da operação institucional, e o
            motor recusa a mensagem que tentar.
          </span>
        </div>

        <Campo id="cb-base" rotulo="Base legal" valor={f.baseLegal}
               aoMudar={(v) => setF({ ...f, baseLegal: v })}
               ajuda="O que autoriza falar com estas pessoas. Fica gravado na campanha para a resposta existir por escrito quando alguém perguntar." />

        <div className="campo">
          <label>Canais habilitados</label>
          <div className="chips">
            {(['whatsapp', 'email', 'sms', 'instagram'] as const).map((c) => {
              const on = canais.includes(c);
              const motivo = motivoDe(c);
              return (
                <button key={c} type="button" className="chip" aria-pressed={on}
                        style={on ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}
                        onClick={() => setCanais(on ? canais.filter((x) => x !== c) : [...canais, c])}>
                  {NOME_CANAL[c] ?? c}
                  {motivo !== 'entrega' && (
                    <span style={{ marginLeft: 5, color: 'var(--ink-3)' }}>
                      {motivo === 'sem_adapter' ? 'sem adapter' : 'sem chip'}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          <span className="ajuda">
            Passo cujo canal a campanha não habilita é pulado, não falha. Canal sem
            remetente faz o passo ser adiado, nunca queimado (D31).
          </span>
        </div>

        <div className="campo">
          <label htmlFor="cb-cad">Cadência (opcional agora)</label>
          <select id="cb-cad" value={f.versao}
                  onChange={(e) => setF({ ...f, versao: e.target.value })}>
            <option value="">escolher depois…</option>
            {versoes.map((v) => (
              <option key={v.id} value={v.id}>
                {v.flow_nome} · v{v.versao} · {v.passos} passos ·{' '}
                {v.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')}
              </option>
            ))}
          </select>
          <span className="ajuda">
            Sem cadência a campanha existe e não inscreve ninguém — a inscrição
            recusa alto, em vez de criar quem encerraria vazio.
          </span>
        </div>

        {cruzam?.length === 0 && (
          <Aviso tipo="erro">
            Esta cadência usa {alvo?.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')} e a
            campanha habilita {canais.map((c) => NOME_CANAL[c] ?? c).join(', ')}. Sem canal
            em comum, todo passo seria pulado — a criação é recusada.
          </Aviso>
        )}

        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}

        <div style={{ display: 'flex', gap: 9 }}>
          <button className="btn prim"
                  disabled={estado === 'criando' || !f.nome.trim() || !f.baseLegal.trim()
                            || !canais.length || cruzam?.length === 0}>
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
    canal: await lerProvedoresCanal(), crm: await lerProvedoresCRM(),
    remetentes: await lerRemetentes(),
  }), [tenant?.tenant_id]);
  const emails = (dados?.remetentes ?? []).filter((r) => r.canal === 'email').length;

  const itens: [string, string, string, string, string][] = [
    ['/config/email', 'email', 'E-mail',
     'Os provedores de e-mail deste cliente: adicionar, verificar a conexão e remover. Cada campanha escolhe um.',
     `${emails} conta${emails === 1 ? '' : 's'}`],
    ['/config/blacklist', 'bloqueio', 'Blacklist',
     'Os termos que tiram a pessoa da lista quando ela responde, o que cada um faz, e domínios de e-mail que nunca recebem.',
     'termos e domínios'],
    ['/config/ia', 'ia', 'Provedores de IA',
     'As contas de IA deste cliente — várias por provedor, se quiser. Toda chave entra aqui e mora no Vault; campanha e assistente só escolhem.',
     `${dados?.ia.length ?? 0} provedores`],
    ['/config/agentes', 'agente', 'Agentes',
     'A persona de cada canal: quando a pessoa responde, ela escreve a resposta — e manda sozinha, se você deixar.',
     `${dados?.agentes.length ?? 0} agentes`],
    ['/config/modelos', 'modelo', 'Modelos de conversa',
     'As receitas de cadência: canais, atrasos e texto de cada passo.',
     `${dados?.modelos.length ?? 0} modelos`],
    ['/config/plataformas', 'plataforma', 'Plataformas de contato',
     'Catálogo de provedores por canal — WhatsApp, e-mail, SMS e Instagram.',
     `${dados?.canal.length ?? 0} provedores`],
    ['/config/vinculadas', 'plataforma', 'Plataformas vinculadas',
     'O CRM deste cliente: ProfitCare, Pipefy, HubSpot, Pipedrive, RD Station, Ploomes, Salesforce ou Zoho. A credencial é deste cliente e mora no Vault.',
     `${dados?.crm.length ?? 0} plataformas`],
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

      <Aviso tipo="neutro">
        <b>Toda chave de IA mora aqui.</b> Conecte quantas contas quiser de cada provedor — duas
        da OpenAI, três da Anthropic. A campanha e o assistente do Início só <b>escolhem</b> uma
        delas; chave nenhuma é digitada lá.
      </Aviso>

      {provs.filter((p) => creds.some((c) => c.provedor === p.slug)).map((p) => {
        const contas = creds.filter((c) => c.provedor === p.slug);
        return (
          <div key={p.slug}>
            <Secao titulo={p.nome}
                   nota={`${contas.length} conta${contas.length === 1 ? '' : 's'}`
                         + (p.tem_adapter ? '' : ' · o motor ainda não compõe com este provedor')} />
            <section className="indice">
              {contas.map((c) => (
                <div key={c.id} className="item" style={{ cursor: 'default' }}>
                  <span className="txt">
                    <b>{c.nome}</b>
                    <p><span className="mono">{c.modelo}</span></p>
                    <span className="chips" style={{ marginTop: 6 }}>
                      <span className="chip">{c.chave_secret_id ? 'chave no Vault' : 'sem chave'}</span>
                      {Object.keys(c.config).map((k) => <span key={k} className="chip">{k}</span>)}
                    </span>
                  </span>
                  <span className={`delta ${c.ativo && c.chave_secret_id ? '' : 'neutra'}`}>
                    {c.ativo ? (c.chave_secret_id ? 'pronta' : 'falta chave') : 'desligada'}
                  </span>
                  {/* Desligar não apaga: a chave fica no Vault e a conta sai das
                      escolhas. Apagar seria perder a chave do cliente num clique. */}
                  {administra && (
                    <button className="btn" onClick={async () => {
                      try { await alternarCredencialIA(c.id, !c.ativo); await recarregar(); }
                      catch (e) { alert(mensagemDeErro(e)); }
                    }}>{c.ativo ? 'Desligar' : 'Ligar'}</button>
                  )}
                </div>
              ))}
            </section>
          </div>
        );
      })}
      {!creds.length && (
        <section className="indice">
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma conta conectada</b>
            <p>Sem conta, agente nenhum compõe nem responde. O motor segue tocando a cadência — só não conversa.</p>
          </span></div>
        </section>
      )}

      <Secao titulo={creds.length ? 'Conectar outra conta' : 'Conectar uma conta'}
             nota="do mesmo provedor ou de outro — cada conta tem o seu nome" />
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
  const { tenant, opera } = useSessao();
  const { dados, erro, carregando, recarregar } = useDados(async () => ({
    agentes: await lerAgentes(),
    credenciais: await lerCredenciaisIA(),
    provedores: await lerProvedoresIA(),
  }), [tenant?.tenant_id]);
  const [abertoId, setAbertoId] = useState<string | null>(null);

  // Usar um agente do catálogo copia a linha para o tenant; sem deduplicar, o
  // original e a cópia apareceriam como dois agentes.
  //
  // O useMemo vem ANTES do return de carregamento: hook depois de return
  // condicional muda a ordem entre renders e o React quebra.
  const agentes = useMemo(() => {
    const m = new Map<string, Agente>();
    for (const a of (dados?.agentes ?? [])) {
      const atual = m.get(a.nome);
      if (!atual || (atual.tenant_id === null && a.tenant_id !== null)) m.set(a.nome, a);
    }
    return [...m.values()].sort((a, b) => a.canal.localeCompare(b.canal) || a.nome.localeCompare(b.nome));
  }, [dados]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  const aberto = agentes.find((a) => a.id === abertoId) ?? null;
  const creds = dados?.credenciais ?? [];
  const provs = dados?.provedores ?? [];

  return (
    <Moldura titulo="Agentes" voltar={() => nav('/config')}
             sub="Uma persona por canal, escolhida na campanha. Quando o contato responde, o agente escreve a resposta. Se ele responde sozinho, ela sai pelo motor; se não, fica de rascunho para uma pessoa mandar.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      <section className="indice">
        {agentes.map((a) => {
          const c = creds.find((x) => x.id === a.ai_credential_id);
          return (
            <LinhaIndice key={a.id} icone={a.canal} cor={corCanal(a.canal)} titulo={a.nome}
                         descricao={`${a.descricao} · ${a.papel} · ${a.tenant_id
                           ? (c ? `compõe com ${c.nome} · ${a.autonomo ? 'responde sozinho' : 'rascunho para uma pessoa'}`
                                : 'sem credencial: não compõe') : 'modelo'}`}
                         contagem={a.tenant_id ? 'seu' : 'catálogo'}
                         aoClicar={() => setAbertoId(abertoId === a.id ? null : a.id)} />
          );
        })}
      </section>
      {aberto && (aberto.tenant_id && opera
        ? <EditorDeAgente key={aberto.id} agente={aberto} credenciais={creds} provedores={provs} aoSalvar={recarregar} />
        : (
          <>
            <Secao titulo={aberto.nome} nota={`${NOME_CANAL[aberto.canal]} · ${aberto.papel}`} />
            <div className="painel">
              {!aberto.tenant_id && (
                <Aviso tipo="neutro">Este é o modelo do catálogo. Ao escolher o agente numa campanha, o
                  cliente ganha uma cópia própria — é ela que se edita aqui.</Aviso>
              )}
              <p style={{ whiteSpace: 'pre-wrap', marginTop: 0 }}>{aberto.instrucoes}</p>
              <Secao titulo="Passa para uma pessoa quando" />
              <p style={{ marginBottom: 0 }}>{aberto.escalar_quando}</p>
            </div>
          </>
        ))}
    </Moldura>
  );
}

/** O agente do cliente, editável pelo que a grade deixa (D66): o que ele diz,
 *  quando passa para uma pessoa, o que nunca escreve, com que credencial — e,
 *  desde o D69, se ele responde sozinho.
 *
 *  O freio é do motor, não desta tela: aqui se diz o que é proibido; quem
 *  confere o texto composto é `motor/agente.ts`, depois do modelo responder. */
function EditorDeAgente({ agente, credenciais, provedores, aoSalvar }: {
  agente: Agente; credenciais: CredencialIA[]; provedores: ProvedorIA[]; aoSalvar(): Promise<void>;
}) {
  const [instrucoes, setInstrucoes] = useState(agente.instrucoes);
  const [escalar, setEscalar] = useState(agente.escalar_quando);
  const [limite, setLimite] = useState(String(agente.limite_trocas));
  const [tamanho, setTamanho] = useState(String(agente.tamanho_maximo));
  const [proibido, setProibido] = useState(agente.proibido.join('\n'));
  const [cred, setCred] = useState(agente.ai_credential_id ?? '');
  const [ativo, setAtivo] = useState(agente.ativo);
  const [autonomo, setAutonomo] = useState(agente.autonomo);
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);
  const escolhida = credenciais.find((c) => c.id === cred);
  const compoe = escolhida ? provedores.find((p) => p.slug === escolhida.provedor)?.tem_adapter ?? false : false;

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    try {
      await salvarAgente(agente.id, {
        instrucoes, escalar_quando: escalar,
        limite_trocas: Number(limite) || agente.limite_trocas,
        tamanho_maximo: Number(tamanho) || agente.tamanho_maximo,
        proibido: proibido.split('\n').map((x) => x.trim()).filter(Boolean),
        ai_credential_id: cred || null, ativo, autonomo,
      });
      setMsg({ tipo: 'ok', texto: 'Agente salvo. Vale para a próxima resposta que chegar.' });
      await aoSalvar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
  }

  return (
    <>
      <Secao titulo={agente.nome} nota={`${NOME_CANAL[agente.canal]} · ${agente.papel}`} />
      <form className="painel" onSubmit={salvar}>
        <div className="campo">
          <label htmlFor="ag-instr">Instrução (o comportamento do agente)</label>
          <textarea id="ag-instr" rows={8} value={instrucoes} onChange={(e) => setInstrucoes(e.target.value)} />
          <span className="ajuda">Tom, o que perguntar, o que oferecer. Pelo menos 120 caracteres. Além disto, o
            motor sempre manda: não inventar preço nem cobertura, não pedir CPF nem cartão, e passar para uma
            pessoa no caso abaixo.</span>
        </div>
        <Campo id="ag-escalar" rotulo="Passa para uma pessoa quando" valor={escalar} aoMudar={setEscalar}
               ajuda="Nesses casos o agente não escreve nem manda nada: a resposta aparece marcada para uma pessoa." />
        <div className="campo">
          <label htmlFor="ag-proib">Nunca escrever</label>
          <textarea id="ag-proib" rows={4} value={proibido} onChange={(e) => setProibido(e.target.value)}
                    placeholder={'garantimos\nsem carência\no menor preço'} />
          <span className="ajuda">Uma expressão por linha. Não é só pedido ao modelo: o motor confere o texto
            composto (sem acento e sem caixa) e barra — não manda — o que contiver uma delas.</span>
        </div>
        <Campo id="ag-tam" rotulo="Tamanho máximo (caracteres)" valor={tamanho} aoMudar={setTamanho}
               ajuda="Entre 80 e 4000. Texto maior é barrado, não cortado." />
        <Campo id="ag-lim" rotulo="Limite de trocas" valor={limite} aoMudar={setLimite}
               ajuda="Depois de tantas respostas na mesma conversa, o agente para e diz que é hora de uma pessoa." />
        <div className="campo">
          <label htmlFor="ag-cred">Compõe com</label>
          <select id="ag-cred" value={cred} onChange={(e) => setCred(e.target.value)}>
            <option value="">Nenhuma credencial — o agente não compõe</option>
            {credenciais.map((c) => (
              <option key={c.id} value={c.id}>{c.nome} · {c.provedor} · {c.modelo}{c.ativo ? '' : ' (desligada)'}</option>
            ))}
          </select>
          <span className="ajuda">As credenciais ficam em Configurações ▸ Provedores de IA.</span>
        </div>
        {escolhida && !compoe && (
          <Aviso tipo="neutro">{escolhida.provedor} ainda não tem adapter de rascunho: com esta credencial o agente
            diz que não tem com que compor.</Aviso>
        )}
        {escolhida && !escolhida.ativo && (
          <Aviso tipo="neutro">Esta credencial está desligada: o agente não compõe enquanto ela estiver assim.</Aviso>
        )}
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', margin: '4px 0 4px' }}>
          <input type="checkbox" checked={autonomo} onChange={(e) => setAutonomo(e.target.checked)} /> Responde sozinho
        </label>
        <p className="ajuda" style={{ margin: '0 0 8px' }}>
          {autonomo
            ? <>A resposta que passa pelos freios sai pelo motor, pela mesma conta que conversa com a pessoa, e paga
                quota como qualquer mensagem. Ela <b>não sai</b> se a pessoa pediu para sair, se respondeu de novo antes,
                se passou a janela de 24h do WhatsApp, ou se a conta está fora do ar ou sem quota — aí o texto volta
                para uma pessoa em Respostas, com o motivo. Com o motor em simulado, nada sai: a resposta aparece como
                simulada.</>
            : <>A resposta fica de rascunho na tela de Respostas, para uma pessoa ler, ajustar e mandar pelo
                aplicativo do canal.</>}
        </p>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', margin: '4px 0 12px' }}>
          <input type="checkbox" checked={ativo} onChange={(e) => setAtivo(e.target.checked)} /> Agente ativo
        </label>
        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
        <button className="btn prim" disabled={instrucoes.trim().length < 120}>Salvar agente</button>
      </form>
    </>
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

/** Plataformas vinculadas: o CRM deste cliente, com a credencial deste cliente.
 *
 * Terceira tela do mesmo padrão (chip, chave de modelo, CRM) e pelo mesmo
 * motivo: cada licença é um tenant, e cada tenant traz o CRM que já usa. Um
 * destino fixo no código seria o produto inteiro apontando para o CRM de um
 * cliente só.
 *
 * **A tela diz, por plataforma, se vincular escreve no CRM.** Desde o D64 o
 * Pipefy escreve, e a conexão dele abre a configuração de fatos e fontes; as
 * outras sete guardam a credencial e nada mais. Prometer efeito que ninguém
 * consome se descobre por um lead que o vendedor nunca viu (D55), e "o
 * Pipefy escreve" não pode virar "todas escrevem" por estar na mesma lista.
 */
export function ConfigVinculadas() {
  const nav = useNavigate();
  const { tenant, administra } = useSessao();
  const { dados, erro, carregando, recarregar } = useDados(
    async () => ({
      provedores: await lerProvedoresCRM(),
      // A RLS de `crm_connections` é de admin inclusive no SELECT. Para quem é
      // operador isto volta vazio, e é por isso que a lista não diz "nenhuma
      // vinculada" sem saber quem está olhando.
      conexoes: administra ? await lerConexoesCRM() : [],
    }), [tenant?.tenant_id, administra],
  );

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const provs: ProvedorCRM[] = dados?.provedores ?? [];
  const conns: ConexaoCRM[] = dados?.conexoes ?? [];
  const nenhumAdapter = provs.length > 0 && provs.every((p) => !p.tem_adapter);

  return (
    <Moldura titulo="Plataformas vinculadas" voltar={() => nav('/config')}
             sub="O CRM deste cliente. A credencial é dele, não do produto: cada licença tem a sua, guardada no Vault, e o banco recusa gravá-la em qualquer outro lugar.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {/* O aviso vem ANTES da lista, não no pé: quem abre esta tela vem
          vincular, e descobrir depois de colar a credencial que nada escreve
          no CRM é a ordem errada. */}
      {nenhumAdapter ? (
        <Aviso tipo="neutro">
          <b>Vincular guarda a credencial e nada mais, por enquanto.</b> Nenhuma
          destas plataformas tem adapter de escrita escrito ainda, então o que o
          motor descobre fica enfileirado na <b>fila de writeback</b> e não chega ao CRM.
        </Aviso>
      ) : (
        <Aviso tipo="neutro">
          <b>Só {provs.filter((p) => p.tem_adapter).map((p) => p.nome).join(', ')} escreve no CRM hoje.</b>{' '}
          Vincular uma das outras guarda a credencial e nada mais: o que o motor
          descobre espera na <b>fila de writeback</b> até o adapter dela existir — e
          aí esta mesma tela passa a escrever, sem pedir a chave de novo.
        </Aviso>
      )}

      <Secao titulo="Vinculadas" nota={administra ? 'uma por conexão' : 'só quem administra vê'} />
      <section className="indice" style={{ marginBottom: 14 }}>
        {conns.length ? conns.map((c) => {
          const p = provs.find((x) => x.slug === c.provedor);
          return (
            <div key={c.id} className="item" style={{ cursor: 'default' }}>
              <span className="txt">
                <b>{c.nome}</b>
                <p>{p?.nome ?? c.provedor}</p>
                <span className="chips" style={{ marginTop: 6 }}>
                  <span className="chip">
                    {c.credencial_secret_id ? 'credencial no Vault' : 'sem credencial'}
                  </span>
                  {Object.keys(c.config).map((k) => <span key={k} className="chip">{k}</span>)}
                  {/* Dizer que não escreve por CONEXÃO, e não só no aviso de
                      cima: a lista é o que sobra na tela depois de salvar. */}
                  {!p?.tem_adapter && <span className="chip">não escreve ainda</span>}
                </span>
              </span>
              {administra && p?.tem_adapter && (
                <button className="btn" style={{ marginRight: 10 }}
                        onClick={() => nav(`/config/vinculadas/${c.id}`)}>
                  Fatos e fontes
                </button>
              )}
              {administra && (
                <button className="btn" style={{ marginRight: 10 }}
                        onClick={async () => {
                          await alternarConexaoCRM(c.id, !c.ativo);
                          await recarregar();
                        }}>
                  {c.ativo ? 'Desligar' : 'Ligar'}
                </button>
              )}
              <span className={`delta ${c.ativo && c.credencial_secret_id ? '' : 'neutra'}`}>
                {c.ativo ? (c.credencial_secret_id ? 'vinculada' : 'falta credencial') : 'desligada'}
              </span>
            </div>
          );
        }) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>{administra ? 'Nenhuma plataforma vinculada' : 'Visível para quem administra'}</b>
            <p>
              {administra
                ? 'O motor continua tocando a cadência e registrando tudo no banco — só não devolve nada ao CRM: os fatos esperam na fila.'
                : 'Credencial de CRM é como chip e chave de modelo: só o dono e o admin do cliente veem e configuram.'}
            </p>
          </span></div>
        )}
      </section>

      {administra && tenant
        ? <FormularioCRM provedores={provs} conexoes={conns} tenant={tenant.tenant_id} aoSalvar={recarregar} />
        : <Aviso tipo="neutro">Só quem administra o cliente vincula plataforma.</Aviso>}
    </Moldura>
  );
}

/** O formulário não conhece CRM nenhum: desenha o que o catálogo declara.
 *
 * E não decide o que é segredo. Manda tudo o que foi preenchido para
 * `salvar_credencial_crm`, e é o banco, lendo o catálogo, que separa Vault de
 * `config` (D28). É por não conhecer nenhum que esta tela sobrevive a um CRM
 * novo — que é uma linha de catálogo e zero mudança aqui.
 */
function FormularioCRM(props: {
  provedores: ProvedorCRM[]; conexoes: ConexaoCRM[]; tenant: string;
  aoSalvar(): Promise<void>;
}) {
  const [slug, setSlug] = useState('');
  const [nome, setNome] = useState('');
  const [valores, setValores] = useState<Record<string, string>>({});
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const escolhido = props.provedores.find((x) => x.slug === slug) ?? props.provedores[0];
  if (!escolhido) return null;
  // A anotação não é decorativa: sem ela o narrowing do guard acima não chega
  // dentro de `salvar`, que é uma closure. Mesmo motivo do FormularioIA.
  const provedor: ProvedorCRM = escolhido;

  // Reenviar o mesmo nome EDITA, e dizer isso antes de salvar evita a descoberta
  // pelo caminho ruim: duas conexões quase iguais e nenhuma pista de qual vale.
  const existente = props.conexoes.find((c) => c.nome === nome.trim());

  function trocarProvedor(novo: string) {
    setSlug(novo);
    // Campo do provedor anterior não sobrevive à troca: o banco recusaria a
    // chave que o provedor novo não declara, e o erro sairia sem explicação.
    setValores({});
    setMsg(null);
  }

  // Obrigatório em branco: o banco recusa, mas com uma diferença que a tela
  // precisa repetir para o botão não parecer quebrado — segredo em branco passa
  // NA EDIÇÃO, porque a tela não consegue devolver o que não pode ler.
  const faltando = provedor.campos.filter((c) => {
    if (!c.obrigatorio) return false;
    if ((valores[c.chave] ?? '').trim()) return false;
    return !(c.segredo && existente?.credencial_secret_id);
  });

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('salvando');
    try {
      await salvarCredencialCRM({
        tenant: props.tenant, nome: nome.trim(), provedor: provedor.slug, campos: valores,
      });
      setMsg({
        tipo: 'ok',
        texto: existente
          ? 'Conexão atualizada.'
          : provedor.tem_adapter
            ? 'Plataforma vinculada. A credencial foi para o Vault.'
            : 'Plataforma vinculada e credencial guardada no Vault. Nada é escrito no CRM ainda — o adapter desta plataforma não existe.',
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

      {provedor.docs_url
        ? <p style={{ marginTop: 0 }}>
            <a href={provedor.docs_url} target="_blank" rel="noopener">
              documentação do {provedor.nome}
            </a>
          </p>
        : <p style={{ marginTop: 0, color: 'var(--ink-3)', fontSize: 13 }}>
            Sem página pública: é CRM da casa, e o contrato se confirma com quem
            o mantém.
          </p>}

      <Campo id="crm-nome" rotulo="Nome da conexão" valor={nome} aoMudar={setNome}
             placeholder="Pipefy da matriz"
             ajuda={existente
               ? `Já existe: salvar edita a conexão ${existente.provedor} em vez de criar outra.`
               : 'Reenviar o mesmo nome edita em vez de duplicar.'} />

      {provedor.campos.map((c) => (
        <Campo key={c.chave} id={`crm-${c.chave}`} rotulo={c.rotulo} tipo={c.tipo}
               valor={valores[c.chave] ?? ''} obrigatorio={c.obrigatorio}
               aoMudar={(v) => setValores({ ...valores, [c.chave]: v })} ajuda={c.ajuda}
               vault={c.segredo
                 ? 'Vai para o Vault. Em branco na edição, a credencial guardada fica como está.'
                 : undefined} />
      ))}

      {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      <button className="btn prim"
              disabled={estado === 'salvando' || !nome.trim() || faltando.length > 0}>
        {estado === 'salvando'
          ? 'Salvando…'
          : existente ? 'Atualizar conexão' : 'Vincular plataforma'}
      </button>
      {faltando.length > 0 && nome.trim() && (
        <span className="ajuda">
          Falta preencher: {faltando.map((c) => c.rotulo).join(', ')}.
        </span>
      )}
    </form>
  );
}

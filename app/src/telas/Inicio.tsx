/**
 * Setup rápido (D72; era o assistente do D67 em /configurar).
 *
 * A lógica — que pergunta vem, o que o plano propõe, quem pode autorizar — é
 * de `assistente.ts`, pura e testada. Aqui mora o que não dá para testar sem
 * navegador: os atalhos, o agente, a conversa e os cartões do plano.
 *
 * Quatro regras que esta tela sustenta e o teste não alcança:
 *
 * - **Nada acontece sem clique.** Cada cartão diz o que vai fazer, e só faz
 *   quando a pessoa aperta "Autorizar". A escrita sai com o JWT dela, então
 *   quem responde se pode é o RLS — o `impedimento` é só para avisar antes.
 *
 * - **O agente propõe, o roteiro decide.** O que o agente devolve passa por
 *   `aplicarSugestao`, o mesmo `valida` de um clique; a conversa mostra cada
 *   resposta com "mudar", e o plano continua esperando "Autorizar".
 *
 * - **Chave nenhuma passa pela conversa.** O texto que parece chave é barrado
 *   ANTES de sair do navegador e antes de ser guardado, pela mesma regra que o
 *   agente usa do lado de lá (`adapters/segredo.ts`), e a pessoa é levada ao
 *   formulário certo.
 *
 * - **A chave de IA entra pelo formulário de Configurações (D68, revisto no
 *   D72).** O atalho de IA abre aqui o MESMO `FormularioIA` da tela de
 *   Provedores de IA — que agora busca os modelos sozinho —, e não um campo
 *   novo: o segredo continua indo por `salvar_credencial_ia` para o Vault.
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  agenteDeSetupDisponivel, ajustarQuota, atribuirAgente, contarContatos, conversarComAgente,
  criarCampanhaDeModelo, definirIADaCampanha,
  lerAgentes, lerCampanhas, lerConexoesCRM, lerCredenciaisIA, lerModelos, lerProvedoresCRM,
  lerProvedoresCanal, lerProvedoresIA, lerRemetentes,
} from '../dados';
import type { CredencialIA, ProvedorIA } from '../dados';
import {
  aplicarSugestao, cumprida, impedimento, legenda, mapaDeRespostas, montarPlano, roteiro, situacao, valida,
  voltarPara,
} from '../assistente';
import type { Acao, Foto, Pergunta, Resposta, Respostas } from '../assistente';
import { Aviso, Campo, Icone, Secao, corCanal } from '../componentes/base';
import { Ico } from '../componentes/icones';
import { FormularioIA } from './Telas';
import { AVISO_DE_CHAVE, lugarDaChave, pareceSegredo } from '@adapters/segredo.ts';
import type { LugarDaChave } from '@adapters/segredo.ts';

export async function lerFoto(administra: boolean, opera: boolean): Promise<Foto> {
  const [provedores, remetentes, provedoresIA, credenciaisIA, provedoresCRM, conexoesCRM,
         modelos, agentes, campanhas, contatos] = await Promise.all([
    lerProvedoresCanal(), lerRemetentes(), lerProvedoresIA(), lerCredenciaisIA(), lerProvedoresCRM(),
    // A RLS de conexão de CRM é só de quem administra, inclusive na leitura:
    // operador vê uma lista vazia, e o assistente não deve tratar isso como erro.
    administra ? lerConexoesCRM() : Promise.resolve([]),
    lerModelos(), lerAgentes(), lerCampanhas(), contarContatos(),
  ]);
  return {
    administra, opera, provedores, remetentes, provedoresIA, credenciaisIA, provedoresCRM,
    conexoesCRM, modelos, agentes, campanhas, contatos,
  };
}

type Fala = { papel: 'pessoa' | 'agente'; texto: string; preencheu?: string[]; guardou?: string[] };

/** O que sobrevive a recarregar a página. Sem segredo nenhum (ver o topo). */
interface Memoria {
  respostas: Respostas;
  /** id da ação → o que ela fez, dito na hora. Mostrado em vez de refazer a conta. */
  feitos: Record<string, string>;
  pulados: string[];
  /** id da ação → id que ela produziu (campanha, credencial), para quem depende dela. */
  produzidos: Record<string, string>;
  /** A conversa com o agente. Texto que parece chave nunca entra aqui. */
  agente: Fala[];
}

const VAZIA: Memoria = { respostas: {}, feitos: {}, pulados: [], produzidos: {}, agente: [] };

function lerMemoria(chave: string): Memoria {
  try {
    const bruto = localStorage.getItem(chave);
    const m = bruto ? { ...VAZIA, ...(JSON.parse(bruto) as Partial<Memoria>) } : VAZIA;
    // Memória antiga, de antes da regra, pode ter guardado o que hoje é barrado.
    return { ...m, agente: (m.agente ?? []).filter((f) => !pareceSegredo(f.texto)) };
  } catch { return VAZIA; }
}

function gravarMemoria(chave: string, m: Memoria) {
  try { localStorage.setItem(chave, JSON.stringify(m)); } catch { /* aba anônima: segue sem memória */ }
}

// ---------------------------------------------------------------------------
// Atalhos: um por coisa que se conecta
// ---------------------------------------------------------------------------

interface Atalho {
  id: LugarDaChave;
  titulo: string;
  icone: string;
  cor?: string;
  /** Para onde "Conectar" leva. A IA não leva: abre o formulário aqui. */
  rota?: string;
  /** O que está conectado agora, lido da foto; vazio = nada ainda. */
  feito: string;
  /** Presente = não dá para conectar, e o texto diz por quê (D54). */
  indisponivel?: string;
  detalhe: string;
}

function atalhos(f: Foto): Atalho[] {
  const contas = (canal: string, oficial?: boolean) => f.remetentes.filter((r) => r.canal === canal
    && r.estado !== 'desativado'
    && (oficial === undefined || f.provedores.find((p) => p.slug === r.provedor)?.oficial === oficial));
  const resumo = (xs: Foto['remetentes']) => xs.length
    ? `${xs.length} conta${xs.length > 1 ? 's' : ''} · até ${xs.reduce((s, x) => s + x.quota_diaria, 0)}/dia` : '';
  const semAdapter = (canal: string, oficial?: boolean) =>
    f.provedores.some((p) => p.canal === canal && p.tem_adapter && p.ativo && (oficial === undefined || p.oficial === oficial))
      ? undefined : 'nenhum provedor sabe enviar por aqui ainda — não é configuração que falta';
  const ia = f.credenciaisIA.filter((c) => c.ativo);
  const crm = f.conexoesCRM.filter((c) => c.ativo);
  return [
    { id: 'whatsapp_nao_oficial', titulo: 'WhatsApp não oficial', icone: 'whatsapp', cor: corCanal('whatsapp'),
      rota: '/canais/whatsapp/nao', feito: resumo(contas('whatsapp', false)),
      indisponivel: semAdapter('whatsapp', false),
      detalhe: 'Chip conectado por QR. É o que roda lista fria.' },
    { id: 'whatsapp_oficial', titulo: 'WhatsApp oficial', icone: 'whatsapp', cor: corCanal('whatsapp'),
      rota: '/canais/whatsapp/oficial', feito: resumo(contas('whatsapp', true)),
      indisponivel: semAdapter('whatsapp', true),
      detalhe: 'API da Meta ou de parceiro, para a sua base com consentimento.' },
    { id: 'email', titulo: 'E-mail', icone: 'email', cor: corCanal('email'), rota: '/config/email',
      feito: resumo(contas('email')), indisponivel: semAdapter('email'),
      detalhe: 'Resend ou SMTP Locaweb, com domínio verificado.' },
    { id: 'sms', titulo: 'SMS', icone: 'sms', cor: corCanal('sms'), rota: '/canais/sms',
      feito: resumo(contas('sms')), indisponivel: semAdapter('sms'),
      detalhe: 'Para avisos curtos e quem não usa WhatsApp.' },
    { id: 'ia', titulo: 'Inteligência artificial', icone: 'ia',
      feito: ia.length ? `${ia.length} conta${ia.length > 1 ? 's' : ''}: ${ia.map((c) => c.nome).join(', ')}` : '',
      detalhe: 'A conta com que o agente responde quem escreve de volta. Os modelos carregam ao colar a chave.' },
    { id: 'crm', titulo: 'CRM', icone: 'plataforma', rota: '/config/vinculadas',
      feito: crm.length ? crm.map((c) => c.nome).join(', ') : '',
      detalhe: 'Para o motor devolver ao card quem respondeu, saiu ou concluiu.' },
  ];
}

export function Setup() {
  const nav = useNavigate();
  const { tenant, administra, opera } = useSessao();
  const chave = `prospecta:assistente:${tenant?.tenant_id ?? ''}`;
  const [foto, setFoto] = useState<Foto | null>(null);
  const [erro, setErro] = useState('');
  const [mem, setMem] = useState<Memoria>(() => lerMemoria(chave));
  const [aberto, setAberto] = useState<LugarDaChave | null>(null);
  const refAtalhos = useRef<HTMLDivElement>(null);

  async function recarregar() {
    try { setFoto(await lerFoto(administra, opera)); setErro(''); }
    catch (e) { setErro(mensagemDeErro(e)); }
  }
  useEffect(() => { setMem(lerMemoria(chave)); void recarregar(); /* eslint-disable-next-line */ }, [chave]);

  function mudar(m: Memoria) { setMem(m); gravarMemoria(chave, m); }

  // O agente aponta; não leva embora. Sair da tela no meio da resposta dele
  // seria a pessoa perder o que ele acabou de dizer.
  function abrir(id: LugarDaChave) {
    setAberto(id);
    requestAnimationFrame(() => refAtalhos.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  }

  if (!foto) {
    return <div className="wrap">{erro ? <Aviso tipo="erro">{erro}</Aviso> : <p className="vazio">Carregando…</p>}</div>;
  }

  const itens = situacao(foto);
  const prontos = itens.filter((i) => i.feito).length;
  const lista = atalhos(foto);

  return (
    <div className="wrap larga">
      <div className="cabeca">
        <div>
          <h1>Setup rápido</h1>
          <p>Diga ao agente como você quer trabalhar, ou conecte cada peça pelos atalhos. Nada é feito
             sem o seu clique: o agente preenche as respostas, e cada passo do plano espera "Autorizar".</p>
        </div>
        <span className="chip" title="lido agora do banco">{prontos} de {itens.length} prontos</span>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <AgenteDeSetup foto={foto} mem={mem} aoMudar={mudar} aoAbrir={(id) => abrir(id)} />

      <div ref={refAtalhos}>
        <Secao titulo="Atalhos" nota="o que já está conectado, lido agora do banco" />
      </div>
      <div className="atalhos">
        {lista.map((a) => (
          <div key={a.id} className={`painel atalho ${a.feito ? 'pronto' : ''}`} data-aberto={aberto === a.id}>
            <div className="atalho-topo">
              <Icone nome={a.icone} cor={a.cor} />
              <b>{a.titulo}</b>
              {a.feito
                ? <span className="chip ok"><Ico nome="check" className="" />pronto</span>
                : a.indisponivel ? <span className="chip">indisponível</span> : null}
            </div>
            <p className="atalho-feito">{a.feito || a.indisponivel || 'Nada conectado ainda.'}</p>
            <p className="atalho-detalhe">{a.detalhe}</p>
            <div className="atalho-acao">
              {a.rota ? (
                <button className={`btn mini ${a.feito ? '' : 'prim'}`} disabled={!!a.indisponivel}
                        onClick={() => nav(a.rota!)}>
                  {a.feito ? 'Gerenciar' : 'Conectar'} <Ico nome="seta" />
                </button>
              ) : (
                <button className={`btn mini ${a.feito ? '' : 'prim'}`} aria-expanded={aberto === a.id}
                        onClick={() => setAberto(aberto === a.id ? null : a.id)}>
                  {aberto === a.id ? 'Fechar' : a.feito ? 'Conectar outra' : 'Conectar'}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>

      {aberto === 'ia' && (
        <PainelIA administra={administra} aoSalvar={recarregar} aoFechar={() => setAberto(null)} />
      )}

      <Conversa foto={foto} mem={mem} aoMudar={mudar} aoRecarregar={recarregar} aoNavegar={nav} />
    </div>
  );
}

/** A conta de IA, conectada aqui mesmo, pelo formulário de Configurações. */
function PainelIA({ administra, aoSalvar, aoFechar }: {
  administra: boolean; aoSalvar(): Promise<void>; aoFechar(): void;
}) {
  const { tenant } = useSessao();
  const [dados, setDados] = useState<{ provedores: ProvedorIA[]; credenciais: CredencialIA[] } | null>(null);
  const [erro, setErro] = useState('');
  async function ler() {
    try { setDados({ provedores: await lerProvedoresIA(), credenciais: await lerCredenciaisIA() }); }
    catch (e) { setErro(mensagemDeErro(e)); }
  }
  useEffect(() => { void ler(); }, []);

  return (
    <>
      <Secao titulo="Conectar uma conta de IA"
             nota={<button className="link" onClick={aoFechar}>fechar</button>} />
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {!administra
        ? <Aviso tipo="neutro">Só quem administra o cliente conecta conta de IA.</Aviso>
        : !dados ? <p className="vazio">Carregando…</p>
        : <FormularioIA provedores={dados.provedores.filter((p) => p.tem_adapter)} credenciais={dados.credenciais}
                        tenant={tenant?.tenant_id ?? ''} provedorInicial="openai"
                        aoSalvar={async () => { await ler(); await aoSalvar(); }} />}
    </>
  );
}

// ---------------------------------------------------------------------------
// O agente
// ---------------------------------------------------------------------------

const EXEMPLOS = [
  'Lista fria no WhatsApp não oficial, 100 por dia',
  'Minha base de clientes por e-mail e WhatsApp oficial',
  'Quero que a OpenAI responda quem escrever de volta',
];

function AgenteDeSetup({ foto, mem, aoMudar, aoAbrir }: {
  foto: Foto; mem: Memoria; aoMudar(m: Memoria): void; aoAbrir(id: LugarDaChave): void;
}) {
  const [texto, setTexto] = useState('');
  const [enviando, setEnviando] = useState(false);
  const [falha, setFalha] = useState('');
  const [pronto, setPronto] = useState<boolean | null>(null);
  const fim = useRef<HTMLDivElement>(null);

  useEffect(() => { agenteDeSetupDisponivel().then(setPronto).catch(() => setPronto(false)); }, []);
  useEffect(() => { fim.current?.scrollIntoView({ block: 'nearest' }); }, [mem.agente.length]);

  async function enviar(msg: string) {
    const m = msg.trim();
    if (!m || enviando) return;
    setFalha('');
    // A chave não sai daqui e não é guardada: a fala da pessoa nem entra na
    // conversa. Só o aviso entra, e o formulário certo abre.
    if (pareceSegredo(m)) {
      setTexto('');
      aoMudar({ ...mem, agente: [...mem.agente, { papel: 'agente', texto: AVISO_DE_CHAVE }] });
      aoAbrir(lugarDaChave(m));
      return;
    }
    setEnviando(true);
    const { atual, respostas } = roteiro(foto, mem.respostas);
    const r = await conversarComAgente({
      mensagem: m,
      historico: mem.agente.slice(-12).map(({ papel, texto: t }) => ({ papel, texto: t })),
      perguntaAtual: atual?.chave ?? null,
      situacao: situacao(foto).map((i) => `${i.titulo}: ${i.detalhe}`),
      respostas,
      mapa: mapaDeRespostas(foto, mem.respostas),
    });
    setEnviando(false);
    if (!r.ok) { setFalha(r.erro); return; }
    setTexto('');
    const s = aplicarSugestao(foto, mem.respostas, r.respostas);
    const nomes = s.aceitas.map((k) => roteiro(foto, s.respostas).passos.find((p) => p.pergunta.chave === k)?.pergunta)
      .filter((p): p is Pergunta => !!p).map((p) => `${rotuloCurto(p.chave)}: ${legenda(p, s.respostas[p.chave]!)}`);
    // O que ficou para quando a conversa chegar lá: sem isto, o agente diz
    // "Pipefy" e a pessoa não vê o Pipefy em lugar nenhum.
    const guardou = Object.keys(r.respostas)
      .filter((k) => !s.aceitas.includes(k) && k in s.respostas && !(k in mem.respostas)).map(rotuloCurto);
    aoMudar({
      ...mem, respostas: s.respostas,
      agente: [...mem.agente, { papel: 'pessoa', texto: m },
               { papel: 'agente', texto: r.mensagem, preencheu: nomes, guardou }],
    });
    if (r.abrir) aoAbrir(r.abrir as LugarDaChave);
  }

  return (
    <section className="painel agente-setup" aria-label="Agente de configuração">
      <div className="agente-cabeca">
        <span className="agente-ico"><Ico nome="faisca" /></span>
        <div>
          <b>Agente de configuração</b>
          <p>{pronto === false
            ? 'Desligado: a chave da plataforma não está no cofre. Os atalhos e a conversa abaixo funcionam sem ele.'
            : 'Escreva do seu jeito. Ele preenche as perguntas abaixo — você confere, muda e autoriza.'}</p>
        </div>
        {mem.agente.length > 0 && (
          <button className="link" onClick={() => aoMudar({ ...mem, agente: [] })}>limpar</button>
        )}
      </div>

      {mem.agente.length > 0 && (
        <div className="agente-falas" aria-live="polite">
          {mem.agente.map((f, i) => (
            <div key={i} className={`balao ${f.papel === 'pessoa' ? 'pes' : 'ass'}`}>
              {f.texto}
              {f.preencheu && f.preencheu.length > 0 && (
                <ul className="preencheu">{f.preencheu.map((x) => <li key={x}><Ico nome="check" className="" />{x}</li>)}</ul>
              )}
              {f.guardou && f.guardou.length > 0 && (
                <p className="guardou">Guardado para quando a conversa chegar lá: {f.guardou.join(', ')}.</p>
              )}
            </div>
          ))}
          {enviando && <div className="balao ass digitando" aria-label="o agente está escrevendo"><i /><i /><i /></div>}
          <div ref={fim} />
        </div>
      )}

      {mem.agente.length === 0 && pronto !== false && (
        <div className="exemplos">
          {EXEMPLOS.map((e) => (
            <button key={e} type="button" className="exemplo" disabled={enviando} onClick={() => void enviar(e)}>{e}</button>
          ))}
        </div>
      )}

      {falha && <Aviso tipo="erro">{falha}</Aviso>}

      <form className="agente-entrada" onSubmit={(e) => { e.preventDefault(); void enviar(texto); }}>
        <textarea value={texto} rows={2} maxLength={2000} disabled={pronto === false}
                  placeholder="Ex.: quero prospectar lista fria no WhatsApp, 80 por dia, e uso Pipefy"
                  aria-label="Mensagem para o agente"
                  onChange={(e) => setTexto(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void enviar(texto); }
                  }} />
        <button className="btn prim" disabled={!texto.trim() || enviando || pronto === false} aria-label="Enviar">
          <Ico nome="enviar" />{enviando ? 'Pensando…' : 'Enviar'}
        </button>
      </form>
      <p className="agente-nota">Não cole chave aqui: ela é barrada antes de sair da tela. Chave entra pelo formulário do atalho.</p>
    </section>
  );
}

function rotuloCurto(chave: string): string {
  if (chave === 'canais') return 'Canais';
  if (chave === 'pool') return 'Para quem';
  if (chave === 'porDia') return 'Por dia';
  if (chave === 'familia:whatsapp') return 'WhatsApp';
  if (chave.startsWith('provedor:')) return `Provedor (${chave.slice(9)})`;
  if (chave === 'ia') return 'IA';
  if (chave === 'ia:conta') return 'Conta de IA';
  if (chave === 'crm') return 'CRM';
  if (chave === 'campanha') return 'Campanha';
  return chave;
}

function Conversa({ foto, mem, aoMudar, aoRecarregar, aoNavegar }: {
  foto: Foto; mem: Memoria; aoMudar(m: Memoria): void; aoRecarregar(): Promise<void>;
  aoNavegar(rota: string): void;
}) {
  const { passos, atual } = useMemo(() => roteiro(foto, mem.respostas), [foto, mem.respostas]);
  const plano = useMemo(() => (atual ? null : montarPlano(foto, mem.respostas)), [foto, mem.respostas, atual]);

  function responder(p: Pergunta, r: Resposta) {
    aoMudar({ ...mem, respostas: { ...mem.respostas, [p.chave]: r } });
  }

  return (
    <>
      <Secao titulo="As perguntas"
             nota={Object.keys(mem.respostas).length
               ? <button className="link" onClick={() => aoMudar({ ...VAZIA, agente: mem.agente })}>recomeçar</button>
               : 'ou responda clicando — leva uns dois minutos'} />
      <div className="conversa">
        {passos.map((p) => (
          <div key={p.pergunta.chave} className="troca">
            <div className="balao ass">{p.pergunta.texto}</div>
            <div className="balao pes">
              {legenda(p.pergunta, p.resposta)}
              <button className="link" onClick={() => aoMudar({
                ...mem, respostas: voltarPara(foto, mem.respostas, p.pergunta.chave),
              })}>mudar</button>
            </div>
          </div>
        ))}
        {atual && <PerguntaAtual key={atual.chave} p={atual} anterior={mem.respostas[atual.chave]} aoResponder={responder} />}
      </div>

      {plano && (
        <>
          <Secao titulo="O plano" nota="nada foi feito ainda — cada passo espera a sua autorização" />
          {plano.avisos.map((a) => <Aviso key={a} tipo="neutro">{a}</Aviso>)}
          <div className="cartoes">
            {plano.acoes.map((a, i) => (
              <Cartao key={a.id} n={i + 1} acao={a} foto={foto} mem={mem} plano={plano.acoes}
                      aoMudar={aoMudar} aoRecarregar={aoRecarregar} aoNavegar={aoNavegar} />
            ))}
          </div>
        </>
      )}
    </>
  );
}

function PerguntaAtual({ p, anterior, aoResponder }: {
  p: Pergunta; anterior?: Resposta; aoResponder(p: Pergunta, r: Resposta): void;
}) {
  const [marcados, setMarcados] = useState<string[]>(Array.isArray(anterior) ? [...anterior] : []);
  const [nums, setNums] = useState<Record<string, string>>(() =>
    Object.fromEntries((p.numeros ?? []).map((c) => [c.chave, String(c.sugestao)])));

  const numerico = Object.fromEntries(Object.entries(nums).map(([k, v]) => [k, Number(v)]));

  return (
    <div className="troca">
      <div className="balao ass">
        {p.texto}
        {p.ajuda && <p className="ajuda-balao">{p.ajuda}</p>}
      </div>
      <div className="painel resposta">
        {p.forma === 'numeros' ? (
          <>
            {(p.numeros ?? []).map((c) => (
              <Campo key={c.chave} id={`dia-${c.chave}`} rotulo={`${c.rotulo} — mensagens por dia`} mono
                     valor={nums[c.chave] ?? ''} ajuda={c.ajuda}
                     aoMudar={(v) => setNums({ ...nums, [c.chave]: v.replace(/\D/g, '') })} />
            ))}
            <button className="btn prim" disabled={!valida(p, numerico)} onClick={() => aoResponder(p, numerico)}>
              Continuar
            </button>
          </>
        ) : (
          <>
            <div className="opts">
              {p.opcoes.map((o) => {
                const marcado = p.forma === 'multipla' ? marcados.includes(o.valor) : anterior === o.valor;
                return (
                  <button key={o.valor} type="button" className="opt" aria-pressed={marcado}
                          disabled={!!o.indisponivel}
                          onClick={() => {
                            if (p.forma === 'unica') { aoResponder(p, o.valor); return; }
                            setMarcados(marcado ? marcados.filter((x) => x !== o.valor) : [...marcados, o.valor]);
                          }}>
                    <b>{o.rotulo}{o.recomendada && <span className="chip">recomendado</span>}</b>
                    {o.detalhe && <p>{o.detalhe}</p>}
                    {o.indisponivel && <p>{o.indisponivel}</p>}
                  </button>
                );
              })}
            </div>
            {p.forma === 'multipla' && (
              <button className="btn prim" style={{ marginTop: 12 }} disabled={!valida(p, marcados)}
                      onClick={() => aoResponder(p, marcados)}>
                Continuar
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Um cartão do plano
// ---------------------------------------------------------------------------

/**
 * Três jeitos de cartão, e nenhum tem campo de chave (D68):
 *
 * - **executa**: ajustar quota, criar campanha, ligar agentes. "Autorizar"
 *   faz, com o JWT de quem clicou.
 * - **configurar**: conectar conta, chave ou CRM. Leva à tela onde isso se faz;
 *   "pronto" vem do banco, não de um clique aqui.
 * - **abrir**: importação, mapeamento do CRM. Só leva.
 */
function Cartao({ n, acao: a, foto, mem, plano, aoMudar, aoRecarregar, aoNavegar }: {
  n: number; acao: Acao; foto: Foto; mem: Memoria; plano: readonly Acao[];
  aoMudar(m: Memoria): void; aoRecarregar(): Promise<void>; aoNavegar(rota: string): void;
}) {
  const { tenant } = useSessao();
  const [nome, setNome] = useState(a.tipo === 'criar_campanha' ? a.nome : '');
  const [estado, setEstado] = useState<'parado' | 'executando'>('parado');
  const [falha, setFalha] = useState('');

  const feito = a.tipo === 'configurar' ? (a.pronto ? 'Pronto — lido agora do banco.' : undefined) : mem.feitos[a.id];
  const pulado = mem.pulados.includes(a.id);
  const impede = impedimento(foto, a);
  const esperando = a.dependeDe.filter((d) => !cumprida(plano, mem.feitos, d));
  const nomeDe = (id: string) => plano.find((x) => x.id === id)?.titulo ?? id;

  async function executar(): Promise<{ texto: string; produziu?: string }> {
    const t = tenant?.tenant_id ?? '';
    switch (a.tipo) {
      case 'ajustar_quota':
        await ajustarQuota(a.remetente, a.para);
        return { texto: `Quota ajustada de ${a.de} para ${a.para} por dia.` };
      case 'criar_campanha': {
        const r = await criarCampanhaDeModelo({ tenant: t, slug: a.modelo, nome: nome.trim(), canais: [...a.canais] });
        return { texto: `Campanha criada com ${r.passos_criados} passos.`, produziu: r.campaign_id };
      }
      case 'ligar_agentes': {
        const campanha = mem.produzidos.campanha!;
        if (!a.credencial) throw new Error('falta escolher a conta de IA');
        for (const x of a.agentes) await atribuirAgente(campanha, x.agente);
        // A conta vai na CAMPANHA, não no agente: o agente é uma persona que
        // várias campanhas dividem, e trocar a conta dele trocaria em todas (D68).
        await definirIADaCampanha(campanha, a.credencial);
        const conta = foto.credenciaisIA.find((c) => c.id === a.credencial);
        return { texto: `${a.agentes.map((x) => x.nome).join(' e ')} na campanha, compondo com "${conta?.nome ?? 'a conta escolhida'}".` };
      }
      case 'configurar':
      case 'abrir':
        aoNavegar(a.rota);
        return { texto: '' };
    }
  }

  async function autorizar() {
    setFalha(''); setEstado('executando');
    try {
      const r = await executar();
      if (a.tipo === 'configurar' || a.tipo === 'abrir') return;
      aoMudar({
        ...mem,
        feitos: { ...mem.feitos, [a.id]: r.texto },
        produzidos: r.produziu ? { ...mem.produzidos, [a.id]: r.produziu } : mem.produzidos,
        pulados: mem.pulados.filter((x) => x !== a.id),
      });
      await aoRecarregar();
    } catch (e) { setFalha(mensagemDeErro(e)); }
    finally { setEstado('parado'); }
  }

  const depois = feito ? linkDepois(a, mem) : null;
  const leva = a.tipo === 'configurar' || a.tipo === 'abrir';

  return (
    <div className={`painel cartao ${feito ? 'feito' : pulado ? 'pulado' : ''}`}>
      <div className="cartao-cabeca">
        <span className="num">{feito ? <Ico nome="check" className="" /> : n}</span>
        <b>{a.titulo}</b>
        <span className="chip">
          {feito ? 'feito' : pulado ? 'pulado' : a.tipo === 'configurar' ? 'em outra tela'
            : a.exige === 'administra' ? 'admin' : 'operação'}
        </span>
      </div>

      {feito ? (
        <>
          <p className="resultado">{feito}</p>
          {depois && <button className="btn" onClick={() => aoNavegar(depois.rota)}>{depois.rotulo}</button>}
        </>
      ) : pulado ? (
        <button className="link" onClick={() => aoMudar({ ...mem, pulados: mem.pulados.filter((x) => x !== a.id) })}>
          desfazer o pulo
        </button>
      ) : (
        <>
          <p className="se">{leva ? 'O que fazer lá:' : 'Se você autorizar:'}</p>
          <ul className="efeitos">{a.efeitos.map((e) => <li key={e}>{e}</li>)}</ul>

          {a.tipo === 'criar_campanha' && (
            <Campo id={`${a.id}-nome`} rotulo="Nome da campanha" valor={nome} aoMudar={setNome} />
          )}

          {impede && <Aviso tipo="neutro">{leva ? 'Peça a quem administra' : 'Não dá por aqui'}: {impede}.</Aviso>}
          {!impede && esperando.length > 0 && (
            <Aviso tipo="neutro">Espera antes: {esperando.map(nomeDe).join(' e ')}.</Aviso>
          )}
          {falha && <Aviso tipo="erro">{falha}</Aviso>}

          <div className="acoes-cartao">
            <button className="btn prim" onClick={autorizar}
                    disabled={!!impede || esperando.length > 0 || estado === 'executando'
                      || (a.tipo === 'criar_campanha' && !nome.trim())}>
              {estado === 'executando' ? 'Fazendo…' : leva ? 'Abrir' : 'Autorizar'}
            </button>
            <button className="btn" onClick={() => aoMudar({ ...mem, pulados: [...mem.pulados, a.id] })}>
              Pular
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/** Para onde ir depois de um passo feito. */
function linkDepois(a: Acao, mem: Memoria): { rota: string; rotulo: string } | null {
  const id = mem.produzidos[a.id];
  switch (a.tipo) {
    case 'configurar':
      return { rota: a.rota, rotulo: 'Ver em Configurações' };
    case 'criar_campanha':
      return id ? { rota: `/campanhas/${id}`, rotulo: 'Abrir a campanha' } : null;
    case 'ligar_agentes':
      return { rota: '/config/agentes', rotulo: 'Ajustar o que o agente diz' };
    default:
      return null;
  }
}

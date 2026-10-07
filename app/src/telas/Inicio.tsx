/**
 * Setup rápido, por chat (D73; era o assistente do D67 e a tela de atalhos do D72).
 *
 * A conversa É o setup. O condutor (`setupChat.ts`, puro e testado) diz qual é o
 * próximo passo; esta tela pergunta, recebe e executa. O que não dá para testar
 * sem navegador mora aqui, e quatro regras moram com ele:
 *
 * - **A pessoa configura conversando, e cada peça é feita quando a informação
 *   chega.** Por decisão do usuário, a conversa não para em cartão de
 *   "Autorizar": dar a informação é o pedido. Cada execução sai com o JWT de
 *   quem conversa (o RLS decide, como em qualquer tela) e é dita na conversa,
 *   com o resultado — inclusive a verificação da conta com o provedor.
 *
 * - **Segredo não passa pelo modelo, nem pela memória.** Quando o passo pede
 *   uma chave, a caixa de mensagem vira um campo protegido. O valor vai para
 *   `segredos` (um ref, que morre com a página) e dele direto para a função de
 *   banco que o põe no Vault. A conversa mostra "guardada no cofre", nunca a
 *   chave; o agente só sabe que o passo pede uma.
 *
 * - **Texto livre que parece chave não sai daqui.** Fora do campo protegido,
 *   `pareceSegredo` (a mesma regra do agente, `adapters/segredo.ts`) barra a
 *   frase antes de enviar e antes de guardar.
 *
 * - **O agente propõe; o condutor e o banco decidem.** O que o agente devolve
 *   entra pelo `valida` do roteiro e pelo `aceitarValor` de quem digita.
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro, sb } from '../supabase';
import {
  agenteDeSetupDisponivel, ajustarQuota, atribuirAgente, buscarModelosIA, conectarConta, contarContatos,
  conversarComAgente, criarCampanhaDeModelo, definirIADaCampanha, lerAgentes, lerCampanhas, lerConexoesCRM,
  lerCredenciaisIA, lerModelos, lerProvedoresCRM, lerProvedoresCanal, lerProvedoresIA, lerRemetentes,
  provisionarInstancia, salvarCredencialCRM, salvarCredencialIA, verificarRemetente,
} from '../dados';
import {
  aplicarSugestao, legenda, mapaDeRespostas, roteiro, situacao, valida,
} from '../assistente';
import type { Acao, Foto, Pergunta, Resposta } from '../assistente';
import {
  ESTADO_VAZIO, aceitarValor, aposConectar, nomeDaConta, passoParaOAgente, proximoPasso,
} from '../setupChat';
import type { Coleta, EstadoSetup, PassoSetup } from '../setupChat';
import { Aviso } from '../componentes/base';
import { Ico } from '../componentes/icones';
import { AVISO_DE_CHAVE, pareceSegredo } from '@adapters/segredo.ts';

export async function lerFoto(administra: boolean, opera: boolean): Promise<Foto> {
  const [provedores, remetentes, provedoresIA, credenciaisIA, provedoresCRM, conexoesCRM,
         modelos, agentes, campanhas, contatos, servidores] = await Promise.all([
    lerProvedoresCanal(), lerRemetentes(), lerProvedoresIA(), lerCredenciaisIA(), lerProvedoresCRM(),
    // A RLS de conexão de CRM é só de quem administra, inclusive na leitura:
    // operador vê uma lista vazia, e o assistente não deve tratar isso como erro.
    administra ? lerConexoesCRM() : Promise.resolve([]),
    lerModelos(), lerAgentes(), lerCampanhas(), contarContatos(),
    // Servidor ativo é o que deixa a conversa CRIAR o chip (D25, D73). Erro
    // aqui não derruba o setup: sem servidor, a conversa conecta uma instância.
    sb.from('provider_servers').select('id, provedor, nome').eq('ativo', true)
      .then(({ data }) => (data ?? []) as { id: string; provedor: string; nome: string }[]),
  ]);
  return {
    administra, opera, provedores, remetentes, provedoresIA, credenciaisIA, provedoresCRM,
    conexoesCRM, modelos, agentes, campanhas, contatos, servidores,
  };
}

// ---------------------------------------------------------------------------
// A conversa guardada
// ---------------------------------------------------------------------------

type Fala =
  | { de: 'agente'; texto: string; preencheu?: string[] }
  | { de: 'pessoa'; texto: string; protegido?: boolean }
  | { de: 'sistema'; tipo: 'feito' | 'erro' | 'aviso'; texto: string; links?: { rota: string; rotulo: string }[] };

/** O que sobrevive a recarregar a página. Segredo nenhum: ver o topo. */
interface Memoria {
  estado: EstadoSetup;
  falas: Fala[];
  /** O último passo já perguntado, para a mesma pergunta não aparecer duas vezes. */
  perguntado: string;
}

const VAZIA: Memoria = { estado: ESTADO_VAZIO, falas: [], perguntado: '' };

function lerMemoria(chave: string): Memoria {
  try {
    const bruto = localStorage.getItem(chave);
    if (!bruto) return VAZIA;
    const m = JSON.parse(bruto) as Partial<Memoria>;
    // Memória do D72 tinha outra forma; começar limpo é melhor que remendar.
    if (!m.estado || !Array.isArray(m.falas)) return VAZIA;
    return { estado: { ...ESTADO_VAZIO, ...m.estado }, perguntado: m.perguntado ?? '',
             falas: m.falas.filter((f) => !pareceSegredo(f.texto)) };
  } catch { return VAZIA; }
}

function gravarMemoria(chave: string, m: Memoria) {
  try { localStorage.setItem(chave, JSON.stringify(m)); } catch { /* aba anônima: segue sem memória */ }
}

const SAUDACAO = 'Oi! Vou configurar o Prospecta com você: canais, IA, CRM e a primeira campanha. '
  + 'Pode me contar tudo de uma vez ("lista fria no WhatsApp, 100 por dia, com a OpenAI respondendo") '
  + 'ou ir respondendo uma pergunta de cada vez.';

function chaveDoPasso(p: PassoSetup): string {
  if (p.tipo === 'pergunta') return `pergunta:${p.pergunta.chave}`;
  if (p.tipo === 'campo') return `campo:${p.coleta.id}:${p.campo.chave}`;
  if (p.tipo === 'acao' || p.tipo === 'acao_impedida') return `acao:${p.acao.id}`;
  if (p.tipo === 'conectar' || p.tipo === 'sem_permissao') return `${p.tipo}:${p.coleta.id}`;
  return 'fim';
}

function textoDoPasso(p: PassoSetup): string {
  if (p.tipo === 'pergunta') return p.pergunta.texto + (p.pergunta.ajuda ? `\n${p.pergunta.ajuda}` : '');
  if (p.tipo === 'campo') {
    const peca = p.coleta.alvo === 'ia' ? `a conta da ${p.coleta.nomeProvedor}`
      : p.coleta.alvo === 'crm' ? `o ${p.coleta.nomeProvedor}` : `a conta ${p.coleta.nomeProvedor}`;
    const inicio = p.coleta.campos[0]?.chave === p.campo.chave ? `Vamos conectar ${peca}. ` : '';
    const segredo = p.campo.segredo ? '\nCole no campo protegido abaixo: vai direto para o cofre, e eu não vejo.' : '';
    // Rótulo do catálogo é nome de campo ("API key"), não pergunta.
    const pergunta = p.campo.rotulo.endsWith('?') ? p.campo.rotulo
      : p.campo.segredo ? `Agora a chave: ${p.campo.rotulo}.` : `Qual ${p.campo.rotulo.toLowerCase()} usar?`;
    return `${inicio}${pergunta}${p.campo.ajuda ? `\n${p.campo.ajuda}` : ''}${segredo}`;
  }
  return '';
}

// ---------------------------------------------------------------------------
// A tela
// ---------------------------------------------------------------------------

export function Setup() {
  const nav = useNavigate();
  const { tenant, administra, opera } = useSessao();
  const chave = `prospecta:setup-chat:${tenant?.tenant_id ?? ''}`;
  const [foto, setFoto] = useState<Foto | null>(null);
  const [erro, setErro] = useState('');
  const [mem, setMem] = useState<Memoria>(() => lerMemoria(chave));
  // Segredos digitados: só aqui, só em memória, só até irem para o Vault.
  const segredos = useRef<Record<string, Record<string, string>>>({});
  const [prontos, setProntos] = useState<Record<string, string[]>>({});
  const [ocupado, setOcupado] = useState('');
  // O passo que já está rodando. Estado do React chega tarde para isto: em
  // modo de desenvolvimento o efeito roda duas vezes seguidas, e a conta seria
  // conectada duas vezes antes de `ocupado` mudar.
  const rodando = useRef('');
  const memRef = useRef(mem);
  memRef.current = mem;

  async function recarregar(): Promise<Foto | null> {
    try { const f = await lerFoto(administra, opera); setFoto(f); setErro(''); return f; }
    catch (e) { setErro(mensagemDeErro(e)); return null; }
  }
  useEffect(() => { setMem(lerMemoria(chave)); void recarregar(); /* eslint-disable-next-line */ }, [chave]);

  function mudar(fn: (m: Memoria) => Memoria) {
    const novo = fn(memRef.current);
    memRef.current = novo;
    setMem(novo); gravarMemoria(chave, novo);
  }
  const dizer = (...falas: Fala[]) => mudar((m) => ({ ...m, falas: [...m.falas, ...falas] }));

  const passo = useMemo(() => (foto ? proximoPasso(foto, mem.estado, prontos) : null), [foto, mem.estado, prontos]);

  // Cada passo novo que pergunta vira uma fala do agente, uma vez só.
  useEffect(() => {
    if (!passo || ocupado) return;
    const k = chaveDoPasso(passo);
    if ((passo.tipo === 'pergunta' || passo.tipo === 'campo') && memRef.current.perguntado !== k) {
      mudar((m) => ({ ...m, perguntado: k, falas: [...m.falas, {
        de: 'agente', texto: (m.falas.length ? '' : `${SAUDACAO}\n\n`) + textoDoPasso(passo) }] }));
    }
    if (passo.tipo === 'fim' && memRef.current.perguntado !== 'fim' && memRef.current.falas.length) {
      mudar((m) => ({ ...m, perguntado: 'fim', falas: [...m.falas, {
        de: 'sistema', tipo: 'feito', links: [...passo.links],
        texto: 'Pronto: o que dava para configurar por aqui está configurado. O próximo passo é trazer contatos.',
      }] }));
    }
  }, [passo, ocupado]); // eslint-disable-line react-hooks/exhaustive-deps

  // Passos que não perguntam nada rodam sozinhos — é o "configurar à medida
  // que a informação chega". Um de cada vez: `ocupado` segura o próximo.
  useEffect(() => {
    if (!passo || !foto || ocupado) return;
    const k = chaveDoPasso(passo);
    const roda = ['conectar', 'acao', 'sem_permissao', 'acao_impedida'].includes(passo.tipo);
    if (!roda || rodando.current === k) return;
    rodando.current = k;
    if (passo.tipo === 'conectar') void executar(k, () => conectar(passo.coleta, passo.valores));
    if (passo.tipo === 'acao') void executar(k, () => fazerAcao(passo.acao));
    if (passo.tipo === 'sem_permissao') {
      mudar((m) => ({ ...m, estado: { ...m.estado, pulados: [...m.estado.pulados, passo.coleta.id] },
        falas: [...m.falas, { de: 'sistema', tipo: 'aviso',
          texto: `Conectar ${passo.coleta.nomeProvedor} é de quem administra o cliente (dono ou admin). Peça a essa pessoa, ou ela pode abrir esta mesma conversa. Sigo com o resto.` }] }));
    }
    if (passo.tipo === 'acao_impedida') {
      mudar((m) => ({ ...m, estado: { ...m.estado, pulados: [...m.estado.pulados, passo.acao.id] },
        falas: [...m.falas, { de: 'sistema', tipo: 'aviso', texto: `${passo.acao.titulo}: não deu — ${passo.motivo}.` }] }));
    }
  }, [passo, foto, ocupado]); // eslint-disable-line react-hooks/exhaustive-deps

  async function executar(k: string, fazer: () => Promise<void>) {
    setOcupado(k);
    try { await fazer(); } finally { setOcupado(''); rodando.current = ''; }
  }

  /** Conecta a peça com o que foi dito e o que está no ref. */
  async function conectar(col: Coleta, valores: Readonly<Record<string, string>>) {
    const t = tenant?.tenant_id ?? '';
    const seg = segredos.current[col.id] ?? {};
    const esquecer = () => {
      delete segredos.current[col.id];
      setProntos((p) => { const n = { ...p }; delete n[col.id]; return n; });
    };
    try {
      let texto = ''; let produzido: string | undefined; let ressalva = '';
      if (col.alvo === 'canal') {
        const prov = foto!.provedores.find((p) => p.slug === col.provedor)!;
        const { identificador, ...resto } = valores;
        const id = await conectarConta({
          tenant: t, canal: col.canal!, provedor: prov, identificador: identificador ?? '',
          apelido: nomeDaConta(col, valores), tipo: col.pool!, quota: col.quota ?? 1, valores: { ...resto, ...seg },
        });
        const v = await verificarRemetente(id);
        texto = `Conta ${col.nomeProvedor} conectada (${identificador}), até ${col.quota} por dia. A chave foi para o cofre.`;
        ressalva = v.ok ? (v.saude.ok ? ` Perguntei ao provedor: respondeu ok.` : ` Perguntei ao provedor e ele recusou: ${v.saude.detalhe}. A conta ficou salva — confira a chave na tela do canal.`)
          : ` Não consegui verificar agora (${v.erro}).`;
      } else if (col.alvo === 'instancia') {
        const r = await provisionarInstancia({
          serverId: col.servidor!, apelido: nomeDaConta(col, valores), identificador: valores.identificador ?? '',
          tipo: col.pool!, quota: col.quota ?? 1,
        });
        if (!r.ok) throw new Error(r.erro ?? 'o provedor não criou a instância');
        texto = `Chip criado (${valores.identificador}), até ${col.quota} por dia. Leia o QR abaixo no WhatsApp desse número para parear.`;
        setQr(r.qrcode ?? null);
      } else if (col.alvo === 'ia') {
        const { modelo = '', ...resto } = valores;
        produzido = await salvarCredencialIA({
          tenant: t, nome: nomeDaConta(col, valores), provedor: col.provedor, modelo, campos: { ...resto, ...seg },
        });
        texto = `Conta ${col.nomeProvedor} conectada com o modelo ${modelo}. A chave foi para o cofre.`;
      } else {
        await salvarCredencialCRM({ tenant: t, nome: nomeDaConta(col, valores), provedor: col.provedor, campos: { ...valores, ...seg } });
        const p = foto!.provedoresCRM.find((x) => x.slug === col.provedor);
        texto = `${col.nomeProvedor} conectado. A credencial foi para o cofre.`;
        ressalva = p?.tem_adapter
          ? ' O que cada fato faz no CRM (mover de fase, preencher campo) se escolhe na tela da conexão.'
          : ` Por enquanto o ${col.nomeProvedor} só guarda a credencial: nenhum fato é escrito lá até o adapter existir.`;
      }
      esquecer();
      mudar((m) => ({ ...m, estado: aposConectar(m.estado, col, texto, produzido),
        falas: [...m.falas, { de: 'sistema', tipo: 'feito', texto: texto + ressalva }] }));
      await recarregar();
    } catch (e) {
      // A chave pode ser o problema: ela é pedida de novo, e o resto fica.
      esquecer();
      mudar((m) => ({ ...m, perguntado: '', falas: [...m.falas, { de: 'sistema', tipo: 'erro',
        texto: `Não deu para conectar ${col.nomeProvedor}: ${mensagemDeErro(e)}. Vou pedir a chave de novo; se preferir, pule esta conta.` }] }));
    }
  }

  async function fazerAcao(a: Acao) {
    const t = tenant?.tenant_id ?? '';
    try {
      let texto = ''; let produzido: string | undefined;
      if (a.tipo === 'ajustar_quota') {
        await ajustarQuota(a.remetente, a.para);
        texto = `${a.titulo}: de ${a.de} para ${a.para} por dia.`;
      } else if (a.tipo === 'criar_campanha') {
        const r = await criarCampanhaDeModelo({ tenant: t, slug: a.modelo, nome: a.nome, canais: [...a.canais] });
        produzido = r.campaign_id;
        texto = `Campanha "${a.nome}" criada com ${r.passos_criados} passos. Ela está ligada, mas ninguém recebe nada até você inscrever contatos.`;
      } else if (a.tipo === 'ligar_agentes') {
        const campanha = memRef.current.estado.produzidos.campanha!;
        for (const x of a.agentes) await atribuirAgente(campanha, x.agente);
        await definirIADaCampanha(campanha, a.credencial!);
        texto = `${a.agentes.map((x) => x.nome).join(' e ')} na campanha: quando alguém responder, o agente responde sozinho.`;
      }
      mudar((m) => ({ ...m,
        estado: { ...m.estado, feitos: { ...m.estado.feitos, [a.id]: texto },
          produzidos: produzido ? { ...m.estado.produzidos, [a.id]: produzido } : m.estado.produzidos },
        falas: [...m.falas, { de: 'sistema', tipo: 'feito', texto }] }));
      await recarregar();
    } catch (e) {
      mudar((m) => ({ ...m, estado: { ...m.estado, pulados: [...m.estado.pulados, a.id] },
        falas: [...m.falas, { de: 'sistema', tipo: 'erro', texto: `${a.titulo}: não deu — ${mensagemDeErro(e)}.` }] }));
    }
  }

  const [qr, setQr] = useState<string | null>(null);

  if (!foto || !passo) {
    return <div className="wrap">{erro ? <Aviso tipo="erro">{erro}</Aviso> : <p className="vazio">Carregando…</p>}</div>;
  }

  const itens = situacao(foto);

  return (
    <div className="wrap setup-chat">
      <div className="cabeca">
        <div>
          <h1>Setup rápido</h1>
          <p>Uma conversa: eu pergunto, você responde do seu jeito, e cada peça é configurada assim que a
             informação chega. Chave de API vai num campo protegido, direto para o cofre.</p>
        </div>
      </div>
      <div className="estado-setup" aria-label="O que já está pronto, lido do banco">
        {itens.map((i) => (
          <span key={i.id} className={`chip${i.feito ? ' ok' : ''}`} title={i.detalhe}>
            {i.feito && <Ico nome="check" className="" />}{i.titulo}
          </span>
        ))}
        {mem.falas.length > 0 && (
          <button className="link" onClick={() => {
            segredos.current = {}; setProntos({}); setQr(null);
            mudar(() => VAZIA);
          }}>recomeçar</button>
        )}
      </div>
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <Chat foto={foto} mem={mem} passo={passo} ocupado={ocupado} qr={qr}
            aoDizer={dizer} aoMudar={mudar} aoNavegar={nav}
            aoSegredo={(col, chaveCampo, valor) => {
              segredos.current[col] = { ...(segredos.current[col] ?? {}), [chaveCampo]: valor };
              setProntos((p) => ({ ...p, [col]: [...new Set([...(p[col] ?? []), chaveCampo])] }));
            }}
            segredoDe={(col) => segredos.current[col] ?? {}}
            aoEsquecerSegredo={(col, chaveCampo) => {
              const s = { ...(segredos.current[col] ?? {}) }; delete s[chaveCampo];
              segredos.current[col] = s;
              setProntos((p) => ({ ...p, [col]: (p[col] ?? []).filter((x) => x !== chaveCampo) }));
            }} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// O chat
// ---------------------------------------------------------------------------

function Chat(props: {
  foto: Foto; mem: Memoria; passo: PassoSetup; ocupado: string; qr: string | null;
  aoDizer(...f: Fala[]): void; aoMudar(fn: (m: Memoria) => Memoria): void; aoNavegar(rota: string): void;
  aoSegredo(coleta: string, campo: string, valor: string): void;
  segredoDe(coleta: string): Record<string, string>;
  aoEsquecerSegredo(coleta: string, campo: string): void;
}) {
  const { foto, mem, passo } = props;
  const [texto, setTexto] = useState('');
  const [pensando, setPensando] = useState(false);
  const [agentePronto, setAgentePronto] = useState<boolean | null>(null);
  const fim = useRef<HTMLDivElement>(null);

  useEffect(() => { agenteDeSetupDisponivel().then(setAgentePronto).catch(() => setAgentePronto(false)); }, []);
  useEffect(() => { fim.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }, [mem.falas.length, pensando, props.ocupado]);

  const pedeSegredo = passo.tipo === 'campo' && passo.campo.segredo;

  function responder(p: Pergunta, r: Resposta) {
    props.aoMudar((m) => ({ ...m,
      estado: { ...m.estado, respostas: { ...m.estado.respostas, [p.chave]: r } },
      falas: [...m.falas, { de: 'pessoa', texto: legenda(p, r) }] }));
  }

  function valorDoCampo(bruto: string) {
    if (passo.tipo !== 'campo') return;
    const r = aceitarValor(mem.estado, passo.coleta, passo.campo.chave, bruto);
    if (!r.ok) { props.aoDizer({ de: 'pessoa', texto: bruto }, { de: 'agente', texto: `Hmm, ${r.erro}. Pode mandar de novo?` }); return; }
    props.aoMudar((m) => ({ ...m, estado: r.estado, falas: [...m.falas, { de: 'pessoa', texto: r.estado.valores[passo.coleta.id]![passo.campo.chave]! }] }));
  }

  async function enviar() {
    const m = texto.trim();
    if (!m || pensando) return;
    if (pedeSegredo && passo.tipo === 'campo') {
      props.aoSegredo(passo.coleta.id, passo.campo.chave, m);
      setTexto('');
      props.aoDizer({ de: 'pessoa', texto: `${passo.campo.rotulo.replace(/\?$/, '')}: guardada no cofre`, protegido: true });
      return;
    }
    if (pareceSegredo(m)) { setTexto(''); props.aoDizer({ de: 'agente', texto: AVISO_DE_CHAVE }); return; }
    // Num campo, o que se digita é o valor — a não ser que seja uma pergunta,
    // ou uma frase em volta do valor ("pode usar contato@x.com"): número e
    // e-mail que não passam direto vão ao agente, que separa o valor da frase.
    if (passo.tipo === 'campo' && passo.campo.tipo !== 'modelo' && !m.endsWith('?')) {
      const direto = aceitarValor(mem.estado, passo.coleta, passo.campo.chave, m).ok;
      const frase = (passo.campo.tipo === 'email' || passo.campo.tipo === 'telefone') && /\s/.test(m) && agentePronto !== false;
      if (direto || !frase) { setTexto(''); valorDoCampo(m); return; }
    }
    if (agentePronto === false) {
      props.aoDizer({ de: 'pessoa', texto: m }, { de: 'agente', texto: 'O agente está desligado agora (a chave da plataforma não está no cofre). Use as opções acima para responder.' });
      setTexto(''); return;
    }

    setPensando(true);
    const { respostas } = roteiro(foto, mem.estado.respostas);
    const ctx = passoParaOAgente(passo) as { campos_que_voce_pode_preencher?: { chave: string; rotulo: string }[] };
    const r = await conversarComAgente({
      mensagem: m,
      historico: mem.falas.slice(-12).filter((f) => !(f.de === 'pessoa' && f.protegido))
        .map((f) => ({ papel: f.de === 'pessoa' ? 'pessoa' as const : 'agente' as const, texto: f.texto })),
      passo: { tipo: passo.tipo, descricao: JSON.stringify(ctx).slice(0, 1500), campos: ctx.campos_que_voce_pode_preencher ?? [] },
      situacao: situacao(foto).map((i) => `${i.titulo}: ${i.detalhe}`),
      respostas,
      mapa: mapaDeRespostas(foto, mem.estado.respostas),
    });
    setPensando(false);
    if (!r.ok) { props.aoDizer({ de: 'agente', texto: `Não consegui pensar nisso agora (${r.erro}). Pode responder pelas opções?` }); return; }
    setTexto('');

    let estado = mem.estado;
    const s = aplicarSugestao(foto, estado.respostas, r.respostas);
    estado = { ...estado, respostas: s.respostas };
    const preencheu = s.aceitas.map((k) => roteiro(foto, s.respostas).passos.find((p) => p.pergunta.chave === k))
      .filter((p): p is NonNullable<typeof p> => !!p).map((p) => legenda(p.pergunta, p.resposta));
    const campos = r.campos ?? {};
    if (passo.tipo === 'campo') {
      for (const [k, v] of Object.entries(campos)) {
        const a = aceitarValor(estado, passo.coleta, k, v);
        if (a.ok) { estado = a.estado; preencheu.push(a.estado.valores[passo.coleta.id]![k]!); }
      }
    }
    props.aoMudar((mm) => ({ ...mm, estado, falas: [...mm.falas, { de: 'pessoa', texto: m },
      { de: 'agente', texto: r.mensagem, preencheu }] }));
  }

  return (
    <section className="painel chat-setup" aria-label="Conversa de configuração">
      <div className="chat-falas" aria-live="polite">
        {mem.falas.map((f, i) => <BalaoDaFala key={i} f={f} aoNavegar={props.aoNavegar} />)}
        {props.qr && (
          <div className="balao ass qr-chat">
            <img src={props.qr.startsWith('data:') ? props.qr : `data:image/png;base64,${props.qr}`} alt="QR code para parear o WhatsApp" />
            <p>WhatsApp do chip ▸ Aparelhos conectados ▸ Conectar aparelho.</p>
          </div>
        )}
        {(pensando || props.ocupado) && (
          <div className="balao ass digitando" aria-label={props.ocupado ? 'configurando' : 'pensando'}><i /><i /><i /></div>
        )}
        <div ref={fim} />
      </div>

      {!props.ocupado && <RespostaRapida passo={passo} foto={foto} mem={mem} onResponder={responder} onValor={valorDoCampo}
        segredoDe={props.segredoDe} aoEsquecerSegredo={props.aoEsquecerSegredo} aoMudar={props.aoMudar} aoDizer={props.aoDizer} />}

      {passo.tipo !== 'fim' && (
        <form className="agente-entrada" onSubmit={(e) => { e.preventDefault(); void enviar(); }}>
          {pedeSegredo ? (
            <input type="password" className="protegido" value={texto} autoComplete="off" autoFocus
                   aria-label={passo.tipo === 'campo' ? passo.campo.rotulo : 'segredo'}
                   placeholder="Cole aqui — vai direto para o cofre"
                   onChange={(e) => setTexto(e.target.value)} />
          ) : (
            <textarea value={texto} rows={1} maxLength={2000}
                      placeholder={passo.tipo === 'campo' ? (passo.campo.exemplo ? `Ex.: ${passo.campo.exemplo}` : 'Digite aqui') : 'Escreva do seu jeito…'}
                      aria-label="Mensagem"
                      onChange={(e) => setTexto(e.target.value)}
                      onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void enviar(); } }} />
          )}
          <button className="btn prim" disabled={!texto.trim() || pensando || !!props.ocupado} aria-label="Enviar">
            <Ico nome={pedeSegredo ? 'check' : 'enviar'} />{pedeSegredo ? 'Guardar' : 'Enviar'}
          </button>
        </form>
      )}
    </section>
  );
}

function BalaoDaFala({ f, aoNavegar }: { f: Fala; aoNavegar(r: string): void }) {
  if (f.de === 'pessoa') {
    return <div className={`balao pes${f.protegido ? ' protegido' : ''}`}>{f.protegido && <Ico nome="check" className="" />}{f.texto}</div>;
  }
  if (f.de === 'agente') {
    return (
      <div className="balao ass">
        {f.texto}
        {f.preencheu && f.preencheu.length > 0 && (
          <ul className="preencheu">{f.preencheu.map((x, i) => <li key={i}><Ico nome="check" className="" />{x}</li>)}</ul>
        )}
      </div>
    );
  }
  return (
    <div className={`fala-sistema ${f.tipo}`}>
      <Ico nome={f.tipo === 'feito' ? 'check' : 'alerta'} />
      <div>
        <p>{f.texto}</p>
        {f.links && f.links.length > 0 && (
          <div className="links">{f.links.map((l) => (
            <button key={l.rota} className="btn mini" onClick={() => aoNavegar(l.rota)}>{l.rotulo}<Ico nome="seta" /></button>
          ))}</div>
        )}
      </div>
    </div>
  );
}

/** O jeito rápido de responder ao passo: opções, números, modelos. */
function RespostaRapida(props: {
  passo: PassoSetup; foto: Foto; mem: Memoria;
  onResponder(p: Pergunta, r: Resposta): void; onValor(v: string): void;
  segredoDe(coleta: string): Record<string, string>;
  aoEsquecerSegredo(coleta: string, campo: string): void;
  aoMudar(fn: (m: Memoria) => Memoria): void; aoDizer(...f: Fala[]): void;
}) {
  const { passo } = props;
  const [marcados, setMarcados] = useState<string[]>([]);
  const [nums, setNums] = useState<Record<string, string>>({});
  const [modelos, setModelos] = useState<{ estado: 'buscando' | 'pronto' | 'erro'; lista: string[]; erro?: string }>({ estado: 'buscando', lista: [] });
  const k = chaveDoPasso(passo);

  useEffect(() => {
    setMarcados([]);
    if (passo.tipo === 'pergunta' && passo.pergunta.forma === 'numeros') {
      setNums(Object.fromEntries((passo.pergunta.numeros ?? []).map((c) => [c.chave, String(c.sugestao)])));
    }
    if (passo.tipo === 'campo' && passo.campo.tipo === 'modelo') {
      const col = passo.coleta;
      setModelos({ estado: 'buscando', lista: [] });
      void buscarModelosIA({ provedor: col.provedor, campos: { ...(props.mem.estado.valores[col.id] ?? {}), ...props.segredoDe(col.id) } })
        .then((r) => {
          if (r.ok) { setModelos({ estado: 'pronto', lista: r.modelos }); return; }
          setModelos({ estado: 'erro', lista: [], erro: r.erro });
          // Chave recusada: o condutor volta a pedir a chave, e a conversa diz por quê.
          if (!r.semListagem && /recusou|chave/i.test(r.erro)) {
            props.aoDizer({ de: 'sistema', tipo: 'erro', texto: `O provedor recusou a chave: ${r.erro}. Cole de novo, por favor.` });
            props.aoMudar((m) => ({ ...m, perguntado: '' }));
            for (const c of col.campos.filter((c) => c.segredo)) props.aoEsquecerSegredo(col.id, c.chave);
          }
        });
    }
  }, [k]); // eslint-disable-line react-hooks/exhaustive-deps

  const pular = (id: string, nome: string) => (
    <button type="button" className="link" onClick={() => props.aoMudar((m) => ({ ...m,
      estado: { ...m.estado, pulados: [...m.estado.pulados, id] },
      falas: [...m.falas, { de: 'pessoa', texto: `Pular ${nome} por agora` }] }))}>pular esta conta</button>
  );

  if (passo.tipo === 'pergunta') {
    const p = passo.pergunta;
    if (p.forma === 'numeros') {
      const n = Object.fromEntries(Object.entries(nums).map(([c, v]) => [c, Number(v)]));
      return (
        <div className="opcoes-chat">
          {(p.numeros ?? []).map((c) => (
            <label key={c.chave} className="numero-chat">
              <span>{c.rotulo}</span>
              <input inputMode="numeric" value={nums[c.chave] ?? ''} aria-label={`${c.rotulo} por dia`}
                     onChange={(e) => setNums({ ...nums, [c.chave]: e.target.value.replace(/\D/g, '') })} />
              <span>por dia</span>
            </label>
          ))}
          <button className="btn prim mini" disabled={!valida(p, n)} onClick={() => props.onResponder(p, n)}>Confirmar</button>
        </div>
      );
    }
    return (
      <div className="opcoes-chat">
        {p.opcoes.filter((o) => !o.indisponivel).map((o) => {
          const marcado = marcados.includes(o.valor);
          return (
            <button key={o.valor} type="button" className="opcao-chat" aria-pressed={p.forma === 'multipla' ? marcado : undefined}
                    title={o.detalhe}
                    onClick={() => {
                      if (p.forma === 'unica') { props.onResponder(p, o.valor); return; }
                      setMarcados(marcado ? marcados.filter((x) => x !== o.valor) : [...marcados, o.valor]);
                    }}>
              {o.rotulo}{o.recomendada && <span className="rec">recomendado</span>}
            </button>
          );
        })}
        {p.forma === 'multipla' && (
          <button className="btn prim mini" disabled={!valida(p, marcados)} onClick={() => props.onResponder(p, marcados)}>Confirmar</button>
        )}
      </div>
    );
  }

  if (passo.tipo === 'campo') {
    const col = passo.coleta;
    if (passo.campo.tipo === 'modelo') {
      return (
        <div className="opcoes-chat">
          {modelos.estado === 'buscando' && <span className="nota-chat">Buscando os modelos que a sua chave alcança…</span>}
          {modelos.lista.slice(0, 8).map((m) => (
            <button key={m} type="button" className="opcao-chat mono" onClick={() => props.onValor(m)}>{m}</button>
          ))}
          {modelos.estado === 'pronto' && modelos.lista.length > 8 && (
            <span className="nota-chat">ou digite o nome de outro dos {modelos.lista.length} abaixo</span>
          )}
          {modelos.estado === 'erro' && <span className="nota-chat">Não veio a lista ({modelos.erro}). Digite o nome do modelo abaixo.</span>}
          {pular(col.id, col.nomeProvedor)}
        </div>
      );
    }
    return <div className="opcoes-chat">{pular(col.id, col.nomeProvedor)}</div>;
  }
  return null;
}

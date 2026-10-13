// Configurações ▸ Agentes (D76): criar um agente escolhendo persona e
// objetivo, ajustar o texto, e escolher em que canal ele responde. O que muda
// de um canal para outro é da plataforma — `@adapters/prompt-do-agente.ts`, o
// MESMO módulo que o worker usa, monta a prévia.
//
// O que a tela diz em voz alta, porque o efeito é em massa e não aparece
// sozinho (D55): o agente do canal vale para toda campanha sem agente
// próprio; ele responde o que chegar a partir de agora; desligar para de
// responder (não passa a conversa a outro); e o catálogo é cópia.

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  criarAgente, escolherAgenteDaCampanha, escolherAgenteDoCanal, lerAgentes, lerAgentesPorCanal,
  lerCredenciaisIA, lerProvedoresIA, salvarAgente, testarAgente,
} from '../dados';
import type { Agente, AgenteDoCanal, CredencialIA, ProvedorIA, ResultadoDoTeste } from '../dados';
import { Aviso, Campo, LinhaIndice, NOME_CANAL, Pagina, Secao, corCanal } from '../componentes/base';
import { CANAIS, CONTEXTO_MINIMO, OBJETIVOS, PERSONAS, TETOS_DO_AGENTE, montarPedido } from '@adapters/prompt-do-agente.ts';
import {
  CANAIS_DO_AGENTE, PEDIDO_DE_SAIDA_DO_TESTE, camposParaGravar, canaisQueServe, conversaDeExemplo, entradaDaPrevia, oQueFalta,
  oQueMudaNoCanal, rascunhoDe, rascunhoNovo, rotulo, trocarObjetivo, trocarPersona,
} from '../agentes';
import type { CanalDoAgente, Rascunho } from '../agentes';
import { useDados } from './Telas';
import { ColetaDaEmpresa } from './ColetaDaEmpresa';

/** Só os agentes deste cliente: os cinco do catálogo antigo (tenant nulo)
 *  continuam no banco para `atribuir_agente` e o demo, mas não são mais o
 *  jeito de começar — a persona e o objetivo são. */
async function lerAgentesDoCliente(tenant: string): Promise<Agente[]> {
  return (await lerAgentes()).filter((a) => a.tenant_id === tenant);
}

function nomesDosCanais(canais: string[]): string {
  return canais.map((c) => NOME_CANAL[c] ?? c).join(', ');
}

/** O que dizer da conta de IA de um agente. Quem não administra não enxerga as
 *  contas (o RLS mostra só ao admin): "sem conta" seria mentira. */
function contaDoAgente(a: Agente, contas: CredencialIA[], administra: boolean): string {
  if (!a.ai_credential_id) return 'sem conta de IA própria (vale a da campanha)';
  const c = contas.find((x) => x.id === a.ai_credential_id);
  if (c) return `compõe com ${c.nome}${c.ativo ? '' : ' (desligada)'}`;
  return administra ? 'conta de IA removida' : 'com conta de IA';
}

// ---------------------------------------------------------------------------
// A lista e quem responde em cada canal
// ---------------------------------------------------------------------------

export function ConfigAgentes() {
  const nav = useNavigate();
  const { tenant, opera, administra } = useSessao();
  const t = tenant?.tenant_id ?? '';
  const { dados, erro, carregando, recarregar } = useDados(async () => ({
    agentes: t ? await lerAgentesDoCliente(t) : [],
    porCanal: t ? await lerAgentesPorCanal(t) : [] as AgenteDoCanal[],
    contas: administra ? await lerCredenciaisIA() : [] as CredencialIA[],
  }), [t, administra]);
  const [salvando, setSalvando] = useState('');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  if (carregando && !dados) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  const agentes = [...(dados?.agentes ?? [])].sort((a, b) => Number(b.ativo) - Number(a.ativo) || a.nome.localeCompare(b.nome));
  const porCanal = dados?.porCanal ?? [];

  async function escolher(canal: CanalDoAgente, agente: string | null) {
    setSalvando(canal); setMsg(null);
    try {
      await escolherAgenteDoCanal(t, canal, agente);
      const nome = agentes.find((a) => a.id === agente)?.nome;
      setMsg({ tipo: 'ok', texto: nome
        ? `${nome} responde no ${NOME_CANAL[canal]} a partir de agora, em toda campanha sem agente próprio.`
        : `Ninguém responde no ${NOME_CANAL[canal]} a partir de agora, a não ser onde a campanha escolheu um agente.` });
      await recarregar();
    } catch (e) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e) }); }
    finally { setSalvando(''); }
  }

  return (
    <Pagina titulo="Agentes" voltar={{ rotulo: 'Configurações', aoClicar: () => nav('/config') }}
            sub="Um agente é uma persona com um objetivo. Você o cria uma vez e escolhe em que canal ele responde; o que muda de um canal para outro — tamanho, formato, janela de 24h — a plataforma acrescenta sozinha."
            acao={opera ? <button className="btn prim" onClick={() => nav('/config/agentes/novo')}>Criar agente</button> : undefined}>
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <Secao titulo="Quem responde em cada canal" nota="vale para toda campanha sem agente próprio" />
      <div className="painel">
        {CANAIS_DO_AGENTE.map((c) => {
          const info = CANAIS[c];
          const atual = porCanal.find((p) => p.canal === c);
          const escolhido = agentes.find((a) => a.id === atual?.agent_id);
          const candidatos = agentes.filter((a) => a.ativo && canaisQueServe(a).includes(c));
          return (
            <div className="campo" key={c}>
              <label htmlFor={`canal-${c}`} style={{ color: corCanal(c) }}>{NOME_CANAL[c]}</label>
              {!info.recebeResposta ? (
                <span className="ajuda">Nenhum agente responde aqui: {info.porQueNao}.</span>
              ) : opera ? (
                <select id={`canal-${c}`} value={atual?.agent_id ?? ''} disabled={!!salvando}
                        onChange={(e) => void escolher(c, e.target.value || null)}>
                  <option value="">ninguém — a resposta fica para alguém da equipe, em Respostas</option>
                  {candidatos.map((a) => <option key={a.id} value={a.id}>{a.nome} · {rotulo(a)}</option>)}
                  {escolhido && !escolhido.ativo && (
                    <option value={escolhido.id}>{escolhido.nome} · desligado: não responde</option>
                  )}
                </select>
              ) : (
                <span>{escolhido ? `${escolhido.nome} · ${rotulo(escolhido)}` : 'ninguém'}</span>
              )}
              {escolhido && !escolhido.ativo && (
                <span className="ajuda">{escolhido.nome} está desligado: ninguém responde aqui até você ligá-lo ou
                  escolher outro.</span>
              )}
            </div>
          );
        })}
        <p className="nota-tela">A campanha que quiser outro agente — ou nenhum — escolhe na tela dela, em "Quem
          responde". Trocar aqui vale para a próxima resposta que chegar, inclusive nas conversas em andamento: a
          pessoa passa a falar com o agente novo. O que já tinha chegado antes da escolha fica com uma pessoa.</p>
        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      </div>

      <Secao titulo="Seus agentes" nota={`${agentes.length} agente${agentes.length === 1 ? '' : 's'}`} />
      {agentes.length === 0 ? (
        <div className="painel">
          <p className="vazio" style={{ margin: 0 }}>Nenhum agente ainda. Sem agente, quem responde a uma campanha
            fica sem resposta até alguém da equipe escrever, em Respostas.</p>
        </div>
      ) : (
        <section className="indice">
          {agentes.map((a) => {
            const onde = porCanal.filter((p) => p.agent_id === a.id).map((p) => p.canal);
            const ondeTxt = onde.length ? `responde no ${nomesDosCanais(onde)}` : 'não é o agente de canal nenhum';
            const so = a.canal ? `só ${NOME_CANAL[a.canal] ?? a.canal} · ` : '';
            return (
              <LinhaIndice key={a.id} icone={a.canal ?? 'agente'} cor={a.canal ? corCanal(a.canal) : undefined}
                           titulo={a.nome}
                           descricao={`${rotulo(a)} · ${so}${ondeTxt} · ${contaDoAgente(a, dados?.contas ?? [], administra)}`}
                           contagem={!a.ativo ? 'desligado' : a.autonomo ? 'responde sozinho' : 'rascunho'}
                           aoClicar={() => nav(`/config/agentes/${a.id}`)} />
            );
          })}
        </section>
      )}
    </Pagina>
  );
}

// ---------------------------------------------------------------------------
// O construtor
// ---------------------------------------------------------------------------

/** O rascunho é estado da tela: trocar de cliente, de agente ou de campanha
 *  sem remontar levaria o texto de um para o outro — e "Salvar" gravaria o
 *  agente de um cliente com o rascunho de outro. A chave remonta. */
export function ConstrutorDeAgente() {
  const { id } = useParams();
  const [busca] = useSearchParams();
  const { tenant } = useSessao();
  return <Construtor key={`${tenant?.tenant_id ?? ''}|${id ?? ''}|${busca.toString()}`} />;
}

function Construtor() {
  const nav = useNavigate();
  const { id } = useParams();
  const [busca] = useSearchParams();
  const novo = id === 'novo';
  // Vindo da campanha: a escolha vira EXCEÇÃO dela, não o agente do canal.
  const campanha = busca.get('campanha');
  const canalDaCampanha = busca.get('canal');
  const { tenant, opera, administra } = useSessao();
  const t = tenant?.tenant_id ?? '';

  const { dados, erro, carregando } = useDados(async () => ({
    agentes: t ? await lerAgentesDoCliente(t) : [],
    porCanal: t ? await lerAgentesPorCanal(t) : [] as AgenteDoCanal[],
    contas: administra ? await lerCredenciaisIA() : [] as CredencialIA[],
    provedores: administra ? await lerProvedoresIA() : [] as ProvedorIA[],
  }), [t, administra]);

  const agente = useMemo(() => (novo ? null : dados?.agentes.find((a) => a.id === id) ?? null), [dados, id, novo]);
  const [r, setR] = useState<Rascunho | null>(null);
  const [canais, setCanais] = useState<Set<CanalDoAgente>>(new Set());
  const [desfazer, setDesfazer] = useState<{ antes: Rascunho; campos: string } | null>(null);
  const [canalDaPrevia, setCanalDaPrevia] = useState<CanalDoAgente>('whatsapp');
  const [salvando, setSalvando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  // O rascunho nasce quando os dados chegam, uma vez: depois disso é da pessoa.
  useEffect(() => {
    if (!dados || r) return;
    const usaveis = dados.contas.filter((c) => c.ativo && dados.provedores.find((p) => p.slug === c.provedor)?.tem_adapter);
    if (novo) {
      const base = rascunhoNovo(tenant?.nome ?? '', busca.get('objetivo'));
      // Uma conta só que compõe: é ela. Mais de uma: a pessoa escolhe.
      setR({ ...base, ai_credential_id: usaveis.length === 1 ? usaveis[0]!.id : '' });
      // Marcado de saída só o canal que está sem agente — marcar o que já tem
      // seria trocar quem responde sem ninguém ter pedido.
      if (!campanha) {
        setCanais(new Set(CANAIS_DO_AGENTE.filter((c) => CANAIS[c].recebeResposta
          && !dados.porCanal.some((p) => p.canal === c))));
      } else if (canalDaCampanha && (CANAIS_DO_AGENTE as readonly string[]).includes(canalDaCampanha)) {
        setCanais(new Set([canalDaCampanha as CanalDoAgente]));
        setCanalDaPrevia(canalDaCampanha as CanalDoAgente);
      }
    } else if (agente) {
      setR(rascunhoDe(agente));
      setCanais(new Set(dados.porCanal.filter((p) => p.agent_id === agente.id).map((p) => p.canal as CanalDoAgente)));
      if (agente.canal) setCanalDaPrevia(agente.canal);
    }
  }, [dados, agente, novo, r, tenant?.nome, busca, campanha, canalDaCampanha]);

  if (carregando && !dados) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  const voltar = () => nav(campanha ? `/campanhas/${campanha}` : '/config/agentes');
  if (!dados) {
    // Erro ao ler: sem isto, a tela ficava em "Carregando…" para sempre.
    return (
      <Pagina titulo="Agente" voltar={{ rotulo: campanha ? 'Campanha' : 'Agentes', aoClicar: voltar }}>
        <Aviso tipo="erro">{erro || 'Não foi possível ler os agentes deste cliente.'}</Aviso>
      </Pagina>
    );
  }
  if (!novo && !agente) {
    return (
      <Pagina titulo="Agente" voltar={{ rotulo: 'Agentes', aoClicar: voltar }}>
        <Aviso tipo="erro">{erro || 'Este agente não existe neste cliente.'}</Aviso>
      </Pagina>
    );
  }
  if (!r || !dados) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const legado = !!agente?.canal;
  // Vindo da campanha, o canal é o da URL e só ele: oferecer os quatro seria
  // gravar exceção em canal que a campanha nem usa (o banco recusa) ou que
  // ninguém pediu.
  const daCampanha = campanha && canalDaCampanha
    && (CANAIS_DO_AGENTE as readonly string[]).includes(canalDaCampanha) ? canalDaCampanha as CanalDoAgente : null;
  const servidos = canaisQueServe({ canal: agente?.canal ?? null }).filter((c) => !campanha || c === daCampanha);
  const falta = oQueFalta(r, { novo });
  const contas = dados.contas;
  const escolhida = contas.find((c) => c.id === r.ai_credential_id);
  const compoe = escolhida ? !!dados.provedores.find((p) => p.slug === escolhida.provedor)?.tem_adapter && escolhida.ativo : false;
  const mudar = (campos: Partial<Rascunho>) => { setR({ ...r, ...campos }); setMsg(null); };

  function aplicarTroca(troca: { rascunho: Rascunho; perdidos: readonly (keyof Rascunho)[] }) {
    const nomes: Partial<Record<keyof Rascunho, string>> = {
      tom: '"Como fala"', instrucoes: '"O que faz"', escalar_quando: '"Passa para uma pessoa quando"',
    };
    setDesfazer(troca.perdidos.length
      ? { antes: r!, campos: troca.perdidos.map((k) => nomes[k] ?? k).join(' e ') } : null);
    setR(troca.rascunho); setMsg(null);
  }

  async function salvar() {
    if (!r || falta.length) return;
    setSalvando(true); setMsg(null);
    try {
      const campos = camposParaGravar(r);
      const escolhidos = [...canais].filter((c) => servidos.includes(c) && CANAIS[c].recebeResposta);
      if (novo) {
        await criarAgente(t, {
          ...campos,
          // Vindo da campanha, o canal vira exceção dela; senão, agente do canal.
          canais: campanha ? [] : escolhidos,
          campanha: campanha ?? null,
          canaisDaCampanha: campanha ? escolhidos : [],
        });
      } else if (agente) {
        await salvarAgente(agente.id, campos);
        // Os canais são uma segunda escrita aqui, e está certo: o agente já
        // existe e responde onde respondia; o que muda é cada canal, um fato
        // por canal. Na criação é que as duas formam um só (D55).
        if (campanha) {
          // Vindo da campanha, marcar é a exceção DELA — nunca o canal inteiro.
          for (const c of escolhidos) await escolherAgenteDaCampanha(t, campanha, c, agente.id);
        } else {
          const antes = new Set(dados!.porCanal.filter((p) => p.agent_id === agente.id).map((p) => p.canal));
          for (const c of servidos) {
            if (canais.has(c) && !antes.has(c) && CANAIS[c].recebeResposta) await escolherAgenteDoCanal(t, c, agente.id);
            if (!canais.has(c) && antes.has(c)) await escolherAgenteDoCanal(t, c, null);
          }
        }
      }
      voltar();
    } catch (e) {
      setMsg({ tipo: 'erro', texto: mensagemDeErro(e) });
      setSalvando(false);
    }
  }

  async function alternarAtivo() {
    if (!agente) return;
    setSalvando(true); setMsg(null);
    try { await salvarAgente(agente.id, { ativo: !agente.ativo }); voltar(); }
    catch (e) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e) }); setSalvando(false); }
  }

  const persona = PERSONAS.find((p) => p.slug === r.persona);
  const objetivo = OBJETIVOS.find((o) => o.slug === r.objetivo);
  const resumoDoTexto = [
    persona ? `Como fala: da persona ${persona.nome}${r.tom === persona.tom ? '' : ' (ajustado)'}` : 'Como fala: escrito à mão',
    objetivo ? `O que faz: do objetivo ${objetivo.nome}${r.instrucoes === objetivo.roteiro ? '' : ' (ajustado)'}` : 'O que faz: escrito à mão',
    `até ${r.limite_trocas} trocas antes de uma pessoa`,
  ].join(' · ');

  let previa: { sistema: string; mensagem: string } | null = null;
  try { previa = montarPedido(entradaDaPrevia(r, canalDaPrevia)); } catch { previa = null; }

  return (
    <Pagina titulo={novo ? 'Criar agente' : r.nome || 'Agente'}
            voltar={{ rotulo: campanha ? 'Campanha' : 'Agentes', aoClicar: voltar }}
            sub={novo
              ? 'Escolha como ele fala e o que ele faz, diga em nome de quem ele fala, e marque os canais. O resto vem pronto — e dá para ajustar o texto inteiro.'
              : `${rotulo(agente!)}${agente!.ativo ? '' : ' · desligado'}`}>
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {legado && (
        <Aviso tipo="neutro">Criado antes do construtor: responde só no {NOME_CANAL[agente!.canal!]}, e o texto dele
          pode trazer regras desse canal. Para responder em outros canais, crie um agente novo.</Aviso>
      )}
      {!opera && <Aviso tipo="neutro">Quem só lê vê o agente, mas não o altera.</Aviso>}

      <div className="painel">
        <Campo id="ag-nome" rotulo="Nome com que ele se apresenta" valor={r.nome} placeholder="Ex.: Ana"
               aoMudar={(v) => mudar({ nome: v })} desabilitado={!opera}
               ajuda="É o nome que ele usa na conversa e na assinatura do e-mail. Ele não diz que é uma pessoa: se perguntarem, diz que é o assistente virtual da equipe." />

        <Secao titulo="Persona" nota="como ele fala" />
        <div className="opts" role="group" aria-label="Persona">
          {PERSONAS.map((p) => (
            <button key={p.slug} type="button" className="opt" aria-pressed={r.persona === p.slug}
                    disabled={!opera} onClick={() => aplicarTroca(trocarPersona(r, p.slug))}>
              <b>{p.nome}</b><p>{p.resumo}</p>
            </button>
          ))}
        </div>

        <Secao titulo="Objetivo" nota="o que ele faz na conversa" />
        <div className="opts" role="group" aria-label="Objetivo">
          {OBJETIVOS.map((o) => (
            <button key={o.slug} type="button" className="opt" aria-pressed={r.objetivo === o.slug}
                    disabled={!opera} onClick={() => aplicarTroca(trocarObjetivo(r, o.slug))}>
              <b>{o.nome}</b><p>{o.resumo}</p>
            </button>
          ))}
        </div>
        <p className="nota-tela">Todo objetivo termina passando a conversa para uma pessoa quando ela chega no "sim":
          o agente não tem agenda nem fecha negócio. A persona e o objetivo são copiados para o agente — mudar o
          catálogo depois não muda este agente.</p>
        {desfazer && (
          <Aviso tipo="neutro">O texto de {desfazer.campos} que você tinha ajustado foi trocado pelo do catálogo.{' '}
            <button className="link" type="button" onClick={() => { setR(desfazer.antes); setDesfazer(null); }}>
              Desfazer</button></Aviso>
        )}

        <div className="campo">
          <label htmlFor="ag-contexto">Sobre a empresa e a oferta</label>
          <textarea id="ag-contexto" rows={4} value={r.contexto} disabled={!opera} maxLength={TETOS_DO_AGENTE.contexto}
                    onChange={(e) => mudar({ contexto: e.target.value })}
                    placeholder="Falamos em nome da [empresa], em [cidade]. Oferecemos [produto] para [público]. O próximo passo de uma conversa boa é [uma ligação de 15 minutos com um especialista]. Atendemos de segunda a sexta, das 9h às 18h." />
          <span className="ajuda">O que só você sabe: nome da empresa, cidade, o que oferece e para quem, e qual é o
            próximo passo de uma conversa boa. O agente não inventa nada fora disto e do que ele faz.
            {r.objetivo && r.contexto.trim().length < CONTEXTO_MINIMO
              && ` Faltam ${CONTEXTO_MINIMO - r.contexto.trim().length} caracteres.`}</span>
        </div>
        <ColetaDaEmpresa contexto={r.contexto} aoUsar={(texto) => mudar({ contexto: texto })}
                         contas={contas} provedores={dados.provedores} contaDoAgente={r.ai_credential_id}
                         administra={administra} opera={opera} empresa={tenant?.nome ?? ''} />

        <details className="recolhe">
          <summary>Ajustar o texto <span>{resumoDoTexto}</span></summary>
          <div className="campo">
            <label htmlFor="ag-tom">Como fala</label>
            <textarea id="ag-tom" rows={4} value={r.tom} disabled={!opera} maxLength={TETOS_DO_AGENTE.tom} onChange={(e) => mudar({ tom: e.target.value })} />
            <span className="ajuda">Só a voz. Tamanho e formato são de cada canal, e a plataforma os acrescenta.</span>
          </div>
          <div className="campo">
            <label htmlFor="ag-instr">O que faz</label>
            <textarea id="ag-instr" rows={9} value={r.instrucoes} disabled={!opera} maxLength={TETOS_DO_AGENTE.instrucoes}
                      onChange={(e) => mudar({ instrucoes: e.target.value })} />
            <span className="ajuda">Pelo menos 120 caracteres. Além disto, a plataforma sempre manda: não inventar
              preço, cobertura nem condição; não pedir CPF nem cartão; não perguntar de saúde; e passar para uma pessoa
              no caso abaixo ou quando alguém pedir para sair.</span>
          </div>
          <Campo id="ag-escalar" rotulo="Passa para uma pessoa quando" valor={r.escalar_quando}
                 aoMudar={(v) => mudar({ escalar_quando: v })} desabilitado={!opera}
                 ajuda="Nesses casos o agente não escreve nada: a resposta aparece marcada em Respostas, e a pessoa fica sem resposta até alguém da equipe escrever." />
          <div className="campo">
            <label htmlFor="ag-proib">Nunca escrever</label>
            <textarea id="ag-proib" rows={3} value={r.proibido} disabled={!opera}
                      onChange={(e) => mudar({ proibido: e.target.value })} placeholder={'garantimos\nsem carência\no menor preço'} />
            <span className="ajuda">Uma expressão por linha. O motor confere o texto composto (sem acento e sem caixa)
              e barra — não manda — o que contiver uma delas.</span>
          </div>
          <Campo id="ag-lim" rotulo="Limite de trocas" valor={r.limite_trocas} aoMudar={(v) => mudar({ limite_trocas: v })}
                 desabilitado={!opera}
                 ajuda="Depois de tantas respostas na mesma conversa, o agente para e diz que é hora de uma pessoa." />
          <Campo id="ag-tam" rotulo="Tamanho máximo" obrigatorio={false} valor={r.tamanho_maximo}
                 aoMudar={(v) => mudar({ tamanho_maximo: v })} desabilitado={!opera}
                 ajuda="Em branco vale o de cada canal: WhatsApp 700, E-mail 2000, SMS 160, Instagram 800. Preenchido, só encurta — nunca passa do canal. Texto maior é barrado, não cortado." />
        </details>

        <div className="campo">
          <label htmlFor="ag-cred">Compõe com</label>
          {administra ? (
            <select id="ag-cred" value={r.ai_credential_id} disabled={!opera}
                    onChange={(e) => mudar({ ai_credential_id: e.target.value })}>
              <option value="">nenhuma conta própria — vale a escolhida em cada campanha</option>
              {contas.map((c) => (
                <option key={c.id} value={c.id}>{c.nome} · {c.provedor} · {c.modelo}{c.ativo ? '' : ' (desligada)'}</option>
              ))}
            </select>
          ) : (
            <span className="ajuda">A conta de IA é escolhida por quem administra, aqui ou na campanha.</span>
          )}
          <span className="ajuda">A conta escolhida na campanha vale sobre esta. Sem nenhuma das duas, o agente
            diz que não tem com que compor, e a resposta fica para uma pessoa.</span>
        </div>
        {escolhida && !compoe && (
          <Aviso tipo="neutro">{escolhida.ativo ? `${escolhida.provedor} ainda não tem adapter de composição`
            : 'Esta conta está desligada'}: com ela o agente não compõe.</Aviso>
        )}

        <label className="caixa-marca">
          <input type="checkbox" checked={r.autonomo} disabled={!opera} onChange={(e) => mudar({ autonomo: e.target.checked })} />
          Responde sozinho
        </label>
        <p className="nota-tela">
          {r.autonomo
            ? <>A resposta que passa pelos freios sai pelo motor, pela mesma conta que conversa com a pessoa, e paga
                quota como qualquer mensagem. Ela <b>não sai</b> se a pessoa pediu para sair, se respondeu de novo
                antes, se passou a janela de 24h do WhatsApp, ou se a conta está fora do ar ou sem quota — aí o texto
                volta para uma pessoa em Respostas, com o motivo. Com o motor em simulado, nada sai.</>
            : <>A resposta fica de rascunho na tela de Respostas, para uma pessoa ler, ajustar e mandar.</>}
        </p>

        <Secao titulo="Onde ele responde" nota={campanha ? 'só nesta campanha' : 'em toda campanha sem agente próprio'} />
        {servidos.map((c) => {
          const info = CANAIS[c];
          const atual = dados.porCanal.find((p) => p.canal === c);
          const outro = atual && atual.agent_id !== agente?.id ? dados.agentes.find((a) => a.id === atual.agent_id) : null;
          // Desligado, ele não entra em canal nenhum (o banco recusa); desmarcar continua valendo.
          const desligadoNovo = !!agente && !agente.ativo && !canais.has(c);
          return (
            <label key={c} className={`caixa-marca${info.recebeResposta && !desligadoNovo ? '' : ' desligada'}`}>
              <input type="checkbox" disabled={!opera || !info.recebeResposta || desligadoNovo}
                     checked={info.recebeResposta && canais.has(c)}
                     onChange={(e) => {
                       const n = new Set(canais);
                       if (e.target.checked) n.add(c); else n.delete(c);
                       setCanais(n);
                     }} />
              <span style={{ color: corCanal(c), fontWeight: 600 }}>{NOME_CANAL[c]}</span>
              <span className="nota-tela" style={{ margin: 0 }}>
                {!info.recebeResposta ? info.porQueNao
                  : desligadoNovo ? 'ligue o agente para pô-lo num canal'
                  : campanha ? 'nesta campanha, no lugar do agente do canal'
                  : outro ? (canais.has(c) ? `substitui ${outro.nome} neste canal` : `hoje: ${outro.nome}`)
                  : atual ? 'é ele hoje' : 'hoje ninguém responde aqui'}
              </span>
            </label>
          );
        })}

        <details className="recolhe">
          <summary>Prévia <span>o que muda em cada canal, e o texto exato que o modelo recebe</span></summary>
          <ul className="lista-canais">
            {servidos.map((c) => {
              const m = oQueMudaNoCanal(c, camposParaGravar(r).tamanho_maximo);
              return (
                <li key={c}>
                  <b style={{ color: corCanal(c) }}>{m.nome}</b> · até {m.limite} caracteres
                  {!m.recebeResposta && ' · ainda não recebe resposta'}
                  <ul>{m.regras.map((x) => <li key={x}>{x}</li>)}</ul>
                </li>
              );
            })}
          </ul>
          <div className="segmento" role="group" aria-label="Canal da prévia">
            {servidos.map((c) => (
              <button key={c} type="button" aria-pressed={canalDaPrevia === c} onClick={() => setCanalDaPrevia(c)}>
                {NOME_CANAL[c]}</button>
            ))}
          </div>
          {previa ? (
            <pre className="previa-prompt">{previa.sistema}{'\n\n— mensagem —\n\n'}{previa.mensagem}</pre>
          ) : <p className="vazio">A prévia aparece quando o texto estiver completo.</p>}
          <p className="nota-tela">É o pedido que o motor monta quando alguém responde — com uma conversa de exemplo
            ({conversaDeExemplo(r.objetivo).map((h) => `"${h.texto}"`).join(' → ')}).</p>
        </details>

        {servidos.length > 0 && <Testar r={r} canais={servidos} conta={escolhida ?? null} administra={administra} />}

        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
        {falta.length > 0 && opera && <p className="nota-tela">Para salvar, falta: {falta.join('; ')}.</p>}
        {opera && (
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <button className="btn prim" type="button" disabled={salvando || falta.length > 0} onClick={() => void salvar()}>
              {novo ? 'Criar agente' : 'Salvar'}</button>
            <button className="btn" type="button" disabled={salvando} onClick={voltar}>Cancelar</button>
            {!novo && (
              <button className="btn" type="button" disabled={salvando} onClick={() => void alternarAtivo()}
                      title={agente!.ativo ? 'Desligado, ele para de responder em todo lugar — a conversa não passa a outro agente.' : ''}>
                {agente!.ativo ? 'Desligar agente' : 'Ligar agente'}</button>
            )}
          </div>
        )}
        {!novo && agente!.ativo && opera && (
          <p className="nota-tela">Desligar para de responder em todo lugar onde ele responde — e a conversa não
            passa a outro agente: fica com uma pessoa.</p>
        )}
      </div>
    </Pagina>
  );
}

// ---------------------------------------------------------------------------
// Testar antes de ligar
// ---------------------------------------------------------------------------

/** Em simulado ninguém responde, e a primeira vez que alguém leria o agente
 *  seria com um contato de verdade (D42 no agente). Aqui ele escreve com o
 *  texto da tela — salvo ou não —, passa pelos mesmos freios, e nada é
 *  gravado nem enviado. Gasta a conta de IA do cliente, por clique. */
function Testar({ r, canais, conta, administra }: {
  r: Rascunho; canais: CanalDoAgente[]; conta: CredencialIA | null; administra: boolean;
}) {
  const [canal, setCanal] = useState<CanalDoAgente>(canais.find((c) => CANAIS[c].recebeResposta) ?? canais[0]!);
  const [texto, setTexto] = useState('Tenho interesse, como funciona?');
  const [rodando, setRodando] = useState(false);
  const [res, setRes] = useState<ResultadoDoTeste | null>(null);
  const [erro, setErro] = useState('');

  async function testar() {
    if (!conta || rodando) return;
    setRodando(true); setErro(''); setRes(null);
    try { setRes(await testarAgente({ credencial_id: conta.id, canal, texto, agente: entradaDaPrevia(r, canal) })); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setRodando(false); }
  }

  return (
    <details className="recolhe">
      <summary>Testar <span>ele escreve uma resposta de verdade, e nada sai</span></summary>
      {!administra ? (
        <p className="nota-tela">Testar usa a conta de IA, que só quem administra escolhe.</p>
      ) : !conta ? (
        <p className="nota-tela">Escolha em "Compõe com" a conta de IA para testar.</p>
      ) : (
        <>
          <div className="segmento" role="group" aria-label="Canal do teste">
            {canais.map((c) => (
              <button key={c} type="button" aria-pressed={canal === c} onClick={() => setCanal(c)}>{NOME_CANAL[c]}</button>
            ))}
          </div>
          <div className="campo" style={{ marginTop: 12 }}>
            <label htmlFor="ag-teste">O que a pessoa escreveu</label>
            <textarea id="ag-teste" rows={2} value={texto} onChange={(e) => setTexto(e.target.value)} />
            <span className="ajuda">Experimente também "quanto custa?", "quem passou meu número?" e
              "{PEDIDO_DE_SAIDA_DO_TESTE}" — este último a blacklist padrão não pega, e é o agente quem precisa passar a
              conversa para uma pessoa. Se o teste disser que não chegaria ao agente, é a blacklist deste cliente que
              pega a frase.</span>
          </div>
          <button className="btn" type="button" disabled={rodando || !texto.trim()} onClick={() => void testar()}>
            {rodando ? 'Escrevendo…' : `Testar com ${conta.nome}`}</button>
          <p className="nota-tela">Gasta a conta de IA deste cliente. Nada é gravado nem enviado.</p>
          {erro && <Aviso tipo="erro">{erro}</Aviso>}
          {res && (res.situacao === 'pronto'
            ? <div className="balao-teste"><b>{r.nome || 'O agente'} escreveria:</b><p>{res.texto}</p>
                <span className="nota-tela">{res.texto?.length} caracteres · passou pelos freios</span></div>
            : <Aviso tipo={res.situacao === 'erro' ? 'erro' : 'neutro'}>
                {res.situacao === 'escalar' ? 'Passaria para uma pessoa: '
                  : res.situacao === 'bloqueado' ? 'Um freio barraria: '
                  : res.situacao === 'blacklist' || res.situacao === 'recusa' ? 'Não chegaria ao agente: ' : 'Não deu: '}
                {res.motivo}</Aviso>)}
        </>
      )}
    </details>
  );
}

// ---------------------------------------------------------------------------
// Na tela de cada canal
// ---------------------------------------------------------------------------

/** "Quem responde aqui", na tela do canal: a MESMA escolha do panorama de
 *  Agentes, escrita na mesma tabela — escolher o agente onde se configura o
 *  canal é o caminho que a pessoa procura primeiro. */
export function QuemRespondeNoCanal({ canal }: { canal: CanalDoAgente }) {
  const nav = useNavigate();
  const { tenant, opera } = useSessao();
  const t = tenant?.tenant_id ?? '';
  const { dados, erro, recarregar } = useDados(async () => ({
    agentes: t ? await lerAgentesDoCliente(t) : [],
    porCanal: t ? await lerAgentesPorCanal(t) : [] as AgenteDoCanal[],
  }), [t]);
  const [salvando, setSalvando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);
  const info = CANAIS[canal];
  const atual = dados?.porCanal.find((p) => p.canal === canal);
  const escolhido = dados?.agentes.find((a) => a.id === atual?.agent_id);
  // O limite é o do agente quando ele encurta o do canal: a tela não promete
  // 700 de quem foi configurado para 300.
  const formato = oQueMudaNoCanal(canal, escolhido?.tamanho_maximo ?? null);
  const candidatos = (dados?.agentes ?? []).filter((a) => a.ativo && canaisQueServe(a).includes(canal));

  async function escolher(agente: string | null) {
    setSalvando(true); setMsg(null);
    try {
      await escolherAgenteDoCanal(t, canal, agente);
      const nome = dados?.agentes.find((a) => a.id === agente)?.nome;
      setMsg({ tipo: 'ok', texto: nome ? `${nome} responde aqui a partir de agora.` : 'Ninguém responde aqui a partir de agora.' });
      await recarregar();
    } catch (e) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e) }); }
    finally { setSalvando(false); }
  }

  return (
    <>
      <Secao titulo="Quem responde aqui" nota="o agente deste canal, em toda campanha sem agente próprio" />
      <div className="painel">
        {erro && <Aviso tipo="erro">{erro}</Aviso>}
        {!info.recebeResposta ? (
          <p className="nota-tela" style={{ marginTop: 0 }}>Nenhum agente responde por aqui: {info.porQueNao}.</p>
        ) : (
          <div className="campo">
            <label htmlFor={`qr-${canal}`}>Agente do {info.nome}</label>
            {opera ? (
              <select id={`qr-${canal}`} value={atual?.agent_id ?? ''} disabled={salvando || !dados}
                      onChange={(e) => void escolher(e.target.value || null)}>
                <option value="">ninguém — a resposta fica para alguém da equipe, em Respostas</option>
                {candidatos.map((a) => <option key={a.id} value={a.id}>{a.nome} · {rotulo(a)}</option>)}
                {escolhido && !escolhido.ativo && <option value={escolhido.id}>{escolhido.nome} · desligado: não responde</option>}
              </select>
            ) : (
              <span>{escolhido ? `${escolhido.nome} · ${rotulo(escolhido)}` : 'ninguém'}</span>
            )}
            <span className="ajuda">
              {escolhido && !escolhido.ativo
                ? `${escolhido.nome} está desligado: ninguém responde aqui.`
                : `Aqui ele escreve no formato do ${formato.nome}, com até ${formato.limite} caracteres. ${formato.regras[0]!} `
                  + 'Vale para a próxima resposta que chegar; a campanha que quiser outro escolhe na tela dela.'}
            </span>
          </div>
        )}
        {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
        {opera && (
          <button className="link" type="button" onClick={() => nav(candidatos.length ? '/config/agentes' : '/config/agentes/novo')}>
            {candidatos.length ? 'Criar ou ajustar agentes em Configurações ▸ Agentes' : 'Criar o primeiro agente'}</button>
        )}
      </div>
    </>
  );
}

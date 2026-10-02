/** O que o motor fez nesta campanha (D36).
 *
 * Depois de inscrever, o app não mostrava nada — e é justamente aí que a
 * pessoa mais precisa ver. Shadow mode roda o caminho inteiro e não envia:
 * sem uma tela dizendo "14 mensagens, todas simuladas", o modo que de-risca o
 * projeto é indistinguível de estar quebrado.
 *
 * Os números vêm contados do banco (`resumo_da_campanha`), não somados aqui:
 * milhares de enrollments não passam pelo PostgREST linha a linha.
 */
import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { Aviso, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import {
  alternarCampanha, atribuirAgente, definirEmailDaCampanha, definirFlowDaCampanha, definirIADaCampanha,
  lerAgentes, lerCredenciaisIA, lerProvedoresIA,
  lerContasDeEmail,
  lerAgentesDaCampanha, lerCampanhas, lerEventosDaCampanha, lerMensagensDaCampanha,
  lerRespostas, lerResumoDaCampanha, lerVersoesDeFlow, pausarInscricoes,
} from '../dados';
import type {
  Agente, AgenteDaCampanha, Campanha as Camp, ContaDeEmail, CredencialIA, EventoDaCampanha,
  MensagemComposta, ProvedorIA,
  RespostaRecebida, ResumoDaCampanha, VersaoDeFlow,
} from '../dados';
import { ListaDeRespostas } from './Respostas';
import { mensagemDeErro } from '../supabase';

// Frases nominais, não verbos: "1 por resposta" funciona com qualquer
// número, e "1 responderam" não.
const MOTIVO: Record<string, string> = {
  resposta: 'por resposta',
  fim_dos_passos: 'por fim dos passos',
  supressao: 'por supressão',
  mudanca_etapa_crm: 'por mudança de etapa no CRM',
  falha_permanente: 'por falha permanente',
};

/** Contagem de mensagens: concorda com "mensagens". */
const STATUS_PLURAL: Record<string, string> = {
  simulado: 'em shadow mode', pendente: 'na fila', enviado: 'enviadas', falha: 'com falha',
  // Cancelada é mensagem que não saiu porque o estado mudou enquanto ela
  // esperava: opt-out (D39), ou cadência encerrada por resposta (D40). Fica
  // longe de "com falha" de propósito — não é defeito do motor.
  cancelado: 'canceladas antes de sair',
};

/** Etiqueta de uma mensagem só, no evento. */
const STATUS: Record<string, string> = {
  simulado: 'shadow mode', pendente: 'na fila', enviado: 'enviado', falha: 'falha',
  cancelado: 'cancelada antes de sair',
};

export function Campanha() {
  const { id = '' } = useParams();
  const { tenant, opera } = useSessao();
  const [campanha, setCampanha] = useState<Camp | null>(null);
  const [resumo, setResumo] = useState<ResumoDaCampanha | null>(null);
  const [eventos, setEventos] = useState<EventoDaCampanha[]>([]);
  const [mensagens, setMensagens] = useState<MensagemComposta[]>([]);
  const [versoes, setVersoes] = useState<VersaoDeFlow[]>([]);
  const [agentes, setAgentes] = useState<Agente[]>([]);
  const [daCampanha, setDaCampanha] = useState<AgenteDaCampanha[]>([]);
  const [respostas, setRespostas] = useState<RespostaRecebida[]>([]);
  const [emails, setEmails] = useState<ContaDeEmail[]>([]);
  const [contasIA, setContasIA] = useState<CredencialIA[]>([]);
  const [provedoresIA, setProvedoresIA] = useState<ProvedorIA[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);

  async function recarregar() {
    if (!tenant || !id) return;
    setErro('');
    try {
      const [cs, r, ev, ms, vs, ags, ca, rs, em, cia, pia] = await Promise.all([
        lerCampanhas(),
        lerResumoDaCampanha(tenant.tenant_id, id),
        lerEventosDaCampanha(tenant.tenant_id, id),
        lerMensagensDaCampanha(tenant.tenant_id, id),
        lerVersoesDeFlow(),
        lerAgentes(),
        lerAgentesDaCampanha(id),
        lerRespostas(tenant.tenant_id, id),
        lerContasDeEmail(tenant.tenant_id),
        lerCredenciaisIA(),
        lerProvedoresIA(),
      ]);
      setCampanha(cs.find((c) => c.id === id) ?? null);
      setResumo(r);
      setEventos(ev);
      setMensagens(ms);
      setVersoes(vs);
      setAgentes(ags);
      setDaCampanha(ca);
      setRespostas(rs);
      setEmails(em);
      setContasIA(cia);
      setProvedoresIA(pia);
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id, id]);

  if (carregando) return <p className="vazio">Carregando…</p>;
  if (erro) return <Aviso tipo="erro">{erro}</Aviso>;
  if (!campanha || !resumo) return <Aviso tipo="erro">Campanha não encontrada.</Aviso>;

  const simuladas = resumo.por_status.simulado ?? 0;
  const canceladas = resumo.por_status.cancelado ?? 0;
  const soShadow = resumo.mensagens > 0 && simuladas === resumo.mensagens;

  return (
    <>
      <Secao
        titulo={campanha.nome}
        nota={`${campanha.tipo} · ${campanha.canais_habilitados.map((c) => NOME_CANAL[c] ?? c).join(', ')}`
              + (campanha.ativa ? '' : ' · DESLIGADA')}
      />

      <Comando campanha={campanha} resumo={resumo} podeOperar={opera}
               aoMudar={recarregar} aoFalhar={setErro} />

      <Cadencia campanha={campanha} versoes={versoes} podeOperar={opera}
                aoMudar={recarregar} aoFalhar={setErro} />

      {campanha.canais_habilitados.includes('email') && (
        <EmailDaCampanha campanha={campanha} contas={emails} podeOperar={opera}
                         aoMudar={recarregar} aoFalhar={setErro} />
      )}

      <Agentes campanha={campanha} agentes={agentes} atribuidos={daCampanha}
               contasIA={contasIA} provedoresIA={provedoresIA}
               podeOperar={opera} aoMudar={recarregar} aoFalhar={setErro} />

      <div className="kpis cinco">
        <Kpi rotulo="Em cadência" valor={resumo.inscritos_ativos}
             sub={resumo.inscritos_pausados ? `${resumo.inscritos_pausados} pausado(s)` : 'ativos agora'} />
        <Kpi rotulo="Encerrados" valor={resumo.encerrados} sub={motivoResumido(resumo.por_motivo)} />
        <Kpi rotulo="Mensagens" valor={resumo.mensagens} sub={statusResumido(resumo.por_status)} />
        {/* Resposta e clique em KPIs separados porque são coisas diferentes:
            resposta encerra a cadência inteira, clique não (D7). */}
        <Kpi rotulo="Respostas" valor={resumo.respostas} sub="encerram a cadência" />
        <Kpi rotulo="Cliques" valor={resumo.cliques} sub="engajamento, não resposta" />
      </div>

      {canceladas > 0 && (
        <Aviso tipo="neutro">
          <b>{canceladas}</b> {canceladas === 1 ? 'mensagem não saiu' : 'mensagens não saíram'}{' '}
          porque o estado mudou enquanto ela esperava na fila: o contato entrou na supressão
          (D39), ou a cadência foi encerrada por resposta antes de o envio acontecer (D40).
          Nos dois casos a decisão foi respeitada — não é falha do motor nem da conta que ia
          enviar, e por isso não conta como tal.
        </Aviso>
      )}

      {soShadow && (
        <Aviso tipo="neutro">
          <b>Shadow mode.</b> As {resumo.mensagens} mensagens foram calculadas,
          roteadas e reservaram remetente — e <b>nenhuma saiu</b>. É o caminho
          completo rodando sem enviar. Para valer, o worker precisa rodar em
          modo <code className="mono">real</code>.
        </Aviso>
      )}

      <div className="painel">
        <b>Próxima batida</b>
        <p style={{ color: 'var(--ink-2)', fontSize: 13, marginBottom: 0 }}>
          {resumo.vencidos_agora > 0
            ? `${resumo.vencidos_agora} enrollment(s) já vencido(s) — o worker pega na próxima passada.`
            : resumo.proximo_disparo
              ? `Nada vencido agora. O próximo é ${quando(resumo.proximo_disparo)}.`
              : 'Ninguém em cadência: ou todos encerraram, ou ninguém foi inscrito ainda.'}
        </p>
      </div>

      {respostas.length > 0 && (
        <>
          <Secao titulo="O que responderam"
                 nota={`${respostas.length} ${respostas.length === 1 ? 'resposta' : 'respostas'} nesta campanha`} />
          {/* Sem a coluna de campanha: aqui já se sabe qual é. */}
          <ListaDeRespostas lista={respostas} semCampanha />
        </>
      )}

      <Mensagens lista={mensagens} />

      <Secao titulo="Linha do tempo"
             nota={eventos.length ? `${eventos.length} evento(s), mais recente primeiro` : 'nada ainda'} />

      {eventos.length === 0 ? (
        <div className="painel">
          <p className="vazio" style={{ margin: 0 }}>
            Nenhum evento. Se há gente em cadência e nada aconteceu, o motor
            provavelmente não está agendado.
          </p>
        </div>
      ) : (
        <div className="painel">
          <table className="tab">
            <thead>
              <tr><th>Quando</th><th>Quem</th><th>Canal</th><th>O quê</th>
                  <th>Destino</th><th>Remetente</th></tr>
            </thead>
            <tbody>
              {eventos.map((e, i) => (
                <tr key={i}>
                  <td>{quando(e.ocorrido_em)}</td>
                  <td style={{ color: 'var(--ink)' }}>{e.contato}</td>
                  <td style={{ color: corCanal(e.canal) }}>{NOME_CANAL[e.canal] ?? e.canal}</td>
                  <td>
                    {e.tipo}
                    {/* O status fica junto do evento porque é ele que diz se
                        algo saiu de casa — em shadow mode o remetente é
                        escolhido e reservado igual, só não envia. */}
                    {e.status !== 'enviado' && (
                      <span className="chip" style={{ marginLeft: 6 }}>{STATUS[e.status] ?? e.status}</span>
                    )}
                  </td>
                  <td className="mono">{e.destino}</td>
                  <td>{e.remetente}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <button className="btn" onClick={() => void recarregar()}>Atualizar</button>
    </>
  );
}

/**
 * O freio (D54).
 *
 * O motor sempre soube parar: `processar_vencidos` pula campanha com
 * `ativa = false` e enrollment `pausado`. O que faltava era alguém puxar —
 * até aqui, começar uma cadência dava-se pelo produto e pará-la exigia o
 * painel do Supabase.
 *
 * São dois freios de alcance diferente, e a tela diz qual é qual, porque
 * confundi-los é o tipo de engano que só aparece depois:
 *
 *   * desligar a CAMPANHA para tudo o que ela ainda faria, e é reversível —
 *     religar continua de onde parou;
 *   * pausar as INSCRIÇÕES segura pessoa por pessoa, e o relógio de cada uma
 *     fica onde estava. Retomar volta para um horário já vencido, então a
 *     próxima batida anda.
 *
 * Nenhum dos dois cancela mensagem que já está na fila: quem decide isso é o
 * despacho, que não envia por campanha desligada nem por enrollment pausado,
 * e segura a mensagem em vez de cancelá-la, porque parada que volta atrás não
 * pode queimar a chave `(enrollment_id, step_id)` (D40).
 */
function Comando({ campanha, resumo, podeOperar, aoMudar, aoFalhar }: {
  campanha: Camp; resumo: ResumoDaCampanha; podeOperar: boolean;
  aoMudar(): Promise<void>; aoFalhar(m: string): void;
}) {
  const [ocupado, setOcupado] = useState('');
  const [nota, setNota] = useState('');

  async function fazer(rotulo: string, acao: () => Promise<string>) {
    setOcupado(rotulo); setNota(''); aoFalhar('');
    try { setNota(await acao()); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setOcupado(''); }
  }

  return (
    <div className="painel">
      <b>{campanha.ativa ? 'Campanha ligada' : 'Campanha desligada'}</b>
      <p style={{ color: 'var(--ink-2)', fontSize: 13 }}>
        {campanha.ativa
          ? 'O agendador considera esta campanha a cada batida.'
          : 'O agendador ignora esta campanha. Nada novo é criado, e a mensagem '
            + 'que já estava na fila fica segura — não é cancelada, porque religar '
            + 'precisa poder recriá-la.'}
      </p>

      {!podeOperar ? (
        <p className="vazio" style={{ margin: 0 }}>
          Seu papel é de leitura: ligar, desligar e pausar são de operador.
        </p>
      ) : (
        <div style={{ display: 'flex', gap: 9, flexWrap: 'wrap' }}>
          <button className="btn prim" disabled={!!ocupado}
                  onClick={() => void fazer('campanha', async () => {
                    await alternarCampanha(campanha.id, !campanha.ativa);
                    return campanha.ativa ? 'Campanha desligada.' : 'Campanha ligada.';
                  })}>
            {ocupado === 'campanha' ? 'um instante…'
              : campanha.ativa ? 'Desligar a campanha' : 'Ligar a campanha'}
          </button>

          <button className="btn" disabled={!!ocupado || resumo.inscritos_ativos === 0}
                  onClick={() => void fazer('pausar', async () => {
                    const n = await pausarInscricoes(campanha.id, true);
                    return `${n} ${n === 1 ? 'inscrição pausada' : 'inscrições pausadas'}.`;
                  })}>
            {ocupado === 'pausar' ? 'um instante…'
              : `Pausar as ${resumo.inscritos_ativos} em cadência`}
          </button>

          <button className="btn" disabled={!!ocupado || resumo.inscritos_pausados === 0}
                  onClick={() => void fazer('retomar', async () => {
                    const n = await pausarInscricoes(campanha.id, false);
                    return `${n} ${n === 1 ? 'inscrição retomada' : 'inscrições retomadas'}.`;
                  })}>
            {ocupado === 'retomar' ? 'um instante…'
              : `Retomar as ${resumo.inscritos_pausados} pausadas`}
          </button>
        </div>
      )}

      {nota && <Aviso tipo="ok">{nota}</Aviso>}
    </div>
  );
}

/**
 * Qual cadência esta campanha roda (D47).
 *
 * A pergunta é da campanha, e não de cada inscrição: perguntá-la N vezes é dar
 * N chances de responder diferente, e a resposta errada não dá erro — dá
 * campanha "concluída" sem mensagem nenhuma (D35).
 *
 * Repontar não move quem já está inscrito. Cada enrollment carrega o seu
 * `flow_version_id` desde a primeira migration, e é ele que o agendador lê:
 * quem está em curso termina na versão em que entrou (D9).
 */
function Cadencia({ campanha, versoes, podeOperar, aoMudar, aoFalhar }: {
  campanha: Camp; versoes: VersaoDeFlow[]; podeOperar: boolean;
  aoMudar(): Promise<void>; aoFalhar(m: string): void;
}) {
  const [escolha, setEscolha] = useState('');
  const [salvando, setSalvando] = useState(false);

  const atual = versoes.find((v) => v.id === campanha.flow_version_id) ?? null;
  const alvo = versoes.find((v) => v.id === escolha) ?? null;

  // O cruzamento, calculado antes de qualquer chamada. Vazio é recusado pela
  // função; parcial é legítimo e só precisa ser dito.
  const cruzam = alvo
    ? alvo.canais.filter((c) => campanha.canais_habilitados.includes(c))
    : null;

  async function ligar() {
    setSalvando(true); aoFalhar('');
    try { await definirFlowDaCampanha(campanha.id, escolha); setEscolha(''); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setSalvando(false); }
  }

  return (
    <>
      <Secao titulo="Cadência" nota={atual ? `${atual.passos} passos` : 'ainda não ligada'} />
      <div className="painel">
        {atual ? (
          <p style={{ color: 'var(--ink-2)', fontSize: 13, marginTop: 0 }}>
            <b style={{ color: 'var(--ink)' }}>{atual.flow_nome}</b> · v{atual.versao} ·{' '}
            {atual.passos} {atual.passos === 1 ? 'passo' : 'passos'} em{' '}
            {atual.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')}
          </p>
        ) : (
          <Aviso tipo="erro">
            Esta campanha não aponta cadência nenhuma. Inscrever alguém agora
            criaria uma inscrição sem passo para percorrer — e isso não dá
            erro: dá uma campanha &ldquo;concluída&rdquo; sem que ninguém tenha
            recebido nada.
          </Aviso>
        )}

        {podeOperar && (
          <>
            <div className="campo">
              <label htmlFor="cad-v">{atual ? 'Trocar por' : 'Escolher a cadência'}</label>
              <select id="cad-v" value={escolha} onChange={(e) => setEscolha(e.target.value)}>
                <option value="">escolha…</option>
                {versoes.filter((v) => v.id !== campanha.flow_version_id).map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.flow_nome} · v{v.versao} · {v.passos} passos ·{' '}
                    {v.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')}
                  </option>
                ))}
              </select>
              <span className="ajuda">
                Trocar aqui não move quem já está inscrito: cada inscrição
                termina na versão em que entrou.
              </span>
            </div>

            {cruzam?.length === 0 && (
              <Aviso tipo="erro">
                Nenhum canal em comum: a cadência usa{' '}
                {alvo?.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')} e a campanha
                habilita {campanha.canais_habilitados.map((c) => NOME_CANAL[c] ?? c).join(', ')}.
                Todo passo seria pulado. A ligação é recusada.
              </Aviso>
            )}

            {alvo && cruzam && cruzam.length > 0 && cruzam.length < alvo.canais.length && (
              <Aviso tipo="neutro">
                Cruzamento parcial, e isso é permitido: os passos em{' '}
                {alvo.canais.filter((c) => !cruzam.includes(c))
                  .map((c) => NOME_CANAL[c] ?? c).join(', ')}{' '}
                são pulados porque a campanha não habilita esses canais.
              </Aviso>
            )}

            <button className="btn prim"
                    disabled={!escolha || salvando || cruzam?.length === 0}
                    onClick={() => void ligar()}>
              {salvando ? 'ligando…' : atual ? 'Trocar a cadência' : 'Ligar a cadência'}
            </button>
          </>
        )}
      </div>
    </>
  );
}

/**
 * Qual provedor de e-mail esta campanha usa (D62).
 *
 * O cliente cadastra vários em Configurações ▸ E-mail; a campanha escolhe um.
 * Sem escolha, o rodízio entre as contas de e-mail do pool é o de antes. Com
 * escolha, a conta escolhida fora do pool SEGURA o e-mail desta campanha em
 * vez de mandar por outra: mandar pelo provedor que ninguém escolheu seria a
 * escolha valendo só enquanto nada dá errado.
 *
 * A lista só oferece conta do mesmo pool da campanha, mas quem decide é o
 * gatilho do banco (D4) — esta tela só evita oferecer o que ele recusaria.
 */
function EmailDaCampanha({ campanha, contas, podeOperar, aoMudar, aoFalhar }: {
  campanha: Camp; contas: ContaDeEmail[]; podeOperar: boolean;
  aoMudar(): Promise<void>; aoFalhar(m: string): void;
}) {
  const [salvando, setSalvando] = useState(false);
  const atual = contas.find((c) => c.id === campanha.remetente_email_id) ?? null;
  const doPool = contas.filter((c) => c.tipo_permitido === campanha.tipo);
  const outroPool = contas.length - doPool.length;

  async function escolher(valor: string) {
    setSalvando(true); aoFalhar('');
    try { await definirEmailDaCampanha(campanha.id, valor || null); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setSalvando(false); }
  }

  const nome = (c: ContaDeEmail) => `${c.apelido || c.identificador} · ${c.provedor_nome}`;

  return (
    <>
      <Secao titulo="Provedor de e-mail" nota={atual ? 'escolhido para esta campanha' : 'rodízio do pool'} />
      <div className="painel">
        {atual ? (
          <p style={{ color: 'var(--ink-2)', fontSize: 13, marginTop: 0 }}>
            <b style={{ color: 'var(--ink)' }}>{nome(atual)}</b>
            {' · '}<span className="mono">{atual.identificador}</span>
            {atual.estado !== 'ativo' && (
              <b style={{ color: 'var(--warn)' }}>
                {' '}· fora do pool agora: o e-mail desta campanha espera até ela voltar
              </b>
            )}
            {atual.verificacao_ok === false && (
              <b style={{ color: 'var(--crit)' }}> · última verificação falhou</b>
            )}
          </p>
        ) : (
          <p style={{ color: 'var(--ink-2)', fontSize: 13, marginTop: 0 }}>
            Nenhuma conta escolhida: o e-mail sai pela conta de e-mail do pool {campanha.tipo} com
            mais saúde e menos envios no dia.
          </p>
        )}

        {podeOperar && (
          <div className="campo" style={{ marginBottom: 0 }}>
            <label htmlFor="cmp-email">Enviar e-mail por</label>
            <select id="cmp-email" disabled={salvando}
                    value={campanha.remetente_email_id ?? ''}
                    onChange={(e) => void escolher(e.target.value)}>
              <option value="">rodízio entre as contas do pool</option>
              {doPool.map((c) => <option key={c.id} value={c.id}>{nome(c)}</option>)}
            </select>
            <span className="ajuda">
              {doPool.length
                ? 'Adicionar, verificar e remover conta é em Configurações ▸ E-mail.'
                : `Nenhuma conta de e-mail no pool ${campanha.tipo}. Cadastre em Configurações ▸ E-mail.`}
              {outroPool > 0 && ` ${outroPool} conta(s) de outro pool não aparecem: campanha fria não usa remetente de base própria, nem o contrário.`}
            </span>
          </div>
        )}
      </div>
    </>
  );
}

/**
 * Quem responde por cada canal desta campanha — **quando houver quem responda**.
 *
 * `atribuir_agente` deriva o canal do próprio agente (um argumento a menos
 * para errar), copia o agente do catálogo para o cliente na primeira vez que
 * ele é usado — assim editar o seu não mexe no catálogo — e a chave
 * `(campaign_id, canal)` garante um agente por canal.
 *
 * Desde o D66 o motor LÊ `campaign_agents`: quando o contato responde, o agente
 * do canal compõe um rascunho, que aparece na tela de Respostas. E é só isso:
 * nada sai sozinho. Resposta encerra a cadência (invariante 4), e quem continua
 * a conversa é uma pessoa, com o rascunho na mão.
 *
 * A tela diz isso em voz alta de propósito. Oferecer a escolha e deixar a
 * pessoa supor que ela produz efeito é a decoração do D31 com cara de
 * funcionalidade — e o jeito de descobrir seria um lead sem resposta.
 */
function Agentes({ campanha, agentes, atribuidos, contasIA, provedoresIA, podeOperar, aoMudar, aoFalhar }: {
  campanha: Camp; agentes: Agente[]; atribuidos: AgenteDaCampanha[];
  contasIA: CredencialIA[]; provedoresIA: ProvedorIA[]; podeOperar: boolean;
  aoMudar(): Promise<void>; aoFalhar(m: string): void;
}) {
  const nav = useNavigate();
  const [salvando, setSalvando] = useState('');

  // Só o que compõe: conta ligada de provedor com adapter (D66). Uma conta do
  // Gemini na lista seria uma escolha que não produz rascunho nenhum.
  const compoe = (c: CredencialIA) => c.ativo && !!provedoresIA.find((p) => p.slug === c.provedor)?.tem_adapter;
  const usaveis = contasIA.filter(compoe);
  const porProvedor = provedoresIA
    .map((p) => ({ p, contas: usaveis.filter((c) => c.provedor === p.slug) }))
    .filter((x) => x.contas.length);
  const escolhida = contasIA.find((c) => c.id === campanha.ai_credential_id) ?? null;

  async function escolherIA(id: string) {
    setSalvando('ia'); aoFalhar('');
    try { await definirIADaCampanha(campanha.id, id || null); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setSalvando(''); }
  }

  async function atribuir(agente: string) {
    setSalvando(agente); aoFalhar('');
    try { await atribuirAgente(campanha.id, agente); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setSalvando(''); }
  }

  const semAgente = campanha.canais_habilitados.filter(
    (c) => !atribuidos.some((a) => a.canal === c));

  return (
    <>
      <Secao titulo="Quem responde"
             nota={`${atribuidos.length} de ${campanha.canais_habilitados.length} canais com agente`} />
      <div className="painel">
        {/* A conta de IA é escolhida aqui, entre as que já estão conectadas.
            Chave nenhuma passa por esta tela: ela mora em Configurações ▸
            Provedores de IA, e a campanha só aponta para uma conta (D68). */}
        <div className="campo">
          <label htmlFor="ia-campanha">Conta de IA desta campanha</label>
          {usaveis.length === 0 ? (
            <p style={{ color: 'var(--ink-2)', fontSize: 13, margin: '2px 0 0' }}>
              Nenhuma conta de IA conectada ainda.{' '}
              <button className="link" onClick={() => nav('/config/ia')}>Conectar em Configurações ▸ Provedores de IA</button>
            </p>
          ) : podeOperar ? (
            <select id="ia-campanha" value={campanha.ai_credential_id ?? ''} disabled={!!salvando}
                    onChange={(e) => void escolherIA(e.target.value)}>
              <option value="">a conta de cada agente</option>
              {porProvedor.map(({ p, contas }) => (
                <optgroup key={p.slug} label={p.nome}>
                  {contas.map((c) => <option key={c.id} value={c.id}>{c.nome} · {c.modelo}</option>)}
                </optgroup>
              ))}
              {/* A escolhida que deixou de compor continua visível, marcada —
                  sumir com ela da lista esconderia por que não há rascunho. */}
              {escolhida && !compoe(escolhida) && (
                <option value={escolhida.id}>{escolhida.nome} · não compõe (desligada ou sem adapter)</option>
              )}
            </select>
          ) : (
            <p style={{ color: 'var(--ink-2)', fontSize: 13, margin: '2px 0 0' }}>
              {escolhida ? `${escolhida.nome} · ${escolhida.modelo}` : 'a conta de cada agente'}
            </p>
          )}
          <span className="ajuda">
            Vale para todos os agentes desta campanha. Em branco, cada agente usa a conta que tiver no
            cadastro dele.
          </span>
        </div>

        {campanha.canais_habilitados.map((canal) => {
          const atual = atribuidos.find((a) => a.canal === canal);
          // Só agentes DO canal: o agente carrega o seu, e a função o deriva.
          const candidatos = agentes.filter((a) => a.canal === canal);
          return (
            <div className="campo" key={canal}>
              <label htmlFor={`ag-${canal}`} style={{ color: corCanal(canal) }}>
                {NOME_CANAL[canal] ?? canal}
              </label>
              {candidatos.length === 0 ? (
                <p style={{ color: 'var(--ink-2)', fontSize: 13, margin: '2px 0 0' }}>
                  Nenhum agente cadastrado para este canal.
                </p>
              ) : podeOperar ? (
                <select id={`ag-${canal}`} value={atual?.agent_id ?? ''}
                        disabled={!!salvando}
                        onChange={(e) => { if (e.target.value) void atribuir(e.target.value); }}>
                  <option value="">ninguém ainda</option>
                  {candidatos.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.nome} · {a.papel}{a.pronto ? '' : ' · incompleto'}
                    </option>
                  ))}
                </select>
              ) : (
                <p style={{ color: 'var(--ink-2)', fontSize: 13, margin: '2px 0 0' }}>
                  {agentes.find((a) => a.id === atual?.agent_id)?.nome ?? 'ninguém ainda'}
                </p>
              )}
            </div>
          );
        })}

        <Aviso tipo="neutro">
          <b>O agente escreve o rascunho; quem manda é uma pessoa.</b> Quando o contato
          responde, a cadência encerra (é a invariante 4) e o agente deste canal deixa um
          rascunho na tela de Respostas, para ser lido, ajustado e mandado pelo aplicativo do
          canal. Nada sai sozinho. Sem conta de IA — nem na campanha, nem no agente —, ele diz
          que não tem com que compor.
          {semAgente.length > 0 && (
            <> Sem agente em {semAgente.map((c) => NOME_CANAL[c] ?? c).join(', ')}: ali não há rascunho.</>
          )}
        </Aviso>
      </div>
    </>
  );
}

/**
 * O que o motor compôs, palavra por palavra.
 *
 * É a razão de ser do shadow mode: rodar tudo sem enviar só vale se der para
 * ler o que teria sido enviado. Sem isto, o erro mais provável de todos — o
 * template errado — passa direto pelo modo que existe para pegá-lo.
 */
function Mensagens({ lista }: { lista: MensagemComposta[] }) {
  const [aberto, setAberto] = useState(false);
  const comBuraco = lista.filter((m) => m.buraco).length;

  if (lista.length === 0) return null;

  return (
    <>
      <Secao titulo="O que o motor escreveu"
             nota={`${lista.length} ${lista.length === 1 ? 'mensagem' : 'mensagens'}`} />

      {comBuraco > 0 && (
        <Aviso tipo="erro">
          <b>{comBuraco}</b> {comBuraco === 1 ? 'mensagem tem' : 'mensagens têm'} cara de variável
          vazia — pontuação sobrando ou espaço dobrado, o rastro de um{' '}
          <code className="mono">{'{{nome}}'}</code> sem valor. O motor troca variável ausente por
          nada, de propósito (mandar a marcação crua seria pior), mas o texto vira
          &ldquo;Olá , tudo bem?&rdquo;. Quem escreveu o template decide o que fazer: preencher o
          dado, ou escrever uma frase que funcione sem ele.
        </Aviso>
      )}

      <div className="painel">
        <button className="btn" onClick={() => setAberto((v) => !v)}>
          {aberto ? 'Esconder o texto' : 'Ler o texto das mensagens'}
        </button>

        {aberto && (
          <table className="tab">
            <thead>
              <tr><th>Quem</th><th>Passo</th><th>Destino</th><th>O texto</th></tr>
            </thead>
            <tbody>
              {lista.map((m) => (
                <tr key={m.message_id}>
                  <td style={{ color: 'var(--ink)' }}>{m.contato}</td>
                  <td>{m.passo}</td>
                  <td className="mono">{m.destino}</td>
                  <td style={{ whiteSpace: 'pre-wrap', color: 'var(--ink)' }}>
                    {m.conteudo}
                    {m.buraco && (
                      <span className="chip" style={{ marginLeft: 8 }}>variável vazia?</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}

function motivoResumido(por: Record<string, number>): string {
  const partes = Object.entries(por).map(([k, n]) => `${n} ${MOTIVO[k] ?? k}`);
  return partes.length ? partes.join(', ') : 'nenhum ainda';
}

function statusResumido(por: Record<string, number>): string {
  const partes = Object.entries(por).map(([k, n]) => `${n} ${STATUS_PLURAL[k] ?? k}`);
  return partes.length ? partes.join(', ') : 'nenhuma ainda';
}

/** Data curta e local: a pessoa lê "22/09 14:31", não um ISO com fuso. */
function quando(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

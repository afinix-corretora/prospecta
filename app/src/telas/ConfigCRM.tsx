/** Configurações ▸ Plataformas vinculadas ▸ uma conexão (D64).
 *
 * Três perguntas, na ordem em que se responde:
 *
 *   1. O que a plataforma TEM? — "Ler pipes e campos" pede à edge function,
 *      que tem o segredo. O resto da tela oferece escolhas daqui, nunca um id
 *      digitado à mão.
 *   2. O que cada fato FAZ no card? — mover de fase e preencher campo, por
 *      pipe. Mover vem antes de preencher no motor, seja qual for a ordem
 *      aqui: campo de fase só é editável com o card na fase dele.
 *   3. De onde vêm contatos? — pipe, fases, e qual campo é telefone, e-mail ou
 *      nome. A leitura é a mesma da planilha.
 *
 * E uma coisa dita em voz alta: o fato só chega ao CRM para quem TEM card
 * ligado. Contato que veio de planilha não tem card, e o motor não adivinha
 * qual é — buscar por telefone escreveria no card de outra pessoa com o mesmo
 * número. O dreno tira o fato da fila e escreve o motivo.
 */
import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  alternarAcaoCRM, alternarFonteCRM, apagarAcaoCRM, apagarFonteCRM, criarAcaoCRM, criarFonteCRM,
  descobrirCRM, lerAcoesCRM, lerCampanhas, lerConexoesCRM, lerEstruturaCRM, lerFontesCRM,
} from '../dados';
import type {
  AcaoCRM, Campanha, CampoCRM, ConexaoCRM, EstruturaCRM, FatoCRM, FonteCRM, PipeCRM,
} from '../dados';
import { Aviso, Campo, Secao } from '../componentes/base';
import { Moldura } from './Telas';

const FATOS: { fato: FatoCRM; nome: string; desc: string }[] = [
  { fato: 'respondido', nome: 'Respondeu', desc: 'a pessoa respondeu em qualquer canal e a cadência encerrou' },
  { fato: 'opt_out', nome: 'Pediu para sair', desc: 'entrou na supressão: nunca mais recebe nada' },
  { fato: 'identidade_invalida', nome: 'Endereço inválido', desc: 'número ou e-mail não existe' },
  { fato: 'campanha_concluida', nome: 'Cadência concluída', desc: 'todos os passos saíram e ninguém respondeu' },
];

const PAPEIS: { papel: string; nome: string }[] = [
  { papel: 'nome', nome: 'Nome' },
  { papel: 'telefone', nome: 'Telefone (celular vira WhatsApp e SMS)' },
  { papel: 'whatsapp', nome: 'WhatsApp' },
  { papel: 'sms', nome: 'SMS' },
  { papel: 'email', nome: 'E-mail' },
  { papel: 'instagram', nome: 'Instagram' },
];

const IDENTIDADE = new Set(['telefone', 'whatsapp', 'sms', 'email', 'instagram']);

/** Todos os campos de um pipe: formulário inicial e campos de cada fase. */
function camposDoPipe(p: PipeCRM): (CampoCRM & { onde: string })[] {
  return [
    ...p.camposIniciais.map((c) => ({ ...c, onde: c.somenteLeitura ? 'contato do card' : 'formulário inicial' })),
    ...p.fases.flatMap((f) => f.campos.map((c) => ({ ...c, onde: f.nome }))),
  ];
}

export function ConfigCRM() {
  const nav = useNavigate();
  const { id = '' } = useParams();
  const { tenant, administra } = useSessao();
  const [conexao, setConexao] = useState<ConexaoCRM | null>(null);
  const [estrutura, setEstrutura] = useState<EstruturaCRM | null>(null);
  const [acoes, setAcoes] = useState<AcaoCRM[]>([]);
  const [fontes, setFontes] = useState<FonteCRM[]>([]);
  const [campanhas, setCampanhas] = useState<Campanha[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');
  const [lendo, setLendo] = useState(false);
  const [pipeId, setPipeId] = useState('');

  async function recarregar() {
    try {
      const [cs, e, a, f, camp] = await Promise.all([
        lerConexoesCRM(), lerEstruturaCRM(id), lerAcoesCRM(id), lerFontesCRM(id), lerCampanhas(),
      ]);
      setConexao(cs.find((c) => c.id === id) ?? null);
      setEstrutura(e); setAcoes(a); setFontes(f); setCampanhas(camp);
      setErro('');
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }
  useEffect(() => { void recarregar(); }, [id, tenant?.tenant_id]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  if (!conexao) {
    return (
      <Moldura titulo="Conexão" sub="Plataforma vinculada" voltar={() => nav('/config/vinculadas')}>
        <Aviso tipo="neutro">Conexão não encontrada — ou só quem administra o cliente a vê.</Aviso>
      </Moldura>
    );
  }

  const pipes = estrutura?.estrutura?.pipes ?? [];
  const pipe = pipes.find((p) => p.id === pipeId) ?? pipes[0];

  async function ler() {
    setLendo(true);
    try {
      const r = await descobrirCRM(id);
      if (!r.ok) setErro(r.erro ?? 'a leitura falhou');
      await recarregar();
    } finally { setLendo(false); }
  }

  return (
    <Moldura titulo={conexao.nome} voltar={() => nav('/config/vinculadas')}
             sub="O que o motor escreve no CRM quando descobre um fato, e de onde ele traz contatos.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {!conexao.ativo && (
        <Aviso tipo="neutro"><b>Conexão desligada.</b> Nada é escrito nem lido enquanto ela estiver assim; os fatos esperam na fila.</Aviso>
      )}

      <Secao titulo="O que a plataforma tem"
             nota={estrutura ? `lido em ${new Date(estrutura.descoberto_em).toLocaleString('pt-BR')}` : 'ainda não lido'} />
      <div className="painel" style={{ marginBottom: 14 }}>
        {estrutura?.erro && (
          <Aviso tipo="erro">
            <b>A última leitura falhou:</b> {estrutura.erro}
            {pipes.length > 0 && ' — as escolhas abaixo são da leitura anterior.'}
          </Aviso>
        )}
        {pipes.length > 0 ? (
          <div className="campo">
            <label htmlFor="crm-pipe">Pipe</label>
            <select id="crm-pipe" value={pipe?.id ?? ''} onChange={(e) => setPipeId(e.target.value)}>
              {pipes.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nome} — {p.fases.length} fases, {camposDoPipe(p).length} campos
                </option>
              ))}
            </select>
          </div>
        ) : (
          <p className="ajuda" style={{ marginTop: 0 }}>
            Ainda não há pipes para escolher. Ler a plataforma usa a credencial guardada no Vault e não muda nada nela.
          </p>
        )}
        {administra && (
          <button className="btn" disabled={lendo} onClick={() => void ler()}>
            {lendo ? 'Lendo…' : pipes.length ? 'Ler de novo' : 'Ler pipes e campos'}
          </button>
        )}
      </div>

      {pipe && (
        <>
          <Secao titulo="O que cada fato faz no card" nota={pipe.nome} />
          <Aviso tipo="neutro">
            O fato só chega ao card de quem <b>tem card ligado</b> — quem entrou por uma fonte abaixo.
            Contato de planilha não tem card, e o motor não procura um pelo telefone: escreveria no card
            de outra pessoa com o mesmo número. Na fila de writeback ele aparece com o motivo.
          </Aviso>
          {FATOS.map((f) => (
            <AcoesDoFato key={f.fato} fato={f} pipe={pipe} conexao={id} tenant={tenant?.tenant_id ?? ''}
                         administra={administra}
                         acoes={acoes.filter((a) => a.pipe_id === pipe.id && a.fato === f.fato)}
                         aoMudar={recarregar} />
          ))}

          <Secao titulo="Fontes de contato" nota="cards que viram contatos e, se quiser, inscrições" />
          <section className="indice" style={{ marginBottom: 12 }}>
            {fontes.length ? fontes.map((f) => (
              <LinhaFonte key={f.id} fonte={f} pipes={pipes} campanhas={campanhas}
                          administra={administra} aoMudar={recarregar} />
            )) : (
              <div className="item" style={{ cursor: 'default' }}><span className="txt">
                <b>Nenhuma fonte</b>
                <p>Sem fonte, ninguém tem card ligado — e os fatos não têm onde ser escritos.</p>
              </span></div>
            )}
          </section>
          {administra && tenant && (
            <NovaFonte pipe={pipe} conexao={id} tenant={tenant.tenant_id} campanhas={campanhas}
                       aoSalvar={recarregar} />
          )}
        </>
      )}
    </Moldura>
  );
}

function AcoesDoFato(props: {
  fato: (typeof FATOS)[number]; pipe: PipeCRM; conexao: string; tenant: string; administra: boolean;
  acoes: AcaoCRM[]; aoMudar(): Promise<void>;
}) {
  const { fato, pipe } = props;
  const [tipo, setTipo] = useState<'mover_fase' | 'preencher_campo'>('mover_fase');
  const [alvo, setAlvo] = useState('');
  const [valor, setValor] = useState('');
  const [abrir, setAbrir] = useState(false);
  const [msg, setMsg] = useState('');
  // Campo só de leitura (o contato do ProfitCare) serve à fonte, não à ação.
  const campos = camposDoPipe(pipe).filter((c) => !c.somenteLeitura);
  const temMover = props.acoes.some((a) => a.tipo === 'mover_fase' && a.ativo);

  async function fazer(f: () => Promise<void>) {
    setMsg('');
    try { await f(); await props.aoMudar(); } catch (e) { setMsg(mensagemDeErro(e)); }
  }

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    const rotulo = tipo === 'mover_fase'
      ? pipe.fases.find((f) => f.id === alvo)?.nome
      : campos.find((c) => c.id === alvo)?.rotulo;
    await fazer(async () => {
      await criarAcaoCRM({
        tenant: props.tenant, conexao_id: props.conexao, pipe_id: pipe.id, fato: fato.fato, tipo,
        alvo_id: alvo, alvo_rotulo: rotulo ?? alvo, valor: tipo === 'preencher_campo' ? valor : null,
        ordem: props.acoes.length,
      });
      setAlvo(''); setValor(''); setAbrir(false);
    });
  }

  return (
    <div className="painel" style={{ marginBottom: 10 }}>
      <b>{fato.nome}</b>
      <p className="ajuda" style={{ margin: '2px 0 8px' }}>{fato.desc}</p>
      {props.acoes.length ? props.acoes.map((a) => (
        <div key={a.id} className="item" style={{ cursor: 'default', opacity: a.ativo ? 1 : 0.6 }}>
          <span className="txt">
            <strong>{a.tipo === 'mover_fase' ? `Mover para “${a.alvo_rotulo ?? a.alvo_id}”` : `Preencher “${a.alvo_rotulo ?? a.alvo_id}”`}</strong>
            {a.valor && <p className="mono" style={{ fontSize: 11.5 }}>{a.valor}</p>}
            {!a.ativo && <p>desligada</p>}
          </span>
          {props.administra && (
            <span style={{ display: 'flex', gap: 6 }}>
              <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                      onClick={() => void fazer(() => alternarAcaoCRM(a.id, !a.ativo))}>
                {a.ativo ? 'Desligar' : 'Ligar'}
              </button>
              <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                      onClick={() => void fazer(() => apagarAcaoCRM(a.id))}>Apagar</button>
            </span>
          )}
        </div>
      )) : <p className="ajuda" style={{ margin: 0 }}>Nada configurado: o fato sai da fila sem escrever no card, dizendo isso.</p>}
      {msg && <Aviso tipo="erro">{msg}</Aviso>}

      {props.administra && !abrir && (
        <button className="btn" style={{ marginTop: 8 }} onClick={() => setAbrir(true)}>Acrescentar ação</button>
      )}
      {props.administra && abrir && (
        <form onSubmit={salvar} style={{ marginTop: 10 }}>
          <div className="campo">
            <label htmlFor={`t-${fato.fato}`}>Ação</label>
            <select id={`t-${fato.fato}`} value={tipo}
                    onChange={(e) => { setTipo(e.target.value as typeof tipo); setAlvo(''); }}>
              <option value="mover_fase" disabled={temMover}>Mover o card de fase{temMover ? ' (já há uma)' : ''}</option>
              <option value="preencher_campo">Preencher um campo</option>
            </select>
          </div>
          <div className="campo">
            <label htmlFor={`a-${fato.fato}`}>{tipo === 'mover_fase' ? 'Fase de destino' : 'Campo'}</label>
            <select id={`a-${fato.fato}`} value={alvo} onChange={(e) => setAlvo(e.target.value)}>
              <option value="">Escolha…</option>
              {tipo === 'mover_fase'
                ? pipe.fases.map((f) => <option key={f.id} value={f.id}>{f.nome}</option>)
                : campos.map((c) => <option key={`${c.onde}-${c.id}`} value={c.id}>{c.rotulo} ({c.onde})</option>)}
            </select>
          </div>
          {tipo === 'preencher_campo' && (
            <Campo id={`v-${fato.fato}`} rotulo="Valor" valor={valor} aoMudar={setValor}
                   placeholder="Respondeu em {{data}}: {{resposta}}"
                   ajuda="Pode citar {{nome}}, {{data}}, {{campanha}}, {{motivo}}, {{resposta}} e qualquer coluna que o contato trouxe. O campo é sobrescrito, não acrescentado — o motor repete a escrita quando a anterior falha." />
          )}
          <span style={{ display: 'flex', gap: 8 }}>
            <button className="btn prim" disabled={!alvo || (tipo === 'preencher_campo' && !valor.trim())}>Salvar</button>
            <button type="button" className="btn" onClick={() => setAbrir(false)}>Cancelar</button>
          </span>
        </form>
      )}
    </div>
  );
}

function resumoDaFonte(f: FonteCRM): string {
  const r = f.ultimo_resultado;
  if (!f.ultima_execucao || !r) return 'ainda não lida — o motor lê na próxima passada';
  const quando = new Date(f.ultima_execucao).toLocaleString('pt-BR');
  if (typeof r.erro === 'string') return `${quando}: a leitura falhou — ${r.erro}`;
  const n = (k: string) => Number(r[k] ?? 0);
  const insc = (r.inscricao ?? {}) as Record<string, number>;
  const naoInscritos = Object.entries(insc).filter(([k]) => k !== 'inscrito' && k !== 'sem_campanha');
  return `${quando}: ${n('lidos')} cards, ${n('novos')} novos, ${n('criados')} contatos criados`
    + (insc.inscrito ? `, ${insc.inscrito} inscritos` : '')
    + (naoInscritos.length ? `, não inscritos: ${naoInscritos.map(([k, v]) => `${v} ${k.replace(/_/g, ' ')}`).join(', ')}` : '')
    + (n('recusados') ? `, ${n('recusados')} recusados` : '');
}

function LinhaFonte({ fonte, pipes, campanhas, administra, aoMudar }: {
  fonte: FonteCRM; pipes: PipeCRM[]; campanhas: Campanha[]; administra: boolean; aoMudar(): Promise<void>;
}) {
  const [erro, setErro] = useState('');
  const pipe = pipes.find((p) => p.id === fonte.pipe_id);
  const fases = fonte.fases.map((id) => pipe?.fases.find((f) => f.id === id)?.nome ?? id);
  const campanha = campanhas.find((c) => c.id === fonte.campaign_id);
  const erros = (fonte.ultimo_resultado?.erros ?? []) as string[];

  async function fazer(f: () => Promise<void>) {
    setErro('');
    try { await f(); await aoMudar(); } catch (e) { setErro(mensagemDeErro(e)); }
  }

  return (
    <div className="item" style={{ cursor: 'default', opacity: fonte.ativa ? 1 : 0.6 }}>
      <span className="txt">
        <strong>{fonte.nome}</strong>
        <p>
          {fonte.pipe_rotulo ?? fonte.pipe_id} · {fases.join(', ')} · a cada {fonte.intervalo_minutos} min ·{' '}
          {campanha ? `inscreve em “${campanha.nome}”` : 'só importa, sem inscrever'}
        </p>
        <p style={{ fontSize: 11.5 }}>{resumoDaFonte(fonte)}</p>
        {erros.slice(0, 3).map((e) => <p key={e} style={{ fontSize: 11, color: 'var(--ink-3)' }}>{e}</p>)}
        {erro && <p style={{ color: 'var(--crit)', fontSize: 11 }}>{erro}</p>}
      </span>
      {administra && (
        <span style={{ display: 'flex', gap: 6 }}>
          <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                  onClick={() => void fazer(() => alternarFonteCRM(fonte.id, !fonte.ativa))}>
            {fonte.ativa ? 'Pausar' : 'Retomar'}
          </button>
          <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                  onClick={() => void fazer(() => apagarFonteCRM(fonte.id))}>Apagar</button>
        </span>
      )}
    </div>
  );
}

function NovaFonte({ pipe, conexao, tenant, campanhas, aoSalvar }: {
  pipe: PipeCRM; conexao: string; tenant: string; campanhas: Campanha[]; aoSalvar(): Promise<void>;
}) {
  const [nome, setNome] = useState('');
  const [fases, setFases] = useState<string[]>([]);
  const [mapa, setMapa] = useState<Record<string, string>>({ titulo: 'nome' });
  const [campanha, setCampanha] = useState('');
  const [intervalo, setIntervalo] = useState('15');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);
  const campos = camposDoPipe(pipe);
  const temIdentidade = Object.values(mapa).some((p) => IDENTIDADE.has(p));
  const escolhida = campanhas.find((c) => c.id === campanha);

  // Pipe trocado lá em cima: fases e campos do anterior não valem aqui.
  useEffect(() => { setFases([]); setMapa({ titulo: 'nome' }); }, [pipe.id]);

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    try {
      await criarFonteCRM({
        tenant, conexao_id: conexao, nome: nome.trim(), pipe_id: pipe.id, pipe_rotulo: pipe.nome,
        fases, mapa: Object.fromEntries(Object.entries(mapa).filter(([, p]) => p)),
        campaign_id: campanha || null, intervalo_minutos: Math.max(5, Number(intervalo) || 15),
      });
      setMsg({ tipo: 'ok', texto: 'Fonte criada. O motor lê na próxima passada.' });
      setNome(''); setFases([]);
      await aoSalvar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
  }

  return (
    <form className="painel" onSubmit={salvar}>
      <b style={{ display: 'block', marginBottom: 10 }}>Nova fonte em “{pipe.nome}”</b>
      <Campo id="fo-nome" rotulo="Nome" valor={nome} aoMudar={setNome} placeholder="Leads novos do site" />

      <div className="campo">
        <label>Fases lidas</label>
        <span className="chips">
          {pipe.fases.map((f) => (
            <button key={f.id} type="button" className="opt" aria-pressed={fases.includes(f.id)}
                    style={{ padding: '4px 10px' }}
                    onClick={() => setFases(fases.includes(f.id) ? fases.filter((x) => x !== f.id) : [...fases, f.id])}>
              {f.nome}
            </button>
          ))}
        </span>
      </div>

      <div className="campo">
        <label>O que cada campo é</label>
        <span className="ajuda" style={{ marginTop: 0 }}>
          Campo sem papel vira variável da cadência pelo rótulo — “Plano atual” é {'{{plano_atual}}'}.
          A leitura é a mesma da planilha: telefone fixo não vira WhatsApp, e valor que não parece
          telefone sai no resumo da fonte em vez de sumir.
        </span>
        {[{ id: 'titulo', rotulo: 'Título do card', onde: 'card' }, ...campos].map((c) => (
          <span key={`${c.onde}-${c.id}`} style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 6 }}>
            <span style={{ flex: 1, fontSize: 12.5 }}>{c.rotulo} <span style={{ color: 'var(--ink-3)' }}>({c.onde})</span></span>
            <select value={mapa[c.id] ?? ''} style={{ flex: 1 }}
                    onChange={(e) => setMapa({ ...mapa, [c.id]: e.target.value })}>
              <option value="">variável</option>
              {PAPEIS.map((p) => <option key={p.papel} value={p.papel}>{p.nome}</option>)}
            </select>
          </span>
        ))}
      </div>

      <div className="campo">
        <label htmlFor="fo-camp">Inscrever em</label>
        <select id="fo-camp" value={campanha} onChange={(e) => setCampanha(e.target.value)}>
          <option value="">Ninguém — só importar</option>
          {campanhas.map((c) => <option key={c.id} value={c.id}>{c.nome}{c.flow_version_id ? '' : ' (sem cadência)'}</option>)}
        </select>
        <span className="ajuda">
          Cada card passa pela mesma prévia da tela de contatos: quem não tem canal que a cadência usa,
          ou pediu para sair, entra como contato e não é inscrito — e o resumo da fonte conta quantos.
        </span>
      </div>
      {escolhida && !escolhida.flow_version_id && (
        <Aviso tipo="neutro">“{escolhida.nome}” não tem cadência: os cards entram como contatos e ninguém é inscrito até ela ter uma.</Aviso>
      )}
      <Campo id="fo-int" rotulo="Ler a cada (minutos)" valor={intervalo} aoMudar={setIntervalo}
             ajuda="Mínimo 5. O CRM limita requisições; ler a cada minuto seria o motor tirando o CRM do ar." />

      {!temIdentidade && (
        <Aviso tipo="neutro">Marque pelo menos um campo como telefone, WhatsApp, SMS, e-mail ou Instagram — sem isso todo card seria recusado.</Aviso>
      )}
      {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      <button className="btn prim" disabled={!nome.trim() || !fases.length || !temIdentidade}>Criar fonte</button>
    </form>
  );
}

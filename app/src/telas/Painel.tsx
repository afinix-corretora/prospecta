/**
 * Início: o painel de resultados.
 *
 * É a primeira tela para os dois públicos (decisão do usuário): o gestor vê se
 * rendeu, o operador vê quem respondeu e o que pede ação. A ordem é essa:
 *
 *   1. o que o motor NÃO fez — modo simulado, configuração pela metade;
 *   2. os números do período, com a comparação ao período anterior;
 *   3. o ritmo dia a dia, mensagens e respostas no mesmo eixo de tempo;
 *   4. onde os leads estão, quem respondeu, o que está rodando.
 *
 * Tudo é lido do banco a cada visita, com o JWT de quem olha e filtrado pelo
 * cliente escolhido. Nada aqui grava.
 */
import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import {
  contarFunil, lerCampanhas, lerPainel, lerRespostas, lerResumoDaCampanha, lerResumoDaOutbox,
} from '../dados';
import type {
  Campanha, DadosDoPainel, EstagioContado, RespostaRecebida, ResumoDaCampanha, ResumoDaOutbox,
} from '../dados';
import { situacao } from '../assistente';
import type { Item as ItemDaSituacao } from '../assistente';
import { lerFoto } from './Inicio';
import { Aviso, NOME_CANAL, corCanal, tinta } from '../componentes/base';
import { iniciais } from '../componentes/Rail';
import { Ico } from '../componentes/icones';
import { Anel, Barras, GraficoNoTempo, Tendencia, numero } from '../componentes/graficos';
import { mensagemDeErro } from '../supabase';

const PERIODOS = [7, 14, 30] as const;
const CHAVE_PERIODO = 'prospecta:periodo';
const MESES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];

function rotuloDia(d: string) {
  const [, m, dia] = d.split('-');
  return `${Number(dia)} ${MESES[Number(m) - 1]}`;
}

function saudacao(): string {
  const h = new Date().getHours();
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

function hojePorExtenso(): string {
  return new Intl.DateTimeFormat('pt-BR', { weekday: 'long', day: 'numeric', month: 'long' }).format(new Date());
}

/** "agora", "há 12 min", "há 3 h", "ontem", "3 out". */
export function haQuanto(iso: string): string {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 60) return 'agora';
  if (s < 3600) return `há ${Math.floor(s / 60)} min`;
  if (s < 86400) return `há ${Math.floor(s / 3600)} h`;
  if (s < 172800) return 'ontem';
  const d = new Date(iso);
  return `${d.getDate()} ${MESES[d.getMonth()]}`;
}

const pct = (n: number) => `${(n * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`;

/** A variação contra o período anterior. Sem base para comparar, não inventa
 *  porcentagem: diz que é novo, ou que não mudou. */
function Variacao({ agora, antes, pontos }: { agora: number; antes: number; pontos?: boolean }) {
  if (pontos) {
    const d = (agora - antes) * 100;
    if (Math.abs(d) < 0.05) return <span className="delta neutra">estável</span>;
    return (
      <span className={`delta${d < 0 ? ' baixa' : ''}`}>
        <Ico nome={d < 0 ? 'desce' : 'sobe'} className="" />
        {Math.abs(d).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} p.p.
      </span>
    );
  }
  if (antes === 0) return agora > 0 ? <span className="delta">novo</span> : <span className="delta neutra">—</span>;
  const r = (agora - antes) / antes;
  if (Math.abs(r) < 0.005) return <span className="delta neutra">estável</span>;
  return (
    <span className={`delta${r < 0 ? ' baixa' : ''}`}>
      <Ico nome={r < 0 ? 'desce' : 'sobe'} className="" />
      {Math.abs(r * 100).toLocaleString('pt-BR', { maximumFractionDigits: 0 })}%
    </span>
  );
}

interface CampanhaComResumo { c: Campanha; r: ResumoDaCampanha | null }

interface Tudo {
  painel: DadosDoPainel;
  funil: EstagioContado[];
  respostas: RespostaRecebida[];
  campanhas: CampanhaComResumo[];
  outbox: ResumoDaOutbox | null;
  situacao: ItemDaSituacao[] | null;
}

function lerPeriodo(): number {
  try {
    const v = Number(localStorage.getItem(CHAVE_PERIODO));
    return (PERIODOS as readonly number[]).includes(v) ? v : 14;
  } catch { return 14; }
}

export function Painel() {
  const nav = useNavigate();
  const { tenant, administra, opera, sessao } = useSessao();
  const [dias, setDias] = useState<number>(lerPeriodo);
  const [tudo, setTudo] = useState<Tudo | null>(null);
  const [erro, setErro] = useState('');

  useEffect(() => {
    if (!tenant) return;
    let vivo = true;
    setErro('');
    const t = tenant.tenant_id;
    (async () => {
      try {
        const [painel, funil, respostas, campanhas, outbox, foto] = await Promise.all([
          lerPainel(t, dias),
          contarFunil(t).catch(() => [] as EstagioContado[]),
          lerRespostas(t, undefined, 6).catch(() => [] as RespostaRecebida[]),
          lerCampanhas().catch(() => [] as Campanha[]),
          lerResumoDaOutbox(t).catch(() => null),
          lerFoto(administra, opera).catch(() => null),
        ]);
        const ativas = campanhas.filter((c) => c.ativa).slice(0, 5);
        const resumos = await Promise.all(ativas.map((c) =>
          lerResumoDaCampanha(t, c.id).catch(() => null)));
        if (!vivo) return;
        setTudo({
          painel, funil, respostas, outbox,
          campanhas: ativas.map((c, i) => ({ c, r: resumos[i] ?? null })),
          situacao: foto ? situacao(foto) : null,
        });
      } catch (e) {
        if (vivo) setErro(mensagemDeErro(e));
      }
    })();
    return () => { vivo = false; };
  }, [tenant, dias, administra, opera]);

  function escolherPeriodo(n: number) {
    setDias(n);
    try { localStorage.setItem(CHAVE_PERIODO, String(n)); } catch { /* segue sem lembrar */ }
  }

  const meta = (sessao?.user.user_metadata ?? {}) as Record<string, unknown>;
  const nomePessoa = String(meta.nome ?? meta.full_name ?? meta.name ?? '').split(' ')[0];

  return (
    <div className="wrap larga">
      <div className="ola">
        <div>
          <h1>{saudacao()}{nomePessoa ? `, ${nomePessoa}` : ''}</h1>
          <p>{tenant?.nome} · {hojePorExtenso()}</p>
        </div>
        <div className="segmento" role="group" aria-label="Período">
          {PERIODOS.map((n) => (
            <button key={n} aria-pressed={dias === n} onClick={() => escolherPeriodo(n)}>{n} dias</button>
          ))}
        </div>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {!tudo && !erro && <Esqueleto />}
      {tudo && <Conteudo tudo={tudo} dias={dias} aoNavegar={nav} />}
    </div>
  );
}

function Esqueleto() {
  return (
    <div className="grade" aria-busy="true" aria-label="Carregando o painel">
      <div className="kpis">{[0, 1, 2, 3].map((i) => <div key={i} className="esqueleto" style={{ minHeight: 168 }} />)}</div>
      <div className="esqueleto c8" style={{ minHeight: 360 }} />
      <div className="esqueleto c4" style={{ minHeight: 360 }} />
    </div>
  );
}

function Conteudo({ tudo, dias, aoNavegar }: { tudo: Tudo; dias: number; aoNavegar(r: string): void }) {
  const { painel: p, funil, respostas, campanhas, outbox } = tudo;
  const rotulos = useMemo(() => p.dias.map(rotuloDia), [p.dias]);
  const taxa = p.totais.saidas ? p.totais.respostas / p.totais.saidas : 0;
  const taxaAntes = p.anterior.saidas ? p.anterior.respostas / p.anterior.saidas : 0;
  const taxaDia = p.saidas.map((s, i) => (s ? (p.respostas[i] ?? 0) / s : 0));
  const pendentes = (tudo.situacao ?? []).filter((i) => !i.feito);
  const simulado = p.totais.saidas > 0 && p.totais.enviadas === 0;
  const oportunidades = funil.find((e) => e.slug === 'oportunidade')?.total ?? 0;
  const canais = Object.entries(p.porCanal).sort((a, b) => b[1] - a[1]);
  const totalCanais = canais.reduce((a, [, n]) => a + n, 0);

  const series = useMemo(() => [
    { nome: 'Mensagens', cor: 'var(--g-1)', valores: p.saidas, forma: 'linha' as const },
    { nome: 'Respostas', cor: 'var(--g-2)', valores: p.respostas, forma: 'barras' as const },
  ], [p.saidas, p.respostas]);

  return (
    <>
      {/* Shadow mode precisa ser legível, senão parece defeito (D36). */}
      {simulado && (
        <div className="faixa-modo" role="note">
          <Ico nome="alerta" className="" />
          <p><b>Modo simulado.</b> Nos últimos {dias} dias o motor fez o caminho inteiro e nenhuma
             mensagem saiu de verdade: as {numero(p.totais.simuladas)} abaixo são simuladas. O texto de cada
             uma está na tela da campanha.</p>
        </div>
      )}
      {p.amostra && (
        <Aviso tipo="neutro">O período tem mais linhas do que o painel lê de uma vez — as curvas são
          uma amostra dos primeiros registros. Os totais de comparação vêm contados no banco.</Aviso>
      )}

      {tudo.situacao && pendentes.length > 0 && (
        <section className="painel progresso" aria-label="Configuração">
          <Anel feito={tudo.situacao.length - pendentes.length} total={tudo.situacao.length} />
          <div className="txt">
            <h2>{pendentes.length === 1 ? 'Falta um passo para o motor rodar inteiro'
                                        : `Faltam ${pendentes.length} passos para o motor rodar inteiro`}</h2>
            <p>{pendentes[0]!.titulo}: {pendentes[0]!.detalhe}</p>
            <div className="passos">
              {tudo.situacao.map((i) => (
                <span key={i.id} className={`chip${i.feito ? ' ok' : ''}`}>
                  {i.feito && <span className="ponto" />}{i.titulo}
                </span>
              ))}
            </div>
          </div>
          <button className="btn prim" onClick={() => aoNavegar('/configurar')}>Continuar configuração</button>
        </section>
      )}

      <div className="grade">
        <section className="kpis" aria-label="Números do período">
          <article className="kpi serie">
            {/* Em modo simulado nada "saiu": o número é o que o motor teria
                mandado, e o rótulo diz isso em vez de contradizer a faixa. */}
            <div className="linha1"><span className="r">{simulado ? 'Mensagens simuladas' : 'Mensagens que saíram'}</span></div>
            <div className="numero"><b>{numero(p.totais.saidas)}</b><Variacao agora={p.totais.saidas} antes={p.anterior.saidas} /></div>
            <span className="s">
              {simulado ? `nenhuma enviada de verdade · ${dias} dias`
                : p.totais.simuladas ? `${numero(p.totais.enviadas)} enviadas · ${numero(p.totais.simuladas)} simuladas`
                : `em ${dias} dias${p.totais.falhas ? ` · ${numero(p.totais.falhas)} falharam` : ''}`}
            </span>
            <span className="curva"><Tendencia valores={p.saidas} cor="var(--g-1)" /></span>
          </article>

          <article className="kpi serie">
            <div className="linha1"><span className="r">Respostas</span></div>
            <div className="numero"><b>{numero(p.totais.respostas)}</b><Variacao agora={p.totais.respostas} antes={p.anterior.respostas} /></div>
            <span className="s">em todos os canais · {dias} dias</span>
            <span className="curva"><Tendencia valores={p.respostas} cor="var(--g-2)" /></span>
          </article>

          <article className="kpi serie">
            <div className="linha1"><span className="r">Taxa de resposta</span></div>
            <div className="numero">
              <b>{simulado ? '—' : pct(taxa)}</b>
              {!simulado && <Variacao agora={taxa} antes={taxaAntes} pontos />}
            </div>
            <span className="s">{simulado ? 'sem envio real, não há taxa a medir' : 'respostas por mensagem enviada'}</span>
            <span className="curva"><Tendencia valores={simulado ? taxaDia.map(() => 0) : taxaDia} cor="var(--g-2)" /></span>
          </article>

          <article className="kpi">
            <span className="r">Em cadência agora</span>
            <b>{numero(p.emCadencia)}</b>
            <span className="s">com próximo toque marcado</span>
            <div style={{ marginTop: 'auto', paddingTop: 14, display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <span className={`chip${oportunidades ? ' acento' : ''}`}>
                {numero(oportunidades)} {oportunidades === 1 ? 'oportunidade' : 'oportunidades'}
              </span>
              <button className="link" style={{ fontSize: 13 }} onClick={() => aoNavegar('/funil')}>ver no funil</button>
            </div>
          </article>
        </section>

        <section className="painel bloco c8" aria-label="Ritmo da operação">
          <div className="bloco-topo">
            <div>
              <h2>Ritmo da operação</h2>
              <p>{simulado ? 'Mensagens simuladas' : 'Mensagens que saíram'} e respostas que voltaram, dia a dia — cada uma na sua escala.</p>
            </div>
            <div className="legenda">
              <span><i style={{ background: 'var(--g-1)' }} />Mensagens <em>{numero(p.totais.saidas)}</em></span>
              <span><i style={{ background: 'var(--g-2)' }} />Respostas <em>{numero(p.totais.respostas)}</em></span>
            </div>
          </div>
          {p.totais.saidas || p.totais.respostas ? (
            <GraficoNoTempo
              titulo={`Mensagens e respostas por dia, últimos ${dias} dias`}
              rotulos={rotulos} series={series} alturas={[170, 74]} ultimoParcial
              extraDaDica={(i) => (p.saidas[i]
                ? <div><span>Taxa do dia</span><em>{pct(taxaDia[i] ?? 0)}</em></div>
                : null)}
            />
          ) : (
            <Vazio titulo="Nada saiu neste período"
                   texto="Quando uma campanha ligada tiver contatos inscritos, cada toque aparece aqui no dia em que saiu."
                   acao={<button className="btn" onClick={() => aoNavegar('/campanhas')}>Ir para campanhas</button>} />
          )}
        </section>

        <section className="painel bloco c4" aria-label="Funil">
          <div className="bloco-topo">
            <div><h2>Funil</h2><p>Onde cada lead está agora.</p></div>
            <button className="link" onClick={() => aoNavegar('/funil')}>Abrir</button>
          </div>
          {funil.length ? (
            <>
              <Barras itens={funil.map((e) => ({
                chave: e.id, rotulo: e.nome, valor: e.total,
                cor: e.tipo === 'ganho' ? 'var(--g-1)' : e.tipo === 'perdido' ? 'var(--line-strong)' : 'var(--g-2)',
              }))} />
              <Conversao funil={funil} />
            </>
          ) : (
            <p className="vazio">O funil aparece quando o primeiro contato for inscrito.</p>
          )}
        </section>

        <section className="painel bloco c7" aria-label="Respostas recentes">
          <div className="bloco-topo">
            <div><h2>Quem respondeu</h2><p>O texto da pessoa, a campanha e o canal. O agente já pode ter respondido.</p></div>
            <button className="link" onClick={() => aoNavegar('/respostas')}>Ver todas</button>
          </div>
          {respostas.length ? (
            <div className="respostas-lista">
              {respostas.map((r, i) => (
                <button key={`${r.contact_id}-${r.ocorrido_em}-${i}`} className="resp" onClick={() => aoNavegar('/respostas')}>
                  <span className="avatar" aria-hidden="true" style={tinta(corCanal(r.canal))}>
                    {iniciais(r.contato)}
                  </span>
                  <span style={{ minWidth: 0 }}>
                    <b>{r.contato}</b>
                    <p>{r.texto?.trim() ? `“${r.texto.trim()}”` : <em style={{ color: 'var(--ink-3)' }}>sem texto legível</em>}</p>
                    <span className="meta">
                      <span className="chip">{NOME_CANAL[r.canal] ?? r.canal}</span>
                      <span className="chip">{r.campanha}</span>
                      {r.suprimido && <span className="chip erro">pediu para sair</span>}
                    </span>
                  </span>
                  <time dateTime={r.ocorrido_em}>{haQuanto(r.ocorrido_em)}</time>
                </button>
              ))}
            </div>
          ) : (
            <Vazio titulo="Ninguém respondeu ainda"
                   texto="Quando alguém responder, a conversa aparece aqui junto da mensagem que a provocou — e a cadência daquela pessoa para em todas as campanhas." />
          )}
        </section>

        <div className="c5" style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
          <section className="painel bloco" aria-label="Campanhas ativas">
            <div className="bloco-topo">
              <div><h2>Campanhas ligadas</h2><p>Respostas sobre mensagens, desde o início de cada uma.</p></div>
              <button className="link" onClick={() => aoNavegar('/campanhas')}>Todas</button>
            </div>
            {campanhas.length ? (
              <div className="campanhas-lista">
                {campanhas.map(({ c, r }) => (
                  <button key={c.id} className="camp" onClick={() => aoNavegar(`/campanhas/${c.id}`)}>
                    <b>{c.nome}</b>
                    <span className="num">
                      <strong>{r ? numero(r.respostas) : '—'}</strong>
                      <span>{r && r.mensagens ? `${pct(r.respostas / r.mensagens)} de ${numero(r.mensagens)}` : 'sem mensagens'}</span>
                    </span>
                    <small>{c.canais_habilitados.map((x) => NOME_CANAL[x] ?? x).join(' · ')} · {c.tipo}</small>
                  </button>
                ))}
              </div>
            ) : (
              <Vazio titulo="Nenhuma campanha ligada"
                     texto="Um modelo pronto já vem com cadência, base legal e canais."
                     acao={<button className="btn" onClick={() => aoNavegar('/campanhas')}>Escolher modelo</button>} />
            )}
          </section>

          <section className="painel bloco" aria-label="Por canal e CRM">
            <div className="bloco-topo"><div><h2>Por canal</h2><p>{simulado ? 'Por onde as mensagens simuladas iriam.' : 'De onde saíram as mensagens do período.'}</p></div></div>
            {totalCanais ? (
              <>
                <div className="divisao" role="img"
                     aria-label={canais.map(([c, n]) => `${NOME_CANAL[c] ?? c}: ${n}`).join(', ')}>
                  {canais.map(([c, n]) => (
                    <i key={c} style={{ width: `${(n / totalCanais) * 100}%`, background: corCanal(c) }} />
                  ))}
                </div>
                <div className="legenda">
                  {canais.map(([c, n]) => (
                    <span key={c}><i style={{ background: corCanal(c) }} />{NOME_CANAL[c] ?? c} <em>{pct(n / totalCanais)}</em></span>
                  ))}
                </div>
              </>
            ) : <p className="vazio">Sem mensagens no período.</p>}

            {outbox && (
              <button className="camp" style={{ marginTop: 4, borderTop: '1px solid var(--line)', borderRadius: 0, paddingInline: 0 }}
                      onClick={() => aoNavegar('/writeback')}>
                <b>CRM</b>
                <span className="num">
                  <strong>{numero(outbox.pendentes)}</strong>
                  <span>{outbox.pendentes === 1 ? 'fato na fila' : 'fatos na fila'}</span>
                </span>
                <small>
                  {outbox.falhados
                    ? `${numero(outbox.falhados)} desistiram — ver o motivo`
                    : outbox.pendente_mais_antigo_em_horas != null
                      ? `o mais antigo espera há ${Math.round(outbox.pendente_mais_antigo_em_horas)} h`
                      : 'nada esperando'}
                </small>
              </button>
            )}
          </section>
        </div>
      </div>
    </>
  );
}

/** O que o gestor pergunta do funil: de cada cem, quantos viraram
 *  oportunidade, quantos fecharam. Estágio por `slug`, nunca por nome (D57). */
function Conversao({ funil }: { funil: EstagioContado[] }) {
  const total = funil.reduce((a, e) => a + e.total, 0);
  if (!total) return null;
  const de = (slug: string) => funil.find((e) => e.slug === slug)?.total ?? 0;
  const chegaram = de('oportunidade') + de('ganho');
  return (
    <div className="conversao">
      <div><strong>{pct(chegaram / total)}</strong><span>em oportunidade ou ganho</span></div>
      <div><strong>{pct(de('ganho') / total)}</strong><span>fecharam, de {numero(total)}</span></div>
    </div>
  );
}

function Vazio({ titulo, texto, acao }: { titulo: string; texto: string; acao?: ReactNode }) {
  return (
    <div style={{ padding: '18px 4px', display: 'grid', gap: 6, justifyItems: 'start' }}>
      <b style={{ fontSize: 14.5 }}>{titulo}</b>
      <p className="vazio" style={{ margin: 0, maxWidth: '56ch' }}>{texto}</p>
      {acao && <div style={{ marginTop: 8 }}>{acao}</div>}
    </div>
  );
}

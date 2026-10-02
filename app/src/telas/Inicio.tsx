/**
 * Início: o assistente de configuração (D67).
 *
 * A lógica — que pergunta vem, o que o plano propõe, quem pode autorizar — é
 * de `assistente.ts`, pura e testada. Aqui mora o que não dá para testar sem
 * navegador: a conversa, os cartões do plano e a execução de cada um.
 *
 * Duas regras que esta tela sustenta e o teste não alcança:
 *
 * - **Nada acontece sem clique.** Cada cartão diz o que vai fazer, e só faz
 *   quando a pessoa aperta "Autorizar". A escrita sai com o JWT dela, então
 *   quem responde se pode é o RLS — o `impedimento` é só para avisar antes.
 *
 * - **Chave nenhuma passa por aqui (D68).** Não há campo de chave nesta tela.
 *   Conta, chave e CRM se conectam em Configurações (ou na tela do canal); o
 *   assistente leva até lá e, quando a conta aparece no banco, segue a
 *   conversa e só ESCOLHE entre as conectadas. O que o navegador guarda são as
 *   respostas — canais, números, provedor, o id da conta escolhida.
 */
import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  ajustarQuota, atribuirAgente, contarContatos, criarCampanhaDeModelo, definirIADaCampanha,
  lerAgentes, lerCampanhas, lerConexoesCRM, lerCredenciaisIA, lerModelos, lerProvedoresCRM,
  lerProvedoresCanal, lerProvedoresIA, lerRemetentes,
} from '../dados';
import {
  cumprida, impedimento, legenda, montarPlano, roteiro, situacao, valida, voltarPara,
} from '../assistente';
import type { Acao, Foto, Pergunta, Resposta, Respostas } from '../assistente';
import { Aviso, Campo, Secao } from '../componentes/base';

async function lerFoto(administra: boolean, opera: boolean): Promise<Foto> {
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

/** O que sobrevive a recarregar a página. Sem segredo nenhum (ver o topo). */
interface Memoria {
  respostas: Respostas;
  /** id da ação → o que ela fez, dito na hora. Mostrado em vez de refazer a conta. */
  feitos: Record<string, string>;
  pulados: string[];
  /** id da ação → id que ela produziu (campanha, credencial), para quem depende dela. */
  produzidos: Record<string, string>;
}

const VAZIA: Memoria = { respostas: {}, feitos: {}, pulados: [], produzidos: {} };

function lerMemoria(chave: string): Memoria {
  try {
    const bruto = localStorage.getItem(chave);
    return bruto ? { ...VAZIA, ...(JSON.parse(bruto) as Partial<Memoria>) } : VAZIA;
  } catch { return VAZIA; }
}

function gravarMemoria(chave: string, m: Memoria) {
  try { localStorage.setItem(chave, JSON.stringify(m)); } catch { /* aba anônima: segue sem memória */ }
}

export function Inicio() {
  const nav = useNavigate();
  const { tenant, administra, opera } = useSessao();
  const chave = `prospecta:assistente:${tenant?.tenant_id ?? ''}`;
  const [foto, setFoto] = useState<Foto | null>(null);
  const [erro, setErro] = useState('');
  const [mem, setMem] = useState<Memoria>(() => lerMemoria(chave));

  async function recarregar() {
    try { setFoto(await lerFoto(administra, opera)); setErro(''); }
    catch (e) { setErro(mensagemDeErro(e)); }
  }
  useEffect(() => { setMem(lerMemoria(chave)); void recarregar(); /* eslint-disable-next-line */ }, [chave]);

  function mudar(m: Memoria) { setMem(m); gravarMemoria(chave, m); }

  if (!foto) {
    return <div className="wrap">{erro ? <Aviso tipo="erro">{erro}</Aviso> : <p className="vazio">Carregando…</p>}</div>;
  }

  const itens = situacao(foto);
  const prontos = itens.filter((i) => i.feito).length;

  return (
    <div className="wrap">
      <div className="cabeca">
        <div>
          <h1>Início</h1>
          <p>O assistente pergunta como você quer trabalhar, monta um plano e só faz o que você
             autorizar, um passo de cada vez. Chave de API nenhuma é digitada aqui: as contas se
             conectam em Configurações, e o assistente só escolhe entre as que já existem.</p>
        </div>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <Secao titulo="Onde você está" nota={`${prontos} de ${itens.length} prontos — lido agora do banco`} />
      <section className="indice">
        {itens.map((i) => (
          <div key={i.id} className="item" style={{ cursor: 'default' }}>
            <span className={`marca ${i.feito ? 'ok' : ''}`} aria-hidden="true">{i.feito ? '✓' : ''}</span>
            <span className="txt"><b>{i.titulo}</b><p>{i.detalhe}</p></span>
            <span className="cont">{i.feito ? 'pronto' : 'pendente'}</span>
          </div>
        ))}
      </section>

      <Conversa foto={foto} mem={mem} aoMudar={mudar} aoRecarregar={recarregar} aoNavegar={nav} />
    </div>
  );
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
      <Secao titulo="Assistente de configuração"
             nota={Object.keys(mem.respostas).length
               ? <button className="link" onClick={() => aoMudar(VAZIA)}>recomeçar a conversa</button>
               : 'leva uns dois minutos'} />
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
        <span className="num">{feito ? '✓' : n}</span>
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

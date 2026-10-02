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
 * - **O segredo não passa pelo assistente.** O que se digita num campo de
 *   chave vive no estado do cartão, vai para a mesma função que a tela do
 *   canal usa, e é apagado. O que fica guardado no navegador são as RESPOSTAS
 *   (canais, números, nomes de provedor) — nunca um valor de campo.
 */
import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  ajustarQuota, atribuirAgente, conectarConta, contarContatos, criarCampanhaDeModelo, descobrirCRM,
  lerAgentes, lerCampanhas, lerConexoesCRM, lerCredenciaisIA, lerModelos, lerProvedoresCRM,
  lerProvedoresCanal, lerProvedoresIA, lerRemetentes, salvarAgente, salvarCredencialCRM,
  salvarCredencialIA,
} from '../dados';
import {
  impedimento, legenda, montarPlano, roteiro, situacao, valida, voltarPara,
} from '../assistente';
import type { Acao, CampoDeCatalogo, Foto, Pergunta, Resposta, Respostas } from '../assistente';
import { Aviso, Campo, NOME_CANAL, Secao } from '../componentes/base';

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
             autorizar, um passo de cada vez. Chaves de acesso vão direto para o cofre (Vault):
             o assistente nunca as vê.</p>
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

const PLACEHOLDER: Record<string, string> = {
  whatsapp: '5511988880001', sms: '5511988880001', email: 'contato@suaempresa.com.br',
};

function Cartao({ n, acao: a, foto, mem, plano, aoMudar, aoRecarregar, aoNavegar }: {
  n: number; acao: Acao; foto: Foto; mem: Memoria; plano: readonly Acao[];
  aoMudar(m: Memoria): void; aoRecarregar(): Promise<void>; aoNavegar(rota: string): void;
}) {
  const { tenant } = useSessao();
  const [valores, setValores] = useState<Record<string, string>>({});
  const [base, setBase] = useState<{ apelido: string; identificador: string; quota: string; nome: string; modelo: string }>(() => ({
    apelido: '', identificador: '',
    quota: a.tipo === 'conectar_conta' ? String(a.quota) : '',
    nome: a.tipo === 'criar_campanha' ? a.nome
      : a.tipo === 'credencial_ia' ? `${foto.provedoresIA.find((p) => p.slug === a.provedor)?.nome ?? a.provedor} principal`
      : a.tipo === 'conectar_crm' ? (foto.provedoresCRM.find((p) => p.slug === a.provedor)?.nome ?? a.provedor)
      : '',
    modelo: a.tipo === 'credencial_ia' ? a.modelo : '',
  }));
  const [estado, setEstado] = useState<'parado' | 'executando'>('parado');
  const [falha, setFalha] = useState('');

  const feito = mem.feitos[a.id];
  const pulado = mem.pulados.includes(a.id);
  const impede = impedimento(foto, a);
  const esperando = a.dependeDe.filter((d) => !mem.feitos[d]);
  const nomeDe = (id: string) => plano.find((x) => x.id === id)?.titulo ?? id;

  const campos: readonly CampoDeCatalogo[] = 'campos' in a ? a.campos : [];
  const faltaCampo = campos.some((c) => c.obrigatorio && !valores[c.chave]?.trim())
    || (a.tipo === 'conectar_conta' && (!base.identificador.trim() || !(Number(base.quota) > 0)))
    || ((a.tipo === 'credencial_ia' || a.tipo === 'criar_campanha' || a.tipo === 'conectar_crm') && !base.nome.trim())
    || (a.tipo === 'credencial_ia' && !base.modelo.trim());

  async function executar(): Promise<{ texto: string; produziu?: string }> {
    const t = tenant?.tenant_id ?? '';
    switch (a.tipo) {
      case 'conectar_conta': {
        const p = foto.provedores.find((x) => x.slug === a.provedor)!;
        const quota = Number(base.quota);
        const id = await conectarConta({
          tenant: t, canal: a.canal, provedor: p, identificador: base.identificador.trim(),
          apelido: base.apelido.trim(), tipo: a.pool, quota, valores,
        });
        return { texto: `Conta ${base.apelido.trim() || base.identificador.trim()} conectada, até ${quota} por dia. A chave foi para o Vault.`, produziu: id };
      }
      case 'ajustar_quota':
        await ajustarQuota(a.remetente, a.para);
        return { texto: `Quota ajustada de ${a.de} para ${a.para} por dia.` };
      case 'credencial_ia': {
        const id = await salvarCredencialIA({
          tenant: t, nome: base.nome.trim(), provedor: a.provedor, modelo: base.modelo.trim(), campos: valores,
        });
        return { texto: `Chave guardada no Vault como "${base.nome.trim()}".`, produziu: id };
      }
      case 'conectar_crm': {
        const id = await salvarCredencialCRM({ tenant: t, nome: base.nome.trim(), provedor: a.provedor, campos: valores });
        if (!a.escreve) return { texto: 'Credencial guardada no Vault. Nenhum fato é escrito nesta plataforma até o adapter existir.', produziu: id };
        // Ler a estrutura já com a credencial nova é a melhor conferência de
        // que ela funciona — e é o que a tela de mapeamento precisa.
        const d = await descobrirCRM(id);
        return {
          texto: d.ok
            ? 'Credencial guardada e conferida: os pipes e campos já foram lidos. Falta escolher o que cada fato faz.'
            : `Credencial guardada, mas a leitura falhou: ${d.erro ?? 'erro desconhecido'}. Confira o acesso na tela da plataforma.`,
          produziu: id,
        };
      }
      case 'criar_campanha': {
        const r = await criarCampanhaDeModelo({ tenant: t, slug: a.modelo, nome: base.nome.trim(), canais: [...a.canais] });
        return { texto: `Campanha criada com ${r.passos_criados} passos.`, produziu: r.campaign_id };
      }
      case 'ligar_agentes': {
        const campanha = mem.produzidos.campanha!;
        const credencial = a.credencial ?? mem.produzidos.ia!;
        for (const x of a.agentes) await atribuirAgente(campanha, x.agente);
        // `atribuir_agente` cria a cópia do cliente; é nela que a credencial
        // entra, e o agente do catálogo continua intocado.
        const copias = (await lerAgentes()).filter((g) => g.tenant_id !== null);
        for (const x of a.agentes) {
          const c = copias.find((g) => g.nome === x.nome);
          if (!c) throw new Error(`o agente ${x.nome} não apareceu para o cliente depois de atribuído`);
          await salvarAgente(c.id, {
            instrucoes: c.instrucoes, escalar_quando: c.escalar_quando, limite_trocas: c.limite_trocas,
            tamanho_maximo: c.tamanho_maximo, proibido: c.proibido, ativo: c.ativo, ai_credential_id: credencial,
          });
        }
        return { texto: `${a.agentes.map((x) => x.nome).join(' e ')} ${a.agentes.length > 1 ? 'passam' : 'passa'} a escrever rascunhos com a sua chave.` };
      }
      case 'importar':
        aoNavegar('/contatos/importar');
        return { texto: 'Importação aberta.' };
    }
  }

  async function autorizar() {
    setFalha(''); setEstado('executando');
    try {
      const r = await executar();
      // O segredo sai do estado assim que a função o recebeu.
      setValores({});
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

  return (
    <div className={`painel cartao ${feito ? 'feito' : pulado ? 'pulado' : ''}`}>
      <div className="cartao-cabeca">
        <span className="num">{feito ? '✓' : n}</span>
        <b>{a.titulo}</b>
        <span className="chip">{feito ? 'feito' : pulado ? 'pulado' : a.exige === 'administra' ? 'admin' : 'operação'}</span>
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
          <p className="se">Se você autorizar:</p>
          <ul className="efeitos">{a.efeitos.map((e) => <li key={e}>{e}</li>)}</ul>

          {a.tipo === 'conectar_conta' && (
            <>
              <Campo id={`${a.id}-apelido`} rotulo="Apelido da conta" valor={base.apelido}
                     aoMudar={(v) => setBase({ ...base, apelido: v })} placeholder="Comercial SP"
                     obrigatorio={false} ajuda="Um número não diz de quem é. O apelido diz." />
              <Campo id={`${a.id}-ident`} rotulo={a.canal === 'email' ? 'Endereço de envio' : 'Número'} mono
                     valor={base.identificador} aoMudar={(v) => setBase({ ...base, identificador: v })}
                     placeholder={PLACEHOLDER[a.canal]} />
              <Campo id={`${a.id}-quota`} rotulo="Mensagens por dia nesta conta" mono valor={base.quota}
                     aoMudar={(v) => setBase({ ...base, quota: v.replace(/\D/g, '') })}
                     ajuda="O banco recusa enviar além disso, mesmo que a campanha peça." />
            </>
          )}
          {(a.tipo === 'credencial_ia' || a.tipo === 'conectar_crm' || a.tipo === 'criar_campanha') && (
            <Campo id={`${a.id}-nome`} rotulo={a.tipo === 'criar_campanha' ? 'Nome da campanha' : 'Nome da conexão'}
                   valor={base.nome} aoMudar={(v) => setBase({ ...base, nome: v })} />
          )}
          {a.tipo === 'credencial_ia' && (
            <div className="campo">
              <label htmlFor={`${a.id}-modelo`}>Modelo</label>
              <input id={`${a.id}-modelo`} list={`${a.id}-modelos`} value={base.modelo}
                     onChange={(e) => setBase({ ...base, modelo: e.target.value })} placeholder="nome do modelo" />
              <datalist id={`${a.id}-modelos`}>{a.modelos.map((m) => <option key={m} value={m} />)}</datalist>
            </div>
          )}
          {campos.map((c) => (
            <Campo key={c.chave} id={`${a.id}-${c.chave}`} rotulo={c.rotulo} tipo={c.tipo}
                   valor={valores[c.chave] ?? ''} obrigatorio={c.obrigatorio} ajuda={c.ajuda}
                   aoMudar={(v) => setValores({ ...valores, [c.chave]: v })}
                   vault={c.segredo ? 'Vai direto para o Vault — nem o assistente nem esta tela conseguem lê-lo de volta.' : undefined} />
          ))}

          {impede && <Aviso tipo="neutro">Não dá por aqui: {impede}.</Aviso>}
          {!impede && esperando.length > 0 && (
            <Aviso tipo="neutro">Espera antes: {esperando.map(nomeDe).join(' e ')}.</Aviso>
          )}
          {falha && <Aviso tipo="erro">{falha}</Aviso>}

          <div className="acoes-cartao">
            <button className="btn prim" onClick={autorizar}
                    disabled={!!impede || esperando.length > 0 || faltaCampo || estado === 'executando'}>
              {estado === 'executando' ? 'Fazendo…' : a.tipo === 'importar' ? 'Abrir a importação' : 'Autorizar'}
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

/** Para onde ir depois de um passo feito: o que o assistente não faz por você. */
function linkDepois(a: Acao, mem: Memoria): { rota: string; rotulo: string } | null {
  const id = mem.produzidos[a.id];
  switch (a.tipo) {
    case 'conectar_conta':
      return a.canal === 'email'
        ? { rota: '/config/email', rotulo: 'Verificar a conexão' }
        : { rota: `/canais/${a.canal}`, rotulo: `Ver a conta e o webhook em ${NOME_CANAL[a.canal]}` };
    case 'conectar_crm':
      return a.escreve && id ? { rota: `/config/vinculadas/${id}`, rotulo: 'Escolher o que cada fato faz' } : null;
    case 'criar_campanha':
      return id ? { rota: `/campanhas/${id}`, rotulo: 'Abrir a campanha' } : null;
    case 'ligar_agentes':
      return { rota: '/config/agentes', rotulo: 'Ajustar o que o agente diz' };
    default:
      return null;
  }
}

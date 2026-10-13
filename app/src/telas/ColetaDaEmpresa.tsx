// "Colher também de" (D78b): site, Instagram e materiais viram um RASCUNHO de
// "Sobre a empresa e a oferta", no construtor de agentes.
//
// O que a tela diz em voz alta, porque é o que a pessoa não veria sozinha:
// cada fonte que não foi lida, e por quê; que o Instagram não se lê por robô;
// que nada entra no agente sem ela clicar; e que número no texto vira número
// que o agente pode dizer (o freio confere o que ele escreve contra este
// texto). A lógica é `../coleta.ts`, pura e testada; quem confere arquivo e
// endereço é `@adapters/coleta.ts`, o mesmo da edge function.

import { useRef, useState } from 'react';
import { mensagemDeErro } from '../supabase';
import { lerEmpresa } from '../dados';
import type { CredencialIA, ProvedorIA, ResultadoDaColeta } from '../dados';
import { Aviso, Campo } from '../componentes/base';
import { ACEITA, ACEITA_IMAGEM, CABECA, FORMATOS, MAX_ARQUIVOS, TETO_TOTAL, emMb } from '@adapters/coleta.ts';
import { leAnexos } from '@adapters/ia-leitura.ts';
import {
  COLETA_VAZIA, FONTES_DA_COLETA, alternar, aplicarRascunho, contaPadraoDaLeitura,
  oQueFaltaNaColeta, pedidoDaColeta, podeAnexar,
} from '../coleta';
import type { Anexo, EstadoDaColeta } from '../coleta';

function base64DoArquivo(f: File): Promise<string> {
  return new Promise((ok, falha) => {
    const r = new FileReader();
    r.onload = () => { const url = String(r.result); ok(url.slice(url.indexOf(',') + 1)); };
    r.onerror = () => falha(r.error ?? new Error('não foi possível ler o arquivo'));
    r.readAsDataURL(f);
  });
}

const NOME_DO_TIPO: Record<Anexo['tipo'], string> = { pdf: 'PDF', imagem: 'imagem', html: 'HTML', texto: 'TXT' };

const TETOS_EM_PALAVRAS = [...new Map(FORMATOS.map((f) => [f.tipo, f])).values()]
  .map((f) => `${f.tipo === 'imagem' ? 'imagem' : f.nome} até ${emMb(f.teto)}`).join(', ');

export function ColetaDaEmpresa({ contexto, aoUsar, contas, provedores, contaDoAgente, administra, opera, empresa }: {
  contexto: string;
  aoUsar(texto: string): void;
  contas: CredencialIA[];
  provedores: ProvedorIA[];
  /** A de "Compõe com": a leitura começa por ela, se ela serve. */
  contaDoAgente: string;
  administra: boolean;
  opera: boolean;
  empresa: string;
}) {
  const temAdapter = (p: string) => !!provedores.find((x) => x.slug === p)?.tem_adapter;
  const servem = contas.filter((c) => c.ativo && temAdapter(c.provedor));
  const [e, setE] = useState<EstadoDaColeta>(COLETA_VAZIA);
  const [contaId, setContaId] = useState(() => contaPadraoDaLeitura(contas, temAdapter, contaDoAgente || null)?.id ?? '');
  const [lendo, setLendo] = useState(false);
  // O resultado leva o nome da conta que LEU: trocar o select depois não muda a quem o texto é atribuído.
  const [res, setRes] = useState<(ResultadoDaColeta & { lidoCom: string }) | null>(null);
  // Arquivos sendo lidos do disco: enquanto houver, "Ler" esperaria um pedido sem eles.
  const [anexando, setAnexando] = useState(0);
  const [erro, setErro] = useState('');
  const [recusas, setRecusas] = useState<string[]>([]);
  // O texto de antes e o que o rascunho deixou: "Desfazer" só enquanto o
  // campo continua como o rascunho deixou — depois disso, desfazer apagaria o
  // que a pessoa escreveu em cima.
  const [desfazer, setDesfazer] = useState<{ antes: string; depois: string } | null>(null);
  // O que os materiais divergem continua à vista DEPOIS de usar — é aí que a
  // pessoa escreve a versão certa —, até ela dispensar.
  const [divergencia, setDivergencia] = useState('');
  // Um clique, uma leitura: a trava é ref, não estado (D73) — cada leitura
  // gasta a conta de IA do cliente.
  const emCurso = useRef(false);
  const entradaMateriais = useRef<HTMLInputElement>(null);
  const entradaPrints = useRef<HTMLInputElement>(null);

  if (!opera) return null;
  if (!administra) {
    return (
      <p className="nota-tela">Colher este texto do site, do Instagram ou de materiais usa a conta de IA do cliente,
        que só quem administra escolhe.</p>
    );
  }

  const conta = servem.find((c) => c.id === contaId) ?? null;
  const falta = oQueFaltaNaColeta(e, conta?.provedor ?? null);
  const mudar = (n: Partial<EstadoDaColeta>) => { setE((x) => ({ ...x, ...n })); setErro(''); };

  async function anexar(lista: FileList | null, origem: Anexo['origem']) {
    if (!lista?.length) return;
    setRecusas([]);
    setAnexando((n) => n + 1);
    const novos: Anexo[] = [];
    const recusados: string[] = [];
    try {
      for (const f of Array.from(lista)) {
        const cabeca = new Uint8Array(await f.slice(0, CABECA).arrayBuffer());
        // Os que acabaram de entrar contam para o próximo: dez de uma vez não passam do teto juntos.
        const pode = podeAnexar({ ...e, anexos: [...e.anexos, ...novos] }, { nome: f.name, tamanho: f.size, cabeca }, origem);
        if (!pode.ok) { recusados.push(pode.motivo); continue; }
        try {
          novos.push({ id: crypto.randomUUID(), nome: f.name, tamanho: f.size, tipo: pode.tipo, origem, base64: await base64DoArquivo(f) });
        } catch (x) {
          recusados.push(`"${f.name}": ${mensagemDeErro(x)}`);
        }
      }
      setE((x) => ({ ...x, anexos: [...x.anexos, ...novos] }));
      // Somando: duas escolhas de arquivo seguidas não apagam a recusa uma da outra.
      if (recusados.length) setRecusas((r) => [...r, ...recusados]);
    } finally {
      setAnexando((n) => n - 1);
    }
  }

  function tirar(id: string) {
    setE((x) => ({ ...x, anexos: x.anexos.filter((a) => a.id !== id) }));
    setRecusas([]);
  }

  async function ler() {
    if (!conta || falta.length || anexando || emCurso.current) return;
    emCurso.current = true;
    setLendo(true); setErro(''); setRes(null); setDivergencia('');
    try { setRes({ ...await lerEmpresa(pedidoDaColeta(e, conta.id, empresa)), lidoCom: conta.nome }); }
    catch (x) { setErro(mensagemDeErro(x)); }
    finally { setLendo(false); emCurso.current = false; }
  }

  function usar(modo: 'usar' | 'acrescentar') {
    if (!res?.texto) return;
    const r = aplicarRascunho(contexto, res.texto, modo);
    if (!r.ok) { setErro(r.motivo); return; }
    setDesfazer({ antes: contexto, depois: r.texto });
    setDivergencia(res.conferir ?? '');
    aoUsar(r.texto);
    setRes(null); setErro('');
  }

  const listaDeAnexos = (origem: Anexo['origem']) => {
    const daqui = e.anexos.filter((a) => a.origem === origem);
    return daqui.length > 0 && (
      <ul className="lista-anexos">
        {daqui.map((a) => (
          <li key={a.id}>
            <span className="mono">{a.nome}</span>
            <span className="nota-tela">{NOME_DO_TIPO[a.tipo]} · {emMb(a.tamanho)}</span>
            <button className="link" type="button" disabled={lendo} aria-label={`tirar ${a.nome}`} onClick={() => tirar(a.id)}>tirar</button>
          </li>
        ))}
      </ul>
    );
  };

  return (
    <div className="coleta">
      <div className="campo">
        <label id="col-rotulo">Colher também de</label>
        <div className="opcoes-chat" role="group" aria-labelledby="col-rotulo">
          {FONTES_DA_COLETA.map((f) => (
            <button key={f.slug} type="button" className="opcao-chat" aria-pressed={e.marcadas.has(f.slug)}
                    disabled={lendo} onClick={() => { setE((x) => alternar(x, f.slug)); setRecusas([]); }}>
              {f.nome}</button>
          ))}
        </div>
        <span className="ajuda">Marque uma ou mais. O que for lido vira um rascunho deste texto, para você conferir
          antes de usar — nada entra no agente sem o seu clique.</span>
      </div>

      {e.marcadas.size > 0 && (
        <>
          {e.marcadas.has('site') && (
            <Campo id="col-site" rotulo="Endereço do site" valor={e.site} placeholder="www.suaempresa.com.br"
                   aoMudar={(v) => mudar({ site: v })} desabilitado={lendo}
                   ajuda="Lemos a página e até 3 do mesmo site que ela liga — sobre, produtos e planos, contato. Site que monta o conteúdo no navegador chega quase vazio, e a leitura diz quando for o caso." />
          )}

          {e.marcadas.has('instagram') && (
            <>
              <Campo id="col-ig" rotulo="Perfil no Instagram" valor={e.handle} placeholder="@suaempresa" obrigatorio={false}
                     aoMudar={(v) => mudar({ handle: v })} desabilitado={lendo}
                     ajuda="O @ entra no texto como contato da empresa." />
              <div className="campo">
                <label htmlFor="col-ig-texto">O que o perfil diz <span style={{ color: 'var(--ink-3)', fontWeight: 400 }}>(opcional)</span></label>
                <textarea id="col-ig-texto" rows={3} value={e.perfil} disabled={lendo}
                          onChange={(ev) => mudar({ perfil: ev.target.value })}
                          placeholder="Cole aqui a bio e as legendas que dizem o que a empresa oferece." />
                <span className="ajuda">O Instagram não deixa ler perfil por robô — os termos dele proíbem a coleta
                  automática, com ou sem login. Por isso o perfil entra pelo que você cola aqui e pelos prints.</span>
              </div>
              <input ref={entradaPrints} type="file" accept={ACEITA_IMAGEM} multiple style={{ display: 'none' }}
                     onChange={(ev) => { void anexar(ev.target.files, 'instagram'); ev.target.value = ''; }} />
              <button className="btn mini" type="button" disabled={lendo || anexando > 0} onClick={() => entradaPrints.current?.click()}>
                Anexar prints do perfil</button>
              {listaDeAnexos('instagram')}
            </>
          )}

          {e.marcadas.has('materiais') && (
            <div className="campo" style={{ marginTop: 12 }}>
              <label htmlFor="col-materiais">Materiais</label>
              <input id="col-materiais" ref={entradaMateriais} type="file" accept={ACEITA} multiple style={{ display: 'none' }}
                     onChange={(ev) => { void anexar(ev.target.files, 'material'); ev.target.value = ''; }} />
              <div>
                <button className="btn mini" type="button" disabled={lendo || anexando > 0}
                        onClick={() => entradaMateriais.current?.click()}>Anexar arquivos</button>
              </div>
              {listaDeAnexos('material')}
              <span className="ajuda">PDF, JPG, PNG, HTML ou TXT — catálogo, apresentação, tabela de planos. Até{' '}
                {MAX_ARQUIVOS} arquivos e {emMb(TETO_TOTAL)} por leitura ({TETOS_EM_PALAVRAS}). Os arquivos não são
                guardados: vão ao modelo da conta escolhida e só o texto que você usar fica no agente.</span>
            </div>
          )}

          {recusas.length > 0 && <Aviso tipo="erro">Não entrou: {recusas.join('; ')}.</Aviso>}

          <div className="campo" style={{ marginTop: 4 }}>
            <label htmlFor="col-conta">Lê com</label>
            {servem.length ? (
              <select id="col-conta" value={contaId} disabled={lendo} onChange={(ev) => setContaId(ev.target.value)}>
                {!conta && <option value="">escolha a conta de IA</option>}
                {servem.map((c) => (
                  <option key={c.id} value={c.id}>{c.nome} · {c.provedor} · {c.modelo}
                    {leAnexos(c.provedor) ? '' : ' · só texto (não lê PDF nem imagem)'}</option>
                ))}
              </select>
            ) : (
              <span className="ajuda">Nenhuma conta de IA ligada que componha. Conecte uma em Configurações ▸
                Provedores de IA.</span>
            )}
            <span className="ajuda">Gasta a conta de IA deste cliente, por leitura. PDF longo gasta muito: prefira o
              catálogo e a apresentação ao contrato inteiro.</span>
          </div>

          {falta.length > 0 && <p className="nota-tela">Para ler, falta: {falta.join('; ')}.</p>}
          <button className="btn" type="button" disabled={lendo || anexando > 0 || falta.length > 0 || !conta} onClick={() => void ler()}>
            {lendo ? 'Lendo…' : anexando > 0 ? 'Anexando…' : 'Ler e escrever o rascunho'}</button>
          {lendo && <p className="nota-tela">Um site e alguns arquivos levam de alguns segundos a um minuto.</p>}
        </>
      )}

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {res && (
        <div className="coleta-resultado">
          {res.fontes.length > 0 && (
            <ul className="lista-fontes">
              {res.fontes.map((f, i) => (
                <li key={i}>
                  <span className={`chip ${f.lida ? 'ok' : 'erro'}`}>{f.lida ? 'lido' : 'não lido'}</span>
                  <span><b>{f.apelido ? `${f.apelido} · ` : ''}{f.rotulo}</b> — {f.detalhe}</span>
                </li>
              ))}
            </ul>
          )}
          {res.situacao === 'pronto' && res.texto ? (
            <>
              <div className="balao-teste">
                <b>Rascunho de "Sobre a empresa e a oferta"</b>
                <p>{res.texto}</p>
                <span className="nota-tela">{res.texto.length.toLocaleString('pt-BR')} caracteres · lido com {res.lidoCom} ({res.modelo})</span>
              </div>
              {res.conferir && (
                <Aviso tipo="neutro"><b>Os materiais divergem — nada disto foi para o rascunho:</b>
                  <span className="conferir">{res.conferir}</span>
                  Se a condição vale, escreva a versão certa no texto antes de salvar o agente.</Aviso>
              )}
              <Aviso tipo="neutro">Confira antes de usar, principalmente os números: preço, carência e prazo que
                estiverem neste texto o agente passa a poder dizer, porque o freio confere o que ele escreve contra o que
                está aqui. Número errado se corrige no texto acima, antes de salvar o agente.</Aviso>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <button className="btn prim" type="button" onClick={() => usar('usar')}>
                  {contexto.trim() ? 'Usar no lugar do texto' : 'Usar este texto'}</button>
                {contexto.trim() && <button className="btn" type="button" onClick={() => usar('acrescentar')}>Acrescentar ao texto</button>}
                <button className="btn" type="button" onClick={() => { setRes(null); setErro(''); }}>Descartar</button>
              </div>
            </>
          ) : (
            <Aviso tipo={res.situacao === 'erro' ? 'erro' : 'neutro'}>
              {res.situacao === 'erro' ? 'A leitura não deu: ' : ''}{res.motivo}</Aviso>
          )}
        </div>
      )}

      {divergencia && !res && (
        <Aviso tipo="neutro"><b>Para conferir antes de salvar — os materiais divergem, e nada disto está no texto:</b>
          <span className="conferir">{divergencia}</span>
          <button className="link" type="button" onClick={() => setDivergencia('')}>Dispensar</button></Aviso>
      )}
      {desfazer && !res && contexto === desfazer.depois && (
        <Aviso tipo="ok">O rascunho foi para o texto acima — ele só fica no agente quando você salvar.{' '}
          <button className="link" type="button" onClick={() => { aoUsar(desfazer.antes); setDesfazer(null); setDivergencia(''); }}>Desfazer</button></Aviso>
      )}
    </div>
  );
}

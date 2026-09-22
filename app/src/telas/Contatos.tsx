/** Contatos e inscrição em campanha (D35).
 *
 * Duas coisas na mesma tela porque são um gesto só: escolher quem, e depois
 * onde. Separar em duas telas obrigaria a repetir a seleção.
 *
 * A inscrição tem prévia pela mesma razão que a importação, mas o risco aqui
 * é pior, porque é silencioso. Inscrever alguém sem identidade no canal dos
 * passos **não dá erro**: o roteador pula passo a passo e encerra em
 * `fim_dos_passos`, e o relatório mostra "campanha concluída" para quem nunca
 * recebeu nada. `prever_inscricao` é o que transforma isso num número na tela
 * antes de gravar.
 */
import { useEffect, useMemo, useState } from 'react';
import { useSessao } from '../sessao';
import { Aviso, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import {
  inscrever, lerCampanhas, lerContatos, lerVersoesDeFlow, preverInscricao,
} from '../dados';
import type { Campanha, Contato, ContatoPrevisto, VersaoDeFlow } from '../dados';
import { mensagemDeErro } from '../supabase';

export function Contatos() {
  const { tenant, opera } = useSessao();

  const [busca, setBusca] = useState('');
  const [contatos, setContatos] = useState<Contato[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [escolhidos, setEscolhidos] = useState<Set<string>>(new Set());
  const [erro, setErro] = useState('');

  async function recarregar(termo: string) {
    setCarregando(true); setErro('');
    try { setContatos(await lerContatos(termo)); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  // Busca com espera: teclar não pode virar uma consulta por letra.
  useEffect(() => {
    const t = setTimeout(() => { void recarregar(busca); }, 250);
    return () => clearTimeout(t);
  }, [busca]);

  const visiveis = contatos.map((c) => c.id);
  const todosMarcados = visiveis.length > 0 && visiveis.every((id) => escolhidos.has(id));

  function alternar(id: string) {
    setEscolhidos((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id); else n.add(id);
      return n;
    });
  }

  return (
    <>
      <Secao titulo="Contatos"
             nota={carregando ? 'carregando…' : `${contatos.length} na lista`} />

      <div className="painel">
        <input
          className="busca" type="search" value={busca}
          placeholder="Nome, telefone ou e-mail"
          onChange={(e) => setBusca(e.target.value)}
        />
        <p style={{ color: 'var(--ink-3)', fontSize: 12, margin: '8px 0 0' }}>
          O telefone pode ser digitado como está na planilha — a busca compara
          só os dígitos.
        </p>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {!carregando && contatos.length === 0 && (
        <div className="painel">
          <p className="vazio" style={{ margin: 0 }}>
            {busca ? 'Nada com esse termo.' : 'Nenhum contato ainda — comece pela importação.'}
          </p>
        </div>
      )}

      {contatos.length > 0 && (
        <div className="painel">
          <table className="tab">
            <thead>
              <tr>
                <th style={{ width: 28 }}>
                  <input
                    type="checkbox" checked={todosMarcados} aria-label="marcar todos"
                    onChange={() => setEscolhidos(todosMarcados ? new Set() : new Set(visiveis))}
                  />
                </th>
                <th>Nome</th>
                <th>Como falar</th>
                <th>Origem</th>
              </tr>
            </thead>
            <tbody>
              {contatos.map((c) => (
                <tr key={c.id}>
                  <td>
                    <input
                      type="checkbox" checked={escolhidos.has(c.id)}
                      aria-label={`marcar ${c.nome ?? c.id}`}
                      onChange={() => alternar(c.id)}
                    />
                  </td>
                  <td style={{ color: 'var(--ink)' }}>{c.nome ?? <i>(sem nome)</i>}</td>
                  <td><Identidades lista={c.contact_identities} /></td>
                  <td>{c.origem}{c.origem_ref ? ` · ${c.origem_ref}` : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {opera && escolhidos.size > 0 && tenant && (
        <Inscricao
          tenant={tenant.tenant_id}
          contatos={[...escolhidos]}
          aoTerminar={() => { setEscolhidos(new Set()); void recarregar(busca); }}
        />
      )}
    </>
  );
}

function Identidades({ lista }: { lista: Contato['contact_identities'] }) {
  if (!lista.length) return <i style={{ color: 'var(--ink-3)' }}>nenhuma</i>;
  return (
    <span style={{ display: 'inline-flex', gap: 6, flexWrap: 'wrap' }}>
      {lista.map((i) => (
        <span
          key={`${i.canal}-${i.valor_norm}`}
          className="chip"
          // Identidade inválida continua visível: some do envio, não da tela.
          // Escondê-la faria a pessoa procurar por que o contato não recebeu.
          style={{ textDecoration: i.valida ? undefined : 'line-through' }}
          title={i.valida ? undefined : 'marcada inválida'}
        >
          {/* O canal vai escrito, não só na cor: o mesmo número entra em
              whatsapp e em sms, e dois chips de texto idêntico só confundem. */}
          <b style={{ color: i.valida ? corCanal(i.canal) : 'var(--ink-3)', fontWeight: 600 }}>
            {NOME_CANAL[i.canal] ?? i.canal}
          </b>
          <span className="mono" style={{ marginLeft: 5 }}>{i.valor}</span>
        </span>
      ))}
    </span>
  );
}

type Passo = 'escolher' | 'previsto' | 'gravando' | 'pronto';

function Inscricao({ tenant, contatos, aoTerminar }: {
  tenant: string; contatos: string[]; aoTerminar(): void;
}) {
  const [campanhas, setCampanhas] = useState<Campanha[]>([]);
  const [versoes, setVersoes] = useState<VersaoDeFlow[]>([]);
  const [campanha, setCampanha] = useState('');
  const [versao, setVersao] = useState('');
  const [passo, setPasso] = useState<Passo>('escolher');
  const [previsao, setPrevisao] = useState<ContatoPrevisto[]>([]);
  const [feitos, setFeitos] = useState(0);
  const [resultado, setResultado] = useState<{ ok: number; nulos: number; falhas: string[] } | null>(null);
  const [erro, setErro] = useState('');

  useEffect(() => {
    Promise.all([lerCampanhas(), lerVersoesDeFlow()])
      .then(([c, v]) => { setCampanhas(c.filter((x) => x.ativa)); setVersoes(v); })
      .catch((e) => setErro(mensagemDeErro(e)));
  }, []);

  const campanhaAtual = campanhas.find((c) => c.id === campanha);
  const versaoAtual = versoes.find((v) => v.id === versao);

  // O aviso mais útil da tela, e ele aparece antes de qualquer chamada: um
  // flow cujos canais não estão habilitados na campanha não manda nada.
  const canaisUteis = useMemo(() => {
    if (!campanhaAtual || !versaoAtual) return null;
    return versaoAtual.canais.filter((c) => campanhaAtual.canais_habilitados.includes(c));
  }, [campanhaAtual, versaoAtual]);

  async function prever() {
    setErro('');
    try {
      setPrevisao(await preverInscricao({ tenant, campanha, versao, contatos }));
      setPasso('previsto');
    } catch (e) { setErro(mensagemDeErro(e)); }
  }

  async function gravar() {
    setErro(''); setPasso('gravando'); setFeitos(0);
    const r = { ok: 0, nulos: 0, falhas: [] as string[] };
    const entram = previsao.filter((p) => p.acao === 'inscrever');

    for (const p of entram) {
      try {
        const id = await inscrever({ contato: p.contact_id, campanha, versao });
        if (id) r.ok += 1; else r.nulos += 1;
      } catch (e) {
        r.falhas.push(`${comoChamar(p)}: ${mensagemDeErro(e)}`);
      }
      setFeitos((n) => n + 1);
    }

    setResultado(r); setPasso('pronto');
  }

  const conta = (a: ContatoPrevisto['acao']) => previsao.filter((p) => p.acao === a).length;
  const entram = conta('inscrever');

  return (
    <>
      <Secao titulo={`Inscrever ${contatos.length} ${contatos.length === 1 ? 'contato' : 'contatos'}`}
             nota="Nada é gravado antes da conferência." />

      <div className="painel">
        <div className="campo">
          <label htmlFor="i-camp">Campanha</label>
          <select id="i-camp" value={campanha}
                  onChange={(e) => { setCampanha(e.target.value); setPasso('escolher'); }}>
            <option value="">escolha…</option>
            {campanhas.map((c) => (
              <option key={c.id} value={c.id}>
                {c.nome} · {c.tipo} · {c.canais_habilitados.join(', ')}
              </option>
            ))}
          </select>
        </div>

        <div className="campo">
          <label htmlFor="i-fv">Versão de flow</label>
          <select id="i-fv" value={versao}
                  onChange={(e) => { setVersao(e.target.value); setPasso('escolher'); }}>
            <option value="">escolha…</option>
            {versoes.map((v) => (
              <option key={v.id} value={v.id}>
                {v.flow_nome} · v{v.versao} · {v.passos} passos · {v.canais.join(', ')}
              </option>
            ))}
          </select>
          {/* O schema não liga campanha a flow — a dupla só existe dentro de
              `enrollments`. Por isso as duas escolhas são independentes, e por
              isso o canal aparece no rótulo das duas. */}
          <span className="ajuda">
            Campanha e flow são escolhidos separadamente: o schema não guarda
            essa ligação, ela nasce na inscrição.
          </span>
        </div>

        {canaisUteis?.length === 0 && (
          <Aviso tipo="erro">
            Nenhum passo deste flow usa um canal habilitado na campanha
            ({campanhaAtual?.canais_habilitados.join(', ')}). Inscrever não
            daria erro — o motor percorreria todos os passos e encerraria como
            concluído, sem mandar nada para ninguém.
          </Aviso>
        )}

        {campanha && versao && passo === 'escolher' && (
          <button className="btn prim" onClick={() => void prever()}>
            Conferir quem entraria
          </button>
        )}
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {previsao.length > 0 && passo !== 'gravando' && (
        <>
          <div className="kpis">
            <Kpi rotulo="Entram" valor={entram} sub="serão inscritos" />
            <Kpi rotulo="Já inscritos" valor={conta('ja_inscrito')} sub="nesta campanha" />
            <Kpi rotulo="Sem canal" valor={conta('sem_canal')} sub="não receberiam nada" />
            <Kpi rotulo="Suprimidos" valor={conta('suprimido')} sub="não podem receber" />
          </div>

          {conta('sem_canal') > 0 && (
            <Aviso tipo="erro">
              Quem está em <b>sem canal</b> seria inscrito sem erro nenhum e
              encerraria como concluído sem receber uma mensagem sequer. Não
              entra.
            </Aviso>
          )}

          <Fora previsao={previsao} />

          {passo === 'previsto' && (
            <button className="btn prim" disabled={entram === 0} onClick={() => void gravar()}>
              Inscrever {entram}
            </button>
          )}
        </>
      )}

      {passo === 'gravando' && (
        <Aviso tipo="neutro">Inscrevendo… {feitos} de {entram}.</Aviso>
      )}

      {passo === 'pronto' && resultado && (
        <>
          <Aviso tipo={resultado.falhas.length ? 'erro' : 'ok'}>
            {resultado.ok} inscritos.
            {resultado.nulos > 0 && ` ${resultado.nulos} devolveram nulo (supressão entre a prévia e a gravação).`}
            {resultado.falhas.length > 0 && ` ${resultado.falhas.length} falharam.`}
          </Aviso>
          {resultado.falhas.length > 0 && (
            <div className="painel">
              <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12.5, color: 'var(--ink-2)' }}>
                {resultado.falhas.map((f, i) => <li key={i}>{f}</li>)}
              </ul>
            </div>
          )}
          <button className="btn" onClick={aoTerminar}>Voltar à lista</button>
        </>
      )}
    </>
  );
}

/** O nome que a pessoa vê. Uuid cru na tela não ajuda ninguém a decidir. */
const comoChamar = (p: ContatoPrevisto) => p.nome ?? '(sem nome)';

const SITUACAO: Record<ContatoPrevisto['acao'], string> = {
  inscrever: 'entra',
  ja_inscrito: 'já inscrito',
  suprimido: 'suprimido',
  sem_canal: 'sem canal',
  desconhecido: 'desconhecido',
};

/** Quem não entra, e por quê. É o que a pessoa precisa ler antes de decidir. */
function Fora({ previsao }: { previsao: ContatoPrevisto[] }) {
  const fora = previsao.filter((p) => p.acao !== 'inscrever');
  if (!fora.length) return null;
  return (
    <div className="painel">
      <b>Quem fica de fora</b>
      <table className="tab">
        <thead><tr><th>Quem</th><th>Situação</th><th>Por quê</th></tr></thead>
        <tbody>
          {fora.slice(0, 50).map((p) => (
            <tr key={p.contact_id}>
              <td style={{ color: 'var(--ink)' }}>{comoChamar(p)}</td>
              <td>{SITUACAO[p.acao]}</td>
              <td>{p.problema}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {fora.length > 50 && (
        <p style={{ color: 'var(--ink-3)', fontSize: 12, marginBottom: 0 }}>
          e mais {fora.length - 50}.
        </p>
      )}
    </div>
  );
}

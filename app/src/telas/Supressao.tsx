/** Supressão: quem não pode receber nada (D41).
 *
 * A invariante 2 inteira se apoia nesta tabela, e o D39 e o D40 a tornaram
 * autoritativa até no despacho — mas **não havia como pôr ninguém nela** a não
 * ser escrevendo SQL à mão. É o mesmo buraco que o D32 encontrou na ingestão:
 * a garantia existia, a porta de entrada não.
 *
 * Três formas de suprimir, porque são três situações reais:
 *
 *  - **Um endereço** — a pessoa disse "pare" por telefone, e o operador
 *    registra o número. Vale mesmo que o contato ainda não exista na base:
 *    `esta_suprimido` casa por `(canal, valor_norm)`.
 *  - **Uma lista** — o caso do primeiro dia: a lista de opt-out que já existia
 *    antes do motor. Passa pelo mesmo `PlanilhaSource` da importação, porque
 *    normalizar em outro lugar é como a supressão fica furada (D32).
 *
 * A terceira — suprimir **o contato inteiro**, em todo canal — mora na linha da
 * pessoa, na tela de contatos: é lá que se está olhando para ela, e um seletor
 * de contato aqui seria a mesma decisão tomada com menos informação à vista.
 *
 * Não há remover, e não é esquecimento: a tabela é imutável por gatilho.
 */
import { useEffect, useRef, useState } from 'react';
import { PlanilhaSource } from '@adapters/planilha.ts';
import { normalizarTelefone, telefoneValido } from '@adapters/telefone.ts';
import { emailValido, normalizarEmail } from '@adapters/email.ts';
import { useSessao } from '../sessao';
import { Aviso, Campo, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import { lerSupressoes, suprimirEndereco } from '../dados';
import type { Supressao as Sup } from '../dados';
import { mensagemDeErro } from '../supabase';

export function Supressao() {
  const { tenant, opera } = useSessao();
  const [lista, setLista] = useState<Sup[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');

  async function recarregar() {
    setErro('');
    try { setLista(await lerSupressoes()); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  const porEndereco = lista.filter((s) => s.canal).length;
  const porContato = lista.length - porEndereco;

  return (
    <>
      <Secao titulo="Supressão"
             nota="Quem está aqui não recebe nada, por nenhum caminho." />

      <div className="kpis">
        <Kpi rotulo="Endereços" valor={porEndereco} sub="número ou e-mail específico" />
        <Kpi rotulo="Contatos" valor={porContato} sub="a pessoa toda, em todo canal" />
      </div>

      <Aviso tipo="neutro">
        Esta lista é <b>imutável</b>: não dá para editar nem remover, nem por aqui
        nem pelo banco — o gatilho recusa. Tirar alguém daqui seria voltar a falar
        com quem pediu para parar, e isso não é operação de tela. A supressão vale
        acima de qualquer regra da campanha, e vale também para a mensagem que já
        estava na fila esperando envio.
      </Aviso>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {opera && tenant && (
        <Adicionar tenant={tenant.tenant_id} aoGravar={recarregar} />
      )}

      <Secao titulo="Quem está na lista"
             nota={carregando ? 'carregando…' : `${lista.length} no total`} />

      {!carregando && lista.length === 0 ? (
        <div className="painel">
          <p className="vazio" style={{ margin: 0 }}>
            Ninguém ainda. Se você tem uma lista de opt-out de antes do motor,
            importe-a agora — antes da primeira campanha, não depois.
          </p>
        </div>
      ) : (
        <div className="painel">
          <table className="tab">
            <thead><tr><th>Quando</th><th>Quem</th><th>Alcance</th><th>Motivo</th></tr></thead>
            <tbody>
              {lista.map((s) => (
                <tr key={s.id}>
                  <td>{quando(s.criado_em)}</td>
                  <td className={s.canal ? 'mono' : undefined} style={{ color: 'var(--ink)' }}>
                    {s.canal ? s.valor_norm : (s.contacts?.nome ?? '(contato sem nome)')}
                  </td>
                  <td style={{ color: s.canal ? corCanal(s.canal) : 'var(--ink-2)' }}>
                    {s.canal ? NOME_CANAL[s.canal] ?? s.canal : 'todos os canais'}
                  </td>
                  <td>{s.motivo}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

type Modo = 'endereco' | 'lista';

function Adicionar({ tenant, aoGravar }: { tenant: string; aoGravar(): Promise<void> }) {
  const [modo, setModo] = useState<Modo>('endereco');

  return (
    <>
      <Secao titulo="Adicionar" />
      <div className="painel">
        <div className="opts" style={{ marginBottom: 14 }}>
          <button className="opt" aria-pressed={modo === 'endereco'} onClick={() => setModo('endereco')}>
            <b>Um endereço</b>
            <p>Telefone ou e-mail que pediu para parar. Vale mesmo sem contato na base.</p>
          </button>
          <button className="opt" aria-pressed={modo === 'lista'} onClick={() => setModo('lista')}>
            <b>Uma lista</b>
            <p>A lista de opt-out que já existia antes do motor. CSV, como na importação.</p>
          </button>
        </div>

        {modo === 'endereco'
          ? <UmEndereco tenant={tenant} aoGravar={aoGravar} />
          : <UmaLista tenant={tenant} aoGravar={aoGravar} />}
      </div>
    </>
  );
}

function UmEndereco({ tenant, aoGravar }: { tenant: string; aoGravar(): Promise<void> }) {
  const [valor, setValor] = useState('');
  const [motivo, setMotivo] = useState('');
  const [aviso, setAviso] = useState('');
  const [erro, setErro] = useState('');
  const [gravando, setGravando] = useState(false);

  // O canal é deduzido do que foi digitado, com os mesmos normalizadores dos
  // adapters — nunca com uma segunda normalização aqui dentro (D32).
  const lido = interpretar(valor);

  async function gravar() {
    if (!lido) return;
    setErro(''); setAviso(''); setGravando(true);
    try {
      const canais = lido.canais;
      const resultados = await Promise.all(canais.map((canal) => suprimirEndereco({
        tenant, canal, valorNorm: lido.valorNorm, motivo: motivo.trim() || 'pedido da pessoa',
      })));
      const novas = resultados.filter((r) => r === 'nova').length;
      setAviso(novas === 0
        ? 'Já estava na lista — nada muda, e é isso mesmo.'
        : `Suprimido em ${canais.map((c) => NOME_CANAL[c] ?? c).join(' e ')}.`);
      setValor(''); setMotivo('');
      await aoGravar();
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setGravando(false); }
  }

  return (
    <>
      <Campo id="s-valor" rotulo="Telefone ou e-mail" valor={valor} aoMudar={setValor}
             placeholder="(11) 99999-0000 ou pessoa@exemplo.com"
             ajuda={lido
               ? `Entra como ${lido.canais.map((c) => NOME_CANAL[c] ?? c).join(' e ')}: ${lido.valorNorm}`
               : 'Ainda não dá para dizer o que é isto.'} />
      <Campo id="s-motivo" rotulo="Motivo" valor={motivo} aoMudar={setMotivo}
             obrigatorio={false}
             placeholder="pediu por telefone" ajuda="Fica registrado junto, para sempre." />

      {aviso && <Aviso tipo="ok">{aviso}</Aviso>}
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <button className="btn prim" disabled={!lido || gravando} onClick={() => void gravar()}>
        {gravando ? 'Gravando…' : 'Suprimir'}
      </button>
    </>
  );
}

function UmaLista({ tenant, aoGravar }: { tenant: string; aoGravar(): Promise<void> }) {
  const entrada = useRef<HTMLInputElement>(null);
  const [nome, setNome] = useState('');
  const [motivo, setMotivo] = useState('');
  const [previa, setPrevia] = useState<{ canal: string; valorNorm: string }[] | null>(null);
  const [recusadas, setRecusadas] = useState(0);
  const [progresso, setProgresso] = useState(0);
  const [resultado, setResultado] = useState<{ novas: number; jaEstavam: number } | null>(null);
  const [erro, setErro] = useState('');

  async function escolher(f: File) {
    setErro(''); setResultado(null); setProgresso(0); setNome(f.name);
    try {
      const c = new PlanilhaSource(await f.text(), { origem: 'opt-out' }).colherAgora();
      // A colheita traz pessoas; aqui só interessam os endereços. Telefone
      // genérico vira whatsapp e sms, e para supressão isso é o certo: quem
      // pediu para parar pediu nos dois.
      const vistos = new Set<string>();
      const enderecos = c.contatos.flatMap((p) => p.identidades)
        .filter((i) => {
          const k = `${i.canal}|${i.valorNorm}`;
          if (vistos.has(k)) return false;
          vistos.add(k); return true;
        })
        .map((i) => ({ canal: i.canal, valorNorm: i.valorNorm }));
      setPrevia(enderecos);
      setRecusadas(c.recusadas.length + c.ignorados.length);
    } catch (e) { setPrevia(null); setErro(mensagemDeErro(e)); }
  }

  async function gravar() {
    if (!previa) return;
    setErro(''); setProgresso(0);
    const r = { novas: 0, jaEstavam: 0 };
    for (const e of previa) {
      try {
        const x = await suprimirEndereco({
          tenant, canal: e.canal, valorNorm: e.valorNorm,
          motivo: motivo.trim() || 'lista de opt-out importada',
        });
        if (x === 'nova') r.novas += 1; else r.jaEstavam += 1;
      } catch (err) { setErro(mensagemDeErro(err)); return; }
      setProgresso((n) => n + 1);
    }
    setResultado(r); setPrevia(null);
    await aoGravar();
  }

  return (
    <>
      <input ref={entrada} type="file" accept=".csv,text/csv,text/plain" style={{ display: 'none' }}
             onChange={(e) => { const f = e.target.files?.[0]; if (f) void escolher(f); }} />
      <button className="btn" onClick={() => entrada.current?.click()}>
        {nome ? 'Trocar arquivo' : 'Escolher arquivo'}
      </button>
      {nome && <span className="mono" style={{ marginLeft: 10 }}>{nome}</span>}

      <Campo id="s-motivo-lista" rotulo="Motivo" valor={motivo} aoMudar={setMotivo}
             obrigatorio={false} placeholder="lista de opt-out do sistema anterior" />

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {previa && (
        <>
          <Aviso tipo="neutro">
            <b>{previa.length}</b> {previa.length === 1 ? 'endereço' : 'endereços'} para suprimir
            {recusadas > 0 && <> · <b>{recusadas}</b> {recusadas === 1 ? 'linha' : 'linhas'} sem endereço utilizável</>}.
            {progresso > 0 && <> Gravando… {progresso} de {previa.length}.</>}
          </Aviso>
          <button className="btn prim" disabled={progresso > 0} onClick={() => void gravar()}>
            Suprimir {previa.length}
          </button>
        </>
      )}

      {resultado && (
        <Aviso tipo="ok">
          {resultado.novas} {resultado.novas === 1 ? 'endereço entrou' : 'endereços entraram'} na lista
          {resultado.jaEstavam > 0 && `, ${resultado.jaEstavam} já estava(m) lá`}.
        </Aviso>
      )}
    </>
  );
}

/**
 * O que foi digitado, lido pelos normalizadores dos adapters.
 *
 * Telefone genérico entra em whatsapp **e** sms: quem pediu para parar não
 * pediu só num canal. É a mesma leitura da coluna genérica da planilha (D33),
 * e aqui a consequência é a inversa e por isso segura — suprimir a mais nunca
 * machuca ninguém.
 */
function interpretar(bruto: string): { canais: string[]; valorNorm: string } | null {
  const s = bruto.trim();
  if (!s) return null;
  if (s.includes('@') && emailValido(s)) {
    return { canais: ['email'], valorNorm: normalizarEmail(s) };
  }
  if (telefoneValido(s)) {
    return { canais: ['whatsapp', 'sms'], valorNorm: normalizarTelefone(s) };
  }
  return null;
}

function quando(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit' });
}

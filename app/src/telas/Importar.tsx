/** Importação de contatos, com prévia antes de gravar (D32, D34).
 *
 * A tela não conhece canal, não normaliza nada e não decide dedup. Ela lê o
 * arquivo com `PlanilhaSource`, mostra o que a fonte entendeu, pergunta ao
 * servidor o que aconteceria, e só então grava. Os três passos existem porque
 * cada um responde uma pergunta diferente:
 *
 *  1. **O que a fonte entendeu** — qual coluna virou o quê. É a pergunta mais
 *     importante e a que ninguém pensa em fazer: uma planilha com a coluna
 *     "Fone Comercial" importa 500 contatos sem telefone nenhum e sem erro.
 *  2. **O que o servidor faria** — quantos são novos, quantos são reimportação,
 *     quantos estão suprimidos, quais linhas ele recusaria. Nada é gravado.
 *  3. **Gravar** — e aí sim, uma chamada por linha.
 *
 * O passo 2 é a mesma ideia do shadow mode: o caminho inteiro roda sem efeito.
 */
import { useMemo, useRef, useState } from 'react';
import { PlanilhaSource } from '@adapters/planilha.ts';
import { identidadesParaJson } from '@adapters/fonte.ts';
import type { Colheita } from '@adapters/fonte.ts';
import { useSessao } from '../sessao';
import { Aviso, Kpi, Secao } from '../componentes/base';
import { ingerirContato, preverIngestao } from '../dados';
import type { LinhaPrevista } from '../dados';
import { mensagemDeErro } from '../supabase';

type Etapa = 'vazio' | 'lido' | 'previsto' | 'gravando' | 'pronto';

interface Gravacao {
  criados: number;
  atualizados: number;
  falhas: { linha: number; erro: string }[];
}

export function Importar() {
  const { tenant } = useSessao();
  const entrada = useRef<HTMLInputElement>(null);

  const [etapa, setEtapa] = useState<Etapa>('vazio');
  const [arquivo, setArquivo] = useState('');
  const [colheita, setColheita] = useState<Colheita | null>(null);
  const [previsao, setPrevisao] = useState<LinhaPrevista[]>([]);
  const [progresso, setProgresso] = useState(0);
  const [gravacao, setGravacao] = useState<Gravacao | null>(null);
  const [erro, setErro] = useState('');

  const porLinha = useMemo(
    () => new Map(previsao.map((p) => [p.linha, p])),
    [previsao],
  );

  async function escolher(f: File) {
    setErro(''); setPrevisao([]); setGravacao(null); setProgresso(0);
    setArquivo(f.name);
    try {
      const texto = await f.text();
      const c = new PlanilhaSource(texto, { origem: 'planilha' }).colherAgora();
      setColheita(c);
      setEtapa('lido');
    } catch (e) {
      setColheita(null); setEtapa('vazio'); setErro(mensagemDeErro(e));
    }
  }

  async function prever() {
    if (!colheita || !tenant) return;
    setErro('');
    try {
      setPrevisao(await preverIngestao(
        tenant.tenant_id,
        colheita.contatos.map((c) => ({
          linha: c.linha,
          identidades: c.identidades.map((i) => ({ canal: i.canal, valor_norm: i.valorNorm })),
        })),
      ));
      setEtapa('previsto');
    } catch (e) { setErro(mensagemDeErro(e)); }
  }

  async function gravar() {
    if (!colheita || !tenant) return;
    setErro(''); setEtapa('gravando'); setProgresso(0);

    const resultado: Gravacao = { criados: 0, atualizados: 0, falhas: [] };
    // Só o que a prévia aprovou. Mandar o que ela recusou seria pedir a
    // exceção que ela existe para evitar.
    const aGravar = colheita.contatos.filter((c) => porLinha.get(c.linha)?.acao !== 'recusar');

    for (const c of aGravar) {
      try {
        const r = await ingerirContato({
          tenant: tenant.tenant_id,
          origem: colheita.origem,
          identidades: identidadesParaJson(c),
          nome: c.nome,
          origemRef: c.origemRef,
          metadados: c.metadados,
        });
        if (r.acao === 'criado') resultado.criados += 1; else resultado.atualizados += 1;
      } catch (e) {
        // A linha que falha não leva as outras: cada chamada é a sua própria
        // transação, e o relatório final diz exatamente qual linha e por quê.
        resultado.falhas.push({ linha: c.linha, erro: mensagemDeErro(e) });
      }
      setProgresso((n) => n + 1);
    }

    setGravacao(resultado);
    setEtapa('pronto');
  }

  const total = colheita?.contatos.length ?? 0;
  const aGravar = colheita
    ? colheita.contatos.filter((c) => porLinha.get(c.linha)?.acao !== 'recusar').length
    : 0;

  return (
    <>
      <Secao titulo="Importar contatos"
             nota="Planilha em CSV. Nada é gravado antes da conferência." />

      <div className="painel">
        <input
          ref={entrada} type="file" accept=".csv,text/csv,text/plain" style={{ display: 'none' }}
          onChange={(e) => { const f = e.target.files?.[0]; if (f) void escolher(f); }}
        />
        <button className="btn" onClick={() => entrada.current?.click()}>
          {arquivo ? 'Trocar arquivo' : 'Escolher arquivo'}
        </button>
        {arquivo && <span className="mono" style={{ marginLeft: 10 }}>{arquivo}</span>}

        <p style={{ color: 'var(--ink-2)', fontSize: 13, marginBottom: 0 }}>
          O separador é detectado sozinho — o Excel em português exporta com
          ponto e vírgula. Colunas reconhecidas: nome, telefone, celular,
          whatsapp, sms, e-mail, instagram e um código de origem. O resto vira
          metadado do contato.
        </p>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {colheita && (
        <>
          <Secao titulo="O que a planilha tem"
                 nota="Confira o que cada coluna virou antes de seguir." />
          <div className="kpis">
            <Kpi rotulo="Linhas com contato" valor={total} sub="viram pessoa" />
            <Kpi rotulo="Linhas recusadas" valor={colheita.recusadas.length}
                 sub="sem identidade utilizável" />
            <Kpi rotulo="Valores ignorados" valor={colheita.ignorados.length}
                 sub="não passaram na conferência" />
          </div>

          <Colunas colheita={colheita} />

          {colheita.ignorados.length > 0 && (
            <div className="painel">
              <b>Valores que não viraram contato</b>
              <p style={{ color: 'var(--ink-2)', fontSize: 13 }}>
                Estas linhas entram assim mesmo — têm outra forma de contato.
                O que está aqui é o que se perderia em silêncio.
              </p>
              <Tabela
                cabecalho={['Linha', 'Coluna', 'Valor', 'Motivo']}
                linhas={colheita.ignorados.slice(0, 50).map((i) => [
                  String(i.linha), i.coluna, i.valor, i.motivo,
                ])}
                resto={colheita.ignorados.length - 50}
              />
            </div>
          )}

          {colheita.recusadas.length > 0 && (
            <div className="painel">
              <b>Linhas sem contato nenhum</b>
              <Tabela
                cabecalho={['Linha', 'Motivo']}
                linhas={colheita.recusadas.slice(0, 50).map((r) => [String(r.linha), r.motivo])}
                resto={colheita.recusadas.length - 50}
              />
            </div>
          )}

          {etapa === 'lido' && total > 0 && (
            <button className="btn prim" onClick={() => void prever()}>
              Conferir contra a base ({total} {total === 1 ? 'linha' : 'linhas'})
            </button>
          )}
        </>
      )}

      {previsao.length > 0 && (
        <Previa previsao={previsao} colheita={colheita!} />
      )}

      {etapa === 'previsto' && (
        <button className="btn prim" onClick={() => void gravar()} disabled={aGravar === 0}>
          Importar {aGravar} {aGravar === 1 ? 'contato' : 'contatos'}
        </button>
      )}

      {etapa === 'gravando' && (
        <Aviso tipo="neutro">Gravando… {progresso} de {aGravar}.</Aviso>
      )}

      {etapa === 'pronto' && gravacao && (
        <>
          <Secao titulo="Resultado" />
          <div className="kpis">
            <Kpi rotulo="Criados" valor={gravacao.criados} sub="pessoas novas" />
            <Kpi rotulo="Atualizados" valor={gravacao.atualizados} sub="já estavam na base" />
            <Kpi rotulo="Falharam" valor={gravacao.falhas.length} sub="nenhuma levou as outras" />
          </div>
          {gravacao.falhas.length > 0 && (
            <div className="painel">
              <Tabela
                cabecalho={['Linha', 'Erro']}
                linhas={gravacao.falhas.map((f) => [String(f.linha), f.erro])}
              />
            </div>
          )}
        </>
      )}
    </>
  );
}

/** O mapeamento de colunas, que é a conferência que ninguém pensa em fazer. */
function Colunas({ colheita }: { colheita: Colheita }) {
  // Deduzido do resultado, não do cabeçalho: mostrar o que a fonte de fato
  // produziu é mais honesto do que repetir o que ela pretendia produzir.
  const porCanal = new Map<string, number>();
  for (const c of colheita.contatos) {
    for (const i of c.identidades) porCanal.set(i.canal, (porCanal.get(i.canal) ?? 0) + 1);
  }
  const comNome = colheita.contatos.filter((c) => c.nome).length;
  const metadados = new Set(colheita.contatos.flatMap((c) => Object.keys(c.metadados)));

  return (
    <div className="painel">
      <b>O que virou o quê</b>
      <Tabela
        cabecalho={['O que', 'Quantos']}
        linhas={[
          ['nome', `${comNome} de ${colheita.contatos.length}`],
          ...[...porCanal.entries()].map(([canal, n]) => [canal, String(n)] as string[]),
          ['metadados', metadados.size ? [...metadados].join(', ') : 'nenhum'],
        ]}
      />
      {porCanal.size === 0 && (
        <Aviso tipo="erro">
          Nenhuma identidade foi reconhecida. Confira o cabeçalho da planilha —
          a coluna de contato precisa se chamar telefone, celular, whatsapp,
          sms, e-mail ou instagram.
        </Aviso>
      )}
    </div>
  );
}

function Previa({ previsao, colheita }: { previsao: LinhaPrevista[]; colheita: Colheita }) {
  const conta = (a: string) => previsao.filter((p) => p.acao === a).length;
  const suprimidas = previsao.reduce((s, p) => s + p.identidades_suprimidas, 0);
  const recusadas = previsao.filter((p) => p.acao === 'recusar');
  const nome = new Map(colheita.contatos.map((c) => [c.linha, c.nome ?? '(sem nome)']));

  return (
    <>
      <Secao titulo="O que aconteceria"
             nota="Conferido contra a base. Ainda não foi gravado nada." />
      <div className="kpis">
        <Kpi rotulo="Contatos novos" valor={conta('criar')} sub="entram agora" />
        <Kpi rotulo="Já na base" valor={conta('atualizar')} sub="reimportação" />
        <Kpi rotulo="O servidor recusaria" valor={conta('recusar')} sub="não serão enviados" />
        <Kpi rotulo="Endereços suprimidos" valor={suprimidas}
             sub="entram, mas nunca recebem" />
      </div>

      {suprimidas > 0 && (
        <Aviso tipo="neutro">
          Endereço suprimido continua sendo cadastrado — o bloqueio acontece na
          hora do envio, e o cadastro completo é o que faz o retorno ao CRM
          fazer sentido. O que ele não faz é receber mensagem.
        </Aviso>
      )}

      {recusadas.length > 0 && (
        <div className="painel">
          <b>Linhas que o servidor recusaria</b>
          <Tabela
            cabecalho={['Linha', 'Quem', 'Por quê']}
            linhas={recusadas.slice(0, 50).map((p) => [
              String(p.linha), nome.get(p.linha) ?? '', p.problema ?? '',
            ])}
            resto={recusadas.length - 50}
          />
        </div>
      )}
    </>
  );
}

function Tabela({ cabecalho, linhas, resto = 0 }: {
  cabecalho: string[]; linhas: string[][]; resto?: number;
}) {
  if (!linhas.length) return null;
  return (
    <>
      <table className="tab">
        <thead><tr>{cabecalho.map((c) => <th key={c}>{c}</th>)}</tr></thead>
        <tbody>
          {linhas.map((l, i) => (
            <tr key={i}>{l.map((v, j) => (
              <td key={j} className={j === 0 ? 'mono' : undefined}>{v}</td>
            ))}</tr>
          ))}
        </tbody>
      </table>
      {resto > 0 && (
        <p style={{ color: 'var(--ink-3)', fontSize: 12, marginBottom: 0 }}>
          e mais {resto}.
        </p>
      )}
    </>
  );
}

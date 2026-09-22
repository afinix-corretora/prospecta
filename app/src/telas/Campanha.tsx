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
import { useParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { Aviso, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import { lerCampanhas, lerEventosDaCampanha, lerResumoDaCampanha } from '../dados';
import type { Campanha as Camp, EventoDaCampanha, ResumoDaCampanha } from '../dados';
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
  // Canceladas são opt-out honrado depois de a mensagem já existir (D39).
  // Ficam longe de "com falha" de propósito: não são defeito do motor.
  cancelado: 'canceladas por supressão',
};

/** Etiqueta de uma mensagem só, no evento. */
const STATUS: Record<string, string> = {
  simulado: 'shadow mode', pendente: 'na fila', enviado: 'enviado', falha: 'falha',
  cancelado: 'cancelada por supressão',
};

export function Campanha() {
  const { id = '' } = useParams();
  const { tenant } = useSessao();
  const [campanha, setCampanha] = useState<Camp | null>(null);
  const [resumo, setResumo] = useState<ResumoDaCampanha | null>(null);
  const [eventos, setEventos] = useState<EventoDaCampanha[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);

  async function recarregar() {
    if (!tenant || !id) return;
    setErro('');
    try {
      const [cs, r, ev] = await Promise.all([
        lerCampanhas(),
        lerResumoDaCampanha(tenant.tenant_id, id),
        lerEventosDaCampanha(tenant.tenant_id, id),
      ]);
      setCampanha(cs.find((c) => c.id === id) ?? null);
      setResumo(r);
      setEventos(ev);
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
        nota={`${campanha.tipo} · ${campanha.canais_habilitados.map((c) => NOME_CANAL[c] ?? c).join(', ')}`}
      />

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
          <b>{canceladas}</b> {canceladas === 1 ? 'mensagem foi cancelada' : 'mensagens foram canceladas'}{' '}
          porque o contato entrou na supressão <b>depois</b> de a mensagem ser criada. O opt-out foi
          honrado; não é falha do motor nem da conta que ia enviar (D39).
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

/** Writeback: o que o motor tem para contar ao CRM (D46).
 *
 * Esta tela existe pelo mesmo motivo que a da campanha (D36): um número que
 * ninguém lê não é verificação. O D45 fez os fatos nascerem e o D46 fez o
 * dreno existir — mas "zero writebacks saindo" tem **três** causas diferentes
 * que, sem esta tela, produzem exatamente a mesma ausência de sinal:
 *
 *   1. não aconteceu nada ainda  — ninguém respondeu, ninguém pediu para sair
 *   2. nada nunca saiu           — os fatos estão empilhando e o dreno nunca
 *                                  rodou (é o estado de hoje: o adapter do
 *                                  CRM depende do OAuth do projeto legado)
 *   3. o dreno parou             — já saiu coisa antes, e agora empacou
 *
 * As três são derivadas do dado, não escritas à mão. O que as separa é
 * `enviados` (alguma vez saiu?) e `pendente_mais_antigo_em_horas` (há quanto
 * tempo o mais velho está esperando?). Fila vazia não tem mais antigo — é por
 * isso que esse campo é nulo e não zero.
 *
 * Distinguir a 2 da 3 importa de verdade: na 2 a fila crescendo é o
 * comportamento correto de um motor que guarda o que descobriu enquanto o
 * caminho de saída não existe. Mostrar isso como alarme ensinaria a ignorar o
 * alarme — que é como o de verdade, o 3, passa despercebido.
 */
import { useEffect, useState } from 'react';
import { useSessao } from '../sessao';
import { Aviso, Kpi, Secao } from '../componentes/base';
import { lerResumoDaOutbox, lerWritebacksFalhados } from '../dados';
import type { ResumoDaOutbox, WritebackFalhado } from '../dados';
import { situacaoDoWriteback } from './situacao_do_writeback';
import type { Estado } from './situacao_do_writeback';
import { mensagemDeErro } from '../supabase';

const ROTULO_FATO: Record<WritebackFalhado['fato'], string> = {
  opt_out: 'pediu para sair',
  identidade_invalida: 'endereço inválido',
  respondido: 'respondeu',
  campanha_concluida: 'campanha concluída',
};

function Situacao({ e }: { e: Estado }) {
  if (e.tipo === 'vazio') {
    return (
      <Aviso tipo="neutro">
        Nenhum fato para contar ainda. O motor escreve aqui quando alguém
        responde, pede para sair, tem endereço recusado pelo provedor ou
        termina a cadência.
      </Aviso>
    );
  }

  if (e.tipo === 'nunca_saiu') {
    return (
      <Aviso tipo="neutro">
        <b>Os fatos estão sendo guardados, e nenhum saiu ainda.</b>{' '}
        Isto é o esperado nesta fase: o motor já descobre e registra, mas o
        adapter do CRM ainda não existe — ele depende do OAuth que mora no
        projeto legado. Nada se perde enquanto isso; cada fato está gravado e
        datado, e sai na ordem quando o caminho existir.
        {e.horas !== null && (
          <> O mais antigo espera há <b>{e.horas} h</b>.</>
        )}
      </Aviso>
    );
  }

  if (e.tipo === 'parado') {
    return (
      <Aviso tipo="erro">
        <b>O dreno parece parado.</b> Já saiu writeback antes, e agora o fato
        mais antigo está esperando há <b>{e.horas} h</b> — mais que o teto de
        espera entre tentativas. Vale olhar o worker e a credencial do CRM.
      </Aviso>
    );
  }

  return <Aviso tipo="ok">O dreno está em dia.</Aviso>;
}

export function Writeback() {
  const { tenant } = useSessao();
  const [resumo, setResumo] = useState<ResumoDaOutbox | null>(null);
  const [falhados, setFalhados] = useState<WritebackFalhado[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');

  async function recarregar() {
    if (!tenant) return;
    setErro('');
    try {
      const [r, f] = await Promise.all([
        lerResumoDaOutbox(tenant.tenant_id),
        lerWritebacksFalhados(tenant.tenant_id),
      ]);
      setResumo(r);
      setFalhados(f);
    } catch (e) {
      setErro(mensagemDeErro(e));
    } finally {
      setCarregando(false);
    }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  return (
    <>
      <Secao
        titulo="Writeback"
        nota="O que o motor descobriu e tem para contar ao CRM."
      />

      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {carregando && <Aviso tipo="neutro">Lendo…</Aviso>}

      {resumo && (
        <>
          <Situacao e={situacaoDoWriteback(resumo)} />

          <div className="kpis">
            <Kpi rotulo="Na fila" valor={resumo.pendentes} sub="ainda não contados ao CRM" />
            <Kpi rotulo="Vencidos agora" valor={resumo.vencidos_agora}
                 sub="prontos para a próxima passada" />
            <Kpi rotulo="Entregues" valor={resumo.enviados} sub="o CRM já sabe" />
            <Kpi rotulo="Desistidos" valor={resumo.falhados}
                 sub="tentaram 8 vezes e não chegaram" />
            <Kpi
              rotulo="Mais antigo na fila"
              valor={resumo.pendente_mais_antigo_em_horas === null
                ? '—'
                : `${resumo.pendente_mais_antigo_em_horas} h`}
              sub={resumo.pendente_mais_antigo_em_horas === null
                ? 'a fila está vazia'
                : 'esperando desde então'}
            />
          </div>

          {falhados.length > 0 && (
            <>
              <Secao
                titulo="Não chegaram"
                nota={'Estes fatos desistiram depois de oito tentativas. O CRM não '
                    + 'sabe deles, e ninguém vai tentar de novo sozinho.'}
              />
              <table className="tab">
                <thead>
                  <tr>
                    <th>Contato</th><th>Fato</th><th>Destino</th>
                    <th>Tentativas</th><th>Último erro</th>
                  </tr>
                </thead>
                <tbody>
                  {falhados.map((f) => (
                    <tr key={f.writeback_id}>
                      <td>{f.nome ?? '(sem nome)'}</td>
                      <td>{ROTULO_FATO[f.fato] ?? f.fato}</td>
                      <td className="mono">{f.destino}</td>
                      <td className="mono">{f.tentativas}</td>
                      <td>{f.ultimo_erro || '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </>
      )}
    </>
  );
}

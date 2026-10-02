// Implementação da porta `BancoCrm` sobre o supabase-js (D64).
//
// Separada de `banco-supabase.ts` pelo motivo de `motor/porta-crm.ts`: só a
// function que fala com CRM empacota isto.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { BancoCrm, FonteVencida, LinhaDoPlano } from '../../../motor/porta-crm.ts';

/**
 * A metade CRM da porta (D64). Mesma regra da de cima: cada método é uma RPC
 * e a tradução do resultado, e o segredo só passa por `credenciaisDaConexao`.
 */
export function bancoCrmSupabase(sb: SupabaseClient): BancoCrm {
  const rpc = async (nome: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(nome, args);
    if (error) throw new Error(`${nome}: ${error.message}`);
    return data;
  };

  return {
    async reivindicarWritebacks(limite) {
      const linhas = (await rpc('reivindicar_writebacks', { p_limite: limite })) ?? [];
      return (linhas as { writeback_id: string; fato: string }[])
        .map((l) => ({ writeback_id: l.writeback_id, fato: l.fato }));
    },

    async planoDeWriteback(id) {
      return ((await rpc('plano_de_writeback', { p_writeback_id: id })) ?? []) as LinhaDoPlano[];
    },

    async credenciaisDaConexao(conexaoId) {
      const { data, error } = await sb
        .from('crm_connections').select('config').eq('id', conexaoId).single();
      if (error) throw new Error(`conexão ${conexaoId}: ${error.message}`);
      const segredo = await rpc('segredo_da_conexao_crm', { p_conexao_id: conexaoId });
      if (!segredo) throw new Error(`conexão ${conexaoId}: segredo não resolvido no Vault`);
      const config = (data?.config ?? {}) as Record<string, unknown>;
      const juntas: Record<string, string> = {};
      for (const [k, v] of Object.entries(config)) juntas[k] = String(v ?? '');
      for (const [k, v] of Object.entries(JSON.parse(String(segredo)) as Record<string, unknown>)) {
        juntas[k] = String(v ?? '');
      }
      return juntas;
    },

    async concluirWriteback(id, ok, resultado, erro) {
      // Anotar antes de registrar: registrar tira a linha do lease, e um
      // resultado escrito depois disso poderia cair sobre a tentativa seguinte.
      await rpc('anotar_resultado_writeback', { p_writeback_id: id, p_resultado: resultado });
      await rpc('registrar_resultado_writeback', {
        p_writeback_id: id, p_ok: ok, p_erro: erro ?? null,
      });
    },

    async fontesVencidas() {
      return ((await rpc('fontes_crm_vencidas', {})) ?? []) as FonteVencida[];
    },

    async refsVinculadas(conexaoId) {
      const linhas = ((await rpc('refs_vinculadas', { p_conexao_id: conexaoId })) ?? []) as unknown[];
      return new Set(linhas.map((l) => String(
        typeof l === 'object' && l !== null ? Object.values(l)[0] : l)));
    },

    async ingerirDoCrm(fonteId, ref, identidades, nome, metadados) {
      const linhas = (await rpc('ingerir_do_crm', {
        p_fonte_id: fonteId, p_ref_externa: ref, p_identidades: identidades,
        p_nome: nome, p_metadados: metadados,
      })) as { acao: string; inscricao: string }[] | null;
      const l = linhas?.[0];
      if (!l) throw new Error(`ingerir_do_crm: nada devolvido para o card ${ref}`);
      return { acao: l.acao, inscricao: l.inscricao };
    },

    async registrarExecucaoFonte(fonteId, resultado) {
      await rpc('registrar_execucao_fonte', { p_fonte_id: fonteId, p_resultado: resultado });
    },
  };
}

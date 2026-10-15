// Implementação da porta `BancoAgente` sobre o supabase-js (D66, D69).
//
// Arquivo próprio pelo motivo de `banco-crm.ts`: só o worker empacota isto.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { BancoAgente, Envio, RespostaParaRascunhar } from '../../../motor/porta-agente.ts';
import { juntarCredenciais } from '../../../adapters/ia.ts';

export function bancoAgenteSupabase(sb: SupabaseClient): BancoAgente {
  const rpc = async (nome: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(nome, args);
    if (error) throw new Error(`${nome}: ${error.message}`);
    return data;
  };

  return {
    async respostasParaRascunhar(limite) {
      // D76: a fila que sabe do agente do canal e da exceção da campanha.
      // `respostas_para_o_agente` (D69) fica sem chamador e sai pelo SQL
      // Editor (D63), como `respostas_para_rascunhar` antes dela.
      return ((await rpc('fila_do_agente', { p_limite: limite })) ?? []) as RespostaParaRascunhar[];
    },

    async credenciaisDaIa(tenantId, credencialId) {
      // O cliente vai no filtro: com a chave do serviço não há RLS, e o id
      // sozinho deixaria o tenant implícito (D76).
      const { data, error } = await sb
        .from('ai_credentials').select('config')
        .eq('tenant_id', tenantId).eq('id', credencialId).single();
      if (error) throw new Error(`credencial de IA ${credencialId}: ${error.message}`);
      const segredo = await rpc('segredo_da_credencial_ia', { p_credencial_id: credencialId });
      if (!segredo) throw new Error(`credencial de IA ${credencialId}: segredo não resolvido no Vault`);
      // A MESMA junção do "Testar" (D76): os dois erram igual.
      return juntarCredenciais(data?.config ?? {}, String(segredo));
    },

    async registrarRascunho(eventoId, agenteId, situacao, texto, motivo, modelo) {
      await rpc('registrar_rascunho', {
        p_message_event_id: eventoId, p_agent_id: agenteId, p_situacao: situacao,
        p_texto: texto, p_motivo: motivo, p_modelo: modelo,
      });
    },

    async enfileirarResposta(eventoId, modo) {
      return (await rpc('enfileirar_resposta', { p_message_event_id: eventoId, p_modo: modo })) as Envio;
    },
  };
}

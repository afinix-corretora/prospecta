// Implementação da porta `BancoAgente` sobre o supabase-js (D66).
//
// Arquivo próprio pelo motivo de `banco-crm.ts`: só o worker empacota isto.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { BancoAgente, RespostaParaRascunhar } from '../../../motor/porta-agente.ts';

export function bancoAgenteSupabase(sb: SupabaseClient): BancoAgente {
  const rpc = async (nome: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(nome, args);
    if (error) throw new Error(`${nome}: ${error.message}`);
    return data;
  };

  return {
    async respostasParaRascunhar(limite) {
      return ((await rpc('respostas_para_rascunhar', { p_limite: limite })) ?? []) as RespostaParaRascunhar[];
    },

    async credenciaisDaIa(credencialId) {
      const { data, error } = await sb
        .from('ai_credentials').select('config').eq('id', credencialId).single();
      if (error) throw new Error(`credencial de IA ${credencialId}: ${error.message}`);
      const segredo = await rpc('segredo_da_credencial_ia', { p_credencial_id: credencialId });
      if (!segredo) throw new Error(`credencial de IA ${credencialId}: segredo não resolvido no Vault`);
      const juntas: Record<string, string> = {};
      for (const [k, v] of Object.entries((data?.config ?? {}) as Record<string, unknown>)) juntas[k] = String(v ?? '');
      for (const [k, v] of Object.entries(JSON.parse(String(segredo)) as Record<string, unknown>)) juntas[k] = String(v ?? '');
      return juntas;
    },

    async registrarRascunho(eventoId, agenteId, situacao, texto, motivo, modelo) {
      await rpc('registrar_rascunho', {
        p_message_event_id: eventoId, p_agent_id: agenteId, p_situacao: situacao,
        p_texto: texto, p_motivo: motivo, p_modelo: modelo,
      });
    },
  };
}

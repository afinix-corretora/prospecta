// Implementação da porta `Banco` sobre o supabase-js.
//
// É a única camada que não tem teste automatizado: não dá para exercitá-la
// fora do Supabase. Por isso ela é fina de propósito — cada método é uma
// chamada de RPC e a tradução do resultado. Toda decisão vive em `motor/`,
// que é testado, ou no SQL, que também é.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { Banco, Culpa, MensagemParaEnviar } from '../../../motor/porta.ts';
import type { TipoEvento } from '../../../adapters/tipos.ts';

export function clienteAdmin(): SupabaseClient {
  // Anti-regra: secret nunca sai do Vault para constante nem para código.
  // Estas duas são injetadas pelo runtime das edge functions.
  const url = Deno.env.get('SUPABASE_URL');
  const chave = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !chave) throw new Error('SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY ausentes');
  return createClient(url, chave);
}

export function bancoSupabase(sb: SupabaseClient): Banco {
  const rpc = async (nome: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(nome, args);
    if (error) throw new Error(`${nome}: ${error.message}`);
    return data;
  };

  return {
    async processarVencidos(limite, modo) {
      const linhas = await rpc('processar_vencidos', { p_limite: limite, p_modo: modo });
      return Array.isArray(linhas) ? linhas.length : 0;
    },

    async reivindicarPendentes(limite) {
      const linhas = await rpc('reivindicar_pendentes', { p_limite: limite });
      return (linhas ?? []) as MensagemParaEnviar[];
    },

    async credenciaisDoRemetente(senderId) {
      const { data, error } = await sb
        .from('sender_accounts')
        .select('provedor, credenciais_secret_id')
        .eq('id', senderId)
        .single();
      if (error) throw new Error(`remetente ${senderId}: ${error.message}`);

      const segredo = await rpc('get_decrypted_meta_token', {
        p_secret_id: data.credenciais_secret_id,
      });
      if (!segredo) throw new Error(`remetente ${senderId}: segredo não resolvido no Vault`);

      return { provedor: data.provedor, credenciais: JSON.parse(String(segredo)) };
    },

    async registrarResultado(messageId, ok, providerMessageId, erro, culpa) {
      await rpc('registrar_resultado_envio', {
        p_message_id: messageId,
        p_ok: ok,
        p_provider_id: providerMessageId ?? null,
        p_erro: erro ?? null,
        p_culpa: (culpa ?? 'transitorio') satisfies Culpa,
      });
    },

    async registrarEventoProvedor(providerMessageId, tipo: TipoEvento, ocorridoEm, payload) {
      const gravado = await rpc('registrar_evento_provedor', {
        p_provider_id: providerMessageId,
        p_tipo: tipo,
        p_ocorrido_em: ocorridoEm,
        p_payload: payload,
      });
      return gravado === true;
    },
  };
}

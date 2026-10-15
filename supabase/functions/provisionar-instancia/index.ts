// Cria uma instância no provedor e devolve o chip pronto.
//
// Toda decisão — a ordem, a pergunta pelo número antes do provedor e o
// desfazer quando o banco recusa — está em `motor/provisionamento.ts`, que tem
// teste. Aqui só se liga a porta ao banco.
//
// Quem pede precisa ALCANÇAR o servidor. Até o D62 esta function lia o
// servidor só com a chave do serviço, que passa por cima do RLS: qualquer
// usuário logado, de qualquer cliente, que soubesse o id de um servidor,
// criava instância com o token de administração de outro cliente. Agora o
// servidor é lido primeiro com o JWT do pedido, e quem decide é o RLS de
// `provider_servers` (quem administra o cliente).

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { provisionarDoPedido } from '../../../motor/provisionamento.ts';
import type {
  ContaComONumero, PedidoProvisionamento, PortaProvisionamento, ServidorDoPedido,
} from '../../../motor/provisionamento.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const pedido = (await req.json().catch(() => ({}))) as PedidoProvisionamento;
    const sb = clienteAdmin();

    const porta: PortaProvisionamento = {
      async servidorVisivel(id) {
        const { data, error } = await clienteDoUsuario(req)
          .from('provider_servers').select('id').eq('id', id).maybeSingle();
        if (error) throw new Error(`servidor ${id}: ${error.message}`);
        return Boolean(data);
      },
      async servidor(id) {
        const { data, error } = await sb
          .from('provider_servers')
          .select('id, tenant_id, provedor, base_url, ativo')
          .eq('id', id)
          .single();
        if (error) throw new Error(`servidor ${id}: ${error.message}`);
        return data as ServidorDoPedido;
      },
      async contasComONumero(identificadores) {
        const { data, error } = await sb
          .from('sender_accounts')
          .select('tenant_id, canal, provedor, apelido, tipo_permitido, removido_em')
          .in('identificador', [...identificadores]);
        if (error) throw new Error(`contas com o número: ${error.message}`);
        return (data ?? []) as ContaComONumero[];
      },
      async tokenDeAdmin(serverId) {
        const { data } = await sb.rpc('segredo_do_servidor', { p_server_id: serverId });
        return data ? String(data) : null;
      },
      urlDoWebhook(token) {
        return `${Deno.env.get('SUPABASE_URL')}/functions/v1/canal-webhook/${token}`;
      },
      async criarConta(c) {
        const { data, error } = await sb.rpc('criar_remetente_provisionado', {
          p_server_id: c.server_id,
          p_apelido: c.apelido,
          p_identificador: c.identificador,
          p_tipo_permitido: c.tipo_permitido,
          p_quota_diaria: c.quota_diaria,
          p_credenciais: c.credenciais,
          p_webhook_token: c.webhook_token,
          p_config: c.config,
        });
        if (error) throw new Error(`criar_remetente_provisionado: ${error.message}`);
        return { sender_id: ((data ?? [])[0] as { sender_id: string }).sender_id };
      },
    };

    const r = await provisionarDoPedido(porta, pedido);
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('[provisionar-instancia]', e);
    return responder({ ok: false, erro: e instanceof Error ? e.message : String(e) }, 500);
  }
});

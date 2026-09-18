// Cria uma instância no provedor e devolve o chip pronto.
//
// A ordem importa e não é arbitrária:
//
//   1. resolve o servidor e o token de admin (Vault)
//   2. cria a instância no provedor
//   3. só então grava conta e credencial, numa transação só
//
// Inverter 2 e 3 deixaria conta apontando para instância que não existe se o
// provedor recusasse. Nesta ordem, o pior caso é uma instância órfã no painel
// do provedor — visível e descartável, em vez de silenciosa no nosso banco.
//
// O QR não é guardado: vai na resposta e morre ali. Guardar QR é guardar
// credencial de sessão de WhatsApp.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { criarAdapter } from '../../../adapters/registro.ts';

interface Pedido {
  server_id: string;
  apelido: string;
  identificador: string;
  tipo_permitido: 'morna' | 'fria';
  quota_diaria: number;
  nome_instancia?: string;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return Response.json({ ok: false, erro: 'use POST' }, { status: 405 });
  }

  try {
    const p = (await req.json()) as Pedido;
    const sb = clienteAdmin();

    const { data: servidor, error } = await sb
      .from('provider_servers')
      .select('id, provedor, base_url, admin_secret_id, ativo')
      .eq('id', p.server_id)
      .single();
    if (error) throw new Error(`servidor ${p.server_id}: ${error.message}`);
    if (!servidor.ativo) throw new Error('servidor inativo');

    const adapter = criarAdapter(servidor.provedor);
    if (!adapter.provisionar) {
      throw new Error(`${servidor.provedor} não cria instância — a conta é cadastrada à mão`);
    }

    const { data: admin } = await sb.rpc('segredo_do_servidor', { p_server_id: servidor.id });
    if (!admin) throw new Error('token de administração não resolvido no Vault');

    // O token do webhook é sorteado aqui, antes de falar com o provedor, para
    // a instância nascer já apontando para o endpoint dela. Criar primeiro e
    // apontar depois deixaria uma janela em que a resposta do contato chega e
    // não tem para onde ir.
    const webhookToken = crypto.randomUUID();
    const webhookUrl =
      `${Deno.env.get('SUPABASE_URL')}/functions/v1/canal-webhook/${webhookToken}`;

    const nome = p.nome_instancia ?? p.apelido;
    const criada = await adapter.provisionar({
      baseUrl: servidor.base_url,
      adminToken: String(admin),
      nome,
      webhookUrl,
    });
    if (!criada.ok || !criada.credenciais) {
      return Response.json({ ok: false, erro: criada.erro ?? 'falha ao criar instância' },
        { status: 502 });
    }

    const { data: conta, error: erroConta } = await sb.rpc('criar_remetente_provisionado', {
      p_server_id: servidor.id,
      p_apelido: p.apelido,
      p_identificador: p.identificador,
      p_tipo_permitido: p.tipo_permitido,
      p_quota_diaria: p.quota_diaria,
      p_credenciais: criada.credenciais,
      p_webhook_token: webhookToken,
      p_config: { instancia: criada.instancia ?? nome, base_url: servidor.base_url },
    });
    if (erroConta) throw new Error(`criar_remetente_provisionado: ${erroConta.message}`);

    const linha = (conta ?? [])[0] as { sender_id: string; webhook_token: string };

    return Response.json({
      ok: true,
      sender_id: linha.sender_id,
      webhook_url: webhookUrl,
      instancia: criada.instancia,
      qrcode: criada.qrcode ?? null,
    });
  } catch (e) {
    console.error('[provisionar-instancia]', e);
    return Response.json(
      { ok: false, erro: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
});

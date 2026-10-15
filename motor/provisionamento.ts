// Criar chip pela plataforma: o que a edge function `provisionar-instancia`
// decide (D25, D62, D73).
//
// A ordem importa e não é arbitrária:
//
//   1. quem pede precisa ALCANÇAR o servidor — lido com o JWT dele, o RLS de
//      `provider_servers` responde (D62);
//   2. o número não pode ser chip ATIVO de ninguém — pergunta feita ao banco
//      ANTES de falar com o provedor (D73); chip removido não conta (D74);
//   3. cria a instância no provedor;
//   4. só então grava conta e credencial, numa transação só;
//   5. se o banco recusar mesmo assim, apaga a instância que acabou de criar.
//
// Inverter 3 e 4 deixaria conta apontando para instância que não existe se o
// provedor recusasse. Nesta ordem, o risco é a instância sem dono — e foi o
// que aconteceu: o setup por chat pediu de novo, a cada render, um número que
// já era chip, e cada pedido deixou uma instância no painel da UAZAPI. 56 em
// 35 minutos. O passo 2 tira a causa conhecida; o 5 cobre o que sobrar (dois
// pedidos ao mesmo tempo, o Vault fora do ar). A causa de fundo — o segredo
// nomeado pelo número, que fazia até chip removido colidir — saiu no D74.
//
// O QR não é guardado: vai na resposta e morre ali. Guardar QR é guardar
// credencial de sessão de WhatsApp.

import type { Buscador, ChannelAdapter } from '../adapters/tipos.ts';
import { criarAdapter } from '../adapters/registro.ts';
import { desprovisionar } from '../adapters/desprovisionar.ts';
import { normalizarTelefone, telefoneValido } from '../adapters/telefone.ts';

export interface ServidorDoPedido {
  readonly id: string;
  readonly tenant_id: string;
  readonly provedor: string;
  readonly base_url: string;
  readonly ativo: boolean;
}

/** Conta que já usa o número, de QUALQUER cliente e arquivada ou não. */
export interface ContaComONumero {
  readonly tenant_id: string;
  readonly canal: string;
  readonly provedor: string;
  readonly apelido: string | null;
  readonly tipo_permitido: string;
  readonly removido_em: string | null;
}

export interface ContaNova {
  readonly server_id: string;
  readonly apelido: string;
  readonly identificador: string;
  readonly tipo_permitido: 'morna' | 'fria';
  readonly quota_diaria: number;
  readonly credenciais: Record<string, string>;
  readonly webhook_token: string;
  readonly config: Record<string, unknown>;
}

export interface PortaProvisionamento {
  /** Quem pediu enxerga este servidor? Lido com o JWT dele. */
  servidorVisivel(id: string): Promise<boolean>;
  /** O servidor, pela chave do serviço. */
  servidor(id: string): Promise<ServidorDoPedido>;
  /** Pela chave do serviço: a pergunta é sobre o produto inteiro, não sobre o cliente. */
  contasComONumero(identificadores: readonly string[]): Promise<ContaComONumero[]>;
  /** Token de administração do servidor, do Vault. */
  tokenDeAdmin(serverId: string): Promise<string | null>;
  urlDoWebhook(token: string): string;
  /** `criar_remetente_provisionado`; lança quando o banco recusa. */
  criarConta(conta: ContaNova): Promise<{ sender_id: string }>;
}

export type PedidoProvisionamento = {
  server_id?: unknown; apelido?: unknown; identificador?: unknown;
  tipo_permitido?: unknown; quota_diaria?: unknown; nome_instancia?: unknown;
};

export type RespostaProvisionamento =
  | { status: 200; corpo: { ok: true; sender_id: string; webhook_url: string; instancia?: string; qrcode: string | null } }
  | { status: 400 | 404 | 409 | 500 | 502; corpo: { ok: false; erro: string } };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function recusa(status: 400 | 404 | 409 | 500 | 502, erro: string): RespostaProvisionamento {
  return { status, corpo: { ok: false, erro } };
}

/**
 * Por que este número não pode virar chip aqui — ou `null` quando pode.
 *
 * Só conta ATIVA impede. Um número é uma sessão de WhatsApp só: chip ativo
 * neste cliente é a unicidade de `sender_accounts`, que recusaria depois de a
 * instância existir; chip ativo noutro cliente é o mesmo aparelho, e ler o QR
 * aqui derrubaria a sessão de lá.
 *
 * Conta arquivada não impede, e isso é o D74. Até ele o segredo era nomeado
 * pelo número e continuava no Vault depois do arquivamento, então o número
 * nunca mais virava chip — o D62 tinha liberado a unicidade das arquivadas
 * justamente para isso funcionar. Desde o D74 o segredo é nomeado pela conta.
 *
 * A conta de outro cliente não é descrita: dizer o apelido seria contar a um
 * cliente o que o outro cadastrou.
 */
export function porQueONumeroNaoServe(
  contas: readonly ContaComONumero[],
  alvo: { tenant_id: string; provedor: string; canal: string; numero: string },
): string | null {
  const ativas = contas.filter((c) => !c.removido_em && (c.canal === alvo.canal || c.provedor === alvo.provedor));

  const minha = ativas.find((c) => c.tenant_id === alvo.tenant_id);
  if (minha) {
    const pool = minha.tipo_permitido === 'fria' ? 'lista fria' : 'base própria';
    return `${alvo.numero} já é o chip "${minha.apelido || alvo.numero}" (${pool}). Um número é um chip só.`;
  }

  if (ativas.length) return `${alvo.numero} já está em uso como chip e não pode ser cadastrado de novo.`;
  return null;
}

export async function provisionarDoPedido(
  porta: PortaProvisionamento,
  pedido: PedidoProvisionamento,
  buscar: Buscador = fetch,
  adapterDe: (provedor: string) => ChannelAdapter = (p) => criarAdapter(p, buscar),
): Promise<RespostaProvisionamento> {
  const serverId = typeof pedido.server_id === 'string' ? pedido.server_id : '';
  if (!UUID.test(serverId)) return recusa(400, 'server_id inválido');

  const apelido = typeof pedido.apelido === 'string' ? pedido.apelido.trim() : '';
  if (!apelido) return recusa(400, 'dê um apelido ao chip');

  // O banco recebe o número como o resto do motor o escreve. Gravar o que veio
  // digitado faria "(17) 98134-7908" e "5517981347908" passarem por dois chips
  // — e passarem pela pergunta do passo 2 (D32).
  const bruto = typeof pedido.identificador === 'string' ? pedido.identificador : '';
  if (!telefoneValido(bruto)) return recusa(400, 'número inválido — use DDD e número, com ou sem o 55');
  const numero = normalizarTelefone(bruto);

  const tipo = pedido.tipo_permitido;
  if (tipo !== 'morna' && tipo !== 'fria') return recusa(400, 'tipo_permitido deve ser morna ou fria');

  const quota = Number(pedido.quota_diaria);
  if (!Number.isInteger(quota) || quota < 1) return recusa(400, 'quota_diaria deve ser um inteiro a partir de 1');

  if (!(await porta.servidorVisivel(serverId))) return recusa(404, 'servidor não encontrado');

  const servidor = await porta.servidor(serverId);
  if (!servidor.ativo) return recusa(409, 'servidor inativo');

  const adapter = adapterDe(servidor.provedor);
  if (!adapter.provisionar) {
    return recusa(400, `${servidor.provedor} não cria instância — a conta é cadastrada à mão`);
  }

  // 2. Antes do provedor. Pergunta-se pelos dois jeitos de escrever o número
  // porque contas antigas podem ter entrado sem normalizar.
  const contas = await porta.contasComONumero([...new Set([bruto.trim(), numero])]);
  const motivo = porQueONumeroNaoServe(contas, {
    tenant_id: servidor.tenant_id, provedor: servidor.provedor, canal: adapter.canal, numero,
  });
  if (motivo) return recusa(409, motivo);

  const admin = await porta.tokenDeAdmin(servidor.id);
  if (!admin) return recusa(500, 'token de administração não resolvido no Vault');

  // O token do webhook é sorteado antes de falar com o provedor, para a
  // instância nascer já apontando para o endpoint dela. Criar primeiro e
  // apontar depois deixaria uma janela em que a resposta do contato chega e
  // não tem para onde ir.
  const webhookToken = crypto.randomUUID();
  const webhookUrl = porta.urlDoWebhook(webhookToken);

  const nome = typeof pedido.nome_instancia === 'string' && pedido.nome_instancia.trim()
    ? pedido.nome_instancia.trim() : apelido;

  const criada = await adapter.provisionar({ baseUrl: servidor.base_url, adminToken: admin, nome, webhookUrl });
  if (!criada.ok || !criada.credenciais) return recusa(502, criada.erro ?? 'falha ao criar instância');

  let conta: { sender_id: string };
  try {
    conta = await porta.criarConta({
      server_id: servidor.id,
      apelido,
      identificador: numero,
      tipo_permitido: tipo,
      quota_diaria: quota,
      credenciais: criada.credenciais,
      webhook_token: webhookToken,
      config: { instancia: criada.instancia ?? nome, base_url: servidor.base_url },
    });
  } catch (e) {
    // 5. A instância existe e a conta não: sem dono, ela é a órfã do D73.
    const desfeito = await desprovisionar(servidor.provedor, criada.credenciais, buscar);
    const erro = e instanceof Error ? e.message : String(e);
    return recusa(500, desfeito.ok
      ? `a conta não foi gravada (${erro}); a instância criada no provedor foi apagada`
      : `a conta não foi gravada (${erro}); a instância "${criada.instancia ?? nome}" ficou no painel do provedor e precisa ser apagada lá (${desfeito.detalhe})`);
  }

  return {
    status: 200,
    corpo: { ok: true, sender_id: conta.sender_id, webhook_url: webhookUrl, instancia: criada.instancia, qrcode: criada.qrcode ?? null },
  };
}

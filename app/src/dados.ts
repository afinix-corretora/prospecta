/** Leituras e escritas do produto. Uma função por pergunta, nome do domínio.
 *
 * Nenhuma chamada filtra por tenant à mão: quem filtra é o RLS. Escrever o
 * filtro aqui também daria a impressão de que é ele que protege — e no dia em
 * que alguém esquecesse, ninguém notaria a diferença.
 */
import { sb } from './supabase';
import { cruzarEntregaveis } from './entregaveis';
import type { CanalEntregavel, MotivoDoCanal } from './entregaveis';

export type { CanalEntregavel, MotivoDoCanal };

export interface ProvedorCanal {
  slug: string;
  canal: 'whatsapp' | 'email' | 'sms' | 'instagram';
  nome: string;
  descricao: string;
  oficial: boolean;
  tem_adapter: boolean;
  /** Fora do ar no catálogo. O pool pergunta `tem_adapter AND ativo` antes de
   *  escolher (D31), então a tela lê as duas colunas, não uma. */
  ativo: boolean;
  campos: CampoProvedor[];
  docs_url: string | null;
  ordem: number;
}

export interface CampoProvedor {
  chave: string;
  rotulo: string;
  tipo: 'texto' | 'senha';
  obrigatorio: boolean;
  segredo: boolean;
  ajuda: string | null;
}

export interface Remetente {
  id: string;
  canal: ProvedorCanal['canal'];
  identificador: string;
  apelido: string | null;
  provedor: string;
  tipo_permitido: 'morna' | 'fria';
  quota_diaria: number;
  enviados_na_janela: number;
  estado: string;
  health_score: number;
  webhook_token: string;
  provider_server_id: string | null;
  config: Record<string, string>;
  /** Última pergunta ao provedor feita pelo botão "Verificar conexão" (D62).
   *  `null` em `verificacao_ok` é "nunca verificada", que não é "falhou". */
  verificado_em: string | null;
  verificacao_ok: boolean | null;
  verificacao_detalhe: string | null;
}

export interface Servidor {
  id: string;
  provedor: string;
  nome: string;
  base_url: string;
  admin_secret_id: string | null;
  ativo: boolean;
}

export interface Campanha {
  id: string;
  nome: string;
  tipo: 'morna' | 'fria';
  objetivo: string | null;
  ativa: boolean;
  canais_habilitados: string[];
  template_slug: string | null;
  /** A versão de flow que esta campanha roda hoje. NULL = ainda não ligada,
   *  e nesse estado inscrever recusa alto em vez de encerrar vazio (D47). */
  flow_version_id: string | null;
  /** A conta de e-mail que esta campanha usa (D62). NULL = rodízio entre as
   *  contas de e-mail do pool, que é o comportamento de antes. */
  remetente_email_id: string | null;
  /** A conta de IA desta campanha (D68), escolhida entre as conectadas em
   *  Configurações. NULL = a conta de cada agente, que é o de antes. */
  ai_credential_id: string | null;
}

export interface Modelo {
  slug: string;
  nome: string;
  descricao: string;
  objetivo: string;
  tipo: 'morna' | 'fria';
  canais: string[];
  passos: unknown[];
  ordem: number;
}

export interface Agente {
  id: string;
  nome: string;
  canal: ProvedorCanal['canal'];
  papel: string;
  descricao: string;
  instrucoes: string;
  escalar_quando: string;
  limite_trocas: number;
  pronto: boolean;
  tenant_id: string | null;
  /** Com que credencial o agente compõe (D66). NULL = não compõe, e a tela diz. */
  ai_credential_id: string | null;
  /** Frases que o rascunho nunca contém — conferidas em código, não só pedidas. */
  proibido: string[];
  tamanho_maximo: number;
  ativo: boolean;
  /** D69: o texto pronto sai sozinho pelo motor. Desligado, fica para uma pessoa (D66). */
  autonomo: boolean;
}

export interface CredencialIA {
  id: string;
  nome: string;
  provedor: string;
  modelo: string;
  /** Só o ponteiro para o Vault. A chave não volta — nem para a tela. */
  chave_secret_id: string | null;
  config: Record<string, string>;
  ativo: boolean;
}

export interface ProvedorIA {
  slug: string;
  nome: string;
  descricao: string;
  campos: CampoProvedor[];
  modelos_sugeridos: string[];
  docs_url: string | null;
  ordem: number;
  /** Se o motor sabe compor rascunho com este provedor (D66). */
  tem_adapter: boolean;
}

/** Plataforma de CRM que o produto sabe receber credencial (D59).
 *
 *  `campos` é o MESMO formato dos outros dois catálogos, e de propósito: a tela
 *  que desenha remetente, credencial de IA e conexão de CRM é a mesma ideia,
 *  e nenhuma das três conhece provedor nenhum (D28).
 */
export interface ProvedorCRM {
  slug: string;
  nome: string;
  descricao: string;
  campos: CampoProvedor[];
  /** Falso nas oito linhas hoje. Não é "não dá", é "ainda não": nenhum adapter
   *  de CRM existe, então vincular guarda a credencial e nada mais. A tela DIZ
   *  isso, porque o jeito de descobrir sozinho seria um lead que ninguém viu
   *  (D55). Fundir este "ainda não" com um "não dá" é o que o D54 proíbe. */
  tem_adapter: boolean;
  docs_url: string | null;
  ordem: number;
}

export interface ConexaoCRM {
  id: string;
  nome: string;
  provedor: string;
  /** Só o ponteiro para o Vault. A credencial não volta — nem para a tela, nem
   *  para quem a colou: `segredo_da_conexao_crm` não é concedida a
   *  `authenticated` (D44). */
  credencial_secret_id: string | null;
  config: Record<string, string>;
  ativo: boolean;
  atualizado_em: string;
}

async function tabela<T>(nome: string, colunas: string, ordem?: string): Promise<T[]> {
  let q = sb.from(nome).select(colunas);
  if (ordem) q = q.order(ordem);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as T[];
}

export const lerProvedoresCanal = () =>
  tabela<ProvedorCanal>('channel_provider_catalog',
    'slug, canal, nome, descricao, oficial, tem_adapter, ativo, campos, docs_url, ordem', 'ordem');

export const lerProvedoresIA = () =>
  tabela<ProvedorIA>('ai_provider_catalog',
    'slug, nome, descricao, campos, modelos_sugeridos, docs_url, ordem, tem_adapter', 'ordem');

export const lerCredenciaisIA = () =>
  tabela<CredencialIA>('ai_credentials', 'id, nome, provedor, modelo, chave_secret_id, config, ativo', 'nome');

export const lerProvedoresCRM = () =>
  tabela<ProvedorCRM>('crm_provider_catalog',
    'slug, nome, descricao, campos, tem_adapter, docs_url, ordem', 'ordem');

/** A RLS de `crm_connections` é só de quem administra, inclusive no SELECT —
 *  credencial de CRM é tão sensível quanto chip. Operador não vê a lista. */
export const lerConexoesCRM = () =>
  tabela<ConexaoCRM>('crm_connections',
    'id, nome, provedor, credencial_secret_id, config, ativo, atualizado_em', 'nome');

/** Conta removida (D62) fica no banco — as mensagens antigas apontam para
 *  ela — mas sai de toda lista. O filtro é aqui, na leitura, e não em cada
 *  tela: uma tela que esquecesse mostraria a conta "fora do pool à mão", e a
 *  pessoa a devolveria ao pool sem saber que a tinha removido. */
export async function lerRemetentes(): Promise<Remetente[]> {
  const { data, error } = await sb.from('sender_accounts')
    .select('id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, ' +
      'enviados_na_janela, estado, health_score, webhook_token, provider_server_id, config, ' +
      'verificado_em, verificacao_ok, verificacao_detalhe')
    .is('removido_em', null);
  if (error) throw error;
  return (data ?? []) as unknown as Remetente[];
}

export const lerServidores = () =>
  tabela<Servidor>('provider_servers', 'id, provedor, nome, base_url, admin_secret_id, ativo', 'nome');

export const lerCampanhas = () =>
  tabela<Campanha>('campaigns',
    'id, nome, tipo, objetivo, ativa, canais_habilitados, template_slug, flow_version_id, remetente_email_id, ' +
    'ai_credential_id');

export const lerModelos = () =>
  tabela<Modelo>('campaign_templates', 'slug, nome, descricao, objetivo, tipo, canais, passos, ordem', 'ordem');

export const lerAgentes = () =>
  tabela<Agente>('agents',
    'id, nome, canal, papel, descricao, instrucoes, escalar_quando, limite_trocas, pronto, tenant_id, ' +
    'ai_credential_id, proibido, tamanho_maximo, ativo, autonomo');

// ---------------------------------------------------------------------------
// Escritas
// ---------------------------------------------------------------------------

/** Servidor + token de administração, com o segredo indo para o Vault (D26). */
export async function salvarServidor(dados: {
  tenant: string; provedor: string; nome: string; baseUrl: string; adminToken: string;
}): Promise<string> {
  const { data, error } = await sb.rpc('salvar_servidor_provedor', {
    p_tenant: dados.tenant,
    p_provedor: dados.provedor,
    p_nome: dados.nome,
    p_base_url: dados.baseUrl,
    // Vazio significa "não mexe no que já está guardado": o campo volta vazio
    // na tela porque segredo não é legível.
    p_admin_token: dados.adminToken.trim() || null,
  });
  if (error) throw error;
  return data as string;
}

/** Credencial de conta que já existe no provedor — Gupshup, Meta, SMTP. */
export async function salvarCredencial(senderId: string, credenciais: Record<string, string>) {
  const { error } = await sb.rpc('salvar_credencial_remetente', {
    p_sender_id: senderId,
    p_credenciais: credenciais,
  });
  if (error) throw error;
}

/** Conta sem credencial ainda: a linha primeiro, o segredo logo depois. */
export async function criarRemetente(dados: {
  tenant: string; canal: string; provedor: string; identificador: string;
  apelido: string; tipo: 'morna' | 'fria'; quota: number; config: Record<string, string>;
}): Promise<string> {
  const { data, error } = await sb
    .from('sender_accounts')
    .insert({
      tenant_id: dados.tenant,
      canal: dados.canal,
      provedor: dados.provedor,
      identificador: dados.identificador,
      apelido: dados.apelido || null,
      tipo_permitido: dados.tipo,
      quota_diaria: dados.quota,
      config: dados.config,
    })
    .select('id')
    .single();
  if (error) throw error;
  return data.id as string;
}

/**
 * Conectar conta que já existe no provedor: a linha primeiro, o segredo logo
 * depois — `salvar_credencial_remetente` precisa do remetente para saber de
 * qual tenant e provedor ele é.
 *
 * Uma função só, chamada pela tela do canal e pelo assistente (D67): duas
 * cópias deste passo seriam duas respostas para "o que vai para `config`?", e
 * a que divergisse gravaria segredo em coluna (D28). O que se separa aqui é só
 * o que NÃO é segredo; tudo o que foi digitado vai para a função, e é ela que
 * lê o catálogo e decide.
 */
export async function conectarConta(dados: {
  tenant: string; canal: string; provedor: Pick<ProvedorCanal, 'slug' | 'campos'>;
  identificador: string; apelido: string; tipo: 'morna' | 'fria'; quota: number;
  valores: Record<string, string>;
}): Promise<string> {
  const { provedor: p, valores } = dados;
  const config = Object.fromEntries(
    p.campos.filter((c) => !c.segredo && valores[c.chave]).map((c) => [c.chave, valores[c.chave]!]),
  );
  const id = await criarRemetente({
    tenant: dados.tenant, canal: dados.canal, provedor: p.slug,
    identificador: dados.identificador, apelido: dados.apelido,
    tipo: dados.tipo, quota: dados.quota, config,
  });
  const segredos = Object.fromEntries(
    p.campos.filter((c) => valores[c.chave]).map((c) => [c.chave, valores[c.chave]!]),
  );
  await salvarCredencial(id, segredos);
  return id;
}

/** A quota é das três colunas de `sender_accounts` que a grade deixa a tela
 *  escrever (D54). O teto de verdade é o banco que aplica. */
export async function ajustarQuota(id: string, quota: number) {
  const { error } = await sb.from('sender_accounts').update({ quota_diaria: quota }).eq('id', id);
  if (error) throw error;
}

/** Só a contagem: a lista de contatos é da tela de contatos. */
export async function contarContatos(): Promise<number> {
  const { count, error } = await sb.from('contacts').select('id', { count: 'exact', head: true });
  if (error) throw error;
  return count ?? 0;
}

export interface InstanciaCriada {
  ok: boolean;
  erro?: string;
  sender_id?: string;
  webhook_url?: string;
  instancia?: string;
  qrcode?: string | null;
}

/** Cria a instância no provedor e devolve o chip pronto (D25). */
export async function provisionarInstancia(dados: {
  serverId: string; apelido: string; identificador: string;
  tipo: 'morna' | 'fria'; quota: number;
}): Promise<InstanciaCriada> {
  const { data, error } = await sb.functions.invoke('provisionar-instancia', {
    body: {
      server_id: dados.serverId,
      apelido: dados.apelido,
      identificador: dados.identificador,
      tipo_permitido: dados.tipo,
      quota_diaria: dados.quota,
    },
  });
  if (error) {
    // A edge function responde 4xx/5xx com um corpo que explica; o supabase-js
    // esconde isso atrás de "non-2xx status code".
    const corpo = await (error as { context?: Response }).context?.json?.().catch(() => null);
    return { ok: false, erro: corpo?.erro ?? error.message };
  }
  return data as InstanciaCriada;
}

/** Credencial de IA, com o catálogo separando segredo de config (D26).
 *
 * A tela manda tudo o que foi preenchido, num objeto só. Quem decide o que é
 * segredo é a função, lendo o catálogo — se a decisão morasse aqui, a UI
 * precisaria conhecer provedor, e é por não conhecer nenhum que ela não quebra
 * quando um provedor novo entra.
 */
export async function salvarCredencialIA(dados: {
  tenant: string; nome: string; provedor: string; modelo: string;
  campos: Record<string, string>;
}): Promise<string> {
  const { data, error } = await sb.rpc('salvar_credencial_ia', {
    p_tenant: dados.tenant,
    p_nome: dados.nome,
    p_provedor: dados.provedor,
    p_modelo: dados.modelo,
    p_campos: dados.campos,
  });
  if (error) throw error;
  return data as string;
}

/** Desligar não apaga: a credencial some do pool e o histórico continua. */
export async function alternarCredencialIA(id: string, ativo: boolean) {
  const { error } = await sb.from('ai_credentials').update({ ativo }).eq('id', id);
  if (error) throw error;
}

/** Vincular plataforma de CRM. Terceiro uso do padrão do D26/D28, e a mesma
 *  regra: a tela manda tudo o que foi preenchido num objeto só, e quem separa
 *  Vault de `config` é a função, lendo o catálogo. Não há `if` de provedor aqui,
 *  nem deve haver — CRM novo é uma linha de catálogo e zero mudança de UI.
 *
 *  Devolve o id da conexão. Chamar com o mesmo `nome` EDITA a que existe, e
 *  segredo em branco preserva a credencial guardada: a tela não consegue
 *  devolver o que não pode ler.
 */
export async function salvarCredencialCRM(dados: {
  tenant: string; nome: string; provedor: string;
  campos: Record<string, string>;
}): Promise<string> {
  const { data, error } = await sb.rpc('salvar_credencial_crm', {
    p_tenant: dados.tenant,
    p_nome: dados.nome,
    p_provedor: dados.provedor,
    p_campos: dados.campos,
  });
  if (error) throw error;
  return data as string;
}

/** Desligar não apaga, igual à credencial de IA: a conexão sai de uso e a
 *  credencial continua no Vault. Apagar seria perder a credencial do cliente
 *  por um clique. */
export async function alternarConexaoCRM(id: string, ativo: boolean) {
  const { error } = await sb.from('crm_connections').update({ ativo }).eq('id', id);
  if (error) throw error;
}

export async function criarCampanhaDeModelo(dados: {
  tenant: string; slug: string; nome: string; canais: string[] | null;
}) {
  const { data, error } = await sb.rpc('criar_campanha_de_modelo', {
    p_tenant: dados.tenant,
    p_slug: dados.slug,
    p_nome: dados.nome,
    p_canais: dados.canais,
  });
  if (error) throw error;
  return (data ?? [])[0] as { campaign_id: string; flow_version_id: string; passos_criados: number };
}

// ---------------------------------------------------------------------------
// O que este cliente consegue entregar hoje (D54)
// ---------------------------------------------------------------------------

/**
 * Cruza o catálogo com as contas do cliente. A regra mora em
 * `entregaveis.ts`, pura, porque é ela que tem teste; aqui só entra a leitura.
 */
export async function lerCanaisEntregaveis(): Promise<CanalEntregavel[]> {
  const [provedores, remetentes] = await Promise.all([lerProvedoresCanal(), lerRemetentes()]);
  return cruzarEntregaveis(provedores, remetentes);
}

// ---------------------------------------------------------------------------
// Ligar e desligar (D54)
// ---------------------------------------------------------------------------
//
// As quatro escritas abaixo vão DIRETO na tabela, sem função em `public`. O
// RLS já diz quem pode: `pode_operar` para campanha e inscrição,
// `pode_administrar` para remetente. Criar `pausar_campanha()` só para repetir
// isso em PL/pgSQL é o que o D41 manda não fazer.
//
// O que torna isso seguro não é esta camada — é a grade de privilégio por
// coluna do D54: `authenticated` só tem UPDATE em `campaigns(ativa, ...)`,
// `enrollments(status)` e `sender_accounts(apelido, quota_diaria, estado)`.
// Uma tela errada aqui não alcança `next_run_at` nem `enviados_na_janela`.

/** O freio da campanha inteira: o agendador pula campanha com `ativa` falso. */
export async function alternarCampanha(id: string, ativa: boolean) {
  const { error } = await sb.from('campaigns').update({ ativa }).eq('id', id);
  if (error) throw error;
}

/**
 * Pausa ou retoma TODAS as inscrições em curso de uma campanha.
 *
 * Pausar não apaga `next_run_at`: o relógio fica onde estava e retomar volta
 * para o horário que já era devido. É por isso que o filtro olha o status de
 * origem — retomar não pode ressuscitar quem encerrou, e `encerrado` é
 * inalcançável daqui de qualquer forma (o CHECK de coerência pede
 * `motivo_encerramento`, coluna que a tela não escreve).
 *
 * Devolve quantas linhas mudaram, para a tela dizer o que aconteceu em vez de
 * só piscar.
 */
export async function pausarInscricoes(campanha: string, pausar: boolean): Promise<number> {
  const { data, error } = await sb
    .from('enrollments')
    .update({ status: pausar ? 'pausado' : 'ativo' })
    .eq('campaign_id', campanha)
    .eq('status', pausar ? 'ativo' : 'pausado')
    .select('id');
  if (error) throw error;
  return (data ?? []).length;
}

/** Tirar o chip do pool à mão. `circuito_aberto` é do breaker, não daqui. */
export async function alternarRemetente(id: string, ativo: boolean) {
  const { error } = await sb
    .from('sender_accounts')
    .update({ estado: ativo ? 'ativo' : 'desativado' })
    .eq('id', id);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Configurações ▸ Blacklist (D63)
// ---------------------------------------------------------------------------
//
// Escrita direta na tabela, sem função em `public`: o RLS já diz que só quem
// administra escreve (D41). Quem normaliza o termo é o banco, com a mesma
// função que normaliza a resposta — a tela manda o que a pessoa digitou.

export type AcaoBlacklist = 'suprimir' | 'identidade_invalida' | 'recusa';

export interface TermoBlacklist {
  id: string;
  termo: string;
  /** `null` = vale sozinho. Preenchido = só com uma destas nas três palavras seguintes. */
  exige_uma_de: string[] | null;
  acao: AcaoBlacklist;
  nota: string | null;
  ativo: boolean;
  origem: 'padrao' | 'cliente';
}

export interface DominioBloqueado {
  id: string;
  dominio: string;
  nota: string | null;
  ativo: boolean;
}

export const lerBlacklistTermos = () =>
  tabela<TermoBlacklist>('blacklist_termos', 'id, termo, exige_uma_de, acao, nota, ativo, origem', 'termo');

export const lerDominiosBloqueados = () =>
  tabela<DominioBloqueado>('blacklist_dominios', 'id, dominio, nota, ativo', 'dominio');

export async function criarTermoBlacklist(d: {
  tenant: string; termo: string; contexto: string[]; acao: AcaoBlacklist; nota: string;
}) {
  const { error } = await sb.from('blacklist_termos').insert({
    tenant_id: d.tenant, termo: d.termo, acao: d.acao,
    exige_uma_de: d.contexto.length ? d.contexto : null,
    nota: d.nota.trim() || null,
  });
  if (error) throw error;
}

export async function mudarTermoBlacklist(
  id: string, mudanca: Partial<Pick<TermoBlacklist, 'acao' | 'ativo'>>,
) {
  const { error } = await sb.from('blacklist_termos').update(mudanca).eq('id', id);
  if (error) throw error;
}

export async function apagarTermoBlacklist(id: string) {
  const { error } = await sb.from('blacklist_termos').delete().eq('id', id);
  if (error) throw error;
}

export async function bloquearDominio(d: { tenant: string; dominio: string; nota: string }) {
  const { error } = await sb.from('blacklist_dominios').insert({
    tenant_id: d.tenant, dominio: d.dominio, nota: d.nota.trim() || null,
  });
  if (error) throw error;
}

export async function alternarDominio(id: string, ativo: boolean) {
  const { error } = await sb.from('blacklist_dominios').update({ ativo }).eq('id', id);
  if (error) throw error;
}

export async function apagarDominio(id: string) {
  const { error } = await sb.from('blacklist_dominios').delete().eq('id', id);
  if (error) throw error;
}

/** O que esta frase dispararia — perguntado ao classificador de verdade, no
 *  banco. Reescrever a regra aqui seria a segunda leitura que diverge (D55). */
export async function testarBlacklist(
  tenant: string, texto: string,
): Promise<{ termo: string; acao: AcaoBlacklist } | null> {
  const { data, error } = await sb.rpc('testar_blacklist', { p_tenant: tenant, p_texto: texto });
  if (error) throw error;
  const linhas = (data ?? []) as { termo: string; acao: AcaoBlacklist }[];
  return linhas[0] ?? null;
}

// ---------------------------------------------------------------------------
// Configurações ▸ E-mail (D62)
// ---------------------------------------------------------------------------

export interface ContaDeEmail {
  id: string;
  apelido: string | null;
  identificador: string;
  provedor: string;
  provedor_nome: string;
  tipo_permitido: 'morna' | 'fria';
  estado: string;
  verificado_em: string | null;
  verificacao_ok: boolean | null;
  verificacao_detalhe: string | null;
}

/** As contas de e-mail que uma campanha pode escolher. Operador lê (é ele
 *  quem monta campanha); o RLS de `sender_accounts` também deixaria, mas a
 *  função já tira as removidas e traz o nome do provedor. */
export async function lerContasDeEmail(tenant: string): Promise<ContaDeEmail[]> {
  const { data, error } = await sb.rpc('contas_de_email', { p_tenant: tenant });
  if (error) throw error;
  return (data ?? []) as ContaDeEmail[];
}

export type Verificacao =
  | { ok: true; saude: { ok: boolean; detalhe: string } }
  | { ok: false; erro: string };

/**
 * "Verificar conexão": quem pergunta ao provedor é a edge function, porque a
 * tela não tem o segredo e não deve ter. O resultado também fica gravado na
 * conta, e é de lá que a lista o lê depois — o retorno daqui é só para a
 * resposta aparecer sem recarregar.
 */
export async function verificarRemetente(id: string): Promise<Verificacao> {
  const { data, error } = await sb.functions.invoke('verificar-remetente', {
    body: { sender_id: id },
  });
  if (error) {
    const corpo = await (error as { context?: Response }).context?.json?.().catch(() => null);
    return { ok: false, erro: corpo?.erro ?? error.message };
  }
  return data as Verificacao;
}

/**
 * Remover não apaga: arquiva. As mensagens antigas apontam para a conta, e
 * apagar a linha levaria o histórico junto. A função recusa — dizendo quais —
 * se alguma campanha escolheu esta conta: tirar o chão de uma campanha ligada
 * não dá erro, dá campanha parada sem remetente.
 */
export async function removerRemetente(id: string) {
  const { error } = await sb.rpc('remover_remetente', { p_sender_id: id });
  if (error) throw error;
}

/** Qual conta de e-mail a campanha usa. `null` volta ao rodízio. Quem confere
 *  canal, pool (D4) e conta removida é o gatilho no banco, não esta tela. */
export async function definirEmailDaCampanha(campanha: string, conta: string | null) {
  const { error } = await sb.from('campaigns').update({ remetente_email_id: conta }).eq('id', campanha);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// A campanha aponta o seu flow (D47)
// ---------------------------------------------------------------------------

/** Liga a campanha a uma versão de flow. `null` desliga. */
export async function definirFlowDaCampanha(campanha: string, versao: string | null) {
  const { error } = await sb.rpc('definir_flow_da_campanha', {
    p_campaign_id: campanha,
    p_flow_version_id: versao,
  });
  if (error) throw error;
}

/** Com qual das contas de IA conectadas esta campanha compõe (D68). `null`
 *  volta à conta de cada agente. A chave não passa por aqui: a conta já está
 *  no Vault, e a campanha só aponta para ela. */
export async function definirIADaCampanha(campanha: string, credencial: string | null) {
  const { error } = await sb.from('campaigns').update({ ai_credential_id: credencial }).eq('id', campanha);
  if (error) throw error;
}

/** Quem responde por cada canal desta campanha. */
export async function atribuirAgente(campanha: string, agente: string) {
  const { error } = await sb.rpc('atribuir_agente', {
    p_campaign_id: campanha,
    p_agent_id: agente,
  });
  if (error) throw error;
}

export interface AgenteDaCampanha {
  canal: ProvedorCanal['canal'];
  agent_id: string;
}

export async function lerAgentesDaCampanha(campanha: string): Promise<AgenteDaCampanha[]> {
  const { data, error } = await sb
    .from('campaign_agents')
    .select('canal, agent_id')
    .eq('campaign_id', campanha);
  if (error) throw error;
  return (data ?? []) as AgenteDaCampanha[];
}

/**
 * Campanha que não vem de modelo (D55).
 *
 * A cadência é apontada dentro da mesma transação, e não por uma segunda
 * chamada daqui: inserir a campanha e apontar o flow de fora é a janela do
 * D54 — criou, caiu a rede, campanha órfã.
 */
export async function criarCampanha(dados: {
  tenant: string; nome: string; tipo: 'morna' | 'fria'; baseLegal: string;
  canais: string[]; objetivo: string; versao: string | null;
}): Promise<string> {
  const { data, error } = await sb.rpc('criar_campanha', {
    p_tenant: dados.tenant,
    p_nome: dados.nome,
    p_tipo: dados.tipo,
    p_base_legal: dados.baseLegal,
    p_canais: dados.canais,
    p_objetivo: dados.objetivo,
    p_flow_version_id: dados.versao,
  });
  if (error) throw error;
  return data as string;
}

export async function criarTenant(nome: string, slug: string): Promise<string> {
  const { data, error } = await sb.rpc('criar_tenant', { p_nome: nome, p_slug: slug });
  if (error) throw error;
  return data as string;
}

// ---------------------------------------------------------------------------
// Importação de contatos (D32, D34)
// ---------------------------------------------------------------------------

export interface LinhaPrevista {
  linha: number;
  acao: 'criar' | 'atualizar' | 'recusar';
  contact_id: string | null;
  nome_atual: string | null;
  identidades_novas: number;
  identidades_existentes: number;
  identidades_suprimidas: number;
  problema: string | null;
}

/** O que `ingerir_contato` faria, sem gravar nada. */
export async function preverIngestao(
  tenant: string,
  linhas: { linha: number; identidades: { canal: string; valor_norm: string }[] }[],
): Promise<LinhaPrevista[]> {
  const { data, error } = await sb.rpc('prever_ingestao', {
    p_tenant: tenant,
    p_linhas: linhas,
  });
  if (error) throw error;
  return (data ?? []) as LinhaPrevista[];
}

export interface ContatoIngerido {
  contact_id: string;
  acao: 'criado' | 'atualizado';
  identidades_novas: number;
  identidades_existentes: number;
  identidades_suprimidas: number;
}

/**
 * Uma chamada por linha, de propósito.
 *
 * Um laço no servidor seria uma viagem só, mas colocaria as 500 linhas na
 * mesma transação: uma recusa no meio desfaz as 499 que já tinham passado.
 * Assim cada linha é a sua própria transação, o progresso é real e a linha que
 * falha não leva as outras junto. O custo é a latência, e é o custo certo —
 * importação é operação de uma vez por dia, não caminho quente.
 */
export async function ingerirContato(dados: {
  tenant: string; origem: string; identidades: unknown[];
  nome?: string; origemRef?: string; metadados?: Record<string, string>;
}): Promise<ContatoIngerido> {
  const { data, error } = await sb.rpc('ingerir_contato', {
    p_tenant: dados.tenant,
    p_origem: dados.origem,
    p_identidades: dados.identidades,
    p_nome: dados.nome ?? null,
    p_origem_ref: dados.origemRef ?? null,
    p_metadados: dados.metadados ?? {},
  });
  if (error) throw error;
  return (data ?? [])[0] as ContatoIngerido;
}

// ---------------------------------------------------------------------------
// Contatos e inscrição em campanha (D35)
// ---------------------------------------------------------------------------

export interface IdentidadeDoContato {
  canal: ProvedorCanal['canal'];
  valor: string;
  valor_norm: string;
  valida: boolean;
}

export interface Contato {
  id: string;
  nome: string | null;
  origem: string;
  origem_ref: string | null;
  criado_em: string;
  contact_identities: IdentidadeDoContato[];
}

/**
 * A busca é por nome e por identidade, porque as duas são como se procura
 * alguém: pelo nome que a planilha trouxe, ou pelo número que apareceu no
 * WhatsApp. `valor_norm` está no filtro de propósito — quem digita
 * "(15) 99123-4567" não acha nada procurando pelo que está gravado.
 */
export async function lerContatos(busca = '', limite = 200): Promise<Contato[]> {
  const colunas = 'id, nome, origem, origem_ref, criado_em, '
    + 'contact_identities(canal, valor, valor_norm, valida)';
  let q = sb.from('contacts').select(colunas).order('criado_em', { ascending: false }).limit(limite);

  const termo = busca.trim();
  if (termo) {
    const digitos = termo.replace(/\D/g, '');
    const alvos = [`nome.ilike.%${termo}%`];
    if (digitos.length >= 4) alvos.push(`contact_identities.valor_norm.ilike.%${digitos}%`);
    else alvos.push(`contact_identities.valor_norm.ilike.%${termo.toLowerCase()}%`);
    q = q.or(alvos.join(','));
  }

  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as unknown as Contato[];
}

export interface VersaoDeFlow {
  id: string;
  flow_id: string;
  versao: number;
  flow_nome: string;
  canais: ProvedorCanal['canal'][];
  passos: number;
  publicado_em: string;
}

/**
 * As versões de flow publicadas, com os canais que cada uma usa.
 *
 * O canal aparece aqui porque é o que decide se a inscrição vale: flow de
 * e-mail numa campanha só de WhatsApp não manda nada para ninguém, e o
 * operador não tem como saber isso olhando o nome.
 */
export async function lerVersoesDeFlow(): Promise<VersaoDeFlow[]> {
  const { data, error } = await sb
    .from('flow_versions')
    .select('id, flow_id, versao, publicado_em, flows(nome), flow_steps(canal, ordem)')
    .order('publicado_em', { ascending: false });
  if (error) throw error;

  return (data ?? []).map((v) => {
    const linha = v as unknown as {
      id: string; flow_id: string; versao: number; publicado_em: string;
      flows: { nome: string } | { nome: string }[] | null;
      flow_steps: { canal: ProvedorCanal['canal'] }[] | null;
    };
    const flow = Array.isArray(linha.flows) ? linha.flows[0] : linha.flows;
    const passos = linha.flow_steps ?? [];
    return {
      id: linha.id,
      flow_id: linha.flow_id,
      versao: linha.versao,
      flow_nome: flow?.nome ?? '(sem nome)',
      canais: [...new Set(passos.map((p) => p.canal))],
      passos: passos.length,
      publicado_em: linha.publicado_em,
    };
  });
}

// ---------------------------------------------------------------------------
// Escrever a cadência (D55)
// ---------------------------------------------------------------------------

export interface PassoDeFlow {
  ordem: number;
  canal: ProvedorCanal['canal'];
  atraso_horas: number;
  template: string;
}

/** Os passos de uma versão, em ordem. É o que a tela carrega para partir de
 *  uma cadência que já existe — editar é publicar a seguinte (D9). */
export async function lerPassosDaVersao(versao: string): Promise<PassoDeFlow[]> {
  const { data, error } = await sb
    .from('flow_steps')
    .select('ordem, canal, atraso_horas, template')
    .eq('flow_version_id', versao)
    .order('ordem');
  if (error) throw error;
  return (data ?? []) as PassoDeFlow[];
}

export interface VariavelDisponivel { chave: string; contatos: number }

/** As chaves que os templates podem usar, com quantos contatos têm cada uma.
 *  Variável sem valor é apagada por `renderizar`, e o rastro é o "Olá ," do
 *  D42 — este número é o mesmo aviso, antes de escrever. */
export async function lerVariaveisDisponiveis(tenant: string): Promise<VariavelDisponivel[]> {
  const { data, error } = await sb.rpc('variaveis_disponiveis', { p_tenant: tenant });
  if (error) throw error;
  return (data ?? []) as VariavelDisponivel[];
}

/**
 * Publica uma versão de cadência. `flowId` nulo cria a cadência.
 *
 * NÃO reponta campanha nenhuma: repontar é `definirFlowDaCampanha`, uma a uma,
 * porque é lá que mora a conferência de canais do D47 — a versão nova pode ter
 * deixado de tocar um canal que a campanha habilita, e trocar em massa
 * esconderia isso.
 */
export async function publicarVersaoDeFlow(dados: {
  tenant: string; flowId: string | null; nome: string | null;
  passos: { canal: string; atraso_horas: number; template: string }[];
}): Promise<{ flow_id: string; flow_version_id: string; versao: number; passos_criados: number }> {
  const { data, error } = await sb.rpc('publicar_versao_de_flow', {
    p_tenant: dados.tenant,
    p_flow_id: dados.flowId,
    p_nome: dados.nome,
    p_passos: dados.passos,
  });
  if (error) throw error;
  return (data ?? [])[0] as
    { flow_id: string; flow_version_id: string; versao: number; passos_criados: number };
}

export interface ContatoPrevisto {
  contact_id: string;
  nome: string | null;
  acao: 'inscrever' | 'ja_inscrito' | 'suprimido' | 'sem_canal' | 'desconhecido';
  canais_alcancaveis: ProvedorCanal['canal'][] | null;
  problema: string | null;
}

/**
 * O que a inscrição faria com cada contato, sem inscrever ninguém.
 *
 * Sem `versao` de propósito (D47): qual flow a campanha roda é pergunta da
 * campanha, e perguntá-la a cada inscrição é dar N chances de responder
 * diferente — sendo que a resposta errada não dá erro, dá campanha
 * "concluída" sem mensagem nenhuma. Campanha ainda sem flow não devolve lista
 * vazia: devolve uma linha por contato dizendo por que não daria.
 */
export async function preverInscricao(dados: {
  tenant: string; campanha: string; contatos: string[];
}): Promise<ContatoPrevisto[]> {
  const { data, error } = await sb.rpc('prever_inscricao_pela_campanha', {
    p_tenant: dados.tenant,
    p_campaign_id: dados.campanha,
    p_contatos: dados.contatos,
  });
  if (error) throw error;
  return (data ?? []) as ContatoPrevisto[];
}

/**
 * Devolve o id do enrollment, ou `null` quando o contato está suprimido — e o
 * nulo mudo é exatamente o motivo de a prévia existir. Uma chamada por
 * contato, pela mesma razão da importação: a que falha não leva as outras.
 */
export async function inscrever(dados: {
  contato: string; campanha: string;
}): Promise<string | null> {
  const { data, error } = await sb.rpc('inscrever_pela_campanha', {
    p_contact_id: dados.contato,
    p_campaign_id: dados.campanha,
  });
  if (error) throw error;
  return (data ?? null) as string | null;
}

// ---------------------------------------------------------------------------
// Painel da campanha (D36)
// ---------------------------------------------------------------------------

export interface ResumoDaCampanha {
  inscritos_ativos: number;
  inscritos_pausados: number;
  encerrados: number;
  por_motivo: Record<string, number>;
  mensagens: number;
  por_status: Record<string, number>;
  respostas: number;
  cliques: number;
  vencidos_agora: number;
  proximo_disparo: string | null;
}

export async function lerResumoDaCampanha(
  tenant: string, campanha: string,
): Promise<ResumoDaCampanha | null> {
  const { data, error } = await sb.rpc('resumo_da_campanha', {
    p_tenant: tenant, p_campaign_id: campanha,
  });
  if (error) throw error;
  return ((data ?? [])[0] as ResumoDaCampanha) ?? null;
}

export interface EventoDaCampanha {
  ocorrido_em: string;
  contato: string;
  canal: ProvedorCanal['canal'];
  tipo: string;
  status: 'pendente' | 'simulado' | 'enviado' | 'falha' | 'cancelado';
  remetente: string;
  destino: string;
}

export async function lerEventosDaCampanha(
  tenant: string, campanha: string, limite = 100,
): Promise<EventoDaCampanha[]> {
  const { data, error } = await sb.rpc('eventos_da_campanha', {
    p_tenant: tenant, p_campaign_id: campanha, p_limite: limite,
  });
  if (error) throw error;
  return (data ?? []) as EventoDaCampanha[];
}

// ---------------------------------------------------------------------------
// O funil (D57)
// ---------------------------------------------------------------------------

export type TipoEstagio = 'aberto' | 'ganho' | 'perdido';
export type OrigemMovimento = 'motor' | 'ia' | 'pessoa';

export interface Estagio {
  id: string;
  nome: string;
  /** O que o CÓDIGO conhece. `nome` é rótulo e pode ser renomeado à vontade —
   *  era exatamente assim que quebrava nos projetos que buscavam pelo nome. */
  slug: string;
  posicao: number;
  cor: string | null;
  tipo: TipoEstagio;
}

export interface Card {
  id: string;
  contact_id: string;
  stage_id: string;
  entrou_no_estagio_em: string;
  movido_por: OrigemMovimento;
  motivo: string | null;
  contato: string;
  campanha: string | null;
}

export async function lerEstagios(): Promise<Estagio[]> {
  const { data, error } = await sb
    .from('pipeline_stages')
    .select('id, nome, slug, posicao, cor, tipo')
    .order('posicao');
  if (error) throw error;
  return (data ?? []) as Estagio[];
}

export async function lerCards(): Promise<Card[]> {
  const { data, error } = await sb
    .from('deals')
    .select('id, contact_id, stage_id, entrou_no_estagio_em, movido_por, motivo,'
          + ' contacts(nome), campaigns(nome)')
    .order('entrou_no_estagio_em', { ascending: false });
  if (error) throw error;

  return (data ?? []).map((d) => {
    const l = d as unknown as {
      id: string; contact_id: string; stage_id: string; entrou_no_estagio_em: string;
      movido_por: OrigemMovimento; motivo: string | null;
      contacts: { nome: string | null } | { nome: string | null }[] | null;
      campaigns: { nome: string } | { nome: string }[] | null;
    };
    const c = Array.isArray(l.contacts) ? l.contacts[0] : l.contacts;
    const camp = Array.isArray(l.campaigns) ? l.campaigns[0] : l.campaigns;
    return {
      id: l.id,
      contact_id: l.contact_id,
      stage_id: l.stage_id,
      entrou_no_estagio_em: l.entrou_no_estagio_em,
      movido_por: l.movido_por,
      motivo: l.motivo,
      contato: c?.nome ?? '(sem nome)',
      campanha: camp?.nome ?? null,
    };
  });
}

/**
 * A única porta para mover um card.
 *
 * Não existe UPDATE em `deals` para o cliente (D54): a função grava a
 * atividade, carimba a entrada no estágio e aplica a regra de que automação
 * não tira card de ganho nem de perdido. Aqui sempre vai como `pessoa` —
 * quem chama é alguém arrastando.
 */
export async function moverCard(deal: string, slug: string, motivo?: string): Promise<boolean> {
  const { data, error } = await sb.rpc('mover_deal', {
    p_deal_id: deal,
    p_stage_slug: slug,
    p_origem: 'pessoa',
    p_motivo: motivo ?? null,
  });
  if (error) throw error;
  return Boolean(data);
}

// ---------------------------------------------------------------------------
// O que as pessoas responderam (D56)
// ---------------------------------------------------------------------------

export interface RespostaRecebida {
  ocorrido_em: string;
  contact_id: string;
  contato: string;
  canal: ProvedorCanal['canal'];
  destino: string;
  campanha: string;
  campaign_id: string;
  passo: number | null;
  /** Nulo quando o provedor não mandou o texto como string. Vazio é honesto;
   *  "[object Object]" seria inventar que a pessoa escreveu isso. */
  texto: string | null;
  em_resposta_a: string;
  suprimido: boolean;
  motivo_supressao: string | null;
}

/**
 * O que chegou de volta, mais recente primeiro.
 *
 * Sem `p_campaign_id` traz de todas as campanhas — que é como se olha o dia,
 * porque resposta encerra a cadência do contato em todas elas (invariante 4).
 */
export async function lerRespostas(
  tenant: string, campanha?: string, limite = 100,
): Promise<RespostaRecebida[]> {
  const { data, error } = await sb.rpc('respostas_recebidas', {
    p_tenant: tenant,
    p_campaign_id: campanha ?? null,
    p_limite: limite,
  });
  if (error) throw error;
  return (data ?? []) as RespostaRecebida[];
}

// ---------------------------------------------------------------------------
// Writeback: o que o motor tem para contar ao CRM (D46)
// ---------------------------------------------------------------------------

export interface ResumoDaOutbox {
  pendentes: number;
  enviados: number;
  falhados: number;
  vencidos_agora: number;
  /** Nulo quando não há pendente. É o número que separa fila vazia de dreno
   *  parado — sem ele, as duas situações são a mesma tela. */
  pendente_mais_antigo_em_horas: number | null;
}

export async function lerResumoDaOutbox(tenant: string): Promise<ResumoDaOutbox | null> {
  const { data, error } = await sb.rpc('resumo_da_outbox', { p_tenant: tenant });
  if (error) throw error;
  return ((data ?? [])[0] as ResumoDaOutbox) ?? null;
}

export interface WritebackFalhado {
  writeback_id: string;
  contact_id: string;
  nome: string | null;
  destino: string;
  fato: 'opt_out' | 'identidade_invalida' | 'respondido' | 'campanha_concluida';
  tentativas: number;
  ultimo_erro: string | null;
  criado_em: string;
}

export async function lerWritebacksFalhados(
  tenant: string, limite = 50,
): Promise<WritebackFalhado[]> {
  const { data, error } = await sb.rpc('writebacks_falhados', {
    p_tenant: tenant, p_limite: limite,
  });
  if (error) throw error;
  return (data ?? []) as WritebackFalhado[];
}

// ---------------------------------------------------------------------------
// Supressão (D41)
// ---------------------------------------------------------------------------

export interface Supressao {
  id: string;
  contact_id: string | null;
  canal: ProvedorCanal['canal'] | null;
  valor_norm: string | null;
  motivo: string;
  criado_em: string;
  contacts: { nome: string | null } | null;
}

export const lerSupressoes = (limite = 500) =>
  tabela<Supressao>('suppression',
    'id, contact_id, canal, valor_norm, motivo, criado_em, contacts(nome)', 'criado_em')
    .then((l) => l.slice(-limite).reverse());

/**
 * Uma supressão por endereço: vale para quem já está na base e para quem
 * ainda vai entrar, porque `esta_suprimido` casa por `(canal, valor_norm)`
 * independentemente de existir contato.
 *
 * Não há função de remover, e não é esquecimento: `suppression` é imutável
 * por gatilho. Tirar alguém de lá seria voltar a falar com quem pediu para
 * parar, e isso não é operação de tela.
 */
export async function suprimirEndereco(dados: {
  tenant: string; canal: string; valorNorm: string; motivo: string;
}): Promise<'nova' | 'ja_existia'> {
  const { error } = await sb.from('suppression').insert({
    tenant_id: dados.tenant,
    canal: dados.canal,
    valor_norm: dados.valorNorm,
    motivo: dados.motivo,
  });
  // 23505 é violação de índice único: já estava suprimido, que é sucesso do
  // ponto de vista de quem pediu — o endereço não recebe nada de qualquer jeito.
  if (error && (error as { code?: string }).code === '23505') return 'ja_existia';
  if (error) throw error;
  return 'nova';
}

/** Supressão do contato inteiro: nenhum canal, nunca mais. */
export async function suprimirContato(dados: {
  tenant: string; contato: string; motivo: string;
}): Promise<'nova' | 'ja_existia'> {
  const { error } = await sb.from('suppression').insert({
    tenant_id: dados.tenant,
    contact_id: dados.contato,
    motivo: dados.motivo,
  });
  if (error && (error as { code?: string }).code === '23505') return 'ja_existia';
  if (error) throw error;
  return 'nova';
}

export interface MensagemComposta {
  message_id: string;
  criado_em: string;
  contato: string;
  canal: ProvedorCanal['canal'];
  destino: string;
  /** Nulo na mensagem do agente (D69): ela responde, não é passo de cadência. */
  passo: number | null;
  status: EventoDaCampanha['status'];
  remetente: string;
  conteudo: string;
  buraco: boolean;
}

/** O texto que o motor compôs — em shadow mode, a única forma de vê-lo. */
export async function lerMensagensDaCampanha(
  tenant: string, campanha: string, limite = 50,
): Promise<MensagemComposta[]> {
  const { data, error } = await sb.rpc('mensagens_da_campanha', {
    p_tenant: tenant, p_campaign_id: campanha, p_limite: limite,
  });
  if (error) throw error;
  return (data ?? []) as MensagemComposta[];
}

// ---------------------------------------------------------------------------
// CRM: o que cada fato faz e de onde vêm contatos (D64)
// ---------------------------------------------------------------------------

export interface CampoCRM { id: string; rotulo: string; tipo: string; opcoes: string[] }
export interface FaseCRM { id: string; nome: string; campos: CampoCRM[] }
export interface PipeCRM { id: string; nome: string; fases: FaseCRM[]; camposIniciais: CampoCRM[] }

/** O que a plataforma tem, lido pela edge function e guardado no banco. A
 *  tela oferece escolhas daqui em vez de pedir id digitado à mão. */
export interface EstruturaCRM {
  conexao_id: string;
  estrutura: { pipes: PipeCRM[] } | null;
  descoberto_em: string;
  erro: string | null;
}

export type FatoCRM = 'respondido' | 'opt_out' | 'identidade_invalida' | 'campanha_concluida';

export interface AcaoCRM {
  id: string;
  conexao_id: string;
  pipe_id: string;
  fato: FatoCRM;
  tipo: 'mover_fase' | 'preencher_campo';
  alvo_id: string;
  alvo_rotulo: string | null;
  valor: string | null;
  ordem: number;
  ativo: boolean;
}

export interface FonteCRM {
  id: string;
  conexao_id: string;
  nome: string;
  pipe_id: string;
  pipe_rotulo: string | null;
  fases: string[];
  mapa: Record<string, string>;
  campaign_id: string | null;
  intervalo_minutos: number;
  ativa: boolean;
  ultima_execucao: string | null;
  ultimo_resultado: Record<string, unknown> | null;
}

export async function lerEstruturaCRM(conexao: string): Promise<EstruturaCRM | null> {
  const { data, error } = await sb.from('crm_estruturas')
    .select('conexao_id, estrutura, descoberto_em, erro').eq('conexao_id', conexao).maybeSingle();
  if (error) throw error;
  return (data ?? null) as EstruturaCRM | null;
}

export async function lerAcoesCRM(conexao: string): Promise<AcaoCRM[]> {
  const { data, error } = await sb.from('crm_acoes')
    .select('id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo')
    .eq('conexao_id', conexao).order('ordem');
  if (error) throw error;
  return (data ?? []) as AcaoCRM[];
}

export async function lerFontesCRM(conexao: string): Promise<FonteCRM[]> {
  const { data, error } = await sb.from('crm_fontes')
    .select('id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa, campaign_id, intervalo_minutos, ativa, ultima_execucao, ultimo_resultado')
    .eq('conexao_id', conexao).order('nome');
  if (error) throw error;
  return (data ?? []) as FonteCRM[];
}

/** Lê pipes, fases e campos na plataforma. Quem tem o segredo é a edge
 *  function; a tela só pede e mostra (D62). */
export async function descobrirCRM(conexao: string): Promise<{ ok: boolean; erro?: string }> {
  const { data, error } = await sb.functions.invoke('crm-descobrir', { body: { conexao_id: conexao } });
  if (error) {
    const corpo = await (error as { context?: Response }).context?.json?.().catch(() => null);
    return { ok: false, erro: corpo?.erro ?? error.message };
  }
  return data as { ok: boolean; erro?: string };
}

/** Escreve direto: o RLS (quem administra) e a grade por coluna já dizem quem
 *  pode — repetir em função seria o D41. */
export async function criarAcaoCRM(dados: Omit<AcaoCRM, 'id' | 'ativo'> & { tenant: string }) {
  const { tenant, ...resto } = dados;
  const { error } = await sb.from('crm_acoes').insert({ tenant_id: tenant, ...resto });
  if (error) throw error;
}

export async function alternarAcaoCRM(id: string, ativo: boolean) {
  const { error } = await sb.from('crm_acoes').update({ ativo }).eq('id', id);
  if (error) throw error;
}

export async function apagarAcaoCRM(id: string) {
  const { error } = await sb.from('crm_acoes').delete().eq('id', id);
  if (error) throw error;
}

export async function criarFonteCRM(dados: {
  tenant: string; conexao_id: string; nome: string; pipe_id: string; pipe_rotulo: string;
  fases: string[]; mapa: Record<string, string>; campaign_id: string | null; intervalo_minutos: number;
}) {
  const { tenant, ...resto } = dados;
  const { error } = await sb.from('crm_fontes').insert({ tenant_id: tenant, ...resto });
  if (error) throw error;
}

export async function alternarFonteCRM(id: string, ativa: boolean) {
  const { error } = await sb.from('crm_fontes').update({ ativa }).eq('id', id);
  if (error) throw error;
}

export async function apagarFonteCRM(id: string) {
  const { error } = await sb.from('crm_fontes').delete().eq('id', id);
  if (error) throw error;
}

/** Os últimos fatos que saíram da fila, com o que o dreno FEZ (D64). "Saiu"
 *  não quer dizer "escreveu": sem card ligado, o fato sai dizendo isso. */
export interface WritebackSaido {
  id: string;
  fato: WritebackFalhado['fato'];
  resultado: string | null;
  criado_em: string;
}

export async function lerWritebacksSaidos(limite = 20): Promise<WritebackSaido[]> {
  const { data, error } = await sb.from('outbox')
    .select('id, fato, resultado, criado_em')
    .eq('status', 'enviado').not('resultado', 'is', null)
    .order('criado_em', { ascending: false }).limit(limite);
  if (error) throw error;
  return (data ?? []) as WritebackSaido[];
}

// ---------------------------------------------------------------------------
// O agente e o rascunho (D66)
// ---------------------------------------------------------------------------

export type SituacaoRascunho = 'pronto' | 'recusa' | 'escalar' | 'bloqueado' | 'limite' | 'sem_credencial' | 'erro';

/** Para onde foi o texto pronto (D69). */
export type EnvioRascunho = 'pessoa' | 'fila' | 'devolvido';

export interface Rascunho {
  id: string;
  contact_id: string;
  agent_id: string | null;
  resposta_em: string;
  situacao: SituacaoRascunho;
  texto: string | null;
  motivo: string | null;
  modelo: string | null;
  envio: EnvioRascunho;
  envio_motivo: string | null;
  /** O status da mensagem do agente, quando o texto foi para a fila. */
  mensagem_status: string | null;
}

/** Os rascunhos recentes. A tela casa cada um com a resposta pelo contato e
 *  pelo instante, que vêm da mesma linha de `message_events`. Desde o D69,
 *  com o status da mensagem que o agente mandou — "na fila" não é "enviado". */
export async function lerRascunhos(limite = 300): Promise<Rascunho[]> {
  const { data, error } = await sb.from('rascunhos')
    .select('id, contact_id, agent_id, resposta_em, situacao, texto, motivo, modelo, envio, envio_motivo')
    .order('resposta_em', { ascending: false }).limit(limite);
  if (error) throw error;
  const lista = (data ?? []) as Omit<Rascunho, 'mensagem_status'>[];
  const naFila = lista.filter((r) => r.envio === 'fila').map((r) => r.id);
  const status = new Map<string, string>();
  if (naFila.length) {
    const { data: msgs, error: e2 } = await sb.from('messages')
      .select('rascunho_id, status').in('rascunho_id', naFila);
    if (e2) throw e2;
    for (const m of (msgs ?? []) as { rascunho_id: string; status: string }[]) status.set(m.rascunho_id, m.status);
  }
  return lista.map((r) => ({ ...r, mensagem_status: status.get(r.id) ?? null }));
}

/** Só as colunas que a grade deixa a tela escrever (D66). */
export async function salvarAgente(id: string, campos: Pick<Agente,
  'instrucoes' | 'escalar_quando' | 'limite_trocas' | 'tamanho_maximo' | 'proibido' | 'ai_credential_id' | 'ativo'
  | 'autonomo'>) {
  const { error } = await sb.from('agents').update(campos).eq('id', id);
  if (error) throw error;
}

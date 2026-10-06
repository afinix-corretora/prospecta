// A porta do agente (D66, D69), irmã de `porta.ts` e `porta-crm.ts`.
//
// Arquivo próprio pelo motivo do D64: só a function que rascunha empacota
// isto, e as outras não mudam de bundle por causa dele.

/** Uma linha de `respostas_para_rascunhar`: a resposta e tudo o que o agente precisa. */
export interface RespostaParaRascunhar {
  readonly message_event_id: string;
  readonly tenant_id: string;
  readonly contact_id: string;
  readonly canal: string;
  readonly texto: string;
  /** Ação da blacklist do cliente que casou com o texto, ou null. */
  readonly regra: string | null;
  readonly agent_id: string;
  readonly agente_nome: string;
  readonly papel: string;
  readonly descricao: string;
  readonly instrucoes: string;
  readonly escalar_quando: string;
  readonly limite_trocas: number;
  readonly proibido: string[];
  readonly tamanho_maximo: number;
  readonly credencial_id: string | null;
  readonly provedor: string | null;
  readonly modelo: string | null;
  readonly provedor_compoe: boolean;
  readonly contato_nome: string | null;
  readonly metadados: Record<string, unknown> | null;
  readonly campanha: string;
  readonly historico: { de: 'nos' | 'pessoa'; texto: string }[];
  readonly rascunhos_anteriores: number;
  /** D69: o agente manda sozinho o rascunho pronto. */
  readonly autonomo: boolean;
  /** D69: composições do cliente nas últimas 24h, e o teto dele. */
  readonly composicoes_hoje: number;
  readonly teto: number;
}

export type Situacao = 'pronto' | 'recusa' | 'escalar' | 'bloqueado' | 'limite' | 'sem_credencial' | 'erro';

/**
 * Para onde foi o texto pronto (D69): para a fila do motor, para uma pessoa
 * (agente não autônomo), ou devolvido a uma pessoa com o motivo gravado.
 */
export type Envio = 'fila' | 'pessoa' | 'devolvido';

export interface BancoAgente {
  respostasParaRascunhar(limite: number): Promise<RespostaParaRascunhar[]>;
  /** A chave do Vault, já como objeto. Fora daqui ninguém toca em segredo. */
  credenciaisDaIa(credencialId: string): Promise<Record<string, string>>;
  registrarRascunho(
    messageEventId: string, agentId: string, situacao: Situacao,
    texto: string | null, motivo: string | null, modelo: string | null,
  ): Promise<void>;
  /**
   * D69: o rascunho pronto vira mensagem, pelo caminho de envio do motor. O
   * banco decide — autonomia, supressão, janela, conta, quota — e grava o
   * motivo quando devolve. Repetir não cria outra mensagem.
   */
  enfileirarResposta(messageEventId: string, modo: 'simulado' | 'real'): Promise<Envio>;
}

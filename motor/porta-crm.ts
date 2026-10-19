// A porta do CRM (D64), irmã de `porta.ts`.
//
// Mora num arquivo próprio para que as edge functions que não falam com CRM
// não empacotem uma linha dela: o digest de cada bundle (D51) só muda quando
// o que ela leva muda, e republicar três functions intocadas seria custo sem
// fato novo.

/** Uma linha de `plano_de_writeback`. `nada` traz o motivo de não haver ação. */
export interface LinhaDoPlano {
  readonly conexao_id: string;
  readonly provedor: string;
  readonly ref_externa: string | null;
  readonly tipo: 'mover_fase' | 'preencher_campo' | 'nada';
  readonly alvo_id: string | null;
  readonly valor: string | null;
  readonly motivo: string | null;
}

export interface FonteVencida {
  readonly fonte_id: string;
  readonly conexao_id: string;
  readonly provedor: string;
  readonly pipe_id: string;
  readonly fases: string[];
  /** id do campo → papel (`adapters/leitura.ts`). `titulo` é o título do card. */
  readonly mapa: Record<string, string>;
  readonly campaign_id: string | null;
}

export interface BancoCrm {
  reivindicarWritebacks(limite: number): Promise<{ writeback_id: string; fato: string }[]>;
  planoDeWriteback(writebackId: string): Promise<LinhaDoPlano[]>;
  /**
   * `config` da conexão mais o segredo do Vault, juntos. Fora daqui ninguém
   * toca em segredo — mesma regra de `credenciaisDoRemetente`.
   */
  credenciaisDaConexao(conexaoId: string): Promise<Record<string, string>>;
  concluirWriteback(writebackId: string, ok: boolean, resultado: string, erro?: string): Promise<void>;

  fontesVencidas(): Promise<FonteVencida[]>;
  refsVinculadas(conexaoId: string): Promise<Set<string>>;
  ingerirDoCrm(
    fonteId: string,
    ref: string,
    identidades: unknown[],
    nome: string | null,
    metadados: Record<string, string>,
  ): Promise<{ acao: string; inscricao: string }>;
  registrarExecucaoFonte(fonteId: string, resultado: Record<string, unknown>): Promise<void>;
}

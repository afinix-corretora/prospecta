// O que falta para salvar uma credencial (D77b) — a regra que a tela repete do
// banco, para o botão não parecer quebrado e o texto dizer a verdade.
//
// Quem decide é o banco: `salvar_credencial_ia` e `salvar_credencial_crm`
// (migration 20261013110000). A chave guardada foi dada a UM destino — o
// provedor e os campos que o catálogo marca `destino` —, então ela só vale em
// branco quando o provedor é o mesmo, nenhuma chave nova veio e nenhum destino
// mudou. Trocar uma das chaves pede as outras. Os casos de
// `tests/credencial.test.ts` são os mesmos de `tests/auditoria.sql`, um de
// cada lado: divergir é a tela habilitando o botão que o banco recusa.
//
// Pura: não lê rede, não sabe de React.

export interface CampoDaCredencial {
  readonly chave: string;
  readonly rotulo: string;
  readonly obrigatorio: boolean;
  readonly segredo: boolean;
  /** O campo decide para onde a chave vai (endereço, domínio, data center). */
  readonly destino?: boolean;
}

export interface CredencialGuardada {
  readonly provedor: string;
  readonly temSegredo: boolean;
  readonly config: Readonly<Record<string, string>>;
}

export type PorQue = 'provedor' | 'endereco' | 'outra_chave';

/** O mesmo de `privado.mesmo_destino`: caixa, espaço e barra no fim não mudam o endereço. */
export function mesmoDestino(a: string | undefined, b: string | undefined): boolean {
  const n = (x: string | undefined) => (x ?? '').trim().replace(/\/+$/, '').toLowerCase();
  return n(a) === n(b);
}

export function oQueFalta(
  campos: readonly CampoDaCredencial[], provedor: string,
  valores: Readonly<Record<string, string>>, guardada: CredencialGuardada | null,
): { faltam: CampoDaCredencial[]; porQue: PorQue | null } {
  const preenchido = (c: CampoDaCredencial) => !!(valores[c.chave] ?? '').trim();
  const chaveNova = campos.some((c) => c.segredo && preenchido(c));
  const mesmoProvedor = !!guardada && guardada.provedor === provedor;
  // Sem chave nova, o banco mantém o campo não secreto que o pedido não trouxe.
  const efetivo = (c: CampoDaCredencial) =>
    c.chave in valores ? valores[c.chave] : mesmoProvedor && !chaveNova ? guardada!.config[c.chave] : undefined;
  const mudouDestino = mesmoProvedor
    && campos.some((c) => c.destino && !mesmoDestino(efetivo(c), guardada!.config[c.chave]));
  const reaproveita = mesmoProvedor && guardada!.temSegredo && !chaveNova && !mudouDestino;

  const faltam = campos.filter((c) => c.obrigatorio
    && !(efetivo(c) ?? '').trim()
    && !(c.segredo && reaproveita));
  const porQue: PorQue | null = !guardada?.temSegredo || !faltam.some((c) => c.segredo) ? null
    : chaveNova ? 'outra_chave' : !mesmoProvedor ? 'provedor' : mudouDestino ? 'endereco' : null;
  return { faltam, porQue };
}

/** O texto que acompanha o campo de segredo, dito antes de salvar. */
export function textoDoSegredo(guardada: CredencialGuardada | null, provedor: string, porQue: PorQue | null): string {
  if (porQue === 'outra_chave') return 'Vai para o Vault. Trocar uma das chaves pede as outras junto: a guardada é um objeto só.';
  if (porQue === 'provedor') return 'Vai para o Vault. A chave guardada é de outro provedor e não vai junto — cole a nova.';
  if (porQue === 'endereco') return 'Vai para o Vault. O endereço mudou: a chave guardada foi dada para o anterior e é pedida de novo.';
  if (guardada?.temSegredo && guardada.provedor === provedor) {
    return 'Vai para o Vault. Em branco, a chave guardada fica como está — enquanto o endereço for o mesmo e nenhuma outra chave mudar.';
  }
  return 'Vai para o Vault.';
}

/**
 * O que o formulário mostra quando o nome digitado passa a casar com outra
 * credencial (ou com nenhuma): o que não é segredo, da guardada, mais SÓ o que
 * a pessoa digitou. Mesclar com o que estava na tela levava os valores de
 * "Pipefy" para "Pipefy matriz" enquanto o nome era digitado, e salvar
 * sobrescrevia o client_id da segunda sem aviso (D77b).
 */
export function preencher(
  campos: readonly CampoDaCredencial[], guardada: CredencialGuardada | null, provedor: string,
  valores: Readonly<Record<string, string>>, digitados: ReadonlySet<string>,
): Record<string, string> {
  return {
    ...valoresGuardados(campos, guardada, provedor),
    ...Object.fromEntries(Object.entries(valores).filter(([k, v]) => digitados.has(k) && v.trim())),
  };
}

/** O formulário abre com o que não é segredo já preenchido: em branco passa a
 *  significar em branco, e a lista de modelos usa o mesmo destino que será salvo. */
export function valoresGuardados(
  campos: readonly CampoDaCredencial[], guardada: CredencialGuardada | null, provedor: string,
): Record<string, string> {
  if (!guardada || guardada.provedor !== provedor) return {};
  return Object.fromEntries(campos
    .filter((c) => !c.segredo && typeof guardada.config[c.chave] === 'string')
    .map((c) => [c.chave, guardada.config[c.chave]!]));
}

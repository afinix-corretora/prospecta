/** Configurações ▸ E-mail (D62).
 *
 * O cliente cadastra quantos provedores de e-mail quiser e cada campanha
 * escolhe UM. A escolha mora na campanha (`campaigns.remetente_email_id`), e
 * não aqui, porque é a campanha que o agendador lê; esta tela mostra quem
 * escolheu o quê, para que remover uma conta não seja uma surpresa.
 *
 * Verificar conexão pergunta ao provedor pela edge function — a tela não tem o
 * segredo. O resultado fica gravado na conta, e não tira ninguém do pool: quem
 * tira é o circuito, com envio de verdade.
 */
import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import { lerCampanhas, lerProvedoresCanal, lerRemetentes } from '../dados';
import type { Campanha, ProvedorCanal, Remetente } from '../dados';
import { Aviso, Kpi, Secao } from '../componentes/base';
import { ConectarConta, LinhaConta } from './Canal';
import { Moldura } from './Telas';

export function ConfigEmail() {
  const nav = useNavigate();
  const { tenant, administra } = useSessao();
  const [provedores, setProvedores] = useState<ProvedorCanal[]>([]);
  const [contas, setContas] = useState<Remetente[]>([]);
  const [campanhas, setCampanhas] = useState<Campanha[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');

  // Recarregar NÃO volta para "Carregando…": isso desmontaria a linha que
  // acabou de pedir a verificação, e a resposta sumiria junto com ela.
  async function recarregar() {
    try {
      const [p, r, c] = await Promise.all([lerProvedoresCanal(), lerRemetentes(), lerCampanhas()]);
      setProvedores(p.filter((x) => x.canal === 'email'));
      setContas(r.filter((x) => x.canal === 'email'));
      setCampanhas(c);
      setErro('');
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }
  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const comEmail = campanhas.filter((c) => c.canais_habilitados.includes('email'));
  const fixas = comEmail.filter((c) => c.remetente_email_id);
  const verificadasOk = contas.filter((c) => c.verificacao_ok === true).length;

  return (
    <Moldura titulo="E-mail" voltar={() => nav('/config')}
             sub="Os provedores de e-mail deste cliente. Cadastre quantos quiser; cada campanha escolhe um na própria tela. A credencial vai para o Vault.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Contas de e-mail" valor={contas.length}
             sub={`${contas.filter((c) => c.estado === 'ativo').length} no pool`} />
        <Kpi rotulo="Conexão verificada" valor={verificadasOk}
             sub={contas.length - verificadasOk ? `${contas.length - verificadasOk} sem verificação ok` : 'todas ok'} />
        <Kpi rotulo="Campanhas com e-mail" valor={comEmail.length}
             sub={`${fixas.length} com conta escolhida · ${comEmail.length - fixas.length} em rodízio`} />
      </section>

      <Secao titulo="Contas" nota={contas.length ? 'verificar, tirar do pool ou remover' : 'nenhuma ainda'} />
      <section className="indice">
        {contas.length ? contas.map((r) => {
          const usam = fixas.filter((c) => c.remetente_email_id === r.id);
          return (
            <div key={r.id}>
              <LinhaConta conta={r} provedores={provedores} administra={administra} aoMudar={recarregar} />
              {usam.length > 0 && (
                <p className="ajuda" style={{ fontSize: 11.5, color: 'var(--ink-3)', margin: '4px 0 0 16px' }}>
                  Escolhida por: {usam.map((c) => c.nome).join(', ')}. Para remover, troque a conta
                  nessas campanhas antes.
                </p>
              )}
            </div>
          );
        }) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma conta de e-mail</b>
            <p>Sem conta, o motor adia o passo de e-mail em vez de prometer envio que não acontece.</p>
          </span></div>
        )}
      </section>

      {/* Dito aqui porque é o que a pessoa vem procurar depois de cadastrar a
          segunda conta: "e qual delas a campanha usa?". */}
      <Aviso tipo="neutro">
        <b>Qual conta cada campanha usa</b> se escolhe na tela da campanha. Campanha
        sem escolha usa o rodízio entre as contas de e-mail do pool dela — o que
        acontecia antes de existir a escolha. Uma conta escolhida que sair do pool
        segura o e-mail da campanha (o passo espera) em vez de mandar por outra
        conta que ninguém escolheu.
      </Aviso>

      <ConectarConta provs={provedores} canal="email" administra={administra}
                     tenant={tenant?.tenant_id ?? ''} aoMudar={recarregar} />
    </Moldura>
  );
}

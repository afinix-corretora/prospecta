import { useState } from 'react';
import { sb, erroNoLink } from '../supabase';
import { ehLocal, urlDeRetorno } from '../retorno';
import { mensagemDeAcesso, problemaDaSenha, SENHA_MINIMA } from '../acesso';
import { useSessao } from '../sessao';
import { Aviso, Campo } from '../componentes/base';
import { Marca } from '../componentes/icones';
import { carimboLegivel } from '../carimbo';

/**
 * E-mail e senha (D60).
 *
 * Era link por e-mail, e o custo apareceu no uso: a sessão é do endereço onde
 * o link foi aberto, e quem abria o app por outro endereço — um preview da
 * Vercel, outra aba de outro navegador — caía de novo em "receber link", a
 * cada vez, mesmo tendo entrado minutos antes. Com senha, entrar de novo é
 * digitar, não esperar e-mail.
 *
 * O e-mail continua existindo para o que ele faz bem: definir a senha na
 * primeira vez e trocá-la quando esquecida.
 */
export function Entrar() {
  const [modo, setModo] = useState<'senha' | 'recuperar'>(erroNoLink ? 'recuperar' : 'senha');
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [estado, setEstado] = useState<'parado' | 'enviando' | 'enviado'>('parado');
  const [erro, setErro] = useState('');

  async function entrar(e: React.FormEvent) {
    e.preventDefault();
    setErro(''); setEstado('enviando');
    const { error } = await sb.auth.signInWithPassword({ email: email.trim(), password: senha });
    // Sem erro não há o que fazer aqui: `onAuthStateChange` traz a sessão e o
    // portão troca esta tela pelo painel.
    if (error) { setErro(mensagemDeAcesso(error)); setEstado('parado'); }
  }

  async function pedirLink(e: React.FormEvent) {
    e.preventDefault();
    setErro(''); setEstado('enviando');
    const { error } = await sb.auth.resetPasswordForEmail(email.trim(), { redirectTo: urlDeRetorno() });
    if (error) { setErro(mensagemDeAcesso(error)); setEstado('parado'); return; }
    setEstado('enviado');
  }

  function trocarModo(m: 'senha' | 'recuperar') {
    setModo(m); setErro(''); setEstado('parado');
  }

  return (
    <div className="entrar">
      <form onSubmit={modo === 'senha' ? entrar : pedirLink}>
        <div className="selo"><Marca /><b>Prospecta</b></div>
        <h1>{modo === 'senha' ? 'Entrar' : 'Receber link de acesso'}</h1>
        <p>{modo === 'senha' ? 'Motor de cadência multicanal.' : 'Definir ou redefinir a senha.'}</p>

        {modo === 'senha' ? (
          <>
            <Campo id="email" rotulo="E-mail" tipo="email" autocompletar="username"
                   valor={email} aoMudar={setEmail} placeholder="voce@suaempresa.com.br" />
            <Campo id="senha" rotulo="Senha" tipo="senha" autocompletar="current-password"
                   valor={senha} aoMudar={setSenha} placeholder="" />
            {erro && <Aviso tipo="erro">{erro}</Aviso>}
            <button className="btn prim" disabled={estado === 'enviando' || !email || !senha}>
              {estado === 'enviando' ? 'Entrando…' : 'Entrar'}
            </button>
            <p className="troca-modo">
              <button type="button" className="link" onClick={() => trocarModo('recuperar')}>
                Esqueci a senha / primeiro acesso
              </button>
            </p>
          </>
        ) : estado === 'enviado' ? (
          <>
            <Aviso tipo="ok">
              Enviamos para <b>{email}</b> um link para definir a senha. Abra pelo
              mesmo navegador.
            </Aviso>
            {/* O que o app pediu, dito em voz alta (D50). Sem isto, um link que
                volta para outro endereço é um mistério: a requisição deu certo,
                a tela diz "enviado", e o defeito está numa lista que mora no
                painel do Supabase. */}
            <p className="nota-retorno">
              O link vai trazer você de volta para{' '}
              <code className="mono">{urlDeRetorno()}</code>.
              {!ehLocal(urlDeRetorno()) && (
                <>
                  {' '}Se o e-mail apontar para <code className="mono">localhost</code> ou
                  para outro endereço, é porque esta URL não está em
                  <b> Authentication ▸ URL Configuration ▸ Redirect URLs</b> no
                  Supabase — ele ignora o pedido em silêncio e usa o Site URL.
                </>
              )}
            </p>
            <p className="troca-modo">
              <button type="button" className="link" onClick={() => trocarModo('senha')}>
                Voltar para entrar
              </button>
            </p>
          </>
        ) : (
          <>
            {erroNoLink && <Aviso tipo="erro">{erroNoLink}</Aviso>}
            <Campo id="email" rotulo="E-mail" tipo="email" autocompletar="username"
                   valor={email} aoMudar={setEmail} placeholder="voce@suaempresa.com.br"
                   ajuda="Mandamos um link; ao abri-lo, você escolhe a senha." />
            {erro && <Aviso tipo="erro">{erro}</Aviso>}
            <button className="btn prim" disabled={estado === 'enviando' || !email}>
              {estado === 'enviando' ? 'Enviando…' : 'Receber link para definir a senha'}
            </button>
            <p className="troca-modo">
              <button type="button" className="link" onClick={() => trocarModo('senha')}>
                Voltar para entrar
              </button>
            </p>
          </>
        )}

        {/* Mesmo carimbo da tela de configuração: daqui também se responde
            "é o build que acabei de subir?" sem abrir o painel da Vercel. */}
        <p style={{ fontSize: 11, color: 'var(--ink-3)', marginTop: 18, marginBottom: 0 }}>
          build <code className="mono">{carimboLegivel()}</code>
        </p>
      </form>
    </div>
  );
}

/**
 * Chegou pelo link do e-mail: a sessão já existe, falta a senha nova.
 *
 * O portão mostra esta tela no lugar do painel enquanto `definindoSenha` for
 * verdadeiro. Deixar a pessoa passar direto faria do "esqueci a senha" um link
 * de acesso que não troca senha nenhuma.
 */
export function DefinirSenha() {
  const { sessao, senhaDefinida } = useSessao();
  const [senha, setSenha] = useState('');
  const [confirmacao, setConfirmacao] = useState('');
  const [estado, setEstado] = useState<'parado' | 'gravando'>('parado');
  const [erro, setErro] = useState('');

  async function gravar(e: React.FormEvent) {
    e.preventDefault();
    const problema = problemaDaSenha(senha, confirmacao);
    if (problema) { setErro(problema); return; }
    setErro(''); setEstado('gravando');
    const { error } = await sb.auth.updateUser({ password: senha });
    if (error) { setErro(mensagemDeAcesso(error)); setEstado('parado'); return; }
    senhaDefinida();
  }

  return (
    <div className="entrar">
      <form onSubmit={gravar}>
        <div className="selo"><Marca /><b>Prospecta</b></div>
        <h1>Nova senha</h1>
        <p>Para <b>{sessao?.user.email}</b>. Nas próximas vezes, é com ela que você entra.</p>
        {/* O campo de usuário oculto é o que faz o gerenciador de senhas
            guardar a nova associada ao e-mail certo. */}
        <input type="email" autoComplete="username" value={sessao?.user.email ?? ''}
               readOnly hidden />
        <Campo id="nova" rotulo="Senha nova" tipo="senha" autocompletar="new-password"
               valor={senha} aoMudar={setSenha} placeholder=""
               ajuda={`Pelo menos ${SENHA_MINIMA} caracteres.`} />
        <Campo id="confirmacao" rotulo="Repita a senha" tipo="senha" autocompletar="new-password"
               valor={confirmacao} aoMudar={setConfirmacao} placeholder="" />
        {erro && <Aviso tipo="erro">{erro}</Aviso>}
        <button className="btn prim" disabled={estado === 'gravando' || !senha || !confirmacao}>
          {estado === 'gravando' ? 'Gravando…' : 'Gravar senha e entrar'}
        </button>
        <p className="troca-modo">
          <button type="button" className="link" onClick={() => void sb.auth.signOut()}>
            Cancelar e sair
          </button>
        </p>
      </form>
    </div>
  );
}

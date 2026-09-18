import { useState } from 'react';
import { sb, mensagemDeErro } from '../supabase';
import { Aviso, Campo } from '../componentes/base';

/** Link por e-mail: sem senha para vazar, sem senha para o suporte redefinir. */
export function Entrar() {
  const [email, setEmail] = useState('');
  const [estado, setEstado] = useState<'parado' | 'enviando' | 'enviado'>('parado');
  const [erro, setErro] = useState('');

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setErro(''); setEstado('enviando');
    const { error } = await sb.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) { setErro(mensagemDeErro(error)); setEstado('parado'); return; }
    setEstado('enviado');
  }

  return (
    <div className="entrar">
      <form onSubmit={enviar}>
        <h1>Prospecta</h1>
        <p>Motor de cadência multicanal.</p>

        {estado === 'enviado' ? (
          <Aviso tipo="ok">
            Link enviado para <b>{email}</b>. Abra pelo mesmo navegador —
            é ele que guarda a sessão.
          </Aviso>
        ) : (
          <>
            <Campo
              id="email" rotulo="E-mail" valor={email} aoMudar={setEmail}
              placeholder="voce@suaempresa.com.br"
              ajuda="Mandamos um link de acesso. Não existe senha para vazar."
            />
            {erro && <Aviso tipo="erro">{erro}</Aviso>}
            <button className="btn prim" disabled={estado === 'enviando' || !email}>
              {estado === 'enviando' ? 'Enviando…' : 'Receber link de acesso'}
            </button>
          </>
        )}
      </form>
    </div>
  );
}

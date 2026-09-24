import { useState } from 'react';
import { sb, mensagemDeErro } from '../supabase';
import { ehLocal, urlDeRetorno } from '../retorno';
import { Aviso, Campo } from '../componentes/base';
import { carimboLegivel } from '../carimbo';

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
      options: { emailRedirectTo: urlDeRetorno() },
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
          <>
            <Aviso tipo="ok">
              Link enviado para <b>{email}</b>. Abra pelo mesmo navegador —
              é ele que guarda a sessão.
            </Aviso>

            {/* O que o app pediu, dito em voz alta. Sem isto, um link que
                volta para outro endereço é um mistério: a requisição deu
                certo, a tela diz "enviado", e o defeito está numa lista que
                mora no painel do Supabase. */}
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
          </>
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

        {/* Mesmo carimbo da tela de configuração: daqui também se responde
            "é o build que acabei de subir?" sem abrir o painel da Vercel. */}
        <p style={{ fontSize: 11, color: 'var(--ink-3)', marginTop: 18, marginBottom: 0 }}>
          build <code className="mono">{carimboLegivel()}</code>
        </p>
      </form>
    </div>
  );
}

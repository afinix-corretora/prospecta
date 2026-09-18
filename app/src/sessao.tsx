import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { sb } from './supabase';

export type Papel = 'dono' | 'admin' | 'operador' | 'leitor';

export interface Tenant {
  tenant_id: string;
  papel: Papel;
  nome: string;
  slug: string;
}

interface Contexto {
  sessao: Session | null;
  carregando: boolean;
  tenant: Tenant | null;
  tenants: Tenant[];
  trocarTenant(id: string): void;
  administra: boolean;
  opera: boolean;
  recarregarTenants(): Promise<void>;
}

const Ctx = createContext<Contexto | null>(null);

// O tenant escolhido fica no navegador porque é preferência de quem está
// usando, não fato do domínio. Quem impede escrever no tenant errado é o RLS,
// não esta chave — então perdê-la não é problema de segurança, só de conforto.
const CHAVE_TENANT = 'prospecta:tenant';

export function ProvedorSessao({ children }: { children: ReactNode }) {
  const [sessao, setSessao] = useState<Session | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [escolhido, setEscolhido] = useState<string | null>(
    () => localStorage.getItem(CHAVE_TENANT),
  );

  useEffect(() => {
    sb.auth.getSession().then(({ data }) => {
      setSessao(data.session);
      setCarregando(false);
    });
    const { data: sub } = sb.auth.onAuthStateChange((_e, s) => setSessao(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  async function carregarTenants() {
    if (!sessao) { setTenants([]); return; }
    // RLS já limita a `tenant_users` do próprio usuário — não há filtro a
    // escrever aqui, e escrever um daria a falsa impressão de que ele protege.
    const { data, error } = await sb
      .from('tenant_users')
      .select('tenant_id, papel, tenants(nome, slug)');
    if (error) { setTenants([]); return; }

    const linhas = (data ?? []).map((l) => {
      const t = l.tenants as unknown as { nome: string; slug: string } | null;
      return {
        tenant_id: l.tenant_id as string,
        papel: l.papel as Papel,
        nome: t?.nome ?? '—',
        slug: t?.slug ?? '',
      };
    });
    setTenants(linhas);
  }

  useEffect(() => { void carregarTenants(); /* eslint-disable-next-line */ }, [sessao]);

  const tenant = useMemo(() => {
    if (!tenants.length) return null;
    return tenants.find((t) => t.tenant_id === escolhido) ?? tenants[0] ?? null;
  }, [tenants, escolhido]);

  const valor: Contexto = {
    sessao,
    carregando,
    tenant,
    tenants,
    trocarTenant(id) {
      localStorage.setItem(CHAVE_TENANT, id);
      setEscolhido(id);
    },
    administra: tenant?.papel === 'dono' || tenant?.papel === 'admin',
    opera: tenant ? tenant.papel !== 'leitor' : false,
    recarregarTenants: carregarTenants,
  };

  return <Ctx.Provider value={valor}>{children}</Ctx.Provider>;
}

export function useSessao(): Contexto {
  const c = useContext(Ctx);
  if (!c) throw new Error('useSessao fora do ProvedorSessao');
  return c;
}

-- O remetente passa a declarar por qual provedor fala e onde está seu segredo.
--
-- Sem isto o despachante não sabe qual adapter construir: `canal` diz whatsapp,
-- mas whatsapp tem dois provedores (Evolution e Meta Cloud) e D6 roteia entre
-- eles por tipo de campanha, não por canal.
--
-- Sem CHECK na lista de provedores de propósito: a convenção é "canal novo =
-- classe nova, zero mudança no motor", e um CHECK faria cada provedor novo
-- exigir migration. Provedor sem adapter já falha alto e registrado — o
-- despachante trata como culpa do remetente e a conta sai do pool.

ALTER TABLE sender_accounts
  ADD COLUMN provedor text NOT NULL,
  -- Ponteiro para o Vault. Nulo enquanto a conta existe só para shadow mode,
  -- onde nada é enviado e nenhum segredo é preciso.
  ADD COLUMN credenciais_secret_id uuid;

COMMENT ON COLUMN sender_accounts.provedor IS
  'Qual ChannelAdapter fala por esta conta: evolution, meta_cloud, comtele...
   Resolvido em adapters/registro.ts, não aqui.';

COMMENT ON COLUMN sender_accounts.credenciais_secret_id IS
  'Segredo no Vault, resolvido pelo chamador antes de invocar o adapter.
   Nenhum adapter lê segredo por conta própria.';

CREATE INDEX sender_accounts_provedor_idx ON sender_accounts (canal, provedor);

-- UAZAPI entra como o WhatsApp não oficial.
--
-- D14 fechou dizendo que o não-oficial era Evolution, porque o inventário da
-- Fase 0 não achou UAZAPI em nenhum repositório, e deixou a pergunta explícita:
-- confirmar se havia compromisso com UAZAPI invisível no código. A resposta
-- veio — há. Então UAZAPI é o não-oficial daqui para frente (D22).
--
-- Evolution NÃO sai do catálogo. É o que roda hoje no legado e o que os chips
-- existentes usam; tirar do catálogo quebraria a chave estrangeira dessas
-- contas no dia do backfill. Os dois convivem: `ordem` põe UAZAPI primeiro na
-- tela, e a migração de chip é operacional, conta a conta.
--
-- D14 previu que isto seria barato: "a interface ChannelAdapter não conhece
-- provedor; adotar UAZAPI depois é escrever uma classe". Foi isso — uma classe
-- e esta linha.

INSERT INTO channel_provider_catalog
  (slug, canal, nome, descricao, oficial, tem_adapter, campos, docs_url, ordem) VALUES
('uazapi', 'whatsapp', 'UAZAPI (não oficial)',
 'Automação de WhatsApp sem homologação, uma instância por chip. Serve a campanha fria; nunca ao número institucional (D4).',
 false, true,
 '[{"chave":"token","rotulo":"Token da instância","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"O token da instância, não o adminToken"},
   {"chave":"base_url","rotulo":"URL do servidor","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Ex.: https://suaempresa.uazapi.com"},
   {"chave":"instancia","rotulo":"Nome da instância","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Só para identificar no painel da UAZAPI"}]'::jsonb,
 'https://docs.uazapi.com', 3);

-- Evolution desce um degrau na tela: continua disponível, deixa de ser o
-- primeiro que aparece.
UPDATE channel_provider_catalog SET ordem = 4, descricao =
  'Automação de WhatsApp sem homologação. É o que roda no legado; contas novas vão para UAZAPI (D22).'
 WHERE slug = 'evolution';

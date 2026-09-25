-- Reverte a entrada da UAZAPI no catálogo.
--
-- Só remove se nenhuma conta estiver usando: apagar um provedor com remetente
-- apontando para ele é o que a chave estrangeira existe para impedir.

DELETE FROM channel_provider_catalog
 WHERE slug = 'uazapi'
   AND NOT EXISTS (SELECT 1 FROM sender_accounts WHERE provedor = 'uazapi');

UPDATE channel_provider_catalog SET ordem = 3, descricao =
  'Automação de WhatsApp comum, sem homologação. Serve a campanha fria; nunca ao número institucional (D4).'
 WHERE slug = 'evolution';

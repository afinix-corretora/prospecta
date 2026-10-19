-- Reverte o SMTP Locaweb.
--
-- Só remove o provedor se nenhuma conta estiver usando, pela mesma cautela do
-- down do Resend: remetente apontando para provedor apagado é o que a chave
-- estrangeira existe para impedir.

DELETE FROM channel_provider_catalog
 WHERE slug = 'locaweb'
   AND NOT EXISTS (SELECT 1 FROM sender_accounts WHERE provedor = 'locaweb');

UPDATE channel_provider_catalog SET ordem = 6, descricao =
  'Caixa de saída própria. Sem adapter: SMTP precisa de socket, e o motor só fala HTTP (D30). Use um provedor de e-mail por API.'
 WHERE slug = 'smtp';

UPDATE channel_provider_catalog SET ordem = 7 WHERE slug = 'instagram_oficial';

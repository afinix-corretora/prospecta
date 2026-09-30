-- SMTP Locaweb como segundo provedor de e-mail, pela API HTTP (D61).
--
-- O produto se chama "SMTP", mas tem API REST — é ela que o adapter usa. O
-- protocolo SMTP segue sem adapter pelo motivo do D30 (socket não cabe num
-- diretório que só fala `fetch`), e a linha `smtp` continua no catálogo
-- dizendo isso. Agora ela também diz onde está a alternativa.
--
-- Os campos são os do Resend com uma diferença que é o ponto desta migration:
-- `responder_para` é OBRIGATÓRIO. A Locaweb não recebe e-mail. Sem um
-- `Reply-To` apontando para um inbound que o motor lê, a pessoa responde para
-- uma caixa que ninguém processa, e a cadência dela segue mandando toque —
-- a invariante 4 furada sem erro nenhum. Garantia por constraint, não por
-- aviso na tela: conta Locaweb sem destino de resposta não salva.
--
-- Nome de exibição não entra: a API declara `from` como endereço, e prometer
-- um campo que o provedor pode ignorar é guardar decoração (D55).

INSERT INTO channel_provider_catalog
  (slug, canal, nome, descricao, oficial, tem_adapter, campos, docs_url, ordem) VALUES
('locaweb', 'email', 'SMTP Locaweb',
 'E-mail pela API do SMTP Locaweb. O remetente precisa estar confirmado no painel. A Locaweb não recebe resposta: o "Responder para" tem de ser um inbound que o motor lê. Campanha fria usa domínio separado do institucional (D4).',
 true, true,
 '[{"chave":"api_token","rotulo":"Token da API","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Painel do SMTP Locaweb → token de API (vai no cabeçalho x-auth-token)"},
   {"chave":"assunto_padrao","rotulo":"Assunto padrão","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Vale quando o passo não começa com uma linha Assunto: ..."},
   {"chave":"responder_para","rotulo":"Responder para","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Endereço de inbound que o motor lê (hoje, um inbound da Resend deste cliente). É por ele que a resposta encerra a cadência"}]'::jsonb,
 'https://developer.locaweb.com.br/docs/smtp', 6);

UPDATE channel_provider_catalog SET ordem = 7, descricao =
  'Caixa de saída própria por protocolo SMTP. Sem adapter: SMTP precisa de socket, e o motor só fala HTTP (D30). Use um provedor de e-mail por API — Resend ou SMTP Locaweb.'
 WHERE slug = 'smtp';

UPDATE channel_provider_catalog SET ordem = 8 WHERE slug = 'instagram_oficial';

-- Volta a linha ao que o D59 escreveu.
UPDATE crm_provider_catalog
   SET slug = 'softcare',
       nome = 'Softcare (CRM da casa)',
       descricao = 'O CRM do grupo. Por ser nosso, é o único em que o contrato de escrita pode ser ajustado dos dois lados em vez de negociado com a documentação de terceiro.',
       campos = '[{"chave":"base_url","rotulo":"URL da instalação","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Endereço da API do Softcare deste cliente"},
                  {"chave":"token","rotulo":"Token de integração","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Gerado na administração do Softcare"}]'::jsonb
 WHERE slug = 'profitcare';

-- D70: a linha "Softcare" do catálogo era o ProfitCare, e os campos eram
-- suposição (D59). Agora há contrato: a API de integração do ProfitCare
-- (`crm-integracao`, no repositório dele) recebe `Authorization: Bearer pc_...`
-- no endereço do projeto do cliente. Os campos passam a ser os que ela pede.
--
-- `tem_adapter` continua falso: o adapter existe (`adapters/profitcare.ts`),
-- mas a API ainda não está publicada no ProfitCare de produção, e o worker
-- que o registra não foi publicado. Prometer antes seria o D31.
--
-- Nenhuma conexão aponta para 'softcare' (conferido no projeto antes de
-- aplicar); se apontasse, a FK por `slug` recusaria o UPDATE inteiro, que é
-- o que se quer.

UPDATE crm_provider_catalog
   SET slug = 'profitcare',
       nome = 'ProfitCare (CRM da casa)',
       descricao = 'O CRM do grupo. Por ser nosso, o contrato de escrita foi feito para o Prospecta: '
                || 'chave de integração por cliente, ler funis e cards, mover de fase e preencher campo.',
       campos = '[{"chave":"base_url","rotulo":"Endereço do CRM","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Aparece no ProfitCare em Configurações ▸ Integrações, acima das chaves (começa com https://)"},
                  {"chave":"chave","rotulo":"Chave de integração","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Gerada no ProfitCare em Configurações ▸ Integrações. Aparece uma vez só: copie na hora"}]'::jsonb
 WHERE slug = 'softcare';

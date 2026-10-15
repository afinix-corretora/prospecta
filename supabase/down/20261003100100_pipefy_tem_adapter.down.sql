-- Reverte: o Pipefy volta a não ter adapter, e os fatos voltam a esperar.
UPDATE crm_provider_catalog SET tem_adapter = false WHERE slug = 'pipefy';

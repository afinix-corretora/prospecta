-- Tira a criação de campanha sem modelo. As campanhas criadas ficam: são
-- campanhas como as outras, sem nada de especial além de template_slug nulo.

DROP FUNCTION IF EXISTS criar_campanha(uuid, text, tipo_campanha, text, canal[], text, uuid);

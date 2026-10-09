-- Reverte 20260917200000_modelos_de_campanha.sql

DROP FUNCTION IF EXISTS criar_campanha_de_modelo(text, text, canal[]);

ALTER TABLE campaigns
  DROP COLUMN IF EXISTS objetivo,
  DROP COLUMN IF EXISTS template_slug;

DROP TABLE IF EXISTS campaign_templates;

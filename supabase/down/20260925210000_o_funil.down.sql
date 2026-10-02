-- Apaga o funil inteiro. Os cards e a linha do tempo vão junto.

DROP TABLE IF EXISTS deal_activities;
DROP TABLE IF EXISTS deals;
DROP TABLE IF EXISTS pipeline_stages;
DROP TABLE IF EXISTS pipelines;

DROP TYPE IF EXISTS origem_movimento;
DROP TYPE IF EXISTS tipo_estagio;

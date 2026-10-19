-- `recusa_termos` ganha RLS, como a gêmea dela (D58).
--
-- Corretiva imediata, e quem a pegou foi o `get_advisors` do projeto, em nível
-- ERROR: tabela em `public` é publicada pelo PostgREST, e sem RLS ligada ela
-- fica fora da grade — mesmo com o GRANT restrito a `authenticated`. A gêmea
-- `opt_out_termos` já nasceu certa no D48; esta saiu sem.
--
-- Vale registrar como o erro escapou do suite: o meta-teste de RLS do D18
-- percorre `tn.dominio`, que exclui as tabelas de `tn.sem_dono` — e
-- `recusa_termos` entrou nessa lista, com razão, por ser catálogo sem tenant.
-- Ao isentá-la do teste de `tenant_id`, isentei-a também do de RLS. As duas
-- perguntas são diferentes e a lista é uma só.
--
-- Não estou mudando o meta-teste agora: a divisão do D19 é justamente essa —
-- o suite cobre o que é do schema, o advisor cobre o que só existe no
-- Supabase, e este achado é a terceira vez que o par funciona como projetado
-- (D19, D31, e agora). Mudar a lista para cobrir catálogo mereceria pensar se
-- "catálogo sem tenant" e "tabela sem RLS" são a mesma isenção — e a resposta
-- é não.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20260925250000_recusa_termos_com_rls.down.sql

-- Leitura para quem está logado; escrita é de plataforma, por migration.
-- Sem recorte por tenant porque não há tenant: é idioma.
ALTER TABLE recusa_termos ENABLE ROW LEVEL SECURITY;
CREATE POLICY recusa_termos_sel ON recusa_termos FOR SELECT USING (true);

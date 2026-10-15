-- Postgres nao remove valor de enum. O down existe para o teste de
-- reversibilidade nao parar aqui; desfazer de verdade exigiria recriar o tipo
-- e todas as colunas que o usam, o que nao vale para um valor a mais.
SELECT 1;

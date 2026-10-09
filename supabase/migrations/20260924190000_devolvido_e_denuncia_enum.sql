-- Os dois valores de evento que faltavam (D49, parte 1 de 2).
--
-- Migration separada de proposito, pela regra que o D39 ja custou uma vez:
-- `ALTER TYPE ... ADD VALUE` e o uso do valor novo nao cabem na mesma
-- transacao. Quem escrever a parte 2 aqui dentro descobre isso em producao.
--
-- Por que valores novos, e nao reaproveitar `rejeitado`:
--
--   rejeitado   o provedor recusou NA HORA do envio. E sincrono, e ja existe.
--   devolvido   aceitou e depois devolveu. Assincrono, e pode ser temporario
--               (caixa cheia) ou definitivo (endereco nao existe).
--   denuncia    a pessoa marcou como spam. Nao e problema de endereco
--               nenhum: e vontade manifestada, e a mais forte que existe.
--
-- A Resend hoje mapeia `email.bounced` E `email.complained` para `rejeitado`,
-- colapsando as tres colunas acima numa so. Isso e o que a parte 2 desfaz.

ALTER TYPE tipo_evento ADD VALUE IF NOT EXISTS 'devolvido';
ALTER TYPE tipo_evento ADD VALUE IF NOT EXISTS 'denuncia';

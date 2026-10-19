# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Dois públicos com o mesmo peso (confirmado):

- **Gestor da operação** — dono ou gestor comercial da corretora, ou do cliente que licencia o
  produto. Abre para saber se as campanhas estão rendendo, quem respondeu e o que pede atenção.
  Configura canais, IA e CRM de vez em quando.
- **SDR / operador** — passa o dia na operação: lê respostas, move cards no funil, importa listas,
  inscreve contatos em campanhas. Precisa de velocidade e densidade.

## Product Purpose

Prospecta é um motor autônomo de cadência multicanal (WhatsApp, e-mail, SMS; Instagram declarado
sem adapter). Recebe contatos de planilha ou CRM, inscreve em cadências, executa ao longo do tempo
e escreve de volta no CRM os fatos que descobre (opt-out, identidade inválida, respondeu, campanha
concluída). Quando o contato responde, o agente de IA responde sozinho pelo mesmo caminho de envio.
Sucesso é lead respondido e movido no funil sem ninguém perder conversa.

## Positioning

Não é um disparador: o estado vive no contato, e o motor pergunta "quem está vencido agora?". As
quatro invariantes (idempotência, supressão, quota por remetente, encerramento global por resposta)
são garantidas no banco, não por convenção. Cada cliente traz o próprio CRM, chips e chave de IA.

## Operating Context

SaaS multi-tenant (cada licença é um cliente). Configuração inteira pela tela, sem painel do
Supabase. Segredos vão para o Vault e nunca voltam. O motor roda em modo simulado por padrão
(shadow mode): faz tudo e não envia, e a tela precisa deixar isso evidente.

## Capabilities and Constraints

- Telas: Início, Campanhas, Cadências, Contatos, Importar, Supressão, Respostas, Funil, Writeback,
  Canais (por canal e família oficial/não oficial), Configurações (E-mail, Blacklist, Provedores de
  IA, Agentes, Modelos, Plataformas de contato, Plataformas vinculadas), e o assistente de
  configuração.
- O app é React + Vite em `app/`, publicado na Vercel; lê o Supabase com o JWT de quem está logado,
  e o RLS decide o alcance.
- Toda tela que promete um efeito precisa dizer quando ele ainda não acontece (D55, D59).

## Brand Commitments

- Nome: **Prospecta**. Idioma da interface: português do Brasil.
- Referência visual escolhida pelo usuário (vinculante): projeto "Dashboard" de Anya Masher no
  Behance — Anek Latin + Roboto, neutros carvão/lavanda, periwinkle e índigo, menta para o que deu
  certo, item ativo como pílula, gráficos de área em gradiente, blobs desfocados ao fundo, versões
  escura e clara.
- Tema padrão: **escuro**, com opção clara lembrada por pessoa (confirmado).
- Tela inicial: **painel de resultados**; o assistente de configuração vira cartão de progresso
  enquanto houver passo pendente (confirmado).

## Evidence on Hand

Dados reais vêm do banco do cliente. Não há depoimentos, logos de clientes nem números de mercado
no repositório; nenhuma tela deve inventá-los.

## Product Principles

1. O que importa hoje vem primeiro: quem respondeu e o que pede ação.
2. Correto e silencioso não é pronto — o produto diz o que não fez e por quê.
3. Simulado nunca parece enviado.
4. Configurar é pela tela, escolhendo entre contas conectadas; chave só em Configurações.

---
name: Prospecta
description: Motor de cadência multicanal — painel escuro que mostra primeiro o que o motor não fez.
colors:
  ground: "#0D0D12"
  rail: "#121218"
  surface: "#1A1A21"
  surface-2: "#23232C"
  surface-3: "#2D2D38"
  field: "#14141A"
  line: "#2A2A34"
  line-strong: "#3C3C4A"
  ink: "#F4F2FA"
  ink-2: "#AEADBF"
  ink-3: "#8C8BA0"
  accent: "#8E8BFF"
  accent-ink: "#12112B"
  accent-soft: "rgba(142,139,255,.14)"
  accent-line: "rgba(142,139,255,.45)"
  pill: "#3A37C9"
  pill-ink: "#FFFFFF"
  mint: "#3DF5A8"
  ok: "#3DF5A8"
  ok-ink: "#052618"
  ok-soft: "rgba(61,245,168,.12)"
  warn: "#F2B35B"
  warn-soft: "rgba(242,179,91,.13)"
  crit: "#FF8C7D"
  crit-soft: "rgba(255,140,125,.13)"
  wa: "#16A873"
  mail: "#7D79F2"
  sms: "#BF822A"
  ig: "#C760A6"
  g-1: "#16A873"
  g-2: "#7D79F2"
  g-3: "#BF822A"
  g-4: "#C760A6"
  g-grid: "rgba(255,255,255,.06)"
  light-ground: "#F4F0FA"
  light-rail: "#FFFFFF"
  light-surface: "#FFFFFF"
  light-surface-2: "#F3EEF8"
  light-surface-3: "#E9E2F1"
  light-field: "#FBF9FD"
  light-line: "#E7E0EF"
  light-line-strong: "#CFC5DC"
  light-ink: "#15141B"
  light-ink-2: "#55536A"
  light-ink-3: "#67657C"
  light-accent: "#3A37C9"
  light-accent-ink: "#FFFFFF"
  light-accent-soft: "#ECEBFF"
  light-accent-line: "rgba(58,55,201,.35)"
  light-pill: "#3DF5A8"
  light-pill-ink: "#06291B"
  light-ok: "#07744A"
  light-ok-ink: "#FFFFFF"
  light-ok-soft: "#DDF7EA"
  light-warn: "#8F5E05"
  light-warn-soft: "#FBEFD6"
  light-crit: "#B3392A"
  light-crit-soft: "#FCE3DF"
  light-wa: "#07744A"
  light-mail: "#4F4BD8"
  light-sms: "#9A5A0C"
  light-ig: "#B0418A"
  light-g-1: "#0E9C64"
  light-g-2: "#4F4BD8"
  light-g-3: "#B26A12"
  light-g-4: "#B0418A"
  light-g-grid: "rgba(21,20,27,.07)"
typography:
  display:
    fontFamily: "Anek Latin Variable, Anek Latin, Roboto Variable, system-ui, sans-serif"
    fontSize: "34px"
    fontWeight: 600
    lineHeight: 1.12
    letterSpacing: "-0.01em"
    fontVariation: "'wdth' 90"
  headline:
    fontFamily: "Anek Latin Variable, Anek Latin, Roboto Variable, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 600
    lineHeight: 1.12
    letterSpacing: "-0.01em"
    fontVariation: "'wdth' 96"
  figure:
    fontFamily: "Anek Latin Variable, Anek Latin, Roboto Variable, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 600
    lineHeight: 1.05
    letterSpacing: "-0.02em"
    fontFeature: "'tnum' 1"
    fontVariation: "'wdth' 92"
  title:
    fontFamily: "Anek Latin Variable, Anek Latin, Roboto Variable, system-ui, sans-serif"
    fontSize: "17.5px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.01em"
    fontVariation: "'wdth' 96"
  body:
    fontFamily: "Roboto Variable, Roboto, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Roboto Variable, Roboto, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "13.5px"
    fontWeight: 600
    lineHeight: 1.5
  caption:
    fontFamily: "Roboto Variable, Roboto, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "12.5px"
    fontWeight: 400
    lineHeight: 1.45
  axis:
    fontFamily: "Roboto Variable, Roboto, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    fontFeature: "'tnum' 1"
  mono:
    fontFamily: "Roboto Mono Variable, Roboto Mono, ui-monospace, monospace"
    fontSize: "0.94em"
    fontFeature: "'tnum' 1"
rounded:
  xs: "9px"
  sm: "12px"
  md: "14px"
  lg: "18px"
  pill: "999px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "16px"
  xl: "20px"
  page: "30px"
  section: "34px"
  page-mobile: "16px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "0 16px"
    height: "40px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "0 16px"
    height: "40px"
  button-secondary-hover:
    backgroundColor: "{colors.surface-2}"
  icon-button:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-2}"
    rounded: "{rounded.sm}"
    size: "40px"
  nav-item:
    textColor: "{colors.ink-2}"
    rounded: "{rounded.sm}"
    padding: "0 12px"
    height: "40px"
  nav-item-hover:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink}"
  nav-item-active:
    backgroundColor: "{colors.pill}"
    textColor: "{colors.pill-ink}"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
    padding: "20px"
  kpi:
    backgroundColor: "{colors.surface}"
    typography: "{typography.figure}"
    rounded: "{rounded.lg}"
    padding: "18px 18px 16px"
  list-item:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.md}"
    padding: "15px 16px"
  chip:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-2}"
    rounded: "{rounded.pill}"
    padding: "3px 10px"
  chip-ok:
    backgroundColor: "{colors.ok-soft}"
    textColor: "{colors.ok}"
  chip-accent:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
  chip-alert:
    backgroundColor: "{colors.warn-soft}"
    textColor: "{colors.warn}"
  chip-error:
    backgroundColor: "{colors.crit-soft}"
    textColor: "{colors.crit}"
  delta-up:
    backgroundColor: "{colors.ok-soft}"
    textColor: "{colors.ok}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  delta-down:
    backgroundColor: "{colors.crit-soft}"
    textColor: "{colors.crit}"
  delta-neutral:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-3}"
  input:
    backgroundColor: "{colors.field}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "0 13px"
    height: "42px"
  segment:
    backgroundColor: "{colors.surface}"
    padding: "4px"
  segment-option:
    textColor: "{colors.ink-3}"
    rounded: "{rounded.xs}"
    padding: "0 13px"
    height: "32px"
  segment-option-active:
    backgroundColor: "{colors.surface-3}"
    textColor: "{colors.ink}"
  banner-simulated:
    backgroundColor: "{colors.warn-soft}"
    textColor: "{colors.warn}"
    rounded: "{rounded.md}"
    padding: "12px 16px"
  tooltip:
    backgroundColor: "{colors.surface-3}"
    textColor: "{colors.ink}"
    typography: "{typography.caption}"
    rounded: "{rounded.md}"
    padding: "10px 13px"
---

# Design System: Prospecta

## Overview

**Creative North Star: "O Motor à Vista"**

O Prospecta é um motor que trabalha sozinho, e a tela existe para que ninguém confunda "rodou e não fez nada" com "rodou e deu certo". O sistema visual inteiro serve a essa leitura: um chão escuro e calmo (`ground`), cartões opacos um degrau acima (`surface`), e cor só onde há um fato — menta para o que deu certo, âmbar para o que o motor não fez, coral para o que deu errado, periwinkle/índigo para a mão da pessoa (ação, foco, seleção). O mundo vem da referência escolhida pelo usuário, o "Dashboard" de Anya Masher no Behance: Anek Latin estreita nos títulos e números, Roboto na interface, neutros carvão e lavanda, item ativo como pílula preenchida, gráficos de área em gradiente e blobs desfocados atrás dos cartões.

A densidade é de painel de operação, não de página de marketing: texto de 14px, rótulos de 12,5–13,5px, números grandes só onde são o dado principal. A página inicial lê de cima para baixo na ordem do que pede atenção: primeiro o que o motor **não** fez (faixa de modo simulado, cartão de configuração pela metade), depois os números do período contra o período anterior, depois o ritmo diário, e por fim funil, quem respondeu e campanhas ligadas.

O escuro é o padrão; o claro é escolha da pessoa, guardada em `prospecta:tema` e aplicada antes da primeira pintura por um script em `index.html`. Os dois temas são o mesmo sistema com os mesmos nomes de token — só o valor muda sob `:root[data-theme="light"]`.

**Key Characteristics:**
- Escuro por padrão, claro opcional, tokens com o mesmo nome nos dois.
- Profundidade tonal: chão → rail → cartão → superfície 2 → superfície 3, com sombra macia e blobs só nas calhas.
- Duas famílias com papéis fixos: Anek Latin (comprimida, 90–96%) para títulos e números; Roboto para todo o resto.
- Cor semântica, nunca decorativa; cor de gráfico só pelos quatro `--g-*` validados.
- Gráficos sem biblioteca, um eixo Y só, hoje tracejado, mira e dica em todos.
- Ícones desenhados no próprio produto, traço 1.7, grade 24.

## Colors

Carvão e lavanda como neutros, um acento frio que muda de tom com o tema, e uma menta elétrica que mora na interface — nunca dentro da área de um gráfico. Os hex do frontmatter sem prefixo são os valores do tema escuro (padrão); as chaves `light-*` são o valor que **a mesma variável** assume em `[data-theme="light"]`. O código sempre usa `var(--nome)`, nunca o valor do tema.

### Primary
- **Periwinkle de Ação** (`accent`, escuro) / **Índigo Profundo** (`light-accent`, claro): botão primário, link, anel de foco (`outline: 2px solid var(--accent)`), seleção, borda de campo focado (`accent-line` + halo de 4px em `accent-soft`), contadores do rail. É a cor da mão da pessoa. Texto sobre ele usa `accent-ink`.
- **Pílula Ativa** (`pill`): fundo do item de navegação atual. No escuro é o índigo (`#3A37C9`, mesmo da marca); no claro troca para a menta, com `pill-ink` verde-escuro. A troca é deliberada: a pílula é sempre a coisa mais saturada do rail.

### Secondary
- **Menta Elétrica** (`mint`): a assinatura da marca — o ponto da marca, a pílula no claro, o anel de progresso da configuração, e `ok` no tema escuro. Clara demais para preencher área no escuro, por isso não entra em gráfico.
- **Verde de Confirmação** (`ok` / `light-ok`): chip de passo feito, variação positiva, aviso de sucesso, marca de cartão concluído. No claro escurece para `#07744A` para passar como texto.

### Tertiary
- **Âmbar de Aviso** (`warn`): o que o motor não fez. É a cor da faixa de modo simulado e do chip de alerta — nunca de um número de envio.
- **Coral de Erro** (`crit`): variação negativa, chip "pediu para sair", aviso de erro.

### Canais e gráfico
- **Canais** (`wa`, `mail`, `sms`, `ig`): identificam WhatsApp, e-mail, SMS e Instagram em ícone, avatar, legenda e barra de divisão. No escuro coincidem com `--g-1..4`; no claro escurecem porque também viram texto.
- **Séries de gráfico** (`g-1`..`g-4`): verde, periwinkle, ocre e magenta, conferidos por um validador de paleta de dataviz nos dois temas (faixa de luminosidade, croma, separação para daltonismo, contraste contra o cartão). `g-grid` é a linha de grade.

### Neutral
- **Chão Noturno** (`ground`): fundo da página e base do topo translúcido.
- **Rail** (`rail`): um degrau acima do chão, com borda direita `line`.
- **Cartão** (`surface`): todo painel, KPI, item de índice, campo do topo. Opaco.
- **Superfície 2 e 3** (`surface-2`, `surface-3`): hover, chip neutro, trilho de barra, opção selecionada do segmento, dica do gráfico.
- **Campo** (`field`): fundo de input, select e textarea — levemente abaixo do cartão.
- **Linhas** (`line`, `line-strong`): borda de cartão e divisor; `line-strong` para hover, borda de botão secundário e estágio "perdido" do funil.
- **Tinta** (`ink`, `ink-2`, `ink-3`): texto principal, texto de apoio, rótulo terciário. `ink-3` passa de 4,5:1 sobre cartão e chão nos dois temas.

### Named Rules
**The Menta-na-Interface Rule.** `#3DF5A8` pinta interface (pílula clara, ponto da marca, anel, `ok` escuro) e nunca preenche área de gráfico; a série verde do gráfico é `--g-1`.

**The Validator Rule.** Cor de gráfico sai só de `--g-1..4`. Série nova ou tom novo passa pelo validador de paleta nos dois temas antes de entrar; cor escolhida a olho não entra, nem "uma variação" de um `--g-*`.

**The Canal-Vira-Texto Rule.** No tema claro, `--wa`, `--mail`, `--sms` e `--ig` também são cor de texto (nome do canal, iniciais) e precisam passar de 4,5:1 contra o fundo onde o texto de fato está — inclusive a tinta diluída do ícone ou do avatar, não só o cartão branco. Sobre a tinta, o ícone e as iniciais nunca usam a cor pura: `tinta()` (em `componentes/base.tsx`) puxa a cor do canal 28% para `--ink` (`color-mix(in oklab, cor 72%, var(--ink))`), o que passa de 4,9:1 nos dois temas.

**The Simulado-É-Âmbar Rule.** Modo simulado fala em `warn`, nunca em `ok`. Mensagem simulada nunca é rotulada como "enviada" ou "que saíram": o rótulo troca para "Mensagens simuladas", a taxa de resposta vira "—" com o motivo, e a faixa âmbar diz quantas foram simuladas.

## Typography

**Display Font:** Anek Latin Variable (eixos padrão `wght` e `wdth`, empacotada com o build por `@fontsource-variable/anek-latin/standard.css`), com Roboto Variable e system-ui de reserva.
**Body Font:** Roboto Variable (`@fontsource-variable/roboto`), com Roboto e a pilha do sistema de reserva.
**Label/Mono Font:** Roboto Mono Variable para chave, URL de webhook, número de telefone e código.

**Character:** Anek Latin comprimida (`font-stretch` 90–96%) dá aos títulos e números um corpo alto e firme, de painel; Roboto fica neutra e legível no tamanho pequeno da operação. As fontes vêm do build, não do Google — a primeira pintura já sai na letra certa.

### Hierarchy
- **Display** (600, 34px, 1.12, `font-stretch: 90%`): só a saudação do Início ("Boa tarde, Marina"). 28px abaixo de 900px.
- **Headline** (600, 30px, 1.12, 96%): título de página (`h1`). 26px abaixo de 900px.
- **Figure** (600, 30px, 1.05, −0.02em, 92%, algarismos tabulares): número do KPI. Variantes no mesmo desenho: 22px na conversão do funil, 21px no total de campanha, 17px dentro do anel; 24px no KPI do celular.
- **Title** (600, 17.5px, 1.25, 96%): título de bloco do painel. Parentes: 19px no título de seção, 16.5px no título de item de índice, 15.5px na coluna do Kanban, 15px no cartão do assistente.
- **Body** (400, 14px, 1.5): todo texto corrido. Subtítulo de página 14.5px em `ink-2`, até 70ch.
- **Label** (600, 13.5px): rótulo de KPI, botão, nome em lista.
- **Caption** (400, 12.5px, 1.45, `ink-3`): subtítulo de bloco, ajuda de campo, rodapé de KPI, legenda.
- **Axis** (400, 11px, tabular, `ink-3`): marcas de eixo; o título de cada painel do gráfico é 11.5px 600 em `ink-2`.

### Named Rules
**The Número-em-Anek Rule.** Todo número que é o dado principal (KPI, total, conversão, progresso) é Anek Latin 600 comprimida com `font-variant-numeric: tabular-nums`. Número dentro de tabela, dica e legenda fica em Roboto, também tabular.

**The Sem-Caixa-Alta Rule.** Rótulos são frase normal em português, sem caixa alta e sem sobrelinha ("kicker") acima de título. O build não tem nenhum, e o tamanho e o peso já fazem a hierarquia.

## Layout

Casca de duas colunas: rail fixo de 248px (`--rail-w`) à esquerda, conteúdo à direita com topo preso de 68px (busca, tema, avatar). O conteúdo vive em `.wrap`, até 1240px, com 28px em cima e 30px nas laterais.

O Início usa uma grade de 12 colunas com 16px de calha: KPIs na largura toda (`repeat(auto-fit, minmax(200px, 1fr))`, 14px de calha), depois ritmo diário em 8 + funil em 4, depois quem respondeu em 7 + coluna de 5 com campanhas e "por canal". As demais telas empilham painéis com 14px entre vizinhos e seções com 34px acima do título.

A ordem do Início é regra, não composição: o que o motor não fez → números do período com variação contra o anterior → ritmo diário → funil, respostas, campanhas. O seletor de período (7/14/30 dias) mora no cabeçalho, à direita da saudação.

Pontos de quebra observados:
- **1100px:** toda coluna da grade vira largura cheia.
- **900px:** o rail vira gaveta (`min(300px, 86vw)`, desliza da esquerda com véu escuro), o topo ganha botão de menu e a marca, a busca some, o respiro lateral cai para 16px.
- **560px:** KPIs em duas colunas com 10px de calha, número 24px, curva de 38px.

### Named Rules
**The Grupo-Fechado Rule.** Grupos do rail (Canais, Configurações) abrem fechados; só abrem quando a rota atual está dentro deles. Grupo abre índice, não conteúdo — a tela de Configurações é uma lista de itens, cada assunto na sua própria tela (D21).

## Elevation & Depth

Profundidade tonal primeiro, sombra depois. Cada degrau (`ground` → `rail` → `surface` → `surface-2` → `surface-3`) é um passo de luminosidade, e todo cartão tem borda `line` de 1px. A sombra é macia e longa, quase invisível no escuro, só o bastante para descolar o cartão do chão no claro. Atrás de tudo, dois blobs desfocados (`filter: blur(110px)`, `position: fixed`, `z-index: -1`) — periwinkle no alto à direita, menta embaixo à esquerda — aparecem só nas calhas entre cartões opacos. O único desfoque de fundo funcional é o do topo preso (`backdrop-filter: blur(14px) saturate(1.2)` sobre `ground` a 78%), que separa o que rola do que fica.

### Shadow Vocabulary
- **Cartão** (`--shadow`; escuro: `0 1px 0 rgba(255,255,255,.03) inset, 0 18px 40px -24px rgba(0,0,0,.8)`; claro: `0 1px 2px rgba(40,30,70,.04), 0 12px 32px -18px rgba(40,30,70,.22)`): painel, KPI, card do Kanban.
- **Flutuante** (`--shadow-pop`; escuro: `0 20px 50px -18px rgba(0,0,0,.85), 0 0 0 1px var(--line)`; claro: `0 18px 44px -14px rgba(40,30,70,.30), 0 0 0 1px var(--line)`): dica do gráfico, rail como gaveta, cartão de entrar.
- **Halo de foco** (`0 0 0 4px var(--accent-soft)`): campo focado, junto com a borda `accent-line`.

### Named Rules
**The Blob-Atrás Rule.** Os blobs ficam atrás de cartões opacos e nunca capturam clique; cartão translúcido sobre blob não existe. A única exceção é a coluna do Kanban, que é `surface` a 55% de propósito, porque é calha e não cartão.

## Shapes

Cantos generosamente arredondados em quatro passos: 18px (`--r`) para painel, KPI e coluna do Kanban; 14px (`--r-md`) para item de índice, card do Kanban, faixa de modo e dica; 12px (`--r-sm`) para botão, campo, item do rail, opção e aviso; 9px para a opção do segmento e o seletor do card. Chip, variação, contador e barra são pílula (999px). Barras do gráfico têm a ponta arredondada pela metade da largura; trilhos de barra horizontal são 8px de altura em pílula; a divisão por canal é uma barra só de 12px com 2px de cartão entre os pedaços. Balão do assistente é 18px com o canto de origem em 6px. Nada é quadrado; nada tem sombra dura.

## Components

### Buttons
Firmes e baixos, com o peso no rótulo, não no volume.
- **Shape:** cantos de 12px, altura mínima 40px (44px no cartão de entrar), 16px de respiro lateral, ícone de 17px com 8px de espaço.
- **Primary:** `accent` com texto `accent-ink`, sem borda. Um por área de decisão (ex.: "Continuar configuração").
- **Hover / Focus:** primário clareia com `filter: brightness(1.08)`; secundário vai para `surface-2`; `:active` desce 1px; foco é o anel `accent` de 2px com 2px de afastamento. Transição de .16s em `--ease`.
- **Secondary:** `surface` com borda `line-strong` e texto `ink`.
- **Icon button:** 40×40, `surface` com borda `line`, ícone 18px em `ink-2`; hover acende a tinta e a borda.
- **Link:** texto `accent` sublinhado (offset 3px); nos blocos do painel aparece sem sublinhado, 600, e sublinha no hover ("Ver todas", "Abrir").
- **Disabled:** opacidade .5, cursor proibido, sem filtro nem deslocamento.

### Chips e variações
- **Chip:** pílula 12px/500, `surface-2` + `ink-2`; variantes `ok`, `alerta` (`warn`), `erro` (`crit`), `acento`. Um ponto de 8px em `currentColor` marca passo feito.
- **Variação (delta):** pílula 12px/600 tabular com seta de `icones.tsx` (`sobe`/`desce`): verde para alta, coral para baixa, neutra "estável" quando a mudança é menor que 0,5%. Taxas mostram a diferença em pontos percentuais ("0,8 p.p."), não em porcentagem.

### Cards / Containers
- **Corner Style:** 18px.
- **Background:** `surface`, opaco.
- **Shadow Strategy:** `--shadow` (ver Elevation & Depth).
- **Border:** 1px `line`.
- **Internal Padding:** 20px (16px abaixo de 900px); KPI 18/18/16.
- **KPI com tendência:** rótulo, número com variação ao lado, rodapé em caption, e a curva da série encostada na borda de baixo do cartão (64px, gradiente da cor da série de .42 a 0, sem eixo nem dica — o número exato está logo acima).
- **Item de índice:** cartão de 14px com ícone em quadrado de 42px sobre a cor do canal diluída a 16% e desenhado na cor do canal puxada para `--ink` (`tinta()`), título em Anek 16.5px, descrição em caption, contagem e seta à direita; hover sobe a borda e empurra a seta 2px.

### Inputs / Fields
- **Style:** 42px de altura, `field` com borda `line`, cantos de 12px, rótulo 13px/600 acima, ajuda em caption abaixo; select sem cromo do sistema.
- **Focus:** borda `accent-line` e halo de 4px em `accent-soft`, sem outline.
- **Hover:** borda `line-strong`.
- **Busca do topo:** 40px em `surface`, ícone de busca dentro à esquerda.

### Navigation
- **Rail:** 248px em `rail`, marca no topo (quadrado índigo com o P branco e o ponto menta), lista principal, divisor, grupos Canais e Configurações, e no pé o cliente com avatar e os botões Claro/Escuro e Sair.
- **Item:** 40px, ícone 19px, texto 14px em `ink-2`; hover em `surface-2`.
- **Ativo:** pílula preenchida `pill` com `pill-ink` e peso 600 — índigo no escuro, menta no claro.
- **Contador:** pílula `accent-soft`/`accent` à direita (ex.: respostas das últimas 24h), "99+" acima de 99.
- **Subitens:** 34px, recuados, com fio vertical de 1px em `line`; o atual ganha `surface-2` e um fio `accent` de 2px.
- **Mobile:** abaixo de 900px o rail é gaveta com véu; o topo mostra menu, marca, tema e avatar.

### Segmento de período
Trilho `surface` com borda e 4px de respiro; opções de 32px em `ink-3`, a selecionada em `surface-3` com `ink`. Usado para 7/14/30 dias.

### Faixa de modo simulado
Faixa âmbar (`warn-soft`, texto `warn`, borda `warn` a 28%) com o ícone `alerta`, no topo do Início sempre que houve mensagem no período e nenhuma saiu de verdade. Diz quantas foram simuladas e onde ler o texto de cada uma. É o primeiro bloco da página quando existe.

### Gráfico no tempo (assinatura)
SVG próprio, sem biblioteca. Uma grandeza por painel, cada painel com seu título e sua escala, todos empilhados sobre o mesmo eixo de tempo; a mira atravessa todos e a dica mostra todos. Curva monotônica (Fritsch–Carlson) de 2.25px com área em gradiente (.34 → 0); barras finas com gradiente (1 → .35) e ponta redonda. Eixo com topo "redondo" e marcas em 0, ¼, ½, ¾, topo; rótulos de data só onde cabem. O dia de hoje, ainda parcial, sai tracejado (`3 5`) na linha e a 45% na barra, e a dica diz "hoje, parcial". Mira tracejada (`3 4`) em `line-strong`, ponto de 5px com anel `surface`. Setas do teclado andam dia a dia, Esc sai, e uma tabela oculta repete os dados para leitor de tela. Entrada: a linha se desenha em .9s, a área surge em .6s depois de .35s.

### Barras, divisão e anel
- **Barras horizontais:** rótulo, número e nota numa linha; trilho de 8px em `surface-2`; crescem da esquerda em .8s com 40ms entre itens. No funil, estágios abertos em `--g-2`, ganho em `--g-1`, perdido em `line-strong`.
- **Divisão por canal:** uma barra de 12px fatiada nas cores de canal, com legenda e porcentagem.
- **Anel:** 64px, traço de 6px sobre `surface-3`, menta por padrão, "feito/total" no centro em Anek. Só para progresso de verdade (passos da configuração).

### Dica (tooltip)
`surface-3`, 14px de canto, `--shadow-pop`, seta de 10px; título em 12px/600 `ink-2`, uma linha por série com quadradinho da cor, valor 600 tabular.

### Lista de respostas
Avatar de 38px com as iniciais na cor do canal diluída, nome 14px/600, o texto da pessoa entre aspas em até duas linhas, chips de canal e campanha, chip `erro` "pediu para sair" quando suprimido, hora relativa à direita. Linha inteira clicável, hover em `surface-2`.

### Ícones
Conjunto próprio em `componentes/icones.tsx` (e os de canal em `componentes/base.tsx`): grade de 24, traço de 1.7, pontas e junções redondas, sem preenchimento. Tamanhos: 19px no rail, 18px no topo, 17px em botão, 20px em item de índice, 11–15px em seta e marca de passo.

## Do's and Don'ts

### Do:
- **Do** usar sempre `var(--token)`; os dois temas trocam o valor sob o mesmo nome.
- **Do** abrir o Início pelo que o motor não fez (faixa âmbar de simulado, cartão de configuração pendente) antes de qualquer número.
- **Do** comparar todo número do período com o período anterior por meio de uma variação (delta), e taxas em pontos percentuais.
- **Do** separar grandezas de escala diferente em painéis empilhados com o mesmo eixo de tempo.
- **Do** desenhar o dia de hoje tracejado (linha `3 5`, barra a 45%) e dizer "hoje, parcial" na dica.
- **Do** dar a todo gráfico mira, dica, navegação por setas e tabela oculta.
- **Do** tirar cor de gráfico só de `--g-1..4`, e passar pelo validador de paleta nos dois temas qualquer cor nova.
- **Do** conferir 4,5:1 para toda cor de canal usada como texto no tema claro, contra o fundo real (incluindo a tinta diluída).
- **Do** usar Anek Latin 600 comprimida e algarismos tabulares para todo número principal.
- **Do** manter os grupos do rail fechados por padrão (D21).
- **Do** respeitar `prefers-reduced-motion`: animações e transições caem para .01ms e a linha do gráfico aparece já desenhada.

### Don't:
- **Don't** pôr um segundo eixo Y em gráfico nenhum.
- **Don't** rotular mensagem simulada como "enviada" ou "que saiu", nem calcular taxa de resposta sem envio real.
- **Don't** usar a menta `#3DF5A8` como preenchimento de área de gráfico.
- **Don't** escolher cor de gráfico a olho nem derivar tom de um `--g-*` sem o validador.
- **Don't** usar emoji, glifo de fonte ou biblioteca de ícones; ícone novo é desenhado em `icones.tsx` no mesmo traço.
- **Don't** pôr caixa alta, sobrelinha ("kicker") ou rótulo-chamariz acima de título.
- **Don't** abrir grupo de Configurações ou Canais expandido por padrão.
- **Don't** usar o anel para algo que não seja progresso de passos de verdade.
- **Don't** usar sombra dura ou deslocada; profundidade é tom, borda de 1px e a sombra macia do sistema.
- **Don't** deixar cartão translúcido sobre os blobs; cartão é opaco.

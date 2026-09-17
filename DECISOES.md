# Motor de Prospecção Multicanal — Decisões de Arquitetura

> Documento vivo. Cada decisão registra **o que foi decidido**, **por quê** e **a consequência técnica**.
> Decisão revisada gera entrada nova, não edição da antiga.

---

## Contexto

Evolução da base existente (`sdr-resgate-evolution`, Disparador/Blaster) de **disparador em lote** para
**motor de cadência multicanal com estado por contato**. Atende dois casos de uso: resgate de
oportunidades antigas (base própria) e prospecção em listas frias.

Abordagem: *strangler fig* sobre a codebase atual — o sistema novo nasce ao lado e absorve o antigo.
Não é rewrite.

---

## Decisões tomadas

### D1 — O motor é um serviço autônomo com API própria
**Consequência:** não há join com a base do CRM. O motor obrigatoriamente tem `contacts` e
`contact_identities` próprios. Ganho colateral: pode subir em produção antes do ProfitCare estar
pronto, consumindo Pipefy como fonte e trocando depois sem alterar o motor.

### D2 — Ingestão via adapters de entrada, espelhando os adapters de canal
Fontes na v1: planilha (upload) e CRM com seleção de etapas de origem.
**Consequência:** interface `ContactSource` com implementações `PlanilhaSource`, `PipefySource`,
`ProfitCareSource`. Toda identidade carrega `origem` e `origem_ref`. Dedup acontece na ingestão,
não no envio.

### D3 — Writeback para o CRM, com contrato estreito
O motor escreve de volta um conjunto pequeno e fixo de fatos: `opt_out`, `identidade_invalida`,
`respondeu`, `campanha_concluida`. Nunca sobrescreve campo do qual o CRM é dono.
**Consequência:** exige credencial de escrita; exige marcação de autoria em toda escrita e descarte
dos próprios eventos no webhook de volta (prevenção de loop de eco); writeback vai por **outbox
assíncrona com retry**, nunca inline com o envio.

### D4 — Ambos os casos de uso no mesmo motor; `tipo_campanha` é estrutural
Campanha não é rótulo: carrega base legal, pool de remetentes permitido e canais habilitados.
O roteador consulta o tipo antes de escolher remetente.
**Consequência:** campanha fria nunca sorteia remetente da operação morna nem dispara do domínio
institucional. Isolamento de raio de explosão garantido por schema, não por disciplina operacional.

### D5 — Cutover começa por resgate de base própria
Mesma codebase para os dois, ordem diferente em produção. Base própria erra barato; lista fria
errando custa remetente queimado.

### D6 — WhatsApp nos dois modos, roteado por campanha
Oficial (Cloud API) para base própria com opt-in; não-oficial (UAZAPI) para frio.
**Consequência:** dois adapters, dois pools de remetentes. Separar o Business Manager da operação
oficial do BM que roda anúncios do grupo.

### D7 — Condições de encerramento do enrollment
Encerram: **resposta em qualquer canal**, **mudança de etapa no CRM**, **fim dos passos**.
Não encerra: **clique em link** — registra como evento de engajamento, pode acelerar o próximo
passo ou trocar o canal, mas a cadência continua.
*Justificativa:* clique é curiosidade, não intenção; encerrar por clique descarta o lead que estava
esquentando. **Revisável** — marcado para revisão após os primeiros dados do shadow mode.

### D8 — Cadência linear na v1, ramificada depois
**Consequência:** `flow_steps` já nasce com coluna `condicoes` (JSONB, vazia na v1) para evitar
migração grande depois.

### D9 — Flows editados apenas pelo time técnico; sem construtor visual na v1
Flow vive como configuração versionada no repo.
**Consequência crítica:** `flow_versions` imutáveis. O enrollment aponta para uma **versão**, não
para o flow. Editar um flow cria versão nova; quem já está inscrito termina na versão antiga.

### D10 — Instagram entra apenas na janela legítima de 24h
`InstagramAdapter` implementado via API oficial (resposta a quem iniciou contato).
Cold DM **não** é adapter — é automação de navegador com sessão, fingerprint e manutenção contínua.
Fica como spike paralelo (ver S3), sem bloquear o motor.

### D11 — Banimento tratado como custo previsível, não como acidente
Postura de risco definida. **Consequência de projeto:** isolar raiz de identidade entre canais —
domínios de prospecção separados do institucional, BM separado do BM de anúncios, chips como
recurso descartável com custo unitário conhecido e health score no pool.

### D12 — Schema antes dos adapters; inverte a ordem das Fases 1 e 2
A ordem original punha `ChannelAdapter` antes do schema novo. Invertido após o inventário da Fase 0.
*Justificativa:* as quatro invariantes são garantidas por schema — chave única `(enrollment_id,
step_id)`, índice parcial em `next_run_at`, gate de supressão, quota por remetente. Schema errado
custa migration em dado de produção; adapter errado custa uma classe. Além disso a Fase 0 mostrou
que a Fase 1 é bem maior do que se supunha (5 caminhos de saída e 7 de entrada, não 3 clientes),
então deixá-la depois evita bloquear o resto.
**Consequência:** o schema central nasce com teste automatizado das invariantes (`tests/run.sh`)
antes de existir qualquer código de envio. O motor não envia nada até a Fase 1 — o que é aceitável,
porque shadow mode (`status = 'simulado'`) já é caminho de primeira classe no schema.

### D13 — Mapa de status legado: quatro escolhas que o backfill precisava
Tomadas ao fechar `MAPA-STATUS.md`, antes de qualquer linha migrada.

1. **`reengaging` vira enrollment novo** em campanha de reengajamento. O modelo novo não tem camadas.
2. **`waiting_cycle` encerra e reinscreve**, em vez de manter um enrollment vivo com o passo zerado.
3. **`cancelado_operacional` entra no enum** `motivo_encerramento`. Decisão humana não é falha do
   motor, e o relatório precisa distinguir.
4. **Supressão migrada alcança a pessoa**, todos os canais — e `discarded` sem metadado é tratado
   como opt-out.

*Justificativa da 4, que é a de maior consequência:* `blast_leads.status = 'discarded'` é gravado
por dois caminhos opostos — opt-out detectado pelo `evolution-webhook` (com `discarded_reason` e
inserção em `contact_blacklist`) e descarte manual pelo operador (sem metadado). Colapsar os dois
num destino só faria quem pediu para sair voltar a ser elegível, quebrando a invariante 2 no
primeiro dia de produção, com registro de que a pessoa pediu para sair.

**Consequência:** o mapa deixa de ser prosa e vira `backfill/mapa_status.sql`, coberto por
`tests/mapa_status.sql` nos 27 valores legados. Status sem mapeamento derruba o backfill em vez de
virar estado inventado. A migration `20260916140000` acrescenta o valor do item 3.

### D14 — O WhatsApp não-oficial é Evolution API, não UAZAPI
Revisa a premissa de D6, que supunha UAZAPI para o modo frio.
*Evidência:* busca por `uaz` nos quatro repositórios não retorna nenhuma ocorrência em código.
O não-oficial que roda hoje é Evolution API self-hosted (`evolutionapi.grupoafx.com.br`), com
cliente completo em `send-evolution-message` e webhook em `evolution-webhook`.
**Consequência:** `WhatsAppEvolutionAdapter` é o adapter do modo frio, e o cliente UAZAPI que o
"o que sobrevive da codebase atual" listava como "migra quase intacto" não existe para migrar.
O spike S1 muda de objeto: medir queima do pool Evolution atual, com dados de produção que já
existem, em vez de um experimento de duas semanas com UAZAPI.
**Reversível a custo baixo:** a interface `ChannelAdapter` não conhece provedor. Adotar UAZAPI
depois é uma classe nova no `adapters/` e uma linha no registro — nada no motor muda.
*Confirmar com o time comercial se há compromisso contratual com UAZAPI que eu não enxergo pelo
código.*

---

## Decisões adiadas (não decidir agora)

| Tema | Por que esperar |
|---|---|
| RCS | Exige agente verificado junto a agregador/operadoras. Adapter previsto na interface; implementar quando houver volume que justifique o processo. |
| Volumes-alvo e quotas por remetente | Dados virão do shadow mode. Decidir antes é chute. |
| Telas de operação e relatórios | Reversível. Depende de como o flow se comporta em produção. |
| Construtor visual de flows | Só faz sentido quando o time comercial precisar editar (hoje não precisa, D9). |

---

## Spikes abertos

**S1 — Capacidade e queima do UAZAPI.** Qual volume por chip, com que taxa de banimento e qual custo
por remetente. Experimento de ~2 semanas. Não bloqueia o motor.

**S2 — Warm-up de domínios de e-mail.** Provisionamento é o caminho crítico mais longo do projeto
(3–6 semanas de calendário, independente de código). **Iniciar imediatamente, em paralelo à Fase 0.**

**S3 — Viabilidade de cold DM no Instagram.** Medir taxa de conta queimada e custo de manutenção.
Se viável, entra depois como pool de remetentes — a interface já estará pronta.

---

## Ordem de execução

| Fase | Entrega | Risco |
|---|---|---|
| 0 | ✅ Inventário read-only — `INVENTARIO-FASE-0.md`: 83 edge functions e 52 tabelas classificadas | Nenhum |
| 2 | Schema novo com invariantes garantidas por constraint/trigger + backfill de contatos com dedup | Baixo |
| 1 | Interface `ChannelAdapter` sobre os 5 provedores reais (Evolution, Meta Cloud, Gupshup, Twilio, Z-API/360dialog) sem mudar comportamento — ver D12 | Muito baixo |
| 3 | **Shadow mode**: motor calcula e grava tudo como `simulado`, não envia. Compara com o Disparador atual | Nenhum — de-risca tudo |
| 4 | Cutover por campanha, começando por resgate (D5) | Controlado |
| 5 | Deletar o caminho antigo — **com data definida** | Baixo |

---

## O que sobrevive da codebase atual

**Migra quase intacto:** clientes de provedor (Gupshup, Comtele, UAZAPI), `_shared/pipefy.ts` com
OAuth client_credentials, classificador da Ana (vira detecção de resposta), gate de blacklist,
padrão de secrets no Vault, UX do Disparador (upload multi-formato, modos de disparo, resumo por IA).

**Descarta:** modelo de execução em lote, status-como-mutex entre camadas, qualquer tabela modelada
por canal.

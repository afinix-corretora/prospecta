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
**Revisada por D22:** o compromisso existe, e UAZAPI passou a ser o não-oficial.
*Confirmar com o time comercial se há compromisso contratual com UAZAPI que eu não enxergo pelo
código.*

### D15 — Adiamento espera a capacidade voltar, não um intervalo fixo
Quando o pool não tem vaga, o agendador reagenda para quando a capacidade pode voltar:
virada da janela diária se a quota esgotou, fim do prazo se o circuito está aberto, uma hora se não
há remetente cadastrado.
*Como apareceu:* o cenário de `demo/` mostrou um chip frio com quota de 2/dia esgotando na terceira
hora e o motor adiando o mesmo contato de 15 em 15 minutos até o fim — 36 tentativas sem chance de
dar certo. Nenhum teste tinha pego, porque cada adiamento isolado estava correto.
**Consequência:** `proximo_horario_de_pool(canal, tipo)` é a fonte dessa resposta, e o cenário
passou de 105 horas com 36 adiamentos perdidos para 5 dias com zero.

### D16 — Agente é dono da conversa; motor é dono da cadência
Cada canal de uma campanha pode ter um agente de IA como persona de resposta. O motor decide
quando tocar e por onde; quando a pessoa responde, o enrollment encerra (invariante 4) e o agente
assume a conversa dali.
*Justificativa:* o agente não acelera passo, não troca canal e não reescreve cadência. Se fizesse,
haveria dois donos do mesmo estado — e o inventário da Fase 0 mostrou o custo disso no legado, onde
`nina-orchestrator` e os motores de disparo disputavam o mesmo lead.
**Consequência:** `agents` tem canal obrigatório, e `campaign_agents` tem chave primária
`(campaign_id, canal)` — uma persona por canal por campanha. Nenhuma tabela do motor
(`enrollments`, `messages`, `flow_steps`) referencia agente; há teste que verifica isso.
Agente de Instagram não atende WhatsApp: janela de resposta, tom e tamanho de mensagem são
diferentes, e o trigger recusa.

### D17 — Provedor de IA é catálogo, não enum
`ai_provider_catalog` guarda, por provedor, os campos que ele precisa. A tela de configuração se
monta a partir disso — escolher OpenAI mostra API key, organização e base URL; escolher Anthropic
mostra API key e base URL; e nenhum código de UI conhece provedor nenhum.
*Justificativa:* provedor novo é uma linha no catálogo, não um deploy de front.
**Consequência crítica:** o catálogo marca quais campos são segredo, e um trigger em
`ai_credentials` **recusa** gravar qualquer um deles em `config`. Não existe coluna para a chave —
só `chave_secret_id` apontando para o Vault. A anti-regra "nunca colocar secret fora do Vault"
deixa de depender de disciplina e passa a ser verificada pelo banco, com teste.
Lista de modelos é sugestão, não enum: catálogo de modelo muda toda semana e lista fixa envelhece.

### D18 — Multi-tenant desde a primeira migration, em três camadas
`tenant_id` em toda tabela de domínio, chaves estrangeiras **compostas** `(tenant_id, id)`, e RLS
por tenant com papel decidindo escrita (`dono`, `admin`, `operador`, `leitor`).
*Justificativa:* não existe "começa com um cliente e depois vira multi". Adicionar `tenant_id` a
tabelas com dados dentro é backfill com janela de inconsistência em cima de um sistema que já
manda mensagem para gente real. Custa quase nada agora e é reescrita depois.
**Por que três camadas e não só RLS:** RLS protege o que passa pelo PostgREST com um JWT. O worker
roda com a service key e RLS não o alcança — é a chave composta que impede um enrollment do cliente
A apontar para a campanha do cliente B, e ela vale inclusive para superusuário. As camadas cobrem
buracos diferentes; nenhuma confia na de cima.
**Consequências:**
- Supressão é por cliente. O mesmo telefone pode estar na base de dois clientes, e o opt-out dado a
  um não é um fato do outro. `esta_suprimido()` recebe o tenant como primeiro argumento.
- Tenant é sempre explícito em chamada de função. `criar_campanha_de_modelo()` perdeu a sobrecarga
  curta: tenant implícito em função é exatamente como bug entre clientes acontece.
- Catálogo (`campaign_templates` e `agents` com `tenant_id IS NULL`) é compartilhado e imutável para
  o cliente. Atribuir um agente do catálogo **copia** a linha para o tenant — editar a persona não
  vaza para os outros clientes.
- Teste de negação confere SQLSTATE, não só que deu erro: `42501` (RLS), `23503` (chave composta),
  `23001` (gatilho agente/campanha). "Levantou exceção" também é o que um typo faz.

### D19 — `public` é API; o motor mora em `privado`
O PostgREST publica toda função de `public` como `/rest/v1/rpc/<nome>`. Ficam em `public` apenas as
10 funções que alguém de fora chama de verdade; RLS, gatilhos e engrenagens do motor vão para o
schema `privado`, que não está em *Exposed schemas*.
*Justificativa:* a alternativa — revogar EXECUTE e manter tudo em `public` — **não funciona**:
expressão de política RLS e corpo de função de gatilho passam pela checagem de EXECUTE do papel que
está escrevendo, então revogar de `PUBLIC` derruba o RLS e os gatilhos. Testado, não deduzido.
**Consequências:**
- `anon` não executa nada em `public`. O default privilege que o Supabase instala foi revogado, então
  função nova não vira endpoint por esquecimento — virar API é decisão explícita.
- `criar_tenant` virou duas: a self-service (dois argumentos, dono é sempre quem está logado) e a
  administrativa (três argumentos, só `service_role`). A forma antiga, `SECURITY DEFINER` com
  `p_dono` e aberta a `anon`, deixava qualquer visitante criar tenant em nome de um uuid arbitrário.
- Toda função tem `search_path` fixo: sem isso, `SECURITY DEFINER` é escalada de privilégio.
**De onde veio:** do `get_advisors` do projeto real, não do suite. O Postgres de teste não tem os
default privileges do Supabase — o suite passava com o buraco aberto. Ficou uma asserção que pega a
regressão (`pg_default_acl` sem `anon`/`authenticated`), mas o advisor continua sendo a checagem que
enxerga o que só existe no projeto.

### D20 — Provedor de canal é catálogo; Gupshup é o WhatsApp oficial
`channel_provider_catalog` descreve, por canal, cada provedor e os campos que ele precisa —
o mesmo padrão do D17 para IA. `sender_accounts.provedor` passa a ser chave estrangeira para ele.
*Justificativa:* `provedor` era texto livre, com um comentário dizendo que um CHECK obrigaria
migration a cada provedor novo. O comentário estava certo sobre o CHECK e errado sobre a conclusão:
quem evita migration é catálogo, não texto solto. Com texto solto, um typo vira remetente que o
despachante não sabe construir — e isso só aparece na hora do envio.
**Escolhas de provedor:**
- **WhatsApp oficial: Gupshup** (BSP homologada), com adapter em `adapters/whatsapp-gupshup.ts`.
  Múltiplas contas e múltiplas apps convivem: cada app é um `sender_account` com o seu `app_name`,
  o seu `source` e o seu segredo no Vault. Por isso o pool e a quota por remetente (invariante 3)
  continuam valendo sem nada de novo. Meta Cloud fica no catálogo como alternativa direta.
- **WhatsApp não oficial: Evolution API** — automação sem homologação, para campanha fria, longe do
  número institucional (D4). É o que existe na base, conforme D14.
- **SMS: Comtele**, adapter já pronto.
- SMTP e Instagram entram no catálogo declarados **sem adapter**: aparecem na tela, não viram opção
  de envio. O motor recusa antes de prometer.
**Consequência:** a tela de conectar conta se monta a partir de `campos`, então nenhum código de UI
conhece Gupshup, Evolution ou Comtele. E o que o catálogo marca como segredo é recusado em
`sender_accounts.config` por gatilho — a mesma garantia de `ai_credentials`.

### D21 — Tudo em Configurações e Canais é submenu
Abrir Configurações mostra um **índice** do que existe dentro; nada nasce expandido. O mesmo em
Canais, onde cada canal tem a sua tela com as contas conectadas daquele canal.
*Justificativa:* a versão anterior abria Provedores de IA junto com Agentes na mesma tela. Com
quatro assuntos em Configurações e quatro canais, empilhar tudo numa página só deixa de ser
navegação e vira rolagem.
**Consequência:** o rail tem grupos que abrem e fecham, e só o grupo da tela atual fica aberto.
Clicar num grupo já aberto fecha — nunca pula direto para o conteúdo de um filho.

### D22 — O não-oficial passa a ser UAZAPI; Evolution fica no catálogo
Revisa D14. Ela concluiu Evolution porque o inventário da Fase 0 não achou UAZAPI em repositório
nenhum, e deixou a pergunta explícita: *confirmar com o time comercial se há compromisso contratual
com UAZAPI que eu não enxergo pelo código*. Há. Então UAZAPI é o não-oficial daqui para frente.
*Justificativa:* a decisão é contratual, não técnica — e D14 já previa isto ao dizer que era
"reversível a custo baixo, porque a interface `ChannelAdapter` não conhece provedor". Foi
exatamente isso: uma classe em `adapters/whatsapp-uazapi.ts` e uma linha no catálogo.
**Evolution não sai.** É o que roda hoje no legado e é para onde os chips existentes apontam;
removê-la do catálogo quebraria a chave estrangeira dessas contas no dia do backfill. Os dois
convivem, UAZAPI aparece primeiro, e a troca de chip é operacional — conta a conta.
**Sobre a API:** confirmado na documentação que o envio é `POST {base}/send/text` com corpo
`{number, text}` e autenticação por header `token` (o da instância, nunca o `adminToken` — enviar
não precisa de poder administrativo). O nome do campo que carrega o id da mensagem varia entre
versões, então o adapter lê de uma lista de grafias em vez de um caminho fixo. Isso está comentado
no arquivo, separando o que é confirmado do que é defensivo.

### D23 — Nas APIs não oficiais, resposta só encerra enrollment se vier citando
`registrar_evento_provedor` liga o retorno à mensagem por `provider_message_id`. Nas APIs oficiais
isso funciona: a Meta e a Gupshup mandam o `context` da mensagem respondida. Nas não oficiais, a
resposta do contato normalmente **não cita nada** — o payload traz o id da mensagem *dele*, que não
existe em `messages`.
*Decisão:* o adapter da UAZAPI só emite `respondido` quando há citação. Sem citação, não emite —
gravar o id dele seria inventar um vínculo que nunca casa.
**Consequência, que é um buraco aberto:** a invariante 4 (resposta encerra o enrollment inteiro)
**não vale** para resposta sem citação no canal não-oficial. O contato responde, o motor não fica
sabendo, e a cadência continua. Vale hoje para Evolution também — o adapter atual emite o id da
mensagem do contato, que igualmente não casa; a diferença é que ele registra um evento inútil em vez
de nenhum.
**Fechada por D24:** a decisão foi uma URL de webhook por `sender_account`.

### D24 — Um endpoint de webhook por chip
Cada `sender_account` nasce com um `webhook_token` (uuid aleatório) e a sua URL própria:
`/canal-webhook/<token>`. Era por provedor; passou a ser por conta.
*Justificativa:* fecha D23. Quem recebe o evento precisa saber de qual chip ele veio, porque é daí
que sai o tenant — e sem tenant, casar uma resposta pelo número escolheria a mensagem de outro
cliente. A alternativa (o provedor mandar a instância no payload) depende de cada provedor mandar,
e de mandar certo; a URL é nossa e vale para todos.
**Como a resposta encerra a cadência agora:** `registrar_resposta_por_numero(chip, número)` acha a
última mensagem que aquele tenant mandou para aquela identidade e grava `respondido` nela. O
encerramento continua saindo do gatilho de `message_events` — a invariante 4 não ganhou um segundo
caminho, ganhou uma segunda entrada para o mesmo caminho.
**Duas escolhas dentro disso, ambas contraintuitivas:**
- *Não filtra por chip.* A pessoa responde para quem falou com ela, e o pool pode ter trocado de
  chip entre um toque e outro.
- *Não filtra por status da mensagem.* `pendente` entra porque o webhook pode ganhar do
  despachante: o provedor entrega, a pessoa responde e o retorno chega antes de
  `registrar_resultado_envio` gravar `enviado`. Filtrar perderia exatamente a resposta mais rápida.
**O token é a credencial.** Quem tem a URL pode postar evento naquele chip. São 128 bits aleatórios,
um por conta, e token desconhecido responde 404 sem dizer mais nada.
**Evolution também foi corrigida:** ela emitia o id da mensagem do contato, que nunca casava com
`messages`. Agora casa pelo número, como a UAZAPI.

### D25 — A plataforma cria a instância; o segredo nasce no Vault
`provider_servers` guarda URL e token de administração do provedor (o token no Vault, sem coluna de
texto). A partir dele, `provisionar-instancia` cria a instância, guarda o token dela no Vault e
cria o `sender_account` — tudo sem ninguém abrir o painel do provedor.
*Justificativa:* chip novo era trabalho manual em dois sistemas, e o token acabava colado em algum
lugar no caminho. Aqui ele vai do provedor para o Vault sem passar por tela.
**A ordem não é arbitrária:** sorteia o token do webhook → cria a instância no provedor já
apontando para esse endpoint → só então grava conta e credencial, numa transação. Criar primeiro no
banco deixaria conta apontando para instância que não existe se o provedor recusasse; criar a
instância sem webhook e apontar depois deixaria uma janela em que a resposta do contato se perde.
No pior caso sobra uma instância órfã no painel do provedor — visível e descartável, em vez de
silenciosa no nosso banco.
**Não é tabela por canal** (anti-regra): é por provedor. Serve a uma Evolution self-hosted no dia
que precisar. Provedor que não hospeda instância — Gupshup, Meta — não aparece na tela: quem cria
número ali é a operadora.
**Consequência de higiene:** `get_decrypted_meta_token`, que o worker chamava e não existia em
migration nenhuma, virou `segredo_do_remetente`. O despachante quebraria na primeira mensagem real.

### D26 — Provedor se configura no painel do produto, não no do Supabase
`salvar_servidor_provedor` e `salvar_credencial_remetente` gravam no Vault a partir da tela.
*Justificativa:* `provider_servers.admin_secret_id` existia e não havia como preenchê-lo de dentro
da aplicação — escrever no Vault é SECURITY DEFINER, e nada com SECURITY DEFINER estava exposto ao
usuário logado (D19). Na prática isso significava abrir o dashboard do Supabase e colar o token, o
que é o dono do produto tendo acesso de operador do banco. Um cliente do SaaS nunca vai ter isso.
**São a exceção ao D19, e por isso checam permissão em código.** SECURITY DEFINER passa por cima da
RLS; então a pergunta que a política faria (`pode_administrar`) é feita dentro da função. Há teste
para operador barrado e para quem administra passando — é o tipo de checagem que some numa
refatoração sem ninguém notar.
**Token em branco na edição não apaga o guardado.** O campo volta vazio porque segredo não é
legível; tratar vazio como "apagar" derrubaria um servidor que está funcionando.
**O catálogo decide o que é credencial.** Campo que não existe no provedor é recusado em vez de ir
para o Vault como se fosse dele.

### D27 — Oficial e não oficial são telas separadas
`Canais ▸ WhatsApp` virou índice de duas telas: **API Oficial** (Gupshup, Meta) e **API não
oficial** (UAZAPI, Evolution). O servidor de instância mora dentro da segunda, que é o único mundo
em que ele existe.
*Justificativa:* não é organização visual. Oficial e não oficial mudam base contratual, risco de
banimento (D11) e qual pool pode usar (D4). Configurar chip de automação e número homologado na
mesma lista é o que faz alguém apontar uma campanha institucional para um chip frio sem perceber.
**A divisão é derivada, não fixa:** sai de `channel_provider_catalog.oficial`. Canal que só tem um
dos dois — SMS, e-mail, Instagram hoje — continua com uma tela só, sem submenu vazio.

### D28 — Quem separa segredo de config é o catálogo, não a tela
`salvar_credencial_ia` recebe todos os campos preenchidos num objeto só e decide, lendo
`ai_provider_catalog`, o que vai para o Vault e o que vai para `config`.
*Justificativa:* a tela de Provedores de IA era o buraco que o D26 deixou — desenhava os campos que
o catálogo declara e não tinha para onde mandá-los. Ligar um agente exigia o painel do Supabase,
exatamente o que o D26 proíbe.
**A alternativa era a UI mandar dois objetos, `segredos` e `config`.** Foi recusada: obriga a tela a
saber que `api_key` é segredo e `base_url` não, e é justamente por não conhecer provedor nenhum que
ela não quebra quando um provedor novo entra no catálogo. Pior que quebrar: a UI errando a separação
grava chave em `config`, e quem recusa é o gatilho `ai_credentials_sem_segredo` — erro de banco na
cara do usuário, com a chave já tendo passado por onde não devia.
**Chave em branco na edição preserva a guardada,** pela mesma razão do D26: segredo não é legível,
então o campo sempre volta vazio.
**`segredo_da_credencial_ia` não é API.** Devolve a chave em texto claro; só o `service_role` chama.
Nasce sem EXECUTE para ninguém, como manda o D19 — conceder é decisão. Há teste conferindo que
`authenticated` *não* alcança essa, e alcança a de escrita.

### D29 — A chave do motor não mora no comando do job
`privado.agendar_motor()` agenda `SELECT privado.acordar_motor('<url>', <limite>)`. A service key
não aparece: quem a lê é `privado.chave_do_motor()`, do Vault, no instante da batida.
*Justificativa:* a receita corrente para cron + edge function é colar a service key dentro do
comando do job. O comando vive em `cron.job`, que é uma tabela como outra qualquer — vai para
backup, réplica e `pg_dump`, e aparece inteiro para quem tiver SELECT nela. É a anti-regra "nunca
colocar secret fora do Vault", só que escondida atrás de um tutorial.
**O agendamento é operação da plataforma, não do cliente.** As cinco funções nascem em `privado`,
sem EXECUTE para `anon` nem `authenticated`, e só o `service_role` recebe. Não são API e nunca vão
ser: nenhum tenant agenda o motor de ninguém.
**`pg_cron` e `pg_net` entram pela própria migration,** guardadas por `pg_available_extensions` —
o Postgres do teste não as tem, e referência direta faria a suíte inteira parar de aplicar.
**A reversão não derruba as extensões.** São do projeto, não deste schema: outra coisa pode ter
passado a depender delas, e um `CREATE EXTENSION` custa menos que descobrir o que quebrou.
**`ultimas_passadas` existe porque shadow mode não tem sintoma.** Ninguém recebe mensagem, então um
401 no worker pareceria exatamente igual a "não havia vencidos".

### D30 — E-mail sai por provedor HTTP, não por SMTP
O adapter de e-mail é `resend`. `smtp` continua no catálogo com `tem_adapter = false`.
*Justificativa:* `adapters/tipos.ts` diz, na primeira linha, que ali não entra API de runtime — só
`fetch`. É o que faz o mesmo arquivo rodar no Deno da edge function e no Node do teste, sem mock.
SMTP precisa de socket. Ligar SMTP significaria abrir essa exceção para os quatro canais de uma vez,
e um provedor HTTP entrega o mesmo e-mail sem cobrar esse preço.
**`smtp` não sai do catálogo,** pelo mesmo motivo que a Evolution ficou quando a UAZAPI entrou
(D22): sumir com a opção esconde a decisão. Fica listado, declarado sem adapter, com a descrição
dizendo por quê — o motor recusa antes de prometer, em vez de falhar na hora do disparo.
**O assunto vem do próprio passo, não de uma coluna nova.** `flow_steps.template` é um texto só
porque os outros três canais não têm assunto; abrir coluna no motor para a necessidade de um canal
contraria "canal novo = classe nova, zero mudança no motor". O passo pode começar com
`Assunto: ...`, e quando não começa vale `assunto_padrao` — **campo obrigatório do remetente**, de
modo que "passo de e-mail sem assunto" deixa de ser um estado possível.
**A alternativa óbvia — "a primeira linha é o assunto" — foi recusada:** transforma todo parágrafo
curto de abertura em assunto sem que ninguém tenha pedido, e um template já escrito viraria um
e-mail errado sem aviso.
**4xx do provedor é culpa do remetente, não do destino.** `culpa = 'destino'` marca
`contact_identities.valida = false` e escreve `identidade_invalida` no CRM; um domínio não
verificado queimaria o e-mail do contato por um erro que é da conta. Quem diz que um endereço morreu
é o `email.bounced` do webhook.
**`responder_para` é o que faz a invariante 4 valer no canal.** A resposta só vira `email.received`
se cair num domínio de inbound; sem isso a pessoa responde para uma caixa que o motor não lê e a
cadência continua andando — o mesmo furo que o D23 fechou no WhatsApp não oficial. E o casamento é
pelo endereço, nunca pelo `email_id` do e-mail recebido, que é da mensagem dela e não existe em
`messages`.
**`Idempotency-Key` leva a invariante 1 para o outro lado da rede.** A chave única
`(enrollment_id, step_id)` garante uma mensagem no banco; o lease pode expirar e a mesma mensagem
ser reivindicada de novo, e aí quem impede o segundo envio é o provedor.
**Junto veio a checagem de campo obrigatório em `salvar_credencial_remetente`,** que a de IA já
tinha e esta não. Sem ela, `assunto_padrao` obrigatório seria enfeite do catálogo validado só pela
tela — e quem valida não pode ser a tela (D28).

### D31 — O pool pergunta ao catálogo antes de escolher remetente
`remetentes_disponiveis` passa a exigir `tem_adapter` e `ativo` do provedor.
*Justificativa:* `tem_adapter` existia desde o D17 e **nenhum SQL o lia**. O README, o comentário da
tabela e a própria migration do D30 afirmavam "provedor sem adapter não vira opção de envio: o motor
recusa antes de prometer" — e não era verdade. Reproduzido antes de corrigir: conta de e-mail em
`smtp` devolvia `mensagem_criada`.
**O estrago não era o erro, era o passo queimado.** O roteador escolhia a conta, `processar_vencidos`
criava a mensagem e avançava `passo_atual` e `next_run_at`, e só o despachante estourava — virando
`culpa = 'remetente'`, falha registrada e health score derrubado. A pessoa nunca recebia o toque, a
cadência andava como se tivesse recebido, e o console mostrava uma conta boa adoecendo por um
provedor que nunca soube enviar.
**Adiar é recuperável; queimar não.** Sem candidato o roteador já fazia a coisa certa —
`adiado_sem_remetente` — e no dia em que o adapter existir os enrollments parados andam sozinhos.
**Cadastrar a conta continua permitido.** Os chips do legado apontam para provedores que podem não
ter adapter no dia do backfill; foi por isso que o D22 manteve a Evolution no catálogo. Quem filtra
é o pool, não a chave estrangeira.
**`ativo` entra junto pela mesma razão:** o gatilho só olha o INSERT, então nada impedia uma conta já
criada de continuar sendo escolhida depois de o provedor ser desligado no catálogo.
**`proximo_horario_de_pool` não muda.** Ela só responde "quando vale a pena reperguntar", e
reperguntar cedo demais não machuca ninguém.
**O demo era o cenário defeituoso.** `demo/preview.sql` tinha justamente uma conta de e-mail em
`smtp` — mais uma vez foi o cenário completo, e não o teste unitário, que expôs a diferença entre o
que estava escrito e o que o motor fazia (como no D15).
**A mesma varredura achou o formato de falha repetido nos meta-testes.** `tests/tenants.sql`
conferia RLS contra uma **lista de tabelas escrita à mão**, e a lista já tinha ficado para trás:
`provider_servers` entrou com o D24 e nunca foi adicionada — tinha RLS por sorte, não por
verificação. Pior: a FK composta `(tenant_id, id)`, que o D18 chama de camada 2 e é a única que
vale contra o worker (service key, RLS não alcança), era a garantia mais citada do projeto e não
tinha asserção nenhuma. Os três meta-testes agora são derivados do schema: tabela nova nasce
obrigada a ter `tenant_id`, RLS e FK composta, e isentá-la exige entrar numa lista curta de exceções
e dizer por quê. Cada um foi verificado contra uma violação real antes de entrar — asserção que
nunca falha é do mesmo tamanho de coluna que ninguém lê.

### D32 — A ingestão existe, e o dedup mora no banco
`ingerir_contato(tenant, origem, identidades, nome, origem_ref, metadados)` é a entrada de contato.
`ContactSource` no TypeScript lê a fonte e normaliza; o SQL dedup e grava.
*Justificativa:* o `CLAUDE.md` diz "entrada implementa `ContactSource`" e o D1 nomeia
`PlanilhaSource` e `PipefySource` — **nada disso existia, nem a interface**. Em SQL havia só
`inscrever()`, que inscreve um contato que já existe. Não havia como pôr contato no sistema a não
ser escrevendo INSERT à mão, e portanto o motor completo nunca pôde rodar sobre dado real, nem em
shadow mode. Terceiro achado da mesma varredura do D31: o documento afirmava, o código não fazia.
**O dedup fica no banco porque precisa ser atômico** com o índice único
`(tenant_id, canal, valor_norm)`. Duas linhas para a mesma pessoa é o que o D2 proíbe, e separar o
SELECT do INSERT entre processos reabre a corrida — mesmo argumento que manteve o roteador em SQL.
**A normalização NÃO fica no banco,** e essa é a parte contraintuitiva. Ela já mora em
`adapters/telefone.ts` e `adapters/email.ts`, e é de lá que o webhook casa resposta pelo número
(D23). Um segundo normalizador em SQL produziria duas normalizações divergentes — que é, literalmente,
como a supressão fica furada. Então o chamador manda `valor` e `valor_norm`, e `privado.normalizada`
**confere em vez de normalizar**: é trava contra chamador desatento, não um segundo normalizador.
**Fundir dois contatos existentes é recusado, não decidido.** Quando as identidades de uma linha já
pertencem a pessoas diferentes, a importação para com `restrict_violation`. Fundir é destrutivo e não
tem volta; escolher um dos dois em silêncio seria pior do que falhar.
**Identidade suprimida é gravada e contada,** não escondida. O gate é o roteador (invariante 2), e o
cadastro completo é o que faz o writeback no CRM fazer sentido — o que ela ganha na ingestão é
visibilidade: quem importa 500 linhas merece saber que 12 nunca serão tocadas.
**Nome só preenche, metadados só mesclam.** Reimportar uma planilha sem a coluna de nome não pode
apagar o nome que já estava lá, e a segunda fonte acrescenta em vez de substituir.
**O regex não tem barra invertida, de propósito.** A primeira aplicação no projeto passou por um
transporte que duplicou o `\` do ponto escapado, e no banco o padrão virou "exija uma barra
invertida literal no e-mail" — o que recusaria **todo** endereço. O suite não podia pegar: ele roda
o arquivo, onde estava certo. Quem pegou foi o digesto estrutural contra o banco de teste, e a
correção foi escrever o ponto como classe de caractere. É o argumento do digesto ganhando sozinho o
seu custo.

### D33 — A planilha decide o canal pelo cabeçalho, e fixo não vira WhatsApp
`PlanilhaSource` lê o CSV que a operação exporta e devolve contatos normalizados sem escrever nada.
Coluna cujo cabeçalho declara o canal (`WhatsApp`, `SMS`) produz identidade só naquele canal. Coluna
genérica (`Telefone`, `Celular`, `Fone 2`) produz **whatsapp e sms** quando o número é celular, e
**nenhuma identidade** quando é fixo.
*Justificativa:* planilha de operação não tem esquema, e exigir que a pessoa renomeie a coluna antes
de importar é o atrito que faz a importação voltar a ser INSERT à mão. Mas "telefone" não diz canal,
e as duas saídas fáceis são erradas: emitir só `sms` perde o WhatsApp, que é o canal principal;
emitir os dois para qualquer número promete WhatsApp num fixo — e aí o roteador escolhe um destino
que não existe, gasta o passo e derruba a saúde do remetente com uma falha que não era dele. É o
mesmo erro do D31, uma camada acima: o pool não pode prometer o que o despachante não faz, e a
ingestão não pode prometer o que o número não tem. Para o DDI 55 a distinção é confiável (nove
dígitos começando em 9 depois do DDD); fora dele não se adivinha, e o número entra — quem recusa é
o provedor, que é melhor do que descartar em silêncio um internacional bom.
**O que não vira identidade continua visível.** Um telefone com dígito a menos numa linha que tem
e-mail bom não recusa a linha, mas sai em `ignorados` com coluna, valor e motivo. Silêncio aqui é
caro: o contato entraria sem que ninguém soubesse que o telefone se perdeu. Coluna que o motor não
conhece (`Plano atual`, `Corretor`) vira metadado em vez de sumir.
**O número da linha é o que o Excel mostra.** `lerCsv` deixa a linha em branco na lista de
propósito: descartá-la faria o índice andar, e é por esse número que a pessoa acha na planilha dela
a linha que foi recusada.
**Colher é puro, e é isso que torna a prévia possível.** A fonte não escreve, não sabe o que é
tenant e não decide dedup — então a tela consegue mostrar "entram 480, 12 são reimportação, 3 não
têm identidade" antes de qualquer gravação. Mesma ideia do shadow mode: o caminho inteiro roda sem
efeito.
**`adapters/instagram.ts` nasce antes do adapter de Instagram.** O handle precisa ser normalizado
hoje, e `instagram_oficial` ainda está com `tem_adapter = false` (D30). O que não pode acontecer é a
normalização nascer dentro da tela de importação e depois divergir da que o adapter usar — pela
mesma regra do D32, endereço normalizado é chave de dedup e de supressão.
**O teste de ponta a ponta existe porque os outros dois usam cópias.** `tests/fontes.test.ts` repete
as expressões da trava; `tests/ingestao.sql` usa identidades escritas à mão. Nenhum roda a saída
real da `PlanilhaSource` contra a `ingerir_contato` real — e é o par que roda em produção, não cada
metade. Renomear `valor_norm` no JSON deixa os dois verdes e mata a importação inteira, porque a
trava recusa a chamada toda, não a linha.

### D34 — Prévia antes de gravar, e o motor passa a ter tipo
A tela de importação lê o arquivo com `PlanilhaSource`, mostra o que a fonte entendeu, chama
`prever_ingestao` para saber o que aconteceria, e só então grava — uma chamada de
`ingerir_contato` por linha.
*Justificativa:* sem prévia só há duas opções e as duas são ruins: importar e ver o que aconteceu,
ou abrir transação e desfazer, que o PostgREST não permite. É a mesma ideia do shadow mode — o
caminho inteiro roda sem efeito.
**A prévia é linha a linha porque a trava recusa a chamada, não a linha.** Uma identidade malformada
no meio de 500 mata a importação inteira; quem importa merece saber disso antes, e escolher.
**O canal não é convertido com cast.** Vem como texto do cliente, e um cast direto aborta a prévia
inteira num valor inválido — exatamente o que ela existe para evitar. Casa contra os rótulos do
enum e recusa só a linha. Verificado: com o cast, a chamada morre em `invalid input value for enum`.
**A gravação é uma chamada por linha, de propósito.** Um laço no servidor seria uma viagem só, mas
poria as 500 linhas na mesma transação: uma recusa no meio desfaz as 499 que já passaram. Assim cada
linha é a sua própria transação, o progresso é real, e a que falha não leva as outras. O custo é a
latência, e é o custo certo — importação é operação de uma vez por dia, não caminho quente.
**A tela conferência número um é "o que virou o quê".** É a pergunta que ninguém pensa em fazer: uma
planilha com a coluna "Fone Comercial" importa 500 contatos sem telefone nenhum e sem erro nenhum.
**`app/` importa `adapters/` por alias, em vez de copiar.** Copiar o leitor de CSV e os
normalizadores para dentro do app seria a segunda normalização que o D32 proíbe — e a divergência
entre as duas cópias não apareceria em teste, apareceria em supressão furada.
**E foi aí que apareceu o achado:** ao puxar `adapters/` para dentro do `tsc` do app, **oito erros de
tipo reais** surgiram de uma vez. `adapters/` e `motor/` **nunca tinham sido checados por tipo** —
`node --experimental-strip-types` **apaga** os tipos, não os confere, e o `tsconfig.json` do app
olhava só `app/src`. As anotações do motor inteiro valiam de comentário. Nenhum dos oito quebrava
hoje; todos eram do tipo que quebra num payload diferente do do teste (acesso a índice que podia ser
`undefined`, um `flatMap` cujos ramos o compilador não unificava). Agora há `tsconfig.json` na raiz,
com `noUncheckedIndexedAccess`, e `tests/run.sh` roda o `tsc` antes dos testes. Mesmo formato do D31
e do D32: a garantia estava escrita, a verificação não existia.

### D35 — Prévia da inscrição, porque o erro aqui é silencioso
`prever_inscricao(tenant, campanha, flow_version, contatos[])` diz, por contato, se ele entra, se
já está inscrito, se está suprimido ou se não há como alcançá-lo — sem gravar nada. A tela de
contatos seleciona quem, escolhe onde, confere, e só então inscreve.
*Justificativa:* das três formas de a inscrição dar errado, a pior **não dá erro nenhum**.
Inscrever um contato sem identidade no canal dos passos é aceito; o roteador faz
`passo_pulado_sem_identidade` e empurra o enrollment adiante, passo a passo, até encerrar em
`fim_dos_passos`. O relatório mostra **"campanha concluída"** para quem nunca recebeu nada.
Inscrever 500 e descobrir isso depois custa o tempo e, pior, a confiança no número.
As outras duas dão erro, e erro que mata a chamada inteira: reinscrever quem já está inscrito bate
no índice parcial `enrollments_contato_campanha_ativo_uk`; e contato suprimido faz `inscrever`
devolver **NULL em silêncio** — quem chamou recebe um nulo sem motivo e não sabe se foi supressão,
campanha inexistente ou bug.
**Alcançável são três coisas ao mesmo tempo:** identidade `valida`, num canal que o flow usa **e**
que a campanha habilita, e que não esteja suprimida. Qualquer uma sozinha engana.
**O bug que o teste pegou:** `array_agg(DISTINCT ci.canal)` numa junção externa sem par produz
`{NULL}`, e `array_length` devolve **1** — "não tem canal nenhum" passava por "tem um canal", e a
prévia dizia `inscrever` exatamente para quem o motor encerraria sem mandar nada. O `FILTER (WHERE
ci.canal IS NOT NULL)` é o conserto. A prévia estava reproduzindo o silêncio que ela existe para
quebrar.
**Campanha e flow são escolhidos separadamente porque o schema não liga os dois.** `campaigns` não
tem `flow_version_id`; a dupla só existe dentro de `enrollments`. A tela mostra os canais de cada
lado e avisa, antes de qualquer chamada, quando eles não se cruzam — mas isso é contorno de uma
lacuna de modelagem, não solução. Registrar em vez de inventar coluna: a decisão de como ligar
campanha a flow (uma? várias? versionada junto?) é de produto.

### D36 — O shadow mode precisa de tela, senão parece defeito
`resumo_da_campanha` e `eventos_da_campanha` alimentam `app/src/telas/Campanha.tsx`: quantos em
cadência, quantos encerrados e por quê, quantas mensagens e em que status, respostas, cliques, e
quando é a próxima batida.
*Justificativa:* depois de inscrever, o app não mostrava nada. O console (`ui/console.html`) mostra
o **demo**, não o cliente. E o momento em que isso mais dói é exatamente o primeiro: shadow mode
roda o caminho completo e **não envia nada** — sem uma tela dizendo "12 mensagens, todas em shadow
mode", o modo que de-risca o projeto inteiro é indistinguível de estar quebrado.
**Contar no banco, não no cliente.** Milhares de enrollments não passam pelo PostgREST linha a
linha. E `min(next_run_at)` responde a única pergunta que a pessoa realmente faz na primeira semana:
"quando é a próxima?".
**Resposta e clique são KPIs separados, e vêm do evento.** `message_events` é append-only e o status
é derivado; contar pelo evento é o que faz o número bater com a invariante 4 e com o D7 — clique
aparece e **não** encerra.
**O que o teste me corrigiu:** eu tinha assumido que em shadow mode não há remetente, e ia rotular a
coluna como `(shadow mode)`. Falso: `processar_vencidos` **escolhe e reserva** remetente igual, só
não envia. A coluna teria mentido. Quem diz que nada saiu de casa é o `status` da mensagem, e ele
entrou na linha do tempo por causa disso.
**E um teto que era enfeite.** O `least(p_limite, 500)` da linha do tempo passava no teste com e sem
o `least`, porque o cenário tinha três eventos — mesmo formato do `tem_adapter` do D31. Agora o
teste insere 600 eventos e cobra os 500.

### D37 — Os pendentes passam a rebalancear de verdade
`reivindicar_pendentes` vira plpgsql: antes de entregar uma mensagem ao despachante, confere se o
remetente gravado ainda despacha. Se não, troca por outro do mesmo pool; se não houver nenhum,
devolve a mensagem à fila em vez de entregá-la a uma conta morta.
*Justificativa:* a invariante 3 do `CLAUDE.md` promete "conta com erro sai do pool sozinha (circuit
breaker) e **os pendentes rebalanceiam**" — e o comentário do `registrar_falha_remetente` dizia até
por quê: *"os pendentes rebalanceiam porque remetentes_disponiveis deixa de retorná-la"*. **O
raciocínio estava escrito e estava errado.** `remetentes_disponiveis` decide para quem vão as
mensagens **futuras**; quem a consulta é o roteador, ao criar a mensagem. Uma mensagem que já existe
carrega o remetente na própria linha, e `reivindicar_pendentes` nunca reperguntava ao pool.
Reproduzido antes de corrigir, com duas contas boas no mesmo pool: com o circuito de A aberto,
`remetentes_disponiveis` devolvia B (certo) e `reivindicar_pendentes` devolvia a mensagem com A
(errado). O estrago é um laço: o despachante tenta por uma conta morta, falha, a falha volta como
`culpa = 'remetente'` e afunda A mais um pouco, a mensagem segue `pendente`, e na próxima expiração
do lease tudo se repete — com B parado ao lado.
**A reserva do remetente antigo não é devolvida.** Não dá para saber se ele chegou a entregar antes
de adoecer, e devolver o crédito é o único jeito de furar a invariante 3: contar a mais aperta o
envio, contar a menos ultrapassa a quota.
**Quota não entra na checagem do remetente atual.** A reserva daquela mensagem já foi paga quando o
roteador a criou; recobrar seria negar o mesmo envio duas vezes.
**Circuito vencido passa a fechar na borda do lote.** Antes só fechava dentro de `reservar_envio`,
que só roda para quem já foi escolhido — e o pool não escolhe conta de circuito aberto. A conta
ficava presa até alguém tentar usá-la, e ninguém tentava.
**O meta-teste pegou um erro meu no arquivo de reversão.** O `down` refazia a função com
`CREATE OR REPLACE` sem `SET search_path`, que é exatamente o que o D19 aplica por ALTER em massa e
o que `CREATE OR REPLACE` descarta — terceira vez que essa armadilha aparece no projeto, e a
primeira em que foi um teste, e não uma leitura atenta, que a pegou.

### D38 — O evento do provedor passa a dizer de qual chip veio
`registrar_evento_provedor` recebe o chip (`p_sender_id`), tira o tenant dele e filtra a busca.
A assinatura antiga foi derrubada, não mantida ao lado.
*Justificativa:* a função procurava assim, em todos os clientes:
`SELECT id FROM messages WHERE provider_message_id = ? ORDER BY criado_em DESC LIMIT 1`.
`provider_message_id` é do provedor, não nosso, e nada garante que dois clientes não recebam o
mesmo. Com o id colidido, o evento cai na mensagem mais nova — e se o evento é `respondido`,
**encerra a cadência do cliente errado**; se é `rejeitado`, invalida a identidade de outro cliente e
escreve `identidade_invalida` no CRM dele. Reproduzido antes de corrigir: dois clientes com o mesmo
`provider_message_id`, um webhook de resposta, e o enrollment do Cliente B encerrado por um evento
que podia ter vindo do chip do Cliente A.
É o dano do D24 na outra via de casamento, e é literalmente a anti-regra: *"Nunca deixar tenant
implícito em assinatura de função. É como bug entre clientes acontece."* A irmã dela,
`registrar_resposta_por_numero`, já fazia certo desde o D24 — e o comentário do `motor/webhooks.ts`
explicava a razão no ramo de baixo enquanto o ramo de cima cometia o erro: *"Sem chip não há tenant,
e sem tenant casar pelo número escolheria a mensagem de outro cliente."*
**`senderId` deixa de ser opcional em `receberWebhook`.** Como opcional, esquecê-lo casava errado;
como obrigatório, quem cobra é o compilador. E há guarda em tempo de execução junto, porque a edge
function roda JavaScript e um chamador sem tipos passaria `{}`.
**Três armadilhas de teste apareceram escrevendo este teste**, e valem mais que a correção:
um `EXCEPTION` envolvendo o bloco inteiro **desfaz as asserções anteriores** — quatro `confere`
viraram um, em silêncio; reaproveitar o cenário de outro teste fez três asserções falharem por
motivo que não era o delas; e chamar a função e conferir o efeito dela **na mesma expressão SQL**
não funciona, porque o `EXISTS` ao lado lê o snapshot do início da instrução e não vê a linha que a
função acabou de gravar.

### D39 — A supressão vale também depois da mensagem criada
`reivindicar_pendentes` repergunta a supressão antes de entregar cada mensagem ao despachante. Quem
entrou na lista depois de a mensagem existir tem a mensagem marcada `cancelado` e não sai.
*Justificativa:* a invariante 2 diz "contato em `suppression` nunca recebe nada, **por nenhum
caminho de código**". O gatilho `messages_respeita_supressao` guarda o INSERT em `messages`, ou
seja, o momento em que o roteador cria. O despacho não tinha portão nenhum, e entre criar e
despachar existe uma janela: a mensagem nasce `pendente` e espera. Se a pessoa pede para sair nesse
meio — por telefone, por outro canal, por importação de lista de opt-out — a mensagem saía assim
mesmo. E **desde o D37 a janela é ilimitada**, porque sem remetente disponível a mensagem fica
pendente indefinidamente.
Reproduzido antes de corrigir: mensagem pendente, `suppression` inserida, `esta_suprimido`
devolvendo true, e `reivindicar_pendentes` entregando a mensagem ao despachante mesmo assim.
Num produto de prospecção fria no Brasil é o defeito mais caro da varredura: o opt-out está
registrado e a mensagem vai embora.
**`cancelado` é estado novo, não sinônimo de `falha`.** Mesmo argumento do D13, que criou
`cancelado_operacional`: forçar isto em `falha` faria o painel contar opt-out honrado como falha do
motor, e faria a conta que ia enviar levar a culpa no health score. O valor entra por
`ALTER TYPE ... ADD VALUE`, aditivo, e o `down` não o remove — `DROP VALUE` não existe no
PostgreSQL, e recriar o tipo obrigaria a reescrever a coluna de toda mensagem. Valor de enum a mais
é inerte.
**O portão vem antes de tudo na função,** antes de quota, de pool e de rebalanceamento: é o que
"acima de qualquer regra do cliente" quer dizer.
**O enrollment continua sendo encerrado pelo agendador,** na batida seguinte, que já faz isso e tem
teste. O assunto aqui é só não deixar a mensagem sair.

### D40 — O despachante concorda com o agendador
`reivindicar_pendentes` passa a olhar o estado do enrollment e da campanha. Parada definitiva
cancela a mensagem; parada temporária a segura na fila; `fim_dos_passos` despacha normalmente.
*Justificativa:* é a pergunta que o D39 deveria ter provocado na hora. Se a supressão precisava de
portão no despacho porque a janela `pendente` é ilimitada, **o que mais assume que essa janela é
curta?** Três coisas, todas reproduzidas:

| situação | enrollment | despachava |
|---|---|---|
| pessoa respondeu | `encerrado` / `resposta` | sim |
| operador pausou | `pausado` | sim |
| campanha desligada | `ativo`, campanha `ativa = false` | sim |

A primeira é a **invariante 4 furada pela borda**: "resposta em qualquer canal encerra o enrollment
inteiro, não só o passo" — e a mensagem já enfileirada saía mesmo assim, ou seja, quem acabou de
responder levava mais um toque. As outras duas são o despachante discordando do agendador sobre o
mesmo fato: `processar_vencidos` já pula campanha inativa e só olha enrollment ativo.
**A regra óbvia está errada, e o experimento mostrou por quê.** "Só despacha enrollment ativo"
mataria a última mensagem de **todas** as cadências: no último passo o agendador cria a mensagem e
encerra o enrollment com `fim_dos_passos` na mesma passada. Foi um cenário de um passo só que
expôs isso — e, quando sabotei a função com a regra ingênua, quem reprovou foi um teste que já
existia (`tests/rebalanceamento.sql`, seis asserções), não o novo.
**Parada temporária segura, não cancela.** Pausa e campanha desligada voltam atrás; cancelar
perderia o passo para sempre, porque a chave única `(enrollment_id, step_id)` impede recriá-lo.
Mesma lógica do D37: adiar é recuperável, queimar não é.
**`falha_permanente` entra em "cancelar"** junto com os outros. Nada no motor o produz hoje — só o
mapa do backfill — e enrollment que terminou em falha permanente não ganha nada com mais um toque.

### D41 — A supressão ganha porta de entrada
Tela `app/src/telas/Supressao.tsx`: lista quem está suprimido, adiciona um endereço, importa uma
lista de opt-out. Suprimir o contato inteiro fica na linha da pessoa, na tela de contatos.
*Justificativa:* a invariante 2 se apoia inteira nesta tabela, e o D39 e o D40 a tornaram
autoritativa até no despacho — mas **nada no motor, no app ou no webhook escrevia nela**. Só SQL à
mão. É o mesmo buraco que o D32 achou na ingestão: a garantia existia, a porta de entrada não.
**Sem função nova em `public`.** `authenticated` já tem INSERT e a política de RLS já carrega a
regra; criar uma função só para repetir o que a política diz aumentaria a superfície do PostgREST
sem ganhar garantia. O teste passou a exercitar esse caminho **no papel de quem usa o produto**:
operador insere, leitor é recusado com 42501, e operador da A não suprime no cliente B. As duas
negativas foram conferidas contra a versão que passaria.
**O canal é deduzido do que foi digitado, pelos normalizadores dos adapters.** Telefone entra em
whatsapp **e** sms — quem pediu para parar não pediu só num canal. É a leitura da coluna genérica
do D33 com a consequência invertida, e por isso segura: suprimir a mais nunca machuca ninguém.
**A importação de lista reusa `PlanilhaSource`.** Normalizar em outro lugar é exatamente como a
supressão fica furada (D32), e o primeiro dia de qualquer migração é justamente a lista de opt-out
que já existia antes do motor.
**Duplicata não é erro.** `23505` do índice único vira "já estava lá" — do ponto de vista de quem
pediu para sair, o resultado é o mesmo.
**Não há remover, e a tela diz por quê.** A tabela é imutável por gatilho; tirar alguém dali seria
voltar a falar com quem pediu para parar. Suprimir um contato pede confirmação pela mesma razão.

**O que isto NÃO resolve, e continua aberto:** quem responde "PARE" numa cadência tem o enrollment
encerrado por resposta (invariante 4), **mas não entra na supressão** — então a campanha seguinte
volta a falar com ele. Detectar opt-out em texto livre é decisão de produto (e há agentes de IA no
schema para isso); está anotado junto com a pergunta de bounce e denúncia.

---

## Decisões adiadas (não decidir agora)

| Tema | Por que esperar |
|---|---|
| RCS | Exige agente verificado junto a agregador/operadoras. Adapter previsto na interface; implementar quando houver volume que justifique o processo. |
| Volumes-alvo e quotas por remetente | Dados virão do shadow mode. Decidir antes é chute. |
| Telas de operação e relatórios | Reversível. Depende de como o flow se comporta em produção. |
| Construtor visual de flows | Só faz sentido quando o time comercial precisar editar (hoje não precisa, D9). |
| Resposta "PARE" virar supressão | Hoje a resposta encerra o enrollment (invariante 4) mas **não** suprime, então a campanha seguinte volta a falar com a pessoa. Detectar opt-out em texto livre é decisão de produto, e há agentes de IA no schema para isso. A porta de entrada manual já existe (D41). |
| Denúncia de spam e bounce virarem supressão | Hoje `email.complained` e `email.bounced` gravam `rejeitado` e param aí. Transformar em `suppression` é decisão de produto — vale para os quatro canais, não só e-mail, e endereço suprimido não volta. Decidir com o primeiro volume real de campanha fria. |

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

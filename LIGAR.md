# Ligar o motor

Quatro passos, uma vez só. Depois disso o motor acorda sozinho e você não
volta aqui — a não ser para trocar a chave ou mudar a frequência.

**Antes de começar, uma regra que vale para o arquivo inteiro:** a chave não
mora em arquivo nenhum. Não neste, não no `.env`, não numa constante, não num
teste. Ela mora no Vault do Supabase, e o banco a lê no instante da batida. Se
alguém te mandar um procedimento que pede para colar a chave num arquivo do
repositório, o procedimento está errado — `cron.job` e o git vão para backup,
réplica e `pg_dump`, e chave que entrou no histórico não sai mais (D29).

---

## 1. Criar o cliente

Abra o app, cadastre-se e crie o tenant. É a tela de entrada; nada de especial.

O que isso cria: a linha em `tenants`, e você como `dono`. Todo o resto — 
contato, campanha, remetente — pendura nesse `tenant_id`.

---

## 2. A chave do motor

O motor não é um endpoint que alguém chama. É um worker que acorda e pergunta
"quem está vencido agora?". Quem faz a pergunta é o `pg_cron`, e para bater na
edge function ele precisa se autenticar — com a **service key** do projeto.

### 2.1 Pegar a chave certa

No painel do Supabase: **Project Settings ▸ API Keys**.

Lá vão aparecer **duas** chaves, uma debaixo da outra, com o mesmo formato e
quase o mesmo tamanho:

| Chave | Para quê | Serve aqui? |
|---|---|---|
| `anon` / `publishable` | o navegador usa; a RLS limita o que ela alcança | **não** |
| `service_role` / `secret` | passa por cima da RLS; é o worker | **sim** |

**É aqui que o procedimento erra.** Copiar a de cima é o engano mais fácil do
processo inteiro, e ele não reclama em lugar nenhum: o job agenda, a batida
sai, o worker responde 401, e a passada vazia fica **idêntica** a "não havia
ninguém vencido". Você teria um motor parado com cara de motor ocioso.

Por isso o passo 2.3 existe. Não pule.

> Se o seu projeto já usa o formato novo, as chaves são `sb_publishable_...` e
> `sb_secret_...`. Vale a mesma tabela: a `sb_secret_` é a do worker.

### 2.2 Guardar no Vault

**Project Settings ▸ Vault ▸ New secret.**

| Campo | Valor |
|---|---|
| Name | `chave_do_motor` |
| Secret | a chave que você copiou |

Três detalhes que custam tempo se passarem:

- **O nome é exato.** Minúsculo, com sublinhado, sem espaço. `chave-do-motor`
  ou `Chave_do_Motor` não são encontrados, e o sintoma é o mesmo 401 silencioso.
- **Pela tela do Vault, não pelo SQL editor.** O editor guarda histórico de
  consulta; a chave ficaria lá em texto claro, que é exatamente o que esta
  decisão evita.
- **Cuidado com o que vem junto na cópia.** Quebra de linha e espaço nas pontas
  não aparecem num campo de senha, viajam no cabeçalho `Authorization`, e
  devolvem — de novo — um 401 idêntico ao de chave errada.

### 2.3 Conferir antes de agendar

No SQL editor:

```sql
SELECT * FROM privado.conferir_chave_do_motor(
  'https://SEU-PROJETO.supabase.co/functions/v1/motor-worker'
);
```

Com tudo certo, seis linhas verdes:

```
 item     | ok | detalhe
----------+----+----------------------------------------------------
 vault    | t  | disponível
 segredo  | t  | encontrado, com 219 caracteres
 limpeza  | t  | sem espaço nem quebra nas pontas
 formato  | t  | JWT legível
 papel    | t  | service_role — é a correta
 projeto  | t  | a chave é do projeto SEU-PROJETO, o mesmo da URL
 validade | t  | válida até 01/01/2100
```

**Esta função nunca devolve a chave.** Cada linha é um fato *a respeito* dela.
Há teste no suite que falha se alguma edição futura fizer o valor escapar —
conferido contra sabotagem, não só escrito.

Se alguma linha vier vermelha, ela diz o que fazer. As mais comuns:

| `ok = f` em | O que aconteceu |
|---|---|
| `segredo` | o nome não bate. Volte ao 2.2 e confira letra por letra |
| `papel` | você colou a `anon`. É a de baixo, não a de cima |
| `limpeza` | veio espaço ou quebra junto. Regrave sem o excesso |
| `projeto` | a chave é de outro projeto Supabase |
| `validade` | a chave expirou. Gere outra e regrave o segredo |

Passar o URL é opcional, mas passe: sem ele a conferência não tem como saber se
a chave é do projeto para onde o job vai bater.

### 2.4 Agendar

Uma linha:

```sql
SELECT privado.agendar_motor(
  'https://SEU-PROJETO.supabase.co/functions/v1/motor-worker',
  '*/5 * * * *',   -- de 5 em 5 minutos
  50               -- vencidos por passada
);
```

É idempotente: desagenda antes de agendar. Reagendar com outra expressão — 
subir a frequência, baixar no fim de semana — é a operação comum, e duas cópias
do mesmo job dobrariam a carga sem ninguém notar até o rate limit reclamar.

**O corpo não leva `modo`, e o worker trata a ausência como `simulado`.** O
motor calcula, roteia, escolhe remetente, compõe o texto e grava tudo — sem
enviar nada. Ligar o envio de verdade é editar o agendamento, não mudar código.

### 2.5 Ver rodando

Em shadow mode não há sintoma externo nenhum, então:

```sql
SELECT * FROM privado.ultimas_passadas(10);        -- quando, status, corpo
SELECT jobname, schedule, active FROM cron.job;    -- o job existe e está ativo
SELECT privado.desagendar_motor();                 -- parar
```

E para ler o que o motor **compôs** sem ter enviado — o que a pessoa receberia:

```sql
SELECT contato, canal, passo, conteudo, buraco
  FROM mensagens_da_campanha('SEU-TENANT', 'SUA-CAMPANHA');
```

`buraco = true` marca suspeita de variável vazia — o `Olá ,` que uma lista sem
coluna de nome produz. É o erro mais provável de todos, e o shadow mode existe
para você vê-lo antes do cliente.

### 2.6 Trocar a chave, depois

Regrave o segredo no Vault com o mesmo nome. **Nenhum job muda** — a função lê
o Vault a cada batida, não guarda cópia. Rode o 2.3 de novo para conferir.

---

## 3. Cadastrar um remetente

Sem remetente o motor decide tudo e não tem por onde mandar: o passo é
**adiado** (`adiado_sem_remetente`), não queimado. Você vê isso no painel da
campanha como "aguardando remetente".

Tela: **Canais ▸ [o canal] ▸ [oficial ou não oficial] ▸ Nova conta.**

O que cada canal pede está no catálogo do banco, não na tela — a tela só
desenha o que o catálogo declara, e é o banco que recusa campo obrigatório em
branco. Por isso "conta cadastrada" já significa "conta completa".

**O segredo você digita na mesma tela**, e a função `salvar_credencial_remetente`
separa: o que o catálogo marca como segredo vai para o Vault, o resto vai para
`sender_accounts.config`. Não existe coluna para a chave, e um gatilho recusa
gravá-la em `config` mesmo que alguém tente (D28).

Na edição: **segredo em branco mantém o que já está no Vault**; campo
não-secreto em branco limpa.

---

## 4. Republicar as edge functions

As três funções publicadas estão atrás do repositório. Pelo CLI:

```bash
supabase functions deploy motor-worker --project-ref SEU-PROJETO
supabase functions deploy canal-webhook --project-ref SEU-PROJETO
supabase functions deploy provisionar-instancia --project-ref SEU-PROJETO
```

---

## A ordem importa em um ponto só

O passo 2 antes do 3 e do 4 é indiferente. Mas **conferir (2.3) antes de
agendar (2.4)** é o ponto do arquivo inteiro: depois de agendado, o erro de
chave vira um silêncio que parece normalidade, e aí você vai procurá-lo no
lugar errado.

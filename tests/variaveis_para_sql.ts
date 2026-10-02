// As duas leituras da mesma marcação, postas uma contra a outra (D55).
//
// `privado.renderizar` decide, em SQL, o que é uma variável num template:
// troca a chave conhecida e **apaga** a marcação que sobrou. `variaveisDoTexto`
// decide o mesmo, em TypeScript, para a tela dizer quais chaves o texto pede.
//
// São duas regexps escritas à mão, em linguagens diferentes, sobre a mesma
// regra — a forma exata do D32, uma camada acima. A divergência não dá erro:
// a tela diria "todas as variáveis existem na base" sobre uma chave que o
// motor vai apagar, e o contato receberia "Olá ,". É o D42 chegando tarde
// porque o aviso que existe para chegar cedo estava errado.
//
// Este arquivo não compara as regexps: compara o EFEITO das duas sobre a
// mesma lista de textos, que é a única comparação que continua valendo quando
// alguém reescrever uma delas.
//
// Escreve SQL em stdout; quem roda é `tests/run.sh`, que o joga no psql.

import { variaveisDoTexto } from '../app/src/variaveis.ts';

// Os casos que separam uma reprodução fiel de uma parecida: espaço dentro das
// chaves, ponto e sublinhado na chave, hífen e espaço (que NÃO são chave),
// chave vazia, chaveta simples, marcação colada no texto e várias linhas.
const TEXTOS = [
  'Oi {{nome}}, tudo bem?',
  'Oi {{ nome }}!',
  'Oi {{  nome  }}!',
  'Plano {{plano.atual}}',
  '{{plano_atual}} e {{campo2}}',
  '{{nome}}, {{nome}}, {{nome}}',
  'Oi, tudo bem?',
  'Oi {{}}',
  'Oi {{   }}',
  '{{plano-atual}}',
  '{{plano atual}}',
  '{nome}',
  'Ola{{nome}}!',
  'Oi {{nome}},\n\nseu plano e {{plano_atual}}.',
];

const linhas: string[] = [];
const p = (s: string) => linhas.push(s);

/** Literal SQL com cifrao etiquetado: nenhum texto de teste o fecha. */
const lit = (v: string) => `$vv$${v}$vv$`;

p(`\\set ON_ERROR_STOP on`);
p(`SET client_min_messages = warning;`);
p(`CREATE SCHEMA vv;`);
p(`CREATE TABLE vv.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);`);
p(`CREATE FUNCTION vv.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO vv.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $f$;`);

// O cenário precisa conseguir falhar (D36): sem pelo menos um texto COM
// marcação e um SEM, as asserções abaixo passariam com qualquer regexp.
const comVar = TEXTOS.filter((t) => variaveisDoTexto(t).length > 0).length;
p(`SELECT vv.confere('a lista tem texto com e sem marcação',
  ${comVar} > 0 AND ${TEXTOS.length - comVar} > 0,
  '${comVar} com, ${TEXTOS.length - comVar} sem');`);

for (const [i, texto] of TEXTOS.entries()) {
  const achadas = variaveisDoTexto(texto);
  const rotulo = `caso ${i + 1}`;

  if (achadas.length === 0) {
    // O TypeScript não viu marcação: o motor não pode apagar nada. Se ele
    // apagar, a tela estaria deixando passar um buraco sem avisar.
    p(`SELECT vv.confere(${lit(`${rotulo}: sem variável, o motor não mexe no texto`)},
  privado.renderizar(${lit(texto)}, '{}'::jsonb) = ${lit(texto)},
  privado.renderizar(${lit(texto)}, '{}'::jsonb));`);
    continue;
  }

  // O TypeScript viu marcação: sem valor, o motor tem que apagá-la — e é
  // isso que produz o "Olá ,".
  p(`SELECT vv.confere(${lit(`${rotulo}: com variável e sem valor, o motor apaga`)},
  privado.renderizar(${lit(texto)}, '{}'::jsonb) <> ${lit(texto)},
  privado.renderizar(${lit(texto)}, '{}'::jsonb));`);

  // E são ESSAS chaves, não outras: dando valor exatamente às que o
  // TypeScript achou, não pode sobrar marcação nenhuma. Uma chave a menos
  // aqui deixaria resto; uma a mais não teria o que trocar.
  const vars = Object.fromEntries(achadas.map((c) => [c, `<${c}>`]));
  p(`SELECT vv.confere(${lit(`${rotulo}: as chaves que o TypeScript achou são as que o motor troca`)},
  privado.renderizar(${lit(texto)}, ${lit(JSON.stringify(vars))}::jsonb)
    NOT LIKE '%{{%',
  privado.renderizar(${lit(texto)}, ${lit(JSON.stringify(vars))}::jsonb));`);
}

p("\\echo ''");
p("\\echo '============= VARIÁVEIS: TELA x MOTOR ============='");
p(`SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM vv.resultado ORDER BY id;`);
p(`SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM vv.resultado;`);
p(`DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM vv.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'variáveis tela x motor: % asserções falharam',
      (SELECT count(*) FROM vv.resultado WHERE NOT ok);
  END IF;
END; $g$;`);

console.log(linhas.join('\n'));

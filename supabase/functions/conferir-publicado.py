#!/usr/bin/env python3
"""As edge functions publicadas conferem com o repositório?

Existe porque `LIGAR.md` dizia "já feito em 23/09" — um fato escrito à mão, que
ficou falso no dia em que `adapters/` mudou e ninguém reparou. É a mesma classe
do contador de migrations que ficou nove atrás, e do `tem_adapter` do D31: algo
que parece garantia e não é lido por ninguém.

O que ele faz: para cada edge function, resolve o fecho transitivo dos imports
relativos (que é exatamente o que vai no bundle), tira um digest, e compara com
o que `PUBLICADO.json` diz ter sido publicado. Mudou uma linha de qualquer
arquivo que a function empacota, o digest muda, e isto fica vermelho.

Não confere o que está no Supabase — isso precisa de rede e o suite não tem.
Confere se ALGUÉM DISSE que publicou o que está aqui. Publicar e não registrar
dá vermelho; registrar sem publicar é mentira deliberada, e para isso não há
verificação que ajude.

Uma function pode ficar `pendente` com motivo escrito. É a mesma porta que a
lista de exceções do meta-teste de tenant usa: dá para isentar, mas você tem de
vir aqui e dizer por quê — e aí o motivo aparece em toda rodada, o que é o
oposto de esquecer.
"""
import hashlib
import json
import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FUNCOES = os.path.join(RAIZ, 'supabase', 'functions')
REGISTRO = os.path.join(FUNCOES, 'PUBLICADO.json')


def fecho(entrada):
    """Todos os arquivos que o bundle da function vai conter."""
    vistos, fila = set(), [os.path.normpath(entrada)]
    while fila:
        f = fila.pop()
        if f in vistos or not os.path.exists(f):
            continue
        vistos.add(f)
        txt = open(f, encoding='utf-8').read()
        for rel in re.findall(r"""from\s+['"](\.[^'"]+)['"]""", txt):
            fila.append(os.path.normpath(os.path.join(os.path.dirname(f), rel)))
    return sorted(vistos)


def digest(arquivos):
    """Digest do conteúdo, não da data: tocar no arquivo sem mudá-lo não conta."""
    h = hashlib.sha256()
    for f in arquivos:
        h.update(os.path.relpath(f, RAIZ).encode())
        h.update(open(f, 'rb').read())
    return h.hexdigest()[:16]


def main():
    registro = json.load(open(REGISTRO, encoding='utf-8'))
    problemas, avisos = [], []

    for nome in sorted(os.listdir(FUNCOES)):
        dir_fn = os.path.join(FUNCOES, nome)
        entrada = os.path.join(dir_fn, 'index.ts')
        if not os.path.isfile(entrada):
            continue

        arquivos = fecho(entrada)
        atual = digest(arquivos)
        anotado = registro.get(nome)

        if anotado is None:
            problemas.append(f'{nome}: não está em PUBLICADO.json')
            continue

        if anotado.get('pendente'):
            avisos.append(f'{nome}: PENDENTE DE PUBLICAÇÃO — {anotado["pendente"]}')
            continue

        if anotado.get('digest') != atual:
            problemas.append(
                f'{nome}: as fontes mudaram desde a publicação\n'
                f'      publicado {anotado.get("digest")} ({anotado.get("em", "?")}), '
                f'agora {atual}, {len(arquivos)} arquivos\n'
                f'      Publique e atualize PUBLICADO.json, ou marque "pendente" '
                f'com o motivo.')

    for a in avisos:
        print(f'AVISO {a}')
    for p in problemas:
        print(f'FALHA {p}')

    if problemas:
        return 1
    print('PASS  edge functions publicadas conferem com o repositório'
          + (f' ({len(avisos)} pendente(s), ver acima)' if avisos else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())

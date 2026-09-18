#!/usr/bin/env python3
"""Injeta demo/preview.json dentro de ui/console.html.

O console carregava os dados colados à mão. Colar à mão foi como as constantes
de canal sumiram sem ninguém notar: o arquivo tem 90 KB e a diferença não
aparece na revisão. Agora `demo/gerar.sh` roda isto e o dado no console é,
por construção, o que o motor produziu.
"""
import json, pathlib, re, sys

raiz = pathlib.Path(__file__).resolve().parent.parent
dados = json.loads((raiz / 'demo' / 'preview.json').read_text(encoding='utf-8'))

# O console fala 'horas'; o export fala 'horas_simuladas'.
dados['horas'] = dados.pop('horas_simuladas', dados.get('horas', 0))

alvo = raiz / 'ui' / 'console.html'
html = alvo.read_text(encoding='utf-8')

linha = 'const D = ' + json.dumps(dados, ensure_ascii=False, sort_keys=True) + ';'
novo, n = re.subn(r'^const D = \{.*\};$', lambda _: linha, html,
                  count=1, flags=re.MULTILINE)
if n != 1:
    sys.exit('não achei a linha `const D = {...};` em ui/console.html')

alvo.write_text(novo, encoding='utf-8')
print(f'ui/console.html: D atualizado ({len(linha)} bytes)')

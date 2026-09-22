#!/usr/bin/env python3
"""O demo mostra o que teste unitário não pega — e só enquanto o cenário
ainda criar as situações que ele diz mostrar.

Isso não é redundância com `tests/`. Os testes provam que os portões existem
e funcionam; aqui a pergunta é outra: o cenário ainda passa por eles? Já
passou a não passar. `demo/preview.sql` cruzava `reivindicar_pendentes` em
toda batida com os portões do D37, D39 e D40 no caminho, e nenhum disparava,
porque nenhuma das situações acontecia. O console mostrava uma cadência
tranquila e ninguém tinha como notar a diferença.

Um cenário que deixa de exercitar um portão não quebra nada — ele só para de
contar. É o formato de erro que este arquivo recusa.
"""
import json
import pathlib
import sys

RAIZ = pathlib.Path(__file__).resolve().parent
d = json.loads((RAIZ / 'preview.json').read_text(encoding='utf-8'))

linha = d['linha']
mensagens = d['mensagens']


def acoes(nome):
    return [e for e in linha if e['acao'] == nome]


exigido = [
    ('D37 rebalanceamento: alguém trocou de remetente entre criar e despachar',
     lambda: acoes('remetente_trocado')),
    ('D39 supressão no despacho: pendente cancelado por opt-out na janela',
     lambda: [e for e in acoes('envio_cancelado') if 'D39' in e['detalhe']]),
    ('D40 despacho concorda com agendador: pendente cancelado por resposta',
     lambda: [e for e in acoes('envio_cancelado') if 'D40' in e['detalhe']]),
    ('D42 leitura do que o motor compôs: mensagem com variável vazia marcada',
     lambda: [m for m in mensagens if m.get('buraco')]),
    ('quota do chip frio: algum passo adiado por falta de remetente',
     lambda: acoes('adiado_sem_remetente')),
    ('invariante 2: contato suprimido antes da campanha não entra',
     lambda: acoes('inscricao_recusada')),
    ('D33 ingestão: valor que parecia identidade saiu em ignorados, não em silêncio',
     lambda: acoes('valor_ignorado')),
]

faltando = [texto for texto, achar in exigido if not achar()]

for texto, achar in exigido:
    print(('  ok   ' if achar() else '  FALTA ') + texto)

if faltando:
    print(f'\ndemo/preview.sql deixou de exercitar {len(faltando)} situação(ões).',
          file=sys.stderr)
    print('O cenário não quebrou — ele parou de contar. Ver demo/conferir.py.',
          file=sys.stderr)
    sys.exit(1)

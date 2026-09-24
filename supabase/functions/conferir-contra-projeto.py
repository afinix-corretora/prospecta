#!/usr/bin/env python3
"""O que ESTÁ no projeto confere com o repositório, arquivo por arquivo?

Irmão de `conferir-publicado.py`, e a diferença entre os dois é o ponto:

  conferir-publicado.py   confere se ALGUÉM DISSE que publicou o que está aqui.
                          Roda no suite, não precisa de rede, e envelhece no
                          dia em que as fontes mudam.
  conferir-contra-projeto confere o que o projeto TEM de fato. Precisa de rede,
                          então não entra no suite — é o passo que se roda na
                          hora de publicar.

Existe por causa do D51. Sem CLI com acesso à API do Supabase, publicar é
reproduzir dezenas de KB exatos, e foi assim que o D32 nasceu: um transporte
que duplicou uma barra invertida numa regex teria recusado TODO e-mail em
produção. O que torna o transporte aceitável não é cuidado ao copiar — é ler
de volta e comparar. Mesma ideia do digest estrutural do schema.

Uso: quem tem acesso busca o conteúdo publicado e salva em JSON (pela MCP do
Supabase, `get_edge_function`, ou pela API de management), e aponta este
script para o arquivo:

    python3 supabase/functions/conferir-contra-projeto.py \
        publicado.json supabase/functions/canal-webhook/index.ts

Sai 0 quando todo arquivo empacotado bate byte a byte, 1 quando não bate.

UMA DIFERENÇA ESPERADA, que não é erro. O fecho de `conferir-publicado.py`
segue TODO import relativo, inclusive `import type`. O bundler apaga o import
de tipo, então um arquivo que só é importado assim — hoje `motor/porta.ts` —
é enviado e não volta. Ele aparece em "ausentes do bundle" e não conta como
divergência: divergência é arquivo que voltou diferente, ou arquivo no projeto
que não existe aqui.
"""
import difflib
import importlib.util
import json
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))


def carregar_fecho():
    spec = importlib.util.spec_from_file_location(
        'conferir_publicado', os.path.join(AQUI, 'conferir-publicado.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[0])
        print('uso: conferir-contra-projeto.py <publicado.json> <caminho/index.ts>')
        return 2

    arquivo, entrada = sys.argv[1], sys.argv[2]
    d = json.load(open(arquivo, encoding='utf-8'))
    pub = {f['name']: f['content'] for f in d['files']}

    m = carregar_fecho()
    repo = {os.path.relpath(a, m.RAIZ): open(a, encoding='utf-8').read()
            for a in m.fecho(entrada)}

    print(f"{d.get('slug', '?')}: versao {d.get('version')}, "
          f"verify_jwt {d.get('verify_jwt')}")
    print(f"  publicados {len(pub)} | fecho do repositorio {len(repo)}")

    ausentes = sorted(set(repo) - set(pub))
    sobrando = sorted(set(pub) - set(repo))
    print('  ausentes do bundle (import de tipo):', ausentes or 'nenhum')
    print('  no projeto e nao no repositorio:', sobrando or 'nenhum')

    comuns = sorted(set(repo) & set(pub))
    divergem = [k for k in comuns if repo[k] != pub[k]]
    print(f'  identicos byte a byte: {len(comuns) - len(divergem)}/{len(comuns)}')

    for k in divergem:
        print(f'\n  DIVERGE {k}  (- projeto, + repositorio)')
        mostradas = 0
        for linha in difflib.unified_diff(pub[k].splitlines(),
                                          repo[k].splitlines(), lineterm='', n=1):
            if linha.startswith(('---', '+++', '@@')):
                continue
            print('     ', linha[:150])
            mostradas += 1
            if mostradas > 40:
                print('      ... (truncado)')
                break

    if divergem or sobrando:
        print('\nFALHA  o publicado NAO confere com o repositorio')
        return 1
    print('\nPASS   todo arquivo empacotado confere byte a byte')
    return 0


if __name__ == '__main__':
    sys.exit(main())

-- Devolve "nao tenho interesse" e "sem interesse" à lista de opt-out.
-- Reverter isto volta a suprimir para sempre quem recusou a oferta.

INSERT INTO opt_out_termos (termo, exige_uma_de, nota) VALUES
  ('nao tenho interesse', NULL, 'revertido: recusa volta a suprimir'),
  ('sem interesse', NULL, 'revertido: recusa volta a suprimir')
ON CONFLICT (termo) DO NOTHING;

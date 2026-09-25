-- Reverte 20260917180000_adiamento_ate_janela.sql
--
-- processar_vencidos volta ao adiamento fixo de 15 minutos. A função é
-- recriada inteira porque CREATE OR REPLACE não guarda a versão anterior.

DROP FUNCTION IF EXISTS proximo_horario_de_pool(canal, tipo_campanha);

CREATE OR REPLACE FUNCTION processar_vencidos(
  p_limite integer DEFAULT 100,
  p_modo   text    DEFAULT 'simulado'
)
RETURNS TABLE (enrollment_id uuid, acao text, detalhe text)
LANGUAGE plpgsql AS $$
DECLARE
  e enrollments%ROWTYPE; v_campanha campaigns%ROWTYPE; v_passo flow_steps%ROWTYPE;
  v_identidade contact_identities%ROWTYPE; v_remetente sender_accounts%ROWTYPE;
  v_contato contacts%ROWTYPE; v_proximo flow_steps%ROWTYPE;
  v_conteudo text; v_status status_message; v_vars jsonb;
BEGIN
  IF p_modo NOT IN ('simulado','real') THEN
    RAISE EXCEPTION 'modo inválido: %', p_modo USING ERRCODE='invalid_parameter_value';
  END IF;
  v_status := CASE WHEN p_modo='simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  FOR e IN SELECT * FROM enrollments
     WHERE status='ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
     ORDER BY next_run_at LIMIT p_limite FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_campanha FROM campaigns WHERE id = e.campaign_id;
    IF NOT v_campanha.ativa THEN
      enrollment_id:=e.id; acao:='ignorado_campanha_inativa'; detalhe:=v_campanha.nome;
      RETURN NEXT; CONTINUE;
    END IF;
    SELECT * INTO v_contato FROM contacts WHERE id = e.contact_id;
    IF esta_suprimido(e.contact_id, NULL, NULL) THEN
      PERFORM encerrar_enrollment(e.id,'supressao');
      enrollment_id:=e.id; acao:='encerrado_supressao'; detalhe:='contato suprimido';
      RETURN NEXT; CONTINUE;
    END IF;
    SELECT * INTO v_passo FROM flow_steps
     WHERE flow_version_id=e.flow_version_id AND ordem > e.passo_atual ORDER BY ordem LIMIT 1;
    IF NOT FOUND THEN
      PERFORM encerrar_enrollment(e.id,'fim_dos_passos');
      enrollment_id:=e.id; acao:='encerrado_fim'; detalhe:=''; RETURN NEXT; CONTINUE;
    END IF;
    IF NOT (v_passo.canal = ANY (v_campanha.canais_habilitados)) THEN
      UPDATE enrollments SET passo_atual=v_passo.ordem, next_run_at=now() WHERE id=e.id;
      enrollment_id:=e.id; acao:='passo_pulado_canal'; detalhe:=v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;
    SELECT * INTO v_identidade FROM contact_identities
     WHERE contact_id=e.contact_id AND canal=v_passo.canal AND valida
     ORDER BY criado_em DESC LIMIT 1;
    IF NOT FOUND THEN
      UPDATE enrollments SET passo_atual=v_passo.ordem, next_run_at=now() WHERE id=e.id;
      enrollment_id:=e.id; acao:='passo_pulado_sem_identidade'; detalhe:=v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;
    IF esta_suprimido(e.contact_id, v_identidade.canal, v_identidade.valor_norm) THEN
      UPDATE enrollments SET passo_atual=v_passo.ordem, next_run_at=now() WHERE id=e.id;
      enrollment_id:=e.id; acao:='passo_pulado_identidade_suprimida'; detalhe:=v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;
    SELECT * INTO v_remetente FROM remetentes_disponiveis(v_passo.canal, v_campanha.tipo) LIMIT 1;
    IF NOT FOUND OR NOT reservar_envio(v_remetente.id) THEN
      UPDATE enrollments SET next_run_at = now() + interval '15 minutes' WHERE id=e.id;
      enrollment_id:=e.id; acao:='adiado_sem_remetente'; detalhe:=v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;
    v_vars := coalesce(v_contato.metadados,'{}'::jsonb)
           || jsonb_build_object('nome', coalesce(v_contato.nome,''));
    v_conteudo := renderizar(v_passo.template, v_vars);
    BEGIN
      INSERT INTO messages (enrollment_id, step_id, contact_identity_id,
                            sender_account_id, canal, status, conteudo)
      VALUES (e.id, v_passo.id, v_identidade.id, v_remetente.id,
              v_passo.canal, v_status, v_conteudo);
    EXCEPTION WHEN unique_violation THEN
      enrollment_id:=e.id; acao:='passo_ja_reivindicado'; detalhe:=v_passo.ordem::text;
      RETURN NEXT; CONTINUE;
    END;
    SELECT * INTO v_proximo FROM flow_steps
     WHERE flow_version_id=e.flow_version_id AND ordem > v_passo.ordem ORDER BY ordem LIMIT 1;
    IF FOUND THEN
      UPDATE enrollments SET passo_atual=v_passo.ordem,
        next_run_at = now() + make_interval(hours => v_proximo.atraso_horas) WHERE id=e.id;
    ELSE
      UPDATE enrollments SET passo_atual=v_passo.ordem WHERE id=e.id;
      PERFORM encerrar_enrollment(e.id,'fim_dos_passos');
    END IF;
    enrollment_id:=e.id; acao:='mensagem_criada'; detalhe:=v_passo.ordem::text;
    RETURN NEXT;
  END LOOP;
END;
$$;

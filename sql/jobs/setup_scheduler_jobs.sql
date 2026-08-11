-- ============================================================================
-- Jobs DBMS_SCHEDULER para o package XXISV_EVT_COMPLIANCE_PKG.
--
-- XXISV_EVT_SEND_JOB   -> captura e envia eventos novos (NEW/MANUAL/CANCEL)
--                         notificados em CLL_F255_NOTIFICATIONS, com espera
--                         limitada pelo status de processamento.
-- XXISV_EVT_RETRY_JOB  -> retoma eventos que ficaram em POLLING/TIMEOUT além
--                         da janela síncrona do job de envio.
--
-- O ambiente (Homologação/Produção/QA) não é mais parâmetro do job: vem da
-- lookup AMBIENTE em FND_LOOKUP_VALUES (XXISV_CSF_MULTORG_SIC), configurada
-- uma vez por instância EBS — ver sql/seed/seed_lookup_values.sql.
--
-- Ajustar repeat_interval conforme a necessidade de cada instalação.
-- ============================================================================

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'XXISV.XXISV_EVT_SEND_JOB',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'XXISV.XXISV_EVT_COMPLIANCE_PKG.PROCESS_PENDING_EVENTS_P',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=5',
    enabled         => FALSE,
    comments        => 'Envio dos Eventos RT (Reforma Tributaria) para a API da Compliance Fiscal.'
  );
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'XXISV.XXISV_EVT_RETRY_JOB',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'XXISV.XXISV_EVT_COMPLIANCE_PKG.RETRY_PENDING_EVENTS_P',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=10',
    enabled         => FALSE,
    comments        => 'Retomada de Eventos RT ainda pendentes de status final (POLLING/TIMEOUT).'
  );
END;
/

-- Habilitar somente após validar a lookup AMBIENTE/CD/HASH e o endpoint de
-- consulta de status (ver TODO em xxisv_evt_compliance_pkg.pkb / docs/ARQUITETURA.md):
-- BEGIN
--   DBMS_SCHEDULER.ENABLE('XXISV.XXISV_EVT_SEND_JOB');
--   DBMS_SCHEDULER.ENABLE('XXISV.XXISV_EVT_RETRY_JOB');
-- END;
-- /

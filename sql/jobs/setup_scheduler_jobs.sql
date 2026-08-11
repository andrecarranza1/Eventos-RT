-- ============================================================================
-- Jobs DBMS_SCHEDULER para o package XXISV_EVT_COMPLIANCE_PKG.
--
-- XXISV_EVT_SEND_JOB   -> captura e envia eventos novos (NEW/MANUAL/CANCEL)
--                         notificados em CLL_F255_NOTIFICATIONS, com espera
--                         limitada pelo status de processamento.
-- XXISV_EVT_RETRY_JOB  -> retoma eventos que ficaram em POLLING/TIMEOUT além
--                         da janela síncrona do job de envio.
--
-- Ajustar repeat_interval e o ambiente (P_ENV_CODE) conforme a necessidade
-- de cada instalação (HML/PROD/QA).
-- ============================================================================

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'XXISV.XXISV_EVT_SEND_JOB',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'XXISV.XXISV_EVT_COMPLIANCE_PKG.PROCESS_PENDING_EVENTS_P',
    number_of_arguments => 1,
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=5',
    enabled         => FALSE,
    comments        => 'Envio dos Eventos RT (Reforma Tributaria) para a API da Compliance Fiscal.'
  );

  DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(
    job_name          => 'XXISV.XXISV_EVT_SEND_JOB',
    argument_position => 1,
    argument_value    => 'PROD'
  );
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'XXISV.XXISV_EVT_RETRY_JOB',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'XXISV.XXISV_EVT_COMPLIANCE_PKG.RETRY_PENDING_EVENTS_P',
    number_of_arguments => 1,
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=10',
    enabled         => FALSE,
    comments        => 'Retomada de Eventos RT ainda pendentes de status final (POLLING/TIMEOUT).'
  );

  DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(
    job_name          => 'XXISV.XXISV_EVT_RETRY_JOB',
    argument_position => 1,
    argument_value    => 'PROD'
  );
END;
/

-- Habilitar somente após validar XXISV_EVT_CONFIG e o endpoint de consulta
-- de status (ver TODO em xxisv_evt_compliance_pkg.pkb / docs/ARQUITETURA.md):
-- BEGIN
--   DBMS_SCHEDULER.ENABLE('XXISV.XXISV_EVT_SEND_JOB');
--   DBMS_SCHEDULER.ENABLE('XXISV.XXISV_EVT_RETRY_JOB');
-- END;
-- /

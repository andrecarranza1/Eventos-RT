CREATE OR REPLACE PACKAGE BODY xxisv.xxisv_evt_compliance_pkg
IS

  -- Se a rede exigir proxy HTTP de saída para a internet, preencher aqui e
  -- descomentar a chamada UTL_HTTP.SET_PROXY em http_call_f.
  g_http_proxy CONSTANT VARCHAR2(200) := NULL;

  -- --------------------------------------------------------------------------
  -- Configuração via FND_LOOKUP_VALUES (LOOKUP_TYPE já usado no XXISV para
  -- WALLET_PATH/WALLET_PASSWORD). ASSUNÇÃO: os LOOKUP_CODE abaixo (CD, HASH,
  -- AMBIENTE) seguem a mesma convenção — ajustar para os códigos reais
  -- cadastrados, se forem diferentes.
  --
  -- AMBIENTE indica, nesta instância EBS, qual dos 3 ambientes da Compliance
  -- deve ser usado (uma instância EBS fala com um único ambiente Compliance).
  -- As URLs em si ficam fixas aqui no package (pedido explícito: não
  -- depender de mais uma tabela/lookup por ambiente para a URL).
  -- --------------------------------------------------------------------------
  gc_lookup_type        CONSTANT VARCHAR2(30) := 'XXISV_CSF_MULTORG_SIC';
  gc_lk_cd              CONSTANT VARCHAR2(30) := 'CD';
  gc_lk_hash            CONSTANT VARCHAR2(30) := 'HASH';
  gc_lk_wallet_path     CONSTANT VARCHAR2(30) := 'WALLET_PATH';
  gc_lk_wallet_password CONSTANT VARCHAR2(30) := 'WALLET_PASSWORD';
  gc_lk_ambiente        CONSTANT VARCHAR2(30) := 'AMBIENTE';

  gc_ambiente_hml   CONSTANT VARCHAR2(20) := 'HOMOLOGACAO';
  gc_ambiente_prod  CONSTANT VARCHAR2(20) := 'PRODUCAO';
  gc_ambiente_qa    CONSTANT VARCHAR2(20) := 'QA';

  -- Endpoints de envio (Leiaute_API_REST_Eventos_NFe_V1_2.docx, tabela de
  -- endpoints). Ajustar caso a Compliance publique uma URL diferente.
  gc_url_hml   CONSTANT VARCHAR2(500) := 'https://apphml.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe';
  gc_url_prod  CONSTANT VARCHAR2(500) := 'https://app.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe';
  gc_url_qa    CONSTANT VARCHAR2(500) := 'https://qa.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe';

  -- TODO: endpoints de consulta de status, ainda não documentados pela
  -- Compliance Fiscal (leiaute v1.2 só define o envio). Preencher assim que
  -- publicados; enquanto NULL, poll_event_status_p não tenta consultar.
  gc_status_url_hml   CONSTANT VARCHAR2(500) := NULL;
  gc_status_url_prod  CONSTANT VARCHAR2(500) := NULL;
  gc_status_url_qa    CONSTANT VARCHAR2(500) := NULL;

  gc_http_timeout_sec  CONSTANT NUMBER := 30;
  gc_poll_interval_sec CONSTANT NUMBER := 5;
  gc_poll_max_wait_sec CONSTANT NUMBER := 90;

  -- --------------------------------------------------------------------------
  -- Registro dos erros customizados (ORA-200xx) levantados por este package —
  -- referência rápida para suporte/troubleshooting sem precisar grepar o body:
  --   -20002  http_call_f                          falha na chamada HTTP (rede/timeout/TLS)
  --   -20003  update_ebs_status_p                  CLL_F255_RT_EVENTS_PUB.return_status_p retornou erro
  --   -20004  process_one_event_p / retry_one_event_p  EVENT_HEADER_ID não encontrado nas views CLL_F255_*
  --   -20005  process_one_event_p / retry_one_event_p  configuração incompleta em FND_LOOKUP_VALUES
  --   -20006  get_config_f                          valor de AMBIENTE não reconhecido na lookup
  --   -20007  build_payload_f                       código de evento fora do escopo mapeado
  --   -20008  retry_one_event_p                     XXISV_EVT_CONTROL não encontrado para o evento
  -- --------------------------------------------------------------------------

  TYPE t_config_rec IS RECORD (
    endpoint_url        VARCHAR2(500),
    status_endpoint_url VARCHAR2(500),
    mult_org_cd         VARCHAR2(50),
    mult_org_hash       VARCHAR2(500),
    wallet_path         VARCHAR2(500),
    wallet_password     VARCHAR2(200)
  );

  -- Uso interno apenas: controla o fluxo entre get_config_f e quem a chama
  -- (process_one_event_p/retry_one_event_p) — nunca escapa do package body,
  -- sempre é traduzido em RAISE_APPLICATION_ERROR(-20005, ...) antes disso.
  ex_config_not_found EXCEPTION;

  -- --------------------------------------------------------------------------
  -- Cursores privados sobre as views padrão da Localização Brasil (CLL_F255_*).
  -- Colunas usadas conforme EBS_RT_Eventos_Mapping_ISV.xlsx e a Cartilha EBS -
  -- Eventos - NF Deb Cred.pdf. EVENT_STATUS = 'CANCEL' identifica uma
  -- solicitação de cancelamento (ver tabela de status da Cartilha, pág. 8).
  -- --------------------------------------------------------------------------
  CURSOR c_header (p_event_header_id IN NUMBER) IS
    SELECT h.event_header_id,
           h.fd_key,
           h.event_code,
           h.taxpayer_id,
           h.event_creation_date,
           h.event_seq_num,
           h.protocol,
           h.cancel_event_code,
           h.event_status,
           h.process,
           h.ind_aceitacao
    FROM   cll_f255_event_headers_v h
    WHERE  h.event_header_id = p_event_header_id;

  CURSOR c_lines (p_event_header_id IN NUMBER) IS
    SELECT l.fd_line_number,
           l.quantity,
           l.unit_of_measure
    FROM   cll_f255_event_lines_v l
    WHERE  l.event_header_id = p_event_header_id
    ORDER  BY l.fd_line_number;

  -- Notificações ainda não capturadas por este package (1a captura).
  CURSOR c_pending_notifications IS
    SELECT DISTINCT TO_NUMBER(n.parameter_value1) AS event_header_id
    FROM   cll_f255_notifications n
    WHERE  n.event_name = 'oracle.apps.cll.event_headers'
    AND    NOT EXISTS (
             SELECT 1
             FROM   xxisv_evt_control c
             WHERE  c.event_header_id = TO_NUMBER(n.parameter_value1)
           );

  TYPE t_tax_line_rec IS RECORD (
    tax_amount    NUMBER,
    tax_base      NUMBER,
    tax_rate      NUMBER,
    cod_cred_pres VARCHAR2(2)
  );

  -- ==========================================================================
  -- get_tax_line_f
  -- Busca o valor de imposto (IBS ou CBS) de uma linha do evento.
  -- ASSUNÇÃO: CLL_F255_EVENT_TAX_LINES_V referencia a linha do item via
  -- FD_LINE_NUMBER (mesma coluna usada em CLL_F255_EVENT_LINES_V). Validar
  -- esse vínculo contra a definição real da view (não detalhado nem no
  -- mapeamento nem na cartilha) antes de subir para produção.
  -- ==========================================================================
  FUNCTION get_tax_line_f (
    p_event_header_id IN NUMBER,
    p_line_number     IN NUMBER,
    p_tax_name        IN VARCHAR2
  ) RETURN t_tax_line_rec
  IS
    l_rec t_tax_line_rec;
  BEGIN
    SELECT t.tax_amount, t.tax_base, t.tax_rate, t.cod_cred_pres
    INTO   l_rec.tax_amount, l_rec.tax_base, l_rec.tax_rate, l_rec.cod_cred_pres
    FROM   cll_f255_event_tax_lines_v t
    WHERE  t.event_header_id = p_event_header_id
    AND    t.fd_line_number  = p_line_number
    AND    t.tax_name        = p_tax_name
    AND    ROWNUM = 1;

    RETURN l_rec;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN l_rec; -- campos NULL
  END get_tax_line_f;

  -- ==========================================================================
  -- derive_modelo_f
  -- Deriva o "modelo" do documento fiscal (P1.03 do leiaute Compliance) a
  -- partir da chave de acesso da NF-e (posições 21-22), já que a planilha de
  -- mapeamento não traz uma coluna própria para esse campo.
  -- ==========================================================================
  FUNCTION derive_modelo_f (p_fd_key IN VARCHAR2) RETURN VARCHAR2
  IS
  BEGIN
    IF p_fd_key IS NOT NULL AND LENGTH(p_fd_key) = 44 THEN
      RETURN SUBSTR(p_fd_key, 21, 2);
    END IF;
    RETURN '55'; -- fallback: NF-e modelo 55
  END derive_modelo_f;

  -- ==========================================================================
  -- log_http_p
  -- Auditoria das chamadas HTTP. Transação autônoma para preservar o log
  -- mesmo quando a chamada falha e a transação principal é revertida.
  -- ==========================================================================
  PROCEDURE log_http_p (
    p_event_header_id IN NUMBER,
    p_call_type       IN VARCHAR2,
    p_url             IN VARCHAR2,
    p_request_body    IN CLOB,
    p_http_status     IN NUMBER,
    p_response_body   IN CLOB,
    p_error_message   IN VARCHAR2
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO xxisv_evt_http_log (
      event_header_id, call_type, request_url, request_body,
      http_status_code, response_body, error_message
    ) VALUES (
      p_event_header_id, p_call_type, p_url, p_request_body,
      p_http_status, p_response_body, p_error_message
    );
    COMMIT;
  END log_http_p;

  -- ==========================================================================
  -- get_config_f
  -- Monta a configuração de envio a partir de FND_LOOKUP_VALUES
  -- (LOOKUP_TYPE = XXISV_CSF_MULTORG_SIC) + URLs fixas no package. CD/HASH/
  -- AMBIENTE são obrigatórios (sem eles não há como autenticar/rotear a
  -- chamada); WALLET_PATH/WALLET_PASSWORD são opcionais, mesmo padrão do
  -- exemplo original (NULL quando não cadastrados).
  -- ==========================================================================
  FUNCTION get_config_f RETURN t_config_rec
  IS
    l_config   t_config_rec;
    l_ambiente VARCHAR2(20);
  BEGIN
    BEGIN
      SELECT a.tag
      INTO   l_ambiente
      FROM   fnd_lookup_values a
      WHERE  a.lookup_type = gc_lookup_type
      AND    a.lookup_code = gc_lk_ambiente
      AND    a.language    = USERENV('LANG')
      AND    NVL(a.end_date_active, SYSDATE) >= SYSDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE ex_config_not_found;
    END;

    CASE UPPER(l_ambiente)
      WHEN gc_ambiente_hml THEN
        l_config.endpoint_url        := gc_url_hml;
        l_config.status_endpoint_url := gc_status_url_hml;
      WHEN gc_ambiente_prod THEN
        l_config.endpoint_url        := gc_url_prod;
        l_config.status_endpoint_url := gc_status_url_prod;
      WHEN gc_ambiente_qa THEN
        l_config.endpoint_url        := gc_url_qa;
        l_config.status_endpoint_url := gc_status_url_qa;
      ELSE
        RAISE_APPLICATION_ERROR(-20006,
          gc_module_name || ': valor de AMBIENTE não reconhecido na lookup ' || gc_lookup_type || ': ' || l_ambiente);
    END CASE;

    BEGIN
      SELECT a.tag
      INTO   l_config.mult_org_cd
      FROM   fnd_lookup_values a
      WHERE  a.lookup_type = gc_lookup_type
      AND    a.lookup_code = gc_lk_cd
      AND    a.language    = USERENV('LANG')
      AND    NVL(a.end_date_active, SYSDATE) >= SYSDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE ex_config_not_found;
    END;

    BEGIN
      SELECT a.tag
      INTO   l_config.mult_org_hash
      FROM   fnd_lookup_values a
      WHERE  a.lookup_type = gc_lookup_type
      AND    a.lookup_code = gc_lk_hash
      AND    a.language    = USERENV('LANG')
      AND    NVL(a.end_date_active, SYSDATE) >= SYSDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE ex_config_not_found;
    END;

    BEGIN
      SELECT a.tag
      INTO   l_config.wallet_path
      FROM   fnd_lookup_values a
      WHERE  a.lookup_type = gc_lookup_type
      AND    a.lookup_code = gc_lk_wallet_path
      AND    a.language    = USERENV('LANG')
      AND    NVL(a.end_date_active, SYSDATE) >= SYSDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_config.wallet_path := NULL;
    END;

    BEGIN
      SELECT a.tag
      INTO   l_config.wallet_password
      FROM   fnd_lookup_values a
      WHERE  a.lookup_type = gc_lookup_type
      AND    a.lookup_code = gc_lk_wallet_password
      AND    a.language    = USERENV('LANG')
      AND    NVL(a.end_date_active, SYSDATE) >= SYSDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_config.wallet_password := NULL;
    END;

    RETURN l_config;
  END get_config_f;

  -- ==========================================================================
  -- http_call_f
  -- Executa a chamada HTTP (POST de envio ou GET de consulta) via UTL_HTTP e
  -- registra o resultado em XXISV_EVT_HTTP_LOG.
  -- ==========================================================================
  FUNCTION http_call_f (
    p_config          IN t_config_rec,
    p_url             IN VARCHAR2,
    p_method          IN VARCHAR2,
    p_body            IN CLOB,
    p_event_header_id IN NUMBER,
    p_call_type       IN VARCHAR2,
    x_http_status     OUT NUMBER
  ) RETURN CLOB
  IS
    l_http_req  UTL_HTTP.req;
    l_http_resp UTL_HTTP.resp;
    l_response  CLOB;
    l_buffer    VARCHAR2(32767);
    l_body_len  PLS_INTEGER;
    l_offset    PLS_INTEGER;
    l_amount    PLS_INTEGER;
    l_error_msg VARCHAR2(4000);
  BEGIN
    UTL_HTTP.SET_TRANSFER_TIMEOUT(gc_http_timeout_sec);

    IF g_http_proxy IS NOT NULL THEN
      UTL_HTTP.SET_PROXY(g_http_proxy);
    END IF;

    IF p_config.wallet_path IS NOT NULL THEN
      UTL_HTTP.SET_WALLET(p_config.wallet_path, p_config.wallet_password);
    END IF;

    l_http_req := UTL_HTTP.BEGIN_REQUEST(url => p_url, method => p_method);
    UTL_HTTP.SET_HEADER(l_http_req, 'Content-Type', 'application/json');
    UTL_HTTP.SET_HEADER(l_http_req, 'cd', p_config.mult_org_cd);
    UTL_HTTP.SET_HEADER(l_http_req, 'hash', p_config.mult_org_hash);

    IF p_body IS NOT NULL AND DBMS_LOB.GETLENGTH(p_body) > 0 THEN
      l_body_len := DBMS_LOB.GETLENGTH(p_body);
      UTL_HTTP.SET_HEADER(l_http_req, 'Content-Length', TO_CHAR(l_body_len));

      l_offset := 1;
      WHILE l_offset <= l_body_len LOOP
        l_amount := LEAST(32767, l_body_len - l_offset + 1);
        DBMS_LOB.READ(p_body, l_amount, l_offset, l_buffer);
        UTL_HTTP.WRITE_TEXT(l_http_req, l_buffer);
        l_offset := l_offset + l_amount;
      END LOOP;
    END IF;

    l_http_resp := UTL_HTTP.GET_RESPONSE(l_http_req);
    x_http_status := l_http_resp.status_code;

    DBMS_LOB.CREATETEMPORARY(l_response, TRUE);
    BEGIN
      LOOP
        UTL_HTTP.READ_TEXT(l_http_resp, l_buffer, 32767);
        DBMS_LOB.WRITEAPPEND(l_response, LENGTH(l_buffer), l_buffer);
      END LOOP;
    EXCEPTION
      WHEN UTL_HTTP.END_OF_BODY THEN
        NULL;
    END;
    UTL_HTTP.END_RESPONSE(l_http_resp);

    log_http_p(p_event_header_id, p_call_type, p_url, p_body, x_http_status, l_response, NULL);

    RETURN l_response;
  EXCEPTION
    WHEN OTHERS THEN
      l_error_msg := SUBSTR(SQLERRM, 1, 4000);
      BEGIN
        UTL_HTTP.END_RESPONSE(l_http_resp);
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;
      log_http_p(p_event_header_id, p_call_type, p_url, p_body, x_http_status, NULL, l_error_msg);
      RAISE_APPLICATION_ERROR(-20002, gc_module_name || ': falha HTTP (' || p_call_type || '): ' || l_error_msg);
  END http_call_f;

  -- ==========================================================================
  -- Construtores de "dados" por código de evento (Apêndice do leiaute
  -- Compliance: P2, P5, P6, P8, P10, P13). Fontes de coluna conforme as abas
  -- correspondentes de EBS_RT_Eventos_Mapping_ISV.xlsx.
  -- ==========================================================================

  -- 110001 — Cancelamento de evento (P2). dados: objeto único.
  FUNCTION build_dados_110001_f (p_header IN c_header%ROWTYPE) RETURN JSON_OBJECT_T
  IS
    l_dados JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    l_dados.put('codEventoAut', p_header.event_code);
    l_dados.put('nroProtEvento', p_header.protocol);
    RETURN l_dados;
  END build_dados_110001_f;

  -- 112130 / 211124 — Perecimento, perda, roubo ou furto em transporte (P5).
  -- dados: array por item.
  FUNCTION build_dados_perecimento_f (p_event_header_id IN NUMBER) RETURN JSON_ARRAY_T
  IS
    l_arr  JSON_ARRAY_T := JSON_ARRAY_T();
    l_item JSON_OBJECT_T;
    l_ibs  t_tax_line_rec;
    l_cbs  t_tax_line_rec;
  BEGIN
    FOR r IN c_lines(p_event_header_id) LOOP
      l_item := JSON_OBJECT_T();
      l_ibs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'IBS');
      l_cbs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'CBS');

      l_item.put('nroItem', r.fd_line_number);
      l_item.put('vIbs', NVL(l_ibs.tax_amount, 0));
      l_item.put('vCbs', NVL(l_cbs.tax_amount, 0));
      l_item.put('qtde', r.quantity);
      l_item.put('unidade', r.unit_of_measure);

      -- TODO: EBS_RT_Eventos_Mapping_ISV.xlsx reaproveita a mesma coluna
      -- TAX_AMOUNT (filtrando por TAX_NAME) tanto para o imposto da nota
      -- quanto para o crédito de aquisições a estornar, sem um segundo campo
      -- que os diferencie. Enquanto isso não for esclarecido com o time
      -- LAD/Oracle, replicamos o mesmo valor de vIbs/vCbs aqui — NÃO habilitar
      -- os eventos 112130/211124 em produção sem validar este ponto.
      l_item.put('vIbsEstornado', NVL(l_ibs.tax_amount, 0));
      l_item.put('vCbsEstornado', NVL(l_cbs.tax_amount, 0));

      l_arr.append(l_item);
    END LOOP;
    RETURN l_arr;
  END build_dados_perecimento_f;

  -- 112140 — Fornecimento não realizado com pagamento antecipado (P6).
  -- dados: array por item.
  FUNCTION build_dados_112140_f (p_event_header_id IN NUMBER) RETURN JSON_ARRAY_T
  IS
    l_arr  JSON_ARRAY_T := JSON_ARRAY_T();
    l_item JSON_OBJECT_T;
    l_ibs  t_tax_line_rec;
    l_cbs  t_tax_line_rec;
  BEGIN
    FOR r IN c_lines(p_event_header_id) LOOP
      l_item := JSON_OBJECT_T();
      l_ibs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'IBS');
      l_cbs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'CBS');

      l_item.put('nroItem', r.fd_line_number);
      l_item.put('vIbs', NVL(l_ibs.tax_amount, 0));
      l_item.put('vCbs', NVL(l_cbs.tax_amount, 0));
      l_item.put('qtde', r.quantity);
      l_item.put('unidade', r.unit_of_measure);

      l_arr.append(l_item);
    END LOOP;
    RETURN l_arr;
  END build_dados_112140_f;

  -- 211110 — Apropriação de crédito presumido (P8). dados: array por item.
  FUNCTION build_dados_211110_f (p_event_header_id IN NUMBER) RETURN JSON_ARRAY_T
  IS
    l_arr  JSON_ARRAY_T := JSON_ARRAY_T();
    l_item JSON_OBJECT_T;
    l_ibs  t_tax_line_rec;
    l_cbs  t_tax_line_rec;
  BEGIN
    FOR r IN c_lines(p_event_header_id) LOOP
      l_item := JSON_OBJECT_T();
      l_ibs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'IBS');
      l_cbs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'CBS');

      l_item.put('nroItem', r.fd_line_number);
      -- vlBaseCalc (P8.2) não é especificada por imposto na planilha de
      -- mapeamento; assume-se o mesmo valor de base para IBS/CBS do item.
      l_item.put('vlBaseCalc', NVL(l_ibs.tax_base, l_cbs.tax_base));

      IF l_ibs.tax_amount IS NOT NULL THEN
        l_item.put('codCredPresIbs', l_ibs.cod_cred_pres);
        l_item.put('aliqCredPresIbs', l_ibs.tax_rate);
        l_item.put('vlCredPresIbs', l_ibs.tax_amount);
      END IF;

      IF l_cbs.tax_amount IS NOT NULL THEN
        l_item.put('codCredPresCbs', l_cbs.cod_cred_pres);
        l_item.put('aliqCredPresCbs', l_cbs.tax_rate);
        l_item.put('vlCredPresCbs', l_cbs.tax_amount);
      END IF;

      l_arr.append(l_item);
    END LOOP;
    RETURN l_arr;
  END build_dados_211110_f;

  -- 211128 — Aceite de débito na apuração por emissão de nota de crédito
  -- (P10). dados: objeto único.
  FUNCTION build_dados_211128_f (p_header IN c_header%ROWTYPE) RETURN JSON_OBJECT_T
  IS
    l_dados JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    l_dados.put('dmIndAceitacao', p_header.ind_aceitacao);
    RETURN l_dados;
  END build_dados_211128_f;

  -- 211150 — Crédito para bens/serviços que dependem de atividade do
  -- adquirente (P13). dados: array por item.
  FUNCTION build_dados_211150_f (p_event_header_id IN NUMBER) RETURN JSON_ARRAY_T
  IS
    l_arr  JSON_ARRAY_T := JSON_ARRAY_T();
    l_item JSON_OBJECT_T;
    l_ibs  t_tax_line_rec;
    l_cbs  t_tax_line_rec;
  BEGIN
    FOR r IN c_lines(p_event_header_id) LOOP
      l_item := JSON_OBJECT_T();
      l_ibs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'IBS');
      l_cbs  := get_tax_line_f(p_event_header_id, r.fd_line_number, 'CBS');

      l_item.put('nroItem', r.fd_line_number);
      l_item.put('vIbs', NVL(l_ibs.tax_amount, 0));
      l_item.put('vCbs', NVL(l_cbs.tax_amount, 0));

      l_arr.append(l_item);
    END LOOP;
    RETURN l_arr;
  END build_dados_211150_f;

  -- ==========================================================================
  -- build_envelope_f
  -- Monta o envelope {"eventos":[{...}]} do leiaute Compliance (campos P1.xx).
  -- ==========================================================================
  FUNCTION build_envelope_f (
    p_header        IN c_header%ROWTYPE,
    p_codigo_evento IN VARCHAR2,
    p_tipo_autor    IN NUMBER,
    p_dados         IN JSON_ELEMENT_T
  ) RETURN CLOB
  IS
    l_evento  JSON_OBJECT_T := JSON_OBJECT_T();
    l_eventos JSON_ARRAY_T  := JSON_ARRAY_T();
    l_root    JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    l_evento.put('cnpj', p_header.taxpayer_id);
    l_evento.put('modelo', derive_modelo_f(p_header.fd_key));
    l_evento.put('chaveAcesso', p_header.fd_key);
    l_evento.put('codigoEvento', p_codigo_evento);

    IF p_tipo_autor IS NOT NULL THEN
      l_evento.put('tipoAutor', p_tipo_autor);
    END IF;

    l_evento.put('dados', p_dados);
    l_eventos.append(l_evento);
    l_root.put('eventos', l_eventos);

    RETURN l_root.to_clob();
  END build_envelope_f;

  -- ==========================================================================
  -- build_payload_f
  -- Dispatcher: escolhe o construtor de "dados" pelo código de evento e monta
  -- o envelope completo a ser enviado à Compliance.
  -- ==========================================================================
  FUNCTION build_payload_f (p_header IN c_header%ROWTYPE) RETURN CLOB
  IS
    l_dados_obj JSON_OBJECT_T;
    l_dados_arr JSON_ARRAY_T;
  BEGIN
    -- EVENT_STATUS = 'CANCEL' identifica solicitação de cancelamento
    -- (Cartilha EBS - Eventos, tabela de status, pág. 8): o codigoEvento
    -- enviado é sempre 110001, e codEventoAut/nroProtEvento referenciam o
    -- evento originalmente aprovado (EVENT_CODE / PROTOCOL do próprio header).
    IF p_header.event_status = 'CANCEL' THEN
      l_dados_obj := build_dados_110001_f(p_header);
      RETURN build_envelope_f(p_header, gc_evt_cancelamento, NULL, l_dados_obj);
    END IF;

    CASE p_header.event_code
      WHEN gc_evt_perec_fornecedor THEN
        l_dados_arr := build_dados_perecimento_f(p_header.event_header_id);
        RETURN build_envelope_f(p_header, gc_evt_perec_fornecedor, 1, l_dados_arr);

      WHEN gc_evt_perec_adquirente THEN
        l_dados_arr := build_dados_perecimento_f(p_header.event_header_id);
        RETURN build_envelope_f(p_header, gc_evt_perec_adquirente, 2, l_dados_arr);

      WHEN gc_evt_nao_fornecido THEN
        l_dados_arr := build_dados_112140_f(p_header.event_header_id);
        RETURN build_envelope_f(p_header, gc_evt_nao_fornecido, 1, l_dados_arr);

      WHEN gc_evt_cred_presumido THEN
        l_dados_arr := build_dados_211110_f(p_header.event_header_id);
        RETURN build_envelope_f(p_header, gc_evt_cred_presumido, 2, l_dados_arr);

      WHEN gc_evt_aceite_debito THEN
        l_dados_obj := build_dados_211128_f(p_header);
        RETURN build_envelope_f(p_header, gc_evt_aceite_debito, 2, l_dados_obj);

      WHEN gc_evt_credito THEN
        l_dados_arr := build_dados_211150_f(p_header.event_header_id);
        RETURN build_envelope_f(p_header, gc_evt_credito, 2, l_dados_arr);

      ELSE
        RAISE_APPLICATION_ERROR(-20007,
          gc_module_name || ': código de evento fora do escopo mapeado (EVENT_CODE = ' || p_header.event_code || ')');
    END CASE;
  END build_payload_f;

  -- ==========================================================================
  -- update_ebs_status_p
  -- Grava o retorno de status no EBS via CLL_F255_RT_EVENTS_PUB.return_status_p
  -- (Cartilha EBS - Eventos - NF Deb Cred.pdf, cenários #1 a #4).
  -- ==========================================================================
  PROCEDURE update_ebs_status_p (
    p_header             IN c_header%ROWTYPE,
    p_status_msg         IN VARCHAR2,
    p_error_code         IN VARCHAR2 DEFAULT NULL,
    p_error_msg          IN VARCHAR2 DEFAULT NULL,
    p_event_protocol     IN VARCHAR2 DEFAULT NULL,
    p_cancel_event_code  IN VARCHAR2 DEFAULT NULL,
    p_cancel_protocol    IN VARCHAR2 DEFAULT NULL,
    p_cancel_failed      IN VARCHAR2 DEFAULT NULL
  ) IS
    l_return_status  VARCHAR2(4000);
    l_return_message VARCHAR2(4000);
  BEGIN
    cll_f255_rt_events_pub.return_status_p (
      p_event_header_id    => p_header.event_header_id,
      p_fd_key              => p_header.fd_key,
      p_event_code          => p_header.event_code,
      p_taxpayer_id         => p_header.taxpayer_id,
      p_status_msg          => p_status_msg,
      p_error_code          => p_error_code,
      p_error_msg           => p_error_msg,
      p_event_date          => SYSDATE,
      p_event_protocol      => p_event_protocol,
      p_cancel_event_code   => p_cancel_event_code,
      p_cancel_protocol     => p_cancel_protocol,
      p_ind_deferred        => NULL,
      p_reason_code         => NULL,
      p_reason_description  => NULL,
      p_process             => p_header.process,
      p_cancel_failed       => p_cancel_failed,
      x_return_status       => l_return_status,
      x_return_message      => l_return_message
    );

    -- ASSUNÇÃO: a Cartilha não documenta os valores possíveis de
    -- x_return_status; assume-se a convenção EBS padrão ('S' = sucesso).
    -- Validar durante a homologação com o time LAD.
    IF l_return_status != 'S' THEN
      RAISE_APPLICATION_ERROR(-20003,
        gc_module_name || ': CLL_F255_RT_EVENTS_PUB.return_status_p retornou erro: ' || l_return_message);
    END IF;
  END update_ebs_status_p;

  -- ==========================================================================
  -- poll_event_status_p
  -- TODO — pendente de confirmação da Compliance Fiscal: o leiaute v1.2 não
  -- documenta um endpoint de consulta de status. Este procedimento consulta
  -- p_config.status_endpoint_url (gc_status_url_*, placeholder até a
  -- Compliance publicar o contrato real) com um contrato de resposta
  -- assumido; ajustar assim que confirmado.
  --
  -- Falha ao consultar/parsear não deve interromper o job (x_resolved fica
  -- FALSE e o evento é retomado depois pelo job de retry); mas é logada em
  -- XXISV_EVT_HTTP_LOG para dar visibilidade ao suporte — sem isso, um
  -- contrato de resposta quebrado faria os eventos ficarem represados em
  -- TIMEOUT sem nenhuma pista do motivo.
  -- ==========================================================================
  PROCEDURE poll_event_status_p (
    p_config              IN t_config_rec,
    p_header              IN c_header%ROWTYPE,
    p_compliance_batch_ref IN VARCHAR2,
    x_resolved            OUT BOOLEAN,
    x_status_msg          OUT VARCHAR2,
    x_error_code          OUT VARCHAR2,
    x_error_msg           OUT VARCHAR2,
    x_event_protocol      OUT VARCHAR2,
    x_cancel_protocol     OUT VARCHAR2
  ) IS
    l_http_status NUMBER;
    l_response    CLOB;
    l_json        JSON_OBJECT_T;
    l_url         VARCHAR2(1000);
  BEGIN
    x_resolved := FALSE;

    IF p_config.status_endpoint_url IS NULL THEN
      RETURN; -- endpoint ainda não configurado/publicado
    END IF;

    l_url := p_config.status_endpoint_url
             || '?chaveAcesso=' || p_header.fd_key
             || '&codigoEvento=' || p_header.event_code
             || '&batchRef=' || p_compliance_batch_ref;

    l_response := http_call_f(
      p_config          => p_config,
      p_url             => l_url,
      p_method          => 'GET',
      p_body            => NULL,
      p_event_header_id => p_header.event_header_id,
      p_call_type       => 'POLL',
      x_http_status     => l_http_status
    );

    IF l_http_status = 200 AND l_response IS NOT NULL THEN
      -- Contrato de resposta assumido (placeholder):
      -- { "status": "APPROVED|CANCELLED|ERROR|IN_PROCESS", "protocolo": "...",
      --   "protocoloCancelamento": "...", "codigoErro": "...", "mensagemErro": "..." }
      l_json := JSON_OBJECT_T.parse(l_response);
      x_status_msg      := l_json.get_string('status');
      x_event_protocol  := l_json.get_string('protocolo');
      x_cancel_protocol := l_json.get_string('protocoloCancelamento');
      x_error_code      := l_json.get_string('codigoErro');
      x_error_msg       := l_json.get_string('mensagemErro');

      x_resolved := x_status_msg IN ('APPROVED', 'CANCELLED', 'ERROR');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      -- http_call_f já loga falhas de HTTP antes de propagar; aqui cobrimos
      -- o caso de a chamada ter respondido 200 mas com um corpo que não bate
      -- com o contrato assumido (JSON_OBJECT_T.parse/get_string falhando).
      x_resolved := FALSE;
      log_http_p(p_header.event_header_id, 'POLL', p_config.status_endpoint_url,
        NULL, l_http_status, l_response, 'poll_event_status_p: ' || SUBSTR(SQLERRM, 1, 3900));
  END poll_event_status_p;

  -- ==========================================================================
  -- upsert_control_p
  -- ==========================================================================
  PROCEDURE upsert_control_p (
    p_header           IN c_header%ROWTYPE,
    p_local_status     IN VARCHAR2,
    p_http_status      IN NUMBER DEFAULT NULL,
    p_batch_ref        IN VARCHAR2 DEFAULT NULL,
    p_event_protocol   IN VARCHAR2 DEFAULT NULL,
    p_cancel_protocol  IN VARCHAR2 DEFAULT NULL,
    p_error_code       IN VARCHAR2 DEFAULT NULL,
    p_error_msg        IN VARCHAR2 DEFAULT NULL
  ) IS
  BEGIN
    MERGE INTO xxisv_evt_control c
    USING (SELECT p_header.event_header_id AS event_header_id FROM dual) src
    ON (c.event_header_id = src.event_header_id)
    WHEN MATCHED THEN UPDATE SET
      local_status         = p_local_status,
      http_status_code     = NVL(p_http_status, c.http_status_code),
      compliance_batch_ref = NVL(p_batch_ref, c.compliance_batch_ref),
      event_protocol       = NVL(p_event_protocol, c.event_protocol),
      cancel_protocol      = NVL(p_cancel_protocol, c.cancel_protocol),
      error_code           = p_error_code,
      error_message        = p_error_msg,
      attempt_count        = c.attempt_count + 1,
      last_attempt_date    = SYSDATE,
      resolved_date = CASE WHEN p_local_status IN ('APPROVED', 'CANCELLED', 'ERROR')
                            THEN SYSDATE ELSE c.resolved_date END,
      last_updated_by = USER,
      last_update_date = SYSDATE
    WHEN NOT MATCHED THEN INSERT (
      event_header_id, fd_key, event_code, taxpayer_id, local_status,
      http_status_code, compliance_batch_ref, event_protocol, cancel_protocol,
      error_code, error_message, attempt_count, first_sent_date, last_attempt_date
    ) VALUES (
      p_header.event_header_id, p_header.fd_key, p_header.event_code, p_header.taxpayer_id, p_local_status,
      p_http_status, p_batch_ref, p_event_protocol, p_cancel_protocol,
      p_error_code, p_error_msg, 1, SYSDATE, SYSDATE
    );
  END upsert_control_p;

  -- ==========================================================================
  -- apply_resolution_p
  -- Traduz o resultado de poll_event_status_p em status final no EBS
  -- (update_ebs_status_p) e em XXISV_EVT_CONTROL (upsert_control_p) — ou, se
  -- não resolvido, marca TIMEOUT para o job de retry tentar depois. Ponto
  -- único usado tanto pelo envio (process_one_event_p) quanto pela retomada
  -- (retry_one_event_p), para as duas rotinas nunca divergirem nessa regra.
  -- ==========================================================================
  PROCEDURE apply_resolution_p (
    p_header          IN c_header%ROWTYPE,
    p_resolved        IN BOOLEAN,
    p_status_msg      IN VARCHAR2,
    p_error_code      IN VARCHAR2,
    p_error_msg       IN VARCHAR2,
    p_event_protocol  IN VARCHAR2,
    p_cancel_protocol IN VARCHAR2
  ) IS
  BEGIN
    IF p_resolved THEN
      IF p_status_msg = 'APPROVED' THEN
        update_ebs_status_p(p_header, 'APPROVED', p_event_protocol => p_event_protocol);
      ELSIF p_status_msg = 'CANCELLED' THEN
        update_ebs_status_p(p_header, 'CANCELLED',
          p_event_protocol => p_event_protocol,
          p_cancel_event_code => gc_evt_cancelamento,
          p_cancel_protocol => p_cancel_protocol);
      ELSIF p_status_msg = 'ERROR' THEN
        update_ebs_status_p(p_header, 'ERROR', p_error_code => p_error_code, p_error_msg => p_error_msg);
      END IF;

      upsert_control_p(p_header, p_status_msg,
        p_event_protocol => p_event_protocol, p_cancel_protocol => p_cancel_protocol,
        p_error_code => p_error_code, p_error_msg => p_error_msg);
    ELSE
      upsert_control_p(p_header, 'TIMEOUT');
    END IF;
  END apply_resolution_p;

  -- ==========================================================================
  -- process_one_event_p
  -- Envia um evento e aguarda, de forma limitada (poll_max_wait_sec), pelo
  -- retorno de processamento — conforme solicitado: a própria rotina de envio
  -- tenta capturar o status já processado antes de devolver o controle.
  -- Se não resolver dentro da janela, o evento fica em TIMEOUT para o job
  -- RETRY_PENDING_EVENTS_P retomar depois.
  -- ==========================================================================
  PROCEDURE process_one_event_p (
    p_event_header_id IN NUMBER
  ) IS
    l_config          t_config_rec;
    l_header          c_header%ROWTYPE;
    l_payload         CLOB;
    l_http_status     NUMBER;
    l_response        CLOB;
    l_batch_ref       VARCHAR2(100);
    l_elapsed         NUMBER := 0;
    l_resolved        BOOLEAN := FALSE;
    l_status_msg      VARCHAR2(30);
    l_error_code      VARCHAR2(20);
    l_error_msg       VARCHAR2(4000);
    l_event_protocol  VARCHAR2(20);
    l_cancel_protocol VARCHAR2(20);
    l_json            JSON_OBJECT_T;
  BEGIN
    l_config := get_config_f;

    OPEN c_header(p_event_header_id);
    FETCH c_header INTO l_header;
    IF c_header%NOTFOUND THEN
      CLOSE c_header;
      RAISE_APPLICATION_ERROR(-20004, gc_module_name || ': EVENT_HEADER_ID não encontrado: ' || p_event_header_id);
    END IF;
    CLOSE c_header;

    upsert_control_p(l_header, 'PENDING');

    -- 1) Marca IN_PROCESS no EBS antes de enviar (Cartilha, passo 3 de todos
    -- os cenários), sinalizando que a captura foi feita.
    update_ebs_status_p(l_header, 'IN PROCESS');
    upsert_control_p(l_header, 'IN_PROCESS');

    -- 2) Monta e envia o payload
    l_payload := build_payload_f(l_header);

    l_response := http_call_f(
      p_config          => l_config,
      p_url             => l_config.endpoint_url,
      p_method          => 'POST',
      p_body            => l_payload,
      p_event_header_id => l_header.event_header_id,
      p_call_type       => 'SEND',
      x_http_status     => l_http_status
    );

    IF l_http_status NOT IN (200, 201, 202) THEN
      l_error_code := TO_CHAR(l_http_status);
      l_error_msg  := 'Erro no envelope/validação retornado pela Compliance: ' || SUBSTR(l_response, 1, 3900);
      update_ebs_status_p(l_header, 'ERROR', p_error_code => l_error_code, p_error_msg => l_error_msg);
      upsert_control_p(l_header, 'ERROR',
        p_http_status => l_http_status, p_error_code => l_error_code, p_error_msg => l_error_msg);
      RETURN;
    END IF;

    BEGIN
      l_json      := JSON_OBJECT_T.parse(l_response);
      l_batch_ref := l_json.get_string('protocolo');
    EXCEPTION
      WHEN OTHERS THEN
        l_batch_ref := NULL;
    END;

    upsert_control_p(l_header, 'POLLING', p_http_status => l_http_status, p_batch_ref => l_batch_ref);

    -- 3) Espera limitada pelo status final, dentro do mesmo processo de envio
    WHILE l_elapsed < gc_poll_max_wait_sec LOOP
      DBMS_LOCK.SLEEP(gc_poll_interval_sec);
      l_elapsed := l_elapsed + gc_poll_interval_sec;

      poll_event_status_p(
        p_config               => l_config,
        p_header               => l_header,
        p_compliance_batch_ref => l_batch_ref,
        x_resolved             => l_resolved,
        x_status_msg           => l_status_msg,
        x_error_code           => l_error_code,
        x_error_msg            => l_error_msg,
        x_event_protocol       => l_event_protocol,
        x_cancel_protocol      => l_cancel_protocol
      );

      EXIT WHEN l_resolved;
    END LOOP;

    apply_resolution_p(l_header, l_resolved, l_status_msg,
      l_error_code, l_error_msg, l_event_protocol, l_cancel_protocol);
  EXCEPTION
    WHEN ex_config_not_found THEN
      RAISE_APPLICATION_ERROR(-20005,
        gc_module_name || ': configuração incompleta em FND_LOOKUP_VALUES (' || gc_lookup_type || ') — verificar AMBIENTE/CD/HASH.');
  END process_one_event_p;

  -- ==========================================================================
  -- retry_one_event_p
  -- Retoma um evento já enviado (POLLING/TIMEOUT), sem reenviar o payload —
  -- apenas tenta consultar/capturar o status final novamente. Mesmas
  -- validações de process_one_event_p (config/header existentes), para as
  -- duas rotinas se comportarem de forma previsível.
  -- ==========================================================================
  PROCEDURE retry_one_event_p (
    p_event_header_id IN NUMBER
  ) IS
    l_config          t_config_rec;
    l_header          c_header%ROWTYPE;
    l_ctrl            xxisv_evt_control%ROWTYPE;
    l_resolved        BOOLEAN;
    l_status_msg      VARCHAR2(30);
    l_error_code      VARCHAR2(20);
    l_error_msg       VARCHAR2(4000);
    l_event_protocol  VARCHAR2(20);
    l_cancel_protocol VARCHAR2(20);
  BEGIN
    l_config := get_config_f;

    BEGIN
      SELECT * INTO l_ctrl FROM xxisv_evt_control WHERE event_header_id = p_event_header_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20008,
          gc_module_name || ': XXISV_EVT_CONTROL não encontrado para EVENT_HEADER_ID: ' || p_event_header_id);
    END;

    OPEN c_header(p_event_header_id);
    FETCH c_header INTO l_header;
    IF c_header%NOTFOUND THEN
      CLOSE c_header;
      RAISE_APPLICATION_ERROR(-20004, gc_module_name || ': EVENT_HEADER_ID não encontrado: ' || p_event_header_id);
    END IF;
    CLOSE c_header;

    poll_event_status_p(
      p_config               => l_config,
      p_header               => l_header,
      p_compliance_batch_ref => l_ctrl.compliance_batch_ref,
      x_resolved             => l_resolved,
      x_status_msg           => l_status_msg,
      x_error_code           => l_error_code,
      x_error_msg            => l_error_msg,
      x_event_protocol       => l_event_protocol,
      x_cancel_protocol      => l_cancel_protocol
    );

    apply_resolution_p(l_header, l_resolved, l_status_msg,
      l_error_code, l_error_msg, l_event_protocol, l_cancel_protocol);
  EXCEPTION
    WHEN ex_config_not_found THEN
      RAISE_APPLICATION_ERROR(-20005,
        gc_module_name || ': configuração incompleta em FND_LOOKUP_VALUES (' || gc_lookup_type || ') — verificar AMBIENTE/CD/HASH.');
  END retry_one_event_p;

  -- ==========================================================================
  -- Procedimentos públicos
  -- ==========================================================================
  PROCEDURE process_pending_events_p
  IS
  BEGIN
    FOR r IN c_pending_notifications LOOP
      BEGIN
        process_one_event_p(r.event_header_id);
        COMMIT;
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;
          log_http_p(r.event_header_id, 'SEND', NULL, NULL, NULL, NULL, SUBSTR(SQLERRM, 1, 4000));
      END;
    END LOOP;
  END process_pending_events_p;

  PROCEDURE retry_pending_events_p
  IS
  BEGIN
    FOR r IN (
      SELECT event_header_id
      FROM   xxisv_evt_control
      WHERE  local_status IN ('TIMEOUT', 'POLLING')
      ORDER  BY last_attempt_date
    ) LOOP
      BEGIN
        retry_one_event_p(r.event_header_id);
        COMMIT;
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;
          log_http_p(r.event_header_id, 'POLL', NULL, NULL, NULL, NULL, SUBSTR(SQLERRM, 1, 4000));
      END;
    END LOOP;
  END retry_pending_events_p;

END xxisv_evt_compliance_pkg;
/

-- ============================================================================
-- PROYECTO: Analitica de cobranzas
-- MODELO ESTRELLA EN REDSHIFT SERVERLESS
--
-- Ejecutar en el Query Editor v2 de Redshift, conectado a la base de datos
-- del proyecto (ej. dev), DESPUES de crear el namespace con auto-pause 60 s.
--
-- ARQUITECTURA DE CAPAS:
--   S3 raw (CSV)  ->  Glue (limpieza)  ->  S3 curated (Parquet)
--                                              |
--                          tablas de staging (copia fiel del Parquet)
--                                              |
--                          MODELO ESTRELLA (dimensiones + hechos)  <- este archivo
--                                              |
--                                        Power BI Desktop
--
-- POR QUE STAGING + INSERT Y NO COPY DIRECTO AL MODELO FINAL:
-- El COPY desde Parquet mapea por POSICION, no por nombre. El Parquet de la capa
-- curada tiene columnas en un orden distinto al del modelo estrella (y trae columnas
-- tecnicas como _fecha_proceso). Cargar con COPY directo y una lista de columnas
-- desordenada corrompe los datos silenciosamente. Por eso: COPY a staging (mismo
-- orden), y luego INSERT ... SELECT con las columnas nombradas. Es mas codigo pero
-- es correcto y ademas deja el modelo documentado.
--
-- ORDEN DE EJECUCION:
--   1. Este archivo (crea staging + dimensiones + hechos)
--   2. 06_redshift_carga.sql      (COPY desde S3 y carga de dimensiones)
--   3. 06_redshift_carga.sql      (parte 2: carga de las tablas de hechos)
--   4. 07_redshift_vistas_negocio.sql (vistas para Power BI)
-- ============================================================================


-- ============================================================================
-- PARTE 1: ESQUEMA
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS cobranzas;

SET search_path TO cobranzas;


-- ============================================================================
-- PARTE 2: TABLAS DE STAGING
-- Copia fiel de cada Parquet de la capa curada. NO se consultan desde Power BI:
-- existen solo para recibir el COPY. Se pueden truncar y recargar siempre.
--
-- DOS REGLAS QUE NO SE PUEDEN ROMPER (verificado en la doc de Amazon Redshift):
--   1. El orden de columnas DEBE coincidir con el del Parquet.
--   2. El NUMERO de columnas DEBE coincidir. La doc es explicita: "The number of
--      columns in the target table and the number of columns in the data file
--      must match". El Parquet de curated trae una columna tecnica AL FINAL
--      (_fecha_proceso, tipo DATE, la anade el ETL de Glue), asi que el staging
--      tambien la declara como ULTIMA columna. Si se omite, el COPY falla.
-- ============================================================================

DROP TABLE IF EXISTS stg_clientes;
CREATE TABLE stg_clientes (
    cliente_id          VARCHAR(20),
    nombre              VARCHAR(120),
    documento           VARCHAR(20),
    email               VARCHAR(160),
    telefono            VARCHAR(20),
    distrito            VARCHAR(60),
    ingreso_mensual     DECIMAL(12,2),
    score_inicial       INTEGER,
    fecha_alta          DATE,
    segmento            VARCHAR(5),
    email_valido        BOOLEAN,
    telefono_valido     BOOLEAN,
    es_contactable      BOOLEAN,
    _fecha_proceso      DATE
);

DROP TABLE IF EXISTS stg_creditos;
CREATE TABLE stg_creditos (
    credito_id               VARCHAR(20),
    cliente_id               VARCHAR(20),
    producto                 VARCHAR(40),
    producto_desc            VARCHAR(80),
    monto_desembolsado       DECIMAL(12,2),
    plazo_meses              INTEGER,
    tea                      DECIMAL(8,4),
    cuota_mensual            DECIMAL(12,2),
    fecha_desembolso         DATE,
    fecha_vencimiento_final  DATE,
    estado_credito           VARCHAR(20),
    score_desembolso         INTEGER,
    oficina                  VARCHAR(60),
    _fecha_proceso           DATE
);

DROP TABLE IF EXISTS stg_cuotas;
CREATE TABLE stg_cuotas (
    cuota_id                       VARCHAR(20),
    credito_id                     VARCHAR(20),
    cliente_id                     VARCHAR(20),
    nro_cuota                      INTEGER,
    fecha_vencimiento              DATE,
    monto_cuota                    DECIMAL(12,2),
    monto_pagado                   DECIMAL(12,2),
    fecha_pago                     DATE,
    estado_cuota                   VARCHAR(25),
    dias_atraso                    INTEGER,
    monto_pagado_corregido         BOOLEAN,
    fecha_pago_futura_corregida    BOOLEAN,
    fecha_pago_imputada            BOOLEAN,
    dias_atraso_calculado          INTEGER,
    pagada                         BOOLEAN,
    _fecha_proceso                 DATE
);

DROP TABLE IF EXISTS stg_gestiones;
CREATE TABLE stg_gestiones (
    gestion_id                   VARCHAR(20),
    credito_id                   VARCHAR(20),
    cliente_id                   VARCHAR(20),
    cuota_id                     VARCHAR(20),
    fecha_gestion                DATE,
    hora_gestion                 VARCHAR(12),
    canal                        VARCHAR(20),
    tipo_gestion                 VARCHAR(30),
    resultado                    VARCHAR(30),
    asesor_id                    VARCHAR(10),
    monto_promesa                DECIMAL(12,2),
    fecha_promesa_pago           DATE,
    ptp_cumplida                 VARCHAR(5),
    monto_recuperado             DECIMAL(12,2),
    duracion_seg                 INTEGER,
    costo_gestion                DECIMAL(12,2),
    canal_formato_corregido      BOOLEAN,
    resultado_formato_corregido  BOOLEAN,
    es_gestion_efectiva          BOOLEAN,
    es_pago                      BOOLEAN,
    _fecha_proceso               DATE
);

DROP TABLE IF EXISTS stg_mora;
CREATE TABLE stg_mora (
    fecha_corte         DATE,
    credito_id          VARCHAR(20),
    cliente_id          VARCHAR(20),
    dias_atraso         INTEGER,
    bucket_mora         VARCHAR(15),
    saldo_vencido       DECIMAL(12,2),
    saldo_total         DECIMAL(12,2),
    cuotas_vencidas     INTEGER,
    score_actual        INTEGER,
    elegible_castigo    VARCHAR(5),
    bucket_recalculado  BOOLEAN,
    saldo_incoherente   BOOLEAN,
    _fecha_proceso      DATE
);


-- ============================================================================
-- PARTE 3: DIMENSIONES
-- Claves subrogadas (surrogate keys) generadas con IDENTITY: enteros compactos,
-- mas rapidos de unir que textos largos. Se conserva el ID natural para trazabilidad.
-- ============================================================================

DROP TABLE IF EXISTS dim_cliente;
CREATE TABLE dim_cliente (
    cliente_key         INTEGER IDENTITY(1,1),
    cliente_id          VARCHAR(20)  NOT NULL,
    nombre              VARCHAR(120),
    documento           VARCHAR(20),
    distrito            VARCHAR(60),
    segmento            VARCHAR(5),
    rango_ingreso       VARCHAR(20),      -- derivado: segmenta por nivel de ingreso
    score_inicial       INTEGER,
    rango_score         VARCHAR(20),      -- derivado: segmenta por calidad crediticia
    fecha_alta          DATE,
    es_contactable      BOOLEAN,
    tiene_email         BOOLEAN,
    tiene_telefono      BOOLEAN,
    PRIMARY KEY (cliente_key)
)
DISTSTYLE ALL;   -- dimension pequena: se replica en todos los nodos, joins muy rapidos


DROP TABLE IF EXISTS dim_credito;
CREATE TABLE dim_credito (
    credito_key          INTEGER IDENTITY(1,1),
    credito_id           VARCHAR(20) NOT NULL,
    cliente_id           VARCHAR(20),
    producto             VARCHAR(40),
    producto_desc        VARCHAR(80),
    oficina              VARCHAR(60),
    plazo_meses          INTEGER,
    rango_plazo          VARCHAR(20),
    tea                  DECIMAL(8,4),
    monto_desembolsado   DECIMAL(12,2),
    rango_monto          VARCHAR(20),
    cuota_mensual        DECIMAL(12,2),
    fecha_desembolso     DATE,
    anio_desembolso      INTEGER,
    estado_credito       VARCHAR(20),
    score_desembolso     INTEGER,
    PRIMARY KEY (credito_key)
)
DISTKEY (credito_key)
SORTKEY (fecha_desembolso);


-- Dimension de tiempo: permite analizar por dia de semana, mes, trimestre y anio
DROP TABLE IF EXISTS dim_fecha;
CREATE TABLE dim_fecha (
    fecha_key      INTEGER,               -- formato YYYYMMDD, legible y ordenable
    fecha          DATE NOT NULL,
    anio           INTEGER,
    trimestre      INTEGER,
    mes            INTEGER,
    nombre_mes     VARCHAR(20),
    dia            INTEGER,
    dia_semana     INTEGER,               -- 1 = lunes ... 7 = domingo
    nombre_dia     VARCHAR(15),
    es_fin_semana  BOOLEAN,
    anio_mes       VARCHAR(7),            -- 'YYYY-MM' para ejes de Power BI
    PRIMARY KEY (fecha_key)
)
DISTSTYLE ALL;


DROP TABLE IF EXISTS dim_canal;
CREATE TABLE dim_canal (
    canal_key         INTEGER IDENTITY(1,1),
    canal             VARCHAR(20) NOT NULL,
    es_digital        BOOLEAN,       -- SMS, EMAIL, WHATSAPP
    es_presencial     BOOLEAN,       -- VISITA
    es_autogestionado BOOLEAN,       -- SMS, EMAIL, CARTA (sin agente)
    es_bidireccional  BOOLEAN,       -- LLAMADA, WHATSAPP, VISITA (permite dialogo)
    PRIMARY KEY (canal_key)
)
DISTSTYLE ALL;


DROP TABLE IF EXISTS dim_resultado;
CREATE TABLE dim_resultado (
    resultado_key  INTEGER IDENTITY(1,1),
    resultado      VARCHAR(30) NOT NULL,
    grupo          VARCHAR(25),   -- CONTACTO, PROMESA, PAGO, SIN_CONTACTO, RECHAZO
    es_pago        BOOLEAN,
    es_promesa     BOOLEAN,
    es_contacto    BOOLEAN,
    PRIMARY KEY (resultado_key)
)
DISTSTYLE ALL;


DROP TABLE IF EXISTS dim_tipo_gestion;
CREATE TABLE dim_tipo_gestion (
    tipo_gestion_key  INTEGER IDENTITY(1,1),
    tipo_gestion      VARCHAR(30) NOT NULL,
    etapa             VARCHAR(25),   -- PREVENTIVA, TEMPRANA, MORA, NEGOCIACION, JUDICIAL
    PRIMARY KEY (tipo_gestion_key)
)
DISTSTYLE ALL;


DROP TABLE IF EXISTS dim_asesor;
CREATE TABLE dim_asesor (
    asesor_key  INTEGER IDENTITY(1,1),
    asesor_id   VARCHAR(10) NOT NULL,
    PRIMARY KEY (asesor_key)
)
DISTSTYLE ALL;


-- ============================================================================
-- PARTE 4: TABLAS DE HECHOS
-- Tres granos distintos:
--   fct_gestiones      -> una fila por accion de cobranza
--   fct_mora_diaria    -> una fila por credito y dia de corte
--   fct_cuotas         -> una fila por cuota del cronograma
-- Las tres se distribuyen por credito_key porque se unen con dim_credito.
-- ============================================================================

DROP TABLE IF EXISTS fct_gestiones;
CREATE TABLE fct_gestiones (
    gestion_key         INTEGER IDENTITY(1,1),
    -- claves foraneas al modelo
    credito_key         INTEGER,
    cliente_key         INTEGER,
    fecha_key           INTEGER,
    canal_key           INTEGER,
    resultado_key       INTEGER,
    tipo_gestion_key    INTEGER,
    asesor_key          INTEGER,
    -- IDs naturales (para trazabilidad y depuracion)
    gestion_id          VARCHAR(20),
    credito_id          VARCHAR(20),
    cuota_id            VARCHAR(20),
    -- atributos propios del evento
    fecha_gestion       DATE,
    hora_gestion        VARCHAR(12),
    hora_del_dia        INTEGER,        -- 8..19, para analizar mejor momento de contacto
    -- metricas
    monto_promesa       DECIMAL(12,2),
    fecha_promesa_pago  DATE,
    dias_para_promesa   INTEGER,        -- dias entre gestion y promesa
    ptp_cumplida        VARCHAR(5),
    monto_recuperado    DECIMAL(12,2),
    costo_gestion       DECIMAL(12,2),
    duracion_seg        INTEGER,
    es_pago             BOOLEAN,
    es_promesa          BOOLEAN,
    es_gestion_efectiva BOOLEAN,
    PRIMARY KEY (gestion_key)
)
DISTKEY (credito_key)
SORTKEY (fecha_gestion);


DROP TABLE IF EXISTS fct_mora_diaria;
CREATE TABLE fct_mora_diaria (
    mora_key           INTEGER IDENTITY(1,1),
    credito_key        INTEGER,
    cliente_key        INTEGER,
    fecha_key          INTEGER,
    credito_id         VARCHAR(20),
    cliente_id         VARCHAR(20),
    fecha_corte        DATE,
    -- metricas de la foto diaria
    dias_atraso        INTEGER,
    bucket_mora        VARCHAR(15),
    saldo_vencido      DECIMAL(12,2),
    saldo_total        DECIMAL(12,2),
    cuotas_vencidas    INTEGER,
    score_actual       INTEGER,
    elegible_castigo   VARCHAR(5),
    -- indicadores de deterioro respecto al bucket
    orden_bucket       INTEGER,     -- 1=0-30 ... 4=91-180, para calcular roll rate
    PRIMARY KEY (mora_key)
)
DISTKEY (credito_key)
SORTKEY (fecha_corte);


DROP TABLE IF EXISTS fct_cuotas;
CREATE TABLE fct_cuotas (
    cuota_key              INTEGER IDENTITY(1,1),
    credito_key            INTEGER,
    cliente_key            INTEGER,
    fecha_vencimiento_key  INTEGER,
    fecha_pago_key         INTEGER,     -- nulo si no se pago
    cuota_id               VARCHAR(20),
    credito_id             VARCHAR(20),
    nro_cuota              INTEGER,
    fecha_vencimiento      DATE,
    fecha_pago             DATE,
    -- metricas
    monto_cuota            DECIMAL(12,2),
    monto_pagado           DECIMAL(12,2),
    saldo_cuota            DECIMAL(12,2),   -- monto_cuota - monto_pagado
    dias_atraso            INTEGER,
    estado_cuota           VARCHAR(25),
    pagada                 BOOLEAN,
    pago_puntual           BOOLEAN,         -- pago con dias_atraso = 0
    -- banderas de calidad heredadas del ETL (transparencia del dato)
    flag_monto_corregido   BOOLEAN,
    flag_fecha_futura      BOOLEAN,
    flag_fecha_imputada    BOOLEAN,
    PRIMARY KEY (cuota_key)
)
DISTKEY (credito_key)
SORTKEY (fecha_vencimiento);


-- ============================================================================
-- PARTE 5: TABLA DE AUDITORIA DE CALIDAD
-- Guarda el resultado de los chequeos para evidenciar la calidad del dato.
-- ============================================================================

DROP TABLE IF EXISTS aud_calidad_dato;
CREATE TABLE aud_calidad_dato (
    chequeo        VARCHAR(120),
    tabla_origen   VARCHAR(60),
    resultado      INTEGER,       -- el valor medido
    esperado       INTEGER,       -- normalmente 0
    cumple         BOOLEAN,
    fecha_control  DATE DEFAULT CURRENT_DATE
)
DISTSTYLE ALL;


-- ============================================================================
-- VERIFICACION: que existan los objetos
-- ============================================================================
SELECT table_name,
       CASE WHEN table_name LIKE 'stg_%' THEN 'staging'
            WHEN table_name LIKE 'dim_%' THEN 'dimension'
            WHEN table_name LIKE 'fct_%' THEN 'hecho'
            WHEN table_name LIKE 'aud_%' THEN 'auditoria'
            ELSE 'otro' END AS tipo
FROM information_schema.tables
WHERE table_schema = 'cobranzas'
ORDER BY tipo, table_name;

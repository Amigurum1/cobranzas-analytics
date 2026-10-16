-- ============================================================================
-- PROYECTO: Analitica de cobranzas — entorno de datos en AWS
-- CAPA: raw (datos crudos tal como llegan, SIN limpiar)
-- MOTOR: Amazon Athena (us-east-1)
--
-- ⚠️  IMPORTANTE — POR QUE TODAS LAS COLUMNAS SON STRING:
-- La capa raw contiene errores A PROPOSITO (montos negativos, fechas de pago
-- en el futuro, cuotas PAGADAS sin fecha, duplicados). Si declaramos estas
-- columnas como DECIMAL o DATE, la consulta FALLA al leer una fila sucia.
-- Por eso: raw = todo STRING. La conversion de tipos se hace en la capa
-- curated, ya con los datos validados. Esto es una buena practica real.
--
-- ANTES DE EJECUTAR: reemplaza analitica-cobranzas-bruno-ps57hz por el nombre de tu bucket.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. BASE DE DATOS
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS analitica_cobranzas
COMMENT 'Datos de cobranzas — proyecto de portafolio (raw + curated)';


-- ---------------------------------------------------------------------------
-- 2. TABLA: clientes
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analitica_cobranzas.raw_clientes;

CREATE EXTERNAL TABLE analitica_cobranzas.raw_clientes (
    cliente_id        STRING,
    nombre            STRING,
    documento         STRING,
    email             STRING,
    telefono          STRING,
    distrito          STRING,
    ingreso_mensual   STRING,
    score_inicial     STRING,
    fecha_alta        STRING,
    segmento          STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar'      = ',',
    'quoteChar'          = '"',
    'escapeChar'         = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/clientes/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ---------------------------------------------------------------------------
-- 3. TABLA: creditos
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analitica_cobranzas.raw_creditos;

CREATE EXTERNAL TABLE analitica_cobranzas.raw_creditos (
    credito_id               STRING,
    cliente_id               STRING,
    producto                 STRING,
    producto_desc            STRING,
    monto_desembolsado       STRING,
    plazo_meses              STRING,
    tea                      STRING,
    cuota_mensual            STRING,
    fecha_desembolso         STRING,
    fecha_vencimiento_final  STRING,
    estado_credito           STRING,
    score_desembolso         STRING,
    oficina                  STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/creditos/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ---------------------------------------------------------------------------
-- 4. TABLA: cuotas (cronograma de pagos)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analitica_cobranzas.raw_cuotas;

CREATE EXTERNAL TABLE analitica_cobranzas.raw_cuotas (
    cuota_id          STRING,
    credito_id        STRING,
    cliente_id        STRING,
    nro_cuota         STRING,
    fecha_vencimiento STRING,
    monto_cuota       STRING,
    monto_pagado      STRING,
    fecha_pago        STRING,
    estado_cuota      STRING,
    dias_atraso       STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/cuotas/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ---------------------------------------------------------------------------
-- 5. TABLA: gestiones_cobranza (la tabla central del negocio)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analitica_cobranzas.raw_gestiones_cobranza;

CREATE EXTERNAL TABLE analitica_cobranzas.raw_gestiones_cobranza (
    gestion_id           STRING,
    credito_id           STRING,
    cliente_id           STRING,
    cuota_id             STRING,
    fecha_gestion        STRING,
    hora_gestion         STRING,
    canal                STRING,
    tipo_gestion         STRING,
    resultado            STRING,
    asesor_id            STRING,
    monto_promesa        STRING,
    fecha_promesa_pago   STRING,
    ptp_cumplida         STRING,
    monto_recuperado     STRING,
    duracion_seg         STRING,
    costo_gestion        STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/gestiones_cobranza/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ---------------------------------------------------------------------------
-- 6. TABLA: mora_snapshot (foto diaria de la cartera vencida)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS analitica_cobranzas.raw_mora_snapshot;

CREATE EXTERNAL TABLE analitica_cobranzas.raw_mora_snapshot (
    fecha_corte        STRING,
    credito_id         STRING,
    cliente_id         STRING,
    dias_atraso        STRING,
    bucket_mora        STRING,
    saldo_vencido      STRING,
    saldo_total        STRING,
    cuotas_vencidas    STRING,
    score_actual       STRING,
    elegible_castigo   STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/mora_snapshot/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ============================================================================
-- 7. VERIFICACION: que las 5 tablas carguen bien
-- ============================================================================
SELECT 'clientes'            AS tabla, COUNT(*) AS filas FROM analitica_cobranzas.raw_clientes
UNION ALL SELECT 'creditos',            COUNT(*) FROM analitica_cobranzas.raw_creditos
UNION ALL SELECT 'cuotas',              COUNT(*) FROM analitica_cobranzas.raw_cuotas
UNION ALL SELECT 'gestiones_cobranza',  COUNT(*) FROM analitica_cobranzas.raw_gestiones_cobranza
UNION ALL SELECT 'mora_snapshot',       COUNT(*) FROM analitica_cobranzas.raw_mora_snapshot;

-- Resultado esperado (dataset de 5,000 clientes / 18 meses):
--   clientes             5,025
--   creditos             6,254
--   cuotas              71,229
--   gestiones_cobranza  25,689
--   mora_snapshot       21,547

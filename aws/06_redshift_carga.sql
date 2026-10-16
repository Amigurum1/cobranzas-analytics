-- ============================================================================
-- PROYECTO: Analitica de cobranzas
-- CARGA DEL MODELO ESTRELLA EN REDSHIFT
--
-- Ejecutar DESPUES de 05_redshift_schema_estrella.sql
-- Reemplaza <TU-BUCKET> por el nombre de tu bucket S3.
--
-- Este archivo esta dividido en 4 partes. Ejecutalas en orden.
--   PARTE A: COPY desde S3 a las tablas de staging
--   PARTE B: carga de las dimensiones
--   PARTE C: carga de las tablas de hechos
--   PARTE D: auditoria de calidad
--
-- NOTA SOBRE EL COSTO: Redshift Serverless se cobra por RPU-hora encendido
-- (minimo 4 RPU = $1.50/hora). Todo este archivo se ejecuta en minutos.
-- Cuando termines: apaga el namespace o ponlo en auto-pause de 60 segundos.
-- ============================================================================

SET search_path TO cobranzas;

-- Credencial de acceso a S3. En Redshift Serverless lo mas simple es usar el
-- rol IAM del namespace. Si tu namespace no tiene rol asociado, reemplaza por:
--   IAM_ROLE 'arn:aws:iam::<cuenta>:role/<rol-con-acceso-a-s3>'
-- Si usas credenciales temporales, usa CREDENTIALS 'aws_access_key_id=...;aws_secret_access_key=...'
-- (no recomendado: quedan en el historial de consultas).


-- ============================================================================
-- PARTE A: COPY DESDE S3 A STAGING
-- Un COPY por tabla. FORMAT AS PARQUET mapea columnas POR POSICION.
-- ============================================================================

-- A.1 Clientes
TRUNCATE stg_clientes;
COPY stg_clientes
FROM 's3://<TU-BUCKET>/curated/dim_clientes/'
IAM_ROLE DEFAULT
FORMAT AS PARQUET;

-- A.2 Creditos
TRUNCATE stg_creditos;
COPY stg_creditos
FROM 's3://<TU-BUCKET>/curated/fact_creditos/'
IAM_ROLE DEFAULT
FORMAT AS PARQUET;

-- A.3 Cuotas
TRUNCATE stg_cuotas;
COPY stg_cuotas
FROM 's3://<TU-BUCKET>/curated/fact_cuotas/'
IAM_ROLE DEFAULT
FORMAT AS PARQUET;

-- A.4 Gestiones de cobranza
TRUNCATE stg_gestiones;
COPY stg_gestiones
FROM 's3://<TU-BUCKET>/curated/fact_gestiones_cobranza/'
IAM_ROLE DEFAULT
FORMAT AS PARQUET;

-- A.5 Mora snapshot
TRUNCATE stg_mora;
COPY stg_mora
FROM 's3://<TU-BUCKET>/curated/fact_mora_snapshot/'
IAM_ROLE DEFAULT
FORMAT AS PARQUET;

-- Verificacion: los conteos deben coincidir con los de la capa curated
SELECT 'stg_clientes'  AS tabla, COUNT(*) AS filas FROM stg_clientes
UNION ALL SELECT 'stg_creditos',   COUNT(*) FROM stg_creditos
UNION ALL SELECT 'stg_cuotas',     COUNT(*) FROM stg_cuotas
UNION ALL SELECT 'stg_gestiones',  COUNT(*) FROM stg_gestiones
UNION ALL SELECT 'stg_mora',       COUNT(*) FROM stg_mora;

-- Esperado: 5000 / 6254 / 71229 / 25689 / 21547


-- ============================================================================
-- PARTE B: DIMENSIONES
-- ============================================================================

-- B.1 dim_cliente (con atributos derivados)
TRUNCATE dim_cliente;

INSERT INTO dim_cliente (
    cliente_id, nombre, documento, distrito, segmento, rango_ingreso,
    score_inicial, rango_score, fecha_alta, es_contactable,
    tiene_email, tiene_telefono
)
SELECT
    cliente_id,
    nombre,
    documento,
    distrito,
    segmento,
    CASE
        WHEN ingreso_mensual < 1500 THEN 'MENOS DE 1.5K'
        WHEN ingreso_mensual < 2500 THEN '1.5K A 2.5K'
        WHEN ingreso_mensual < 4000 THEN '2.5K A 4K'
        ELSE 'MAS DE 4K'
    END AS rango_ingreso,
    score_inicial,
    CASE
        WHEN score_inicial >= 700 THEN 'BUENO (700+)'
        WHEN score_inicial >= 600 THEN 'MEDIO (600-699)'
        WHEN score_inicial >= 500 THEN 'BAJO (500-599)'
        ELSE 'MUY BAJO (<500)'
    END AS rango_score,
    fecha_alta,
    es_contactable,
    email_valido,
    telefono_valido
FROM stg_clientes;


-- B.2 dim_credito
TRUNCATE dim_credito;

INSERT INTO dim_credito (
    credito_id, cliente_id, producto, producto_desc, oficina, plazo_meses,
    rango_plazo, tea, monto_desembolsado, rango_monto, cuota_mensual,
    fecha_desembolso, anio_desembolso, estado_credito, score_desembolso
)
SELECT
    credito_id,
    cliente_id,
    producto,
    producto_desc,
    oficina,
    plazo_meses,
    CASE
        WHEN plazo_meses <= 6  THEN 'CORTO (<=6)'
        WHEN plazo_meses <= 12 THEN 'MEDIO (7-12)'
        WHEN plazo_meses <= 24 THEN 'LARGO (13-24)'
        ELSE 'MUY LARGO (25+)'
    END AS rango_plazo,
    tea,
    monto_desembolsado,
    CASE
        WHEN monto_desembolsado < 1000 THEN 'MENOS DE 1K'
        WHEN monto_desembolsado < 3000 THEN '1K A 3K'
        WHEN monto_desembolsado < 7000 THEN '3K A 7K'
        ELSE 'MAS DE 7K'
    END AS rango_monto,
    cuota_mensual,
    fecha_desembolso,
    EXTRACT(YEAR FROM fecha_desembolso)::INTEGER AS anio_desembolso,
    estado_credito,
    score_desembolso
FROM stg_creditos;


-- B.3 dim_fecha: 730 dias hacia atras desde hoy, para cubrir cualquier corte
TRUNCATE dim_fecha;

INSERT INTO dim_fecha (
    fecha_key, fecha, anio, trimestre, mes, nombre_mes,
    dia, dia_semana, nombre_dia, es_fin_semana, anio_mes
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER                    AS fecha_key,
    d::DATE                                            AS fecha,
    EXTRACT(YEAR FROM d)::INTEGER                      AS anio,
    EXTRACT(QUARTER FROM d)::INTEGER                   AS trimestre,
    EXTRACT(MONTH FROM d)::INTEGER                     AS mes,
    TRIM(TO_CHAR(d, 'Month'))                          AS nombre_mes,
    EXTRACT(DAY FROM d)::INTEGER                       AS dia,
    EXTRACT(DOW FROM d)::INTEGER                    AS dia_semana,
    TRIM(TO_CHAR(d, 'Day'))                            AS nombre_dia,
    CASE WHEN EXTRACT(DOW FROM d) IN (0, 6) THEN TRUE ELSE FALSE END AS es_fin_semana,
    TO_CHAR(d, 'YYYY-MM')                              AS anio_mes
FROM (
    SELECT DATEADD(day, -n, CURRENT_DATE) AS d
    FROM (
        SELECT ROW_NUMBER() OVER () - 1 AS n
        FROM stg_mora
        LIMIT 730
    )
) serie;


-- B.4 dim_canal
TRUNCATE dim_canal;

INSERT INTO dim_canal (canal, es_digital, es_presencial, es_autogestionado, es_bidireccional)
SELECT DISTINCT
    canal,
    CASE WHEN canal IN ('SMS','EMAIL','WHATSAPP') THEN TRUE ELSE FALSE END,
    CASE WHEN canal = 'VISITA' THEN TRUE ELSE FALSE END,
    CASE WHEN canal IN ('SMS','EMAIL','CARTA') THEN TRUE ELSE FALSE END,
    CASE WHEN canal IN ('LLAMADA','WHATSAPP','VISITA') THEN TRUE ELSE FALSE END
FROM stg_gestiones;


-- B.5 dim_resultado
TRUNCATE dim_resultado;

INSERT INTO dim_resultado (resultado, grupo, es_pago, es_promesa, es_contacto)
SELECT DISTINCT
    resultado,
    CASE
        WHEN resultado IN ('PAGO_TOTAL','PAGO_PARCIAL') THEN 'PAGO'
        WHEN resultado = 'PROMESA_PAGO'                 THEN 'PROMESA'
        WHEN resultado = 'CONTACTADO'                   THEN 'CONTACTO'
        WHEN resultado IN ('RECHAZA_PAGO','CLIENTE_MOLESTO') THEN 'RECHAZO'
        WHEN resultado = 'NUMERO_INVALIDO'              THEN 'DATO_INVALIDO'
        ELSE 'SIN_CONTACTO'
    END,
    CASE WHEN resultado IN ('PAGO_TOTAL','PAGO_PARCIAL') THEN TRUE ELSE FALSE END,
    CASE WHEN resultado = 'PROMESA_PAGO' THEN TRUE ELSE FALSE END,
    CASE WHEN resultado IN ('CONTACTADO','PAGO_TOTAL','PAGO_PARCIAL',
                            'PROMESA_PAGO','RECHAZA_PAGO','CLIENTE_MOLESTO')
         THEN TRUE ELSE FALSE END
FROM stg_gestiones;


-- B.6 dim_tipo_gestion
TRUNCATE dim_tipo_gestion;

INSERT INTO dim_tipo_gestion (tipo_gestion, etapa)
SELECT DISTINCT
    tipo_gestion,
    CASE
        WHEN tipo_gestion = 'RECORDATORIO'       THEN 'PREVENTIVA'
        WHEN tipo_gestion = 'GESTION_PREVENTIVA' THEN 'PREVENTIVA'
        WHEN tipo_gestion = 'GESTION_TEMPRANA'   THEN 'TEMPRANA'
        WHEN tipo_gestion = 'GESTION_MORA'       THEN 'MORA'
        WHEN tipo_gestion = 'NEGOCIACION'        THEN 'NEGOCIACION'
        WHEN tipo_gestion = 'COBRANZA_JUDICIAL'  THEN 'JUDICIAL'
        ELSE 'OTRA'
    END
FROM stg_gestiones;


-- B.7 dim_asesor
TRUNCATE dim_asesor;

INSERT INTO dim_asesor (asesor_id)
SELECT DISTINCT asesor_id FROM stg_gestiones WHERE asesor_id IS NOT NULL;


-- Verificacion de dimensiones
SELECT 'dim_cliente'      AS dimension, COUNT(*) AS filas FROM dim_cliente
UNION ALL SELECT 'dim_credito',    COUNT(*) FROM dim_credito
UNION ALL SELECT 'dim_fecha',      COUNT(*) FROM dim_fecha
UNION ALL SELECT 'dim_canal',      COUNT(*) FROM dim_canal
UNION ALL SELECT 'dim_resultado',  COUNT(*) FROM dim_resultado
UNION ALL SELECT 'dim_tipo_gestion', COUNT(*) FROM dim_tipo_gestion
UNION ALL SELECT 'dim_asesor',     COUNT(*) FROM dim_asesor;


-- ============================================================================
-- PARTE C: TABLAS DE HECHOS
-- ============================================================================

-- C.1 fct_gestiones
TRUNCATE fct_gestiones;

INSERT INTO fct_gestiones (
    credito_key, cliente_key, fecha_key, canal_key, resultado_key,
    tipo_gestion_key, asesor_key, gestion_id, credito_id, cuota_id,
    fecha_gestion, hora_gestion, hora_del_dia, monto_promesa, fecha_promesa_pago,
    dias_para_promesa, ptp_cumplida, monto_recuperado, costo_gestion,
    duracion_seg, es_pago, es_promesa, es_gestion_efectiva
)
WITH gestion_enriquecida AS (
    -- Los JOIN y los calculos van en la CTE, para que el SELECT final sea solo
    -- la lista de columnas. Es mas legible y evita ambiguedades de nombres.
    SELECT
        dc.credito_key,
        dcl.cliente_key,
        df.fecha_key,
        dca.canal_key,
        dr.resultado_key,
        dtg.tipo_gestion_key,
        da.asesor_key,
        g.gestion_id,
        g.credito_id,
        g.cuota_id,
        g.fecha_gestion,
        g.hora_gestion,
        NULLIF(SPLIT_PART(g.hora_gestion, ':', 1), '')::INTEGER AS hora_del_dia,
        g.monto_promesa,
        g.fecha_promesa_pago,
        DATEDIFF(day, g.fecha_gestion, g.fecha_promesa_pago) AS dias_para_promesa,
        NULLIF(g.ptp_cumplida, '') AS ptp_cumplida,
        g.monto_recuperado,
        g.costo_gestion,
        g.duracion_seg,
        -- es_pago y es_promesa se derivan del resultado en la propia carga, en vez de
        -- depender de que la capa curada los traiga. Asi la carga queda correcta
        -- aunque el ETL de arriba cambie, y no hay que reprocesar S3.
        -- Se califica con g. porque 'resultado' tambien existe en dim_resultado:
        -- sin el alias, Redshift lanza "column reference is ambiguous".
        CASE WHEN g.resultado IN ('PAGO_TOTAL','PAGO_PARCIAL') THEN TRUE ELSE FALSE END AS es_pago,
        CASE WHEN g.resultado = 'PROMESA_PAGO'                THEN TRUE ELSE FALSE END AS es_promesa,
        g.es_gestion_efectiva
    FROM stg_gestiones g
    LEFT JOIN dim_credito      dc  ON dc.credito_id   = g.credito_id
    LEFT JOIN dim_cliente      dcl ON dcl.cliente_id  = g.cliente_id
    LEFT JOIN dim_fecha        df  ON df.fecha        = g.fecha_gestion
    LEFT JOIN dim_canal        dca ON dca.canal       = g.canal
    LEFT JOIN dim_resultado    dr  ON dr.resultado    = g.resultado
    LEFT JOIN dim_tipo_gestion dtg ON dtg.tipo_gestion = g.tipo_gestion
    LEFT JOIN dim_asesor       da  ON da.asesor_id    = g.asesor_id
)
SELECT
    credito_key,
    cliente_key,
    fecha_key,
    canal_key,
    resultado_key,
    tipo_gestion_key,
    asesor_key,
    gestion_id,
    credito_id,
    cuota_id,
    fecha_gestion,
    hora_gestion,
    hora_del_dia,
    monto_promesa,
    fecha_promesa_pago,
    dias_para_promesa,
    ptp_cumplida,
    monto_recuperado,
    costo_gestion,
    duracion_seg,
    es_pago,
    es_promesa,
    es_gestion_efectiva
FROM gestion_enriquecida;


-- C.2 fct_mora_diaria
TRUNCATE fct_mora_diaria;

INSERT INTO fct_mora_diaria (
    credito_key, cliente_key, fecha_key, credito_id, cliente_id, fecha_corte,
    dias_atraso, bucket_mora, saldo_vencido, saldo_total, cuotas_vencidas,
    score_actual, elegible_castigo, orden_bucket
)
SELECT
    dc.credito_key,
    dcl.cliente_key,
    df.fecha_key,
    m.credito_id,
    m.cliente_id,
    m.fecha_corte,
    m.dias_atraso,
    m.bucket_mora,
    m.saldo_vencido,
    m.saldo_total,
    m.cuotas_vencidas,
    m.score_actual,
    m.elegible_castigo,
    CASE m.bucket_mora
        WHEN '0-30'    THEN 1
        WHEN '31-60'   THEN 2
        WHEN '61-90'   THEN 3
        WHEN '91-180'  THEN 4
        WHEN '180+'    THEN 5
        ELSE 0
    END AS orden_bucket
FROM stg_mora m
LEFT JOIN dim_credito dc  ON dc.credito_id  = m.credito_id
LEFT JOIN dim_cliente dcl ON dcl.cliente_id = m.cliente_id
LEFT JOIN dim_fecha   df  ON df.fecha       = m.fecha_corte;


-- C.3 fct_cuotas
-- Nota: fecha_pago_key puede ser nulo cuando la cuota no se pago. Eso es correcto
-- en un modelo estrella; Power BI maneja relaciones con valores vacios.
TRUNCATE fct_cuotas;

INSERT INTO fct_cuotas (
    credito_key, cliente_key, fecha_vencimiento_key, fecha_pago_key,
    cuota_id, credito_id, nro_cuota, fecha_vencimiento, fecha_pago,
    monto_cuota, monto_pagado, saldo_cuota, dias_atraso, estado_cuota,
    pagada, pago_puntual, flag_monto_corregido, flag_fecha_futura, flag_fecha_imputada
)
SELECT
    dc.credito_key,
    dcl.cliente_key,
    dfv.fecha_key,
    dfp.fecha_key,
    c.cuota_id,
    c.credito_id,
    c.nro_cuota,
    c.fecha_vencimiento,
    c.fecha_pago,
    c.monto_cuota,
    c.monto_pagado,
    c.monto_cuota - c.monto_pagado AS saldo_cuota,
    c.dias_atraso,
    c.estado_cuota,
    c.pagada,
    CASE WHEN c.pagada AND c.dias_atraso <= 0 THEN TRUE ELSE FALSE END AS pago_puntual,
    c.monto_pagado_corregido,
    c.fecha_pago_futura_corregida,
    c.fecha_pago_imputada
FROM stg_cuotas c
LEFT JOIN dim_credito dc  ON dc.credito_id  = c.credito_id
LEFT JOIN dim_cliente dcl ON dcl.cliente_id = c.cliente_id
LEFT JOIN dim_fecha   dfv ON dfv.fecha      = c.fecha_vencimiento
LEFT JOIN dim_fecha   dfp ON dfp.fecha      = c.fecha_pago;


-- Verificacion de hechos
SELECT 'fct_gestiones'   AS hecho, COUNT(*) AS filas FROM fct_gestiones
UNION ALL SELECT 'fct_mora_diaria', COUNT(*) FROM fct_mora_diaria
UNION ALL SELECT 'fct_cuotas',      COUNT(*) FROM fct_cuotas;

-- Esperado: 25689 / 21547 / 71229


-- ============================================================================
-- PARTE D: AUDITORIA DE CALIDAD
-- Cada chequeo debe dar 0. Es la evidencia de que la carga es correcta.
-- ============================================================================

TRUNCATE aud_calidad_dato;

-- D.1 Conteos entre staging y hechos (deben coincidir)
INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'gestiones: staging vs hecho',
       'fct_gestiones',
       ABS((SELECT COUNT(*) FROM stg_gestiones) - (SELECT COUNT(*) FROM fct_gestiones)),
       0;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'cuotas: staging vs hecho',
       'fct_cuotas',
       ABS((SELECT COUNT(*) FROM stg_cuotas) - (SELECT COUNT(*) FROM fct_cuotas)),
       0;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'mora: staging vs hecho',
       'fct_mora_diaria',
       ABS((SELECT COUNT(*) FROM stg_mora) - (SELECT COUNT(*) FROM fct_mora_diaria)),
       0;

-- D.2 Claves foraneas sin resolver (huerfanos)
INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'gestiones sin credito_key', 'fct_gestiones',
       COUNT(*), 0
FROM fct_gestiones WHERE credito_key IS NULL;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'gestiones sin canal_key', 'fct_gestiones',
       COUNT(*), 0
FROM fct_gestiones WHERE canal_key IS NULL;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'gestiones sin fecha_key', 'fct_gestiones',
       COUNT(*), 0
FROM fct_gestiones WHERE fecha_key IS NULL;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'cuotas sin fecha_vencimiento_key', 'fct_cuotas',
       COUNT(*), 0
FROM fct_cuotas WHERE fecha_vencimiento_key IS NULL;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'mora sin credito_key', 'fct_mora_diaria',
       COUNT(*), 0
FROM fct_mora_diaria WHERE credito_key IS NULL;

-- D.3 Cuadre de negocio: la suma de hechos debe igualar la de staging
INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'cuadre recaudado (cuotas)',
       'fct_cuotas',
       ABS((SELECT ROUND(SUM(monto_pagado),0) FROM stg_cuotas)
         - (SELECT ROUND(SUM(monto_pagado),0) FROM fct_cuotas)),
       0;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'cuadre recuperado (gestiones)',
       'fct_gestiones',
       ABS((SELECT ROUND(SUM(monto_recuperado),0) FROM stg_gestiones)
         - (SELECT ROUND(SUM(monto_recuperado),0) FROM fct_gestiones)),
       0;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'cuadre saldo vencido (mora)',
       'fct_mora_diaria',
       ABS((SELECT ROUND(SUM(saldo_vencido),0) FROM stg_mora)
         - (SELECT ROUND(SUM(saldo_vencido),0) FROM fct_mora_diaria)),
       0;

-- D.4 Reglas de negocio sobre el modelo final
INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'PTP marcada sin fecha de promesa', 'fct_gestiones',
       COUNT(*), 0
FROM fct_gestiones WHERE es_promesa AND fecha_promesa_pago IS NULL;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'pagos con monto recuperado en cero', 'fct_gestiones',
       COUNT(*), 0
FROM fct_gestiones WHERE es_pago AND monto_recuperado = 0;

INSERT INTO aud_calidad_dato (chequeo, tabla_origen, resultado, esperado)
SELECT 'saldo_cuota negativo (pago de mas)', 'fct_cuotas',
       COUNT(*), 0
FROM fct_cuotas WHERE saldo_cuota < 0;

-- Marcar cumplimiento
UPDATE aud_calidad_dato
SET cumple = (resultado = esperado);

-- RESULTADO: todos los chequeos deben salir con cumple = true
SELECT chequeo, tabla_origen, resultado, esperado, cumple
FROM aud_calidad_dato
ORDER BY cumple, chequeo;

SELECT COUNT(*) AS chequeos_totales,
       SUM(CASE WHEN cumple THEN 1 ELSE 0 END) AS chequeos_ok,
       SUM(CASE WHEN NOT cumple THEN 1 ELSE 0 END) AS chequeos_fallidos
FROM aud_calidad_dato;

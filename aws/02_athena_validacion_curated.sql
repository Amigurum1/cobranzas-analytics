-- ============================================================================
-- PROYECTO: Analitica de cobranzas
-- VALIDACION DE LA CAPA CURATED (despues del job de Glue)
--
-- Objetivo: demostrar que la limpieza funciono. TODOS los chequeos deben dar 0.
-- Ejecuta cada bloque en Athena y anota el resultado. Esto es evidencia real
-- de calidad de datos, y es exactamente lo que se espera de este puesto.
--
-- Antes: corre el crawler de curated para que existan las tablas.
-- ============================================================================


-- ===========================================================================
-- CHEQUEO 1: NO deben quedar claves duplicadas
-- ===========================================================================
SELECT 'dim_clientes: cliente_id duplicado' AS chequeo, COUNT(*) AS debe_ser_cero
FROM (
    SELECT cliente_id FROM analitica_cobranzas.dim_clientes
    GROUP BY cliente_id HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'fact_creditos: credito_id duplicado', COUNT(*)
FROM (
    SELECT credito_id FROM analitica_cobranzas.fact_creditos
    GROUP BY credito_id HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'fact_mora_snapshot: (fecha_corte, credito_id) duplicado', COUNT(*)
FROM (
    SELECT fecha_corte, credito_id FROM analitica_cobranzas.fact_mora_snapshot
    GROUP BY fecha_corte, credito_id HAVING COUNT(*) > 1
);


-- ===========================================================================
-- CHEQUEO 2: NO deben quedar problemas de calidad de los 7 originales
-- ===========================================================================
SELECT 'emails invalidos que sobrevivieron' AS chequeo, COUNT(*) AS debe_ser_cero
FROM analitica_cobranzas.dim_clientes
WHERE email IS NOT NULL AND NOT regexp_like(email, '^[^@\s]+@[^@\s]+\.[^@\s]+$')
UNION ALL
SELECT 'telefonos invalidos que sobrevivieron', COUNT(*)
FROM analitica_cobranzas.dim_clientes
WHERE telefono IS NOT NULL AND NOT regexp_like(telefono, '^9[0-9]{8}$')
UNION ALL
SELECT 'montos pagados negativos', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE monto_pagado < 0
UNION ALL
SELECT 'fechas de pago en el futuro', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE fecha_pago > current_date
UNION ALL
SELECT 'PAGADAS sin fecha de pago', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE estado_cuota IN ('PAGADA','PAGADA_CON_ATRASO') AND fecha_pago IS NULL
UNION ALL
SELECT 'canales sin normalizar', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE canal <> upper(trim(canal))
UNION ALL
SELECT 'resultados sin normalizar', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE resultado <> upper(trim(resultado));


-- ===========================================================================
-- CHEQUEO 3: COHERENCIA DE NEGOCIO
-- ===========================================================================
SELECT 'bucket_mora inconsistente con dias_atraso' AS chequeo, COUNT(*) AS debe_ser_cero
FROM analitica_cobranzas.fact_mora_snapshot
WHERE bucket_mora <> CASE
        WHEN dias_atraso <= 0   THEN 'PREVENTIVO'
        WHEN dias_atraso <= 30  THEN '0-30'
        WHEN dias_atraso <= 60  THEN '31-60'
        WHEN dias_atraso <= 90  THEN '61-90'
        WHEN dias_atraso <= 180 THEN '91-180'
        ELSE '180+' END
UNION ALL
SELECT 'saldo_vencido mayor que saldo_total', COUNT(*)
FROM analitica_cobranzas.fact_mora_snapshot
WHERE saldo_vencido > saldo_total
UNION ALL
SELECT 'PROMESA_PAGO sin fecha de promesa', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE resultado = 'PROMESA_PAGO' AND fecha_promesa_pago IS NULL
UNION ALL
SELECT 'monto recuperado sin resultado de pago', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE monto_recuperado > 0
  AND resultado NOT IN ('PAGO_TOTAL','PAGO_PARCIAL')
UNION ALL
SELECT 'creditos con monto desembolsado <= 0', COUNT(*)
FROM analitica_cobranzas.fact_creditos
WHERE monto_desembolsado <= 0
UNION ALL
SELECT 'elegible_castigo inconsistente', COUNT(*)
FROM analitica_cobranzas.fact_mora_snapshot
WHERE elegible_castigo <> CASE WHEN dias_atraso > 180 THEN 'SI' ELSE 'NO' END;


-- ===========================================================================
-- CHEQUEO 4: INTEGRIDAD REFERENCIAL (que no haya hijos huerfanos)
-- ===========================================================================
SELECT 'cuotas sin credito en fact_creditos' AS chequeo, COUNT(*) AS huerfanos
FROM analitica_cobranzas.fact_cuotas c
LEFT JOIN analitica_cobranzas.fact_creditos k ON k.credito_id = c.credito_id
WHERE k.credito_id IS NULL
UNION ALL
SELECT 'gestiones sin credito en fact_creditos', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza g
LEFT JOIN analitica_cobranzas.fact_creditos k ON k.credito_id = g.credito_id
WHERE k.credito_id IS NULL
UNION ALL
SELECT 'gestiones sin cuota en fact_cuotas', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza g
LEFT JOIN analitica_cobranzas.fact_cuotas c ON c.cuota_id = g.cuota_id
WHERE c.cuota_id IS NULL
UNION ALL
SELECT 'mora_snapshot sin credito en fact_creditos', COUNT(*)
FROM analitica_cobranzas.fact_mora_snapshot m
LEFT JOIN analitica_cobranzas.fact_creditos k ON k.credito_id = m.credito_id
WHERE k.credito_id IS NULL;

-- NOTA: los "huerfanos" pueden ser legitimos si el credito quedo fuera por la
-- regla de monto <= 0. Si aparecen, investiga antes de asumir que es un error.


-- ===========================================================================
-- CHEQUEO 5: VOLUMENES ESPERADOS (deben coincidir con el reporte de Glue)
-- ===========================================================================
SELECT 'dim_clientes' AS tabla, COUNT(*) AS filas FROM analitica_cobranzas.dim_clientes
UNION ALL SELECT 'fact_creditos',            COUNT(*) FROM analitica_cobranzas.fact_creditos
UNION ALL SELECT 'fact_cuotas',              COUNT(*) FROM analitica_cobranzas.fact_cuotas
UNION ALL SELECT 'fact_gestiones_cobranza',  COUNT(*) FROM analitica_cobranzas.fact_gestiones_cobranza
UNION ALL SELECT 'fact_mora_snapshot',       COUNT(*) FROM analitica_cobranzas.fact_mora_snapshot;

-- Valores esperados (dataset de 5,000 clientes / 18 meses):
--   dim_clientes             5,000   (crudo 5,025 menos 25 duplicados)
--   fact_creditos            6,254
--   fact_cuotas             71,229
--   fact_gestiones_cobranza 25,689
--   fact_mora_snapshot      21,547


-- ===========================================================================
-- CHEQUEO 6: EFECTO DE LA LIMPIEZA sobre el negocio
-- ===========================================================================
-- Cuantas cuotas se corrigieron y de que tipo
SELECT
    SUM(CASE WHEN monto_pagado_corregido THEN 1 ELSE 0 END)        AS monto_negativo_corregido,
    SUM(CASE WHEN fecha_pago_futura_corregida THEN 1 ELSE 0 END)   AS pago_futuro_corregido,
    SUM(CASE WHEN fecha_pago_imputada THEN 1 ELSE 0 END)           AS fecha_imputada,
    COUNT(*)                                                       AS total_cuotas
FROM analitica_cobranzas.fact_cuotas;

-- Distribucion de clientes segun si se les puede contactar
-- (indicador clave de cobranzas: si no puedes contactar, no puedes cobrar)
SELECT
    es_contactable,
    COUNT(*) AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS porcentaje
FROM analitica_cobranzas.dim_clientes
GROUP BY es_contactable;


-- ===========================================================================
-- CONSULTAS DE NEGOCIO (el entregable final para Power BI)
-- ===========================================================================

-- B1. Aging de cartera al ultimo corte
SELECT
    bucket_mora,
    COUNT(DISTINCT credito_id)  AS creditos,
    SUM(saldo_vencido)          AS saldo_vencido,
    ROUND(100.0 * SUM(saldo_vencido) / SUM(SUM(saldo_vencido)) OVER (), 2) AS pct
FROM analitica_cobranzas.fact_mora_snapshot
WHERE fecha_corte = (SELECT MAX(fecha_corte) FROM analitica_cobranzas.fact_mora_snapshot)
GROUP BY bucket_mora
ORDER BY bucket_mora;

-- B2. Efectividad y costo por canal
SELECT
    canal,
    COUNT(*)                                   AS gestiones,
    SUM(CASE WHEN es_pago THEN 1 ELSE 0 END)   AS pagos_logrados,
    ROUND(100.0 * SUM(CASE WHEN es_pago THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_pago,
    ROUND(SUM(costo_gestion), 2)               AS costo_total,
    ROUND(SUM(monto_recuperado), 2)            AS recuperado,
    ROUND(SUM(costo_gestion) / NULLIF(SUM(monto_recuperado), 0), 4) AS costo_por_sol
FROM analitica_cobranzas.fact_gestiones_cobranza
GROUP BY canal
ORDER BY costo_por_sol;

-- B3. Cumplimiento de promesas de pago (PTP)
SELECT
    canal,
    COUNT(*)                                                          AS ptp,
    SUM(CASE WHEN ptp_cumplida = 'SI' THEN 1 ELSE 0 END)              AS cumplidas,
    ROUND(100.0 * SUM(CASE WHEN ptp_cumplida = 'SI' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_cumplimiento
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE fecha_promesa_pago IS NOT NULL
GROUP BY canal
ORDER BY pct_cumplimiento DESC;

-- B4. Cobertura de gestion: cartera vencida que NO tiene ninguna gestion
-- (el hallazgo que demuestra valor de negocio)
SELECT
    COUNT(DISTINCT c.credito_id)      AS creditos_sin_gestionar,
    ROUND(SUM(c.monto_cuota), 2)      AS saldo_sin_gestionar
FROM analitica_cobranzas.fact_cuotas c
LEFT JOIN analitica_cobranzas.fact_gestiones_cobranza g ON g.cuota_id = c.cuota_id
WHERE c.estado_cuota = 'VENCIDA' AND g.gestion_id IS NULL;

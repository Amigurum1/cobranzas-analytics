-- ============================================================================
-- PROYECTO: Analitica de cobranzas
-- VISTAS DE NEGOCIO PARA POWER BI
--
-- Ejecutar DESPUES de 06_redshift_carga.sql
--
-- Estas vistas encapsulan la logica de negocio en la BASE DE DATOS, no en el
-- reporte. Ventaja: cualquier persona que consulte (o cualquier tablero) ve el
-- mismo numero, calculado igual. Si la regla cambia, se cambia en un solo lugar.
--
-- Power BI se conecta a estas vistas en modo Import o DirectQuery.
-- ============================================================================

SET search_path TO cobranzas;


-- ============================================================================
-- V1. AGING DE CARTERA
-- Distribucion del saldo vencido por banda de mora, en el ultimo corte diario.
-- Responde: "cuanto tengo vencido y en que estado de deterioro".
-- ============================================================================
CREATE OR REPLACE VIEW vw_aging_cartera AS
WITH ultimo_corte AS (
    SELECT MAX(fecha_corte) AS fecha_corte FROM fct_mora_diaria
)
SELECT
    m.fecha_corte,
    m.bucket_mora,
    m.orden_bucket,
    COUNT(DISTINCT m.credito_id)              AS creditos,
    COUNT(DISTINCT m.cliente_id)              AS clientes,
    SUM(m.saldo_vencido)                      AS saldo_vencido,
    SUM(m.saldo_total)                        AS saldo_total,
    AVG(m.dias_atraso)                        AS promedio_dias_atraso,
    MAX(m.dias_atraso)                        AS max_dias_atraso,
    SUM(m.cuotas_vencidas)                    AS cuotas_vencidas,
    ROUND(100.0 * SUM(m.saldo_vencido)
          / SUM(SUM(m.saldo_vencido)) OVER (), 2) AS pct_participacion
FROM fct_mora_diaria m
JOIN ultimo_corte u ON u.fecha_corte = m.fecha_corte
GROUP BY m.fecha_corte, m.bucket_mora, m.orden_bucket;


-- ============================================================================
-- V2. EVOLUCION DIARIA DE LA MORA
-- Serie de tiempo para ver si la mora mejora o empeora.
-- ============================================================================
CREATE OR REPLACE VIEW vw_evolucion_mora AS
SELECT
    m.fecha_corte,
    COUNT(DISTINCT m.credito_id)  AS creditos_en_mora,
    SUM(m.saldo_vencido)          AS saldo_vencido,
    SUM(CASE WHEN m.bucket_mora = '0-30'   THEN m.saldo_vencido ELSE 0 END) AS s_0_30,
    SUM(CASE WHEN m.bucket_mora = '31-60'  THEN m.saldo_vencido ELSE 0 END) AS s_31_60,
    SUM(CASE WHEN m.bucket_mora = '61-90'  THEN m.saldo_vencido ELSE 0 END) AS s_61_90,
    SUM(CASE WHEN m.bucket_mora = '91-180' THEN m.saldo_vencido ELSE 0 END) AS s_91_180,
    SUM(CASE WHEN m.bucket_mora = '180+'   THEN m.saldo_vencido ELSE 0 END) AS s_180_mas,
    ROUND(100.0 * SUM(CASE WHEN m.orden_bucket >= 3 THEN m.saldo_vencido ELSE 0 END)
          / NULLIF(SUM(m.saldo_vencido), 0), 2) AS pct_mora_mayor_60d
FROM fct_mora_diaria m
GROUP BY m.fecha_corte;


-- ============================================================================
-- V3. EFECTIVIDAD Y COSTO POR CANAL
-- Responde: "que canal recupera mas por cada sol invertido".
-- ============================================================================
CREATE OR REPLACE VIEW vw_efectividad_canal AS
SELECT
    c.canal,
    c.es_digital,
    c.es_bidireccional,
    COUNT(*)                                                       AS gestiones,
    COUNT(DISTINCT g.credito_id)                                   AS creditos_gestionados,
    COUNT(DISTINCT g.asesor_key)                                   AS asesores,
    SUM(CASE WHEN r.es_contacto THEN 1 ELSE 0 END)                 AS contactos,
    SUM(CASE WHEN g.es_promesa THEN 1 ELSE 0 END)                  AS promesas,
    SUM(CASE WHEN g.es_pago THEN 1 ELSE 0 END)                     AS pagos,
    ROUND(100.0 * SUM(CASE WHEN r.es_contacto THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_contacto,
    ROUND(100.0 * SUM(CASE WHEN g.es_promesa THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_promesa,
    ROUND(100.0 * SUM(CASE WHEN g.es_pago THEN 1 ELSE 0 END)    / COUNT(*), 2) AS pct_pago,
    SUM(g.costo_gestion)                                           AS costo_total,
    SUM(g.monto_recuperado)                                        AS recuperado_total,
    ROUND(SUM(g.costo_gestion) / NULLIF(SUM(g.monto_recuperado), 0), 4) AS costo_por_sol_recuperado,
    ROUND(AVG(g.duracion_seg), 0)                                  AS duracion_promedio_seg
FROM fct_gestiones g
JOIN dim_canal c     ON c.canal_key = g.canal_key
-- es_contacto vive en dim_resultado, NO en fct_gestiones (que solo tiene
-- es_pago y es_promesa). El JOIN es 1:1 porque resultado_key es la PK.
JOIN dim_resultado r ON r.resultado_key = g.resultado_key
GROUP BY c.canal, c.es_digital, c.es_bidireccional;


-- ============================================================================
-- V4. CUMPLIMIENTO DE PROMESAS DE PAGO (PTP)
-- Indicador estrella de la gestion: el cliente cumple lo que promete?
-- ============================================================================
CREATE OR REPLACE VIEW vw_cumplimiento_ptp AS
SELECT
    c.canal,
    d.nombre_dia,
    COUNT(*)                                                        AS ptp_registradas,
    SUM(CASE WHEN g.ptp_cumplida = 'SI' THEN 1 ELSE 0 END)          AS ptp_cumplidas,
    SUM(CASE WHEN g.ptp_cumplida = 'NO' THEN 1 ELSE 0 END)          AS ptp_incumplidas,
    ROUND(100.0 * SUM(CASE WHEN g.ptp_cumplida = 'SI' THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2)                                 AS pct_cumplimiento,
    SUM(g.monto_promesa)                                            AS monto_prometido,
    ROUND(AVG(g.dias_para_promesa), 1)                              AS dias_promedio_promesa
FROM fct_gestiones g
JOIN dim_canal c  ON c.canal_key = g.canal_key
JOIN dim_fecha d  ON d.fecha_key = g.fecha_key
WHERE g.es_promesa
GROUP BY c.canal, d.nombre_dia;


-- ============================================================================
-- V5. RECUPERACION POR PRODUCTO Y PERFIL DE CLIENTE
-- Responde: "que cartera se recupera mejor".
-- ============================================================================
CREATE OR REPLACE VIEW vw_recuperacion_producto AS
SELECT
    cr.producto_desc,
    cr.rango_monto,
    cl.rango_score,
    COUNT(DISTINCT q.credito_id)                                    AS creditos,
    SUM(q.monto_cuota)                                              AS facturado,
    SUM(q.monto_pagado)                                             AS recaudado,
    SUM(q.saldo_cuota)                                              AS por_cobrar,
    ROUND(100.0 * SUM(q.monto_pagado) / NULLIF(SUM(q.monto_cuota), 0), 2) AS pct_recuperacion,
    SUM(CASE WHEN q.pagada AND NOT q.pago_puntual THEN 1 ELSE 0 END)      AS pagos_con_atraso,
    ROUND(100.0 * SUM(CASE WHEN q.pagada AND NOT q.pago_puntual THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN q.pagada THEN 1 ELSE 0 END), 0), 2)      AS pct_pago_con_atraso
FROM fct_cuotas q
JOIN dim_credito cr ON cr.credito_key = q.credito_key
JOIN dim_cliente cl ON cl.cliente_key = q.cliente_key
GROUP BY cr.producto_desc, cr.rango_monto, cl.rango_score;


-- ============================================================================
-- V6. COBERTURA DE GESTION
-- Responde: "que cartera vencida se quedo sin gestionar". Es un hallazgo de
-- valor: cartera en mora que nadie esta contactando.
-- ============================================================================
CREATE OR REPLACE VIEW vw_cobertura_gestion AS
WITH cuotas_vencidas AS (
    SELECT
        q.cuota_id,
        q.credito_id,
        q.fecha_vencimiento,
        q.monto_cuota,
        q.dias_atraso,
        DATEDIFF(day, q.fecha_vencimiento, CURRENT_DATE) AS dias_desde_vencimiento
    FROM fct_cuotas q
    WHERE q.estado_cuota = 'VENCIDA'
),
con_gestion AS (
    SELECT DISTINCT cuota_id FROM fct_gestiones
)
SELECT
    CASE
        WHEN cv.dias_desde_vencimiento <= 30  THEN '0-30'
        WHEN cv.dias_desde_vencimiento <= 60  THEN '31-60'
        WHEN cv.dias_desde_vencimiento <= 90  THEN '61-90'
        WHEN cv.dias_desde_vencimiento <= 180 THEN '91-180'
        ELSE '180+'
    END                                                             AS bucket,
    COUNT(*)                                                        AS cuotas_vencidas,
    SUM(CASE WHEN cg.cuota_id IS NULL THEN 1 ELSE 0 END)            AS cuotas_sin_gestion,
    ROUND(100.0 * SUM(CASE WHEN cg.cuota_id IS NULL THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                            AS pct_sin_cobertura,
    SUM(cv.monto_cuota)                                             AS saldo_vencido,
    SUM(CASE WHEN cg.cuota_id IS NULL THEN cv.monto_cuota ELSE 0 END) AS saldo_sin_gestionar
FROM cuotas_vencidas cv
LEFT JOIN con_gestion cg ON cg.cuota_id = cv.cuota_id
GROUP BY 1;


-- ============================================================================
-- V7. ROLL RATE
-- Responde: "de los clientes que estaban en 0-30, cuantos pasaron a 31-60".
-- Mide si la estrategia de cobranza esta frenando el deterioro.
-- ============================================================================
CREATE OR REPLACE VIEW vw_roll_rate AS
WITH con_anterior AS (
    SELECT
        m.credito_id,
        m.fecha_corte,
        m.bucket_mora,
        m.orden_bucket,
        LAG(m.bucket_mora)  OVER (PARTITION BY m.credito_id ORDER BY m.fecha_corte) AS bucket_anterior,
        LAG(m.orden_bucket) OVER (PARTITION BY m.credito_id ORDER BY m.fecha_corte) AS orden_anterior,
        LAG(m.fecha_corte)  OVER (PARTITION BY m.credito_id ORDER BY m.fecha_corte) AS corte_anterior
    FROM fct_mora_diaria m
),
transiciones AS (
    SELECT
        bucket_anterior,
        bucket_mora,
        orden_bucket    AS orden_actual,
        orden_anterior,
        DATEDIFF(day, corte_anterior, fecha_corte) AS dias_entre_cortes
    FROM con_anterior
    WHERE bucket_anterior IS NOT NULL
)
SELECT
    bucket_anterior,
    bucket_mora                                              AS bucket_actual,
    CASE
        WHEN orden_actual > orden_anterior THEN 'DETERIORO'
        WHEN orden_actual = orden_anterior THEN 'SE MANTIENE'
        ELSE 'RECUPERA'
    END                                                      AS movimiento,
    COUNT(*)                                                 AS creditos
FROM transiciones
WHERE dias_entre_cortes BETWEEN 1 AND 10
GROUP BY bucket_anterior, bucket_mora, movimiento;


-- ============================================================================
-- V8. MEJOR MOMENTO DE CONTACTO
-- Responde: "que dia y a que hora se logra mas contacto efectivo".
-- Util para asignar turnos de los asesores.
-- ============================================================================
CREATE OR REPLACE VIEW vw_mejor_momento_contacto AS
SELECT
    d.nombre_dia,
    d.dia_semana,
    g.hora_del_dia,
    COUNT(*)                                                    AS gestiones,
    SUM(CASE WHEN g.es_gestion_efectiva THEN 1 ELSE 0 END)      AS gestiones_efectivas,
    ROUND(100.0 * SUM(CASE WHEN g.es_gestion_efectiva THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2)                             AS pct_efectividad,
    SUM(CASE WHEN g.es_pago THEN 1 ELSE 0 END)                  AS pagos,
    ROUND(100.0 * SUM(CASE WHEN g.es_pago THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2)                             AS pct_pago
FROM fct_gestiones g
JOIN dim_fecha d ON d.fecha_key = g.fecha_key
WHERE g.hora_del_dia IS NOT NULL
  AND d.es_fin_semana = FALSE
GROUP BY d.nombre_dia, d.dia_semana, g.hora_del_dia;


-- ============================================================================
-- V9. DESEMPENO POR ASESOR
-- ============================================================================
CREATE OR REPLACE VIEW vw_desempeno_asesor AS
SELECT
    a.asesor_id,
    COUNT(*)                                                       AS gestiones,
    COUNT(DISTINCT g.credito_id)                                   AS creditos_atendidos,
    SUM(CASE WHEN g.es_gestion_efectiva THEN 1 ELSE 0 END)         AS efectivas,
    ROUND(100.0 * SUM(CASE WHEN g.es_gestion_efectiva THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2)                                AS pct_efectividad,
    SUM(CASE WHEN g.es_pago THEN 1 ELSE 0 END)                     AS pagos,
    SUM(CASE WHEN g.es_promesa THEN 1 ELSE 0 END)                  AS promesas,
    ROUND(100.0 * SUM(CASE WHEN g.ptp_cumplida = 'SI' THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN g.es_promesa THEN 1 ELSE 0 END), 0), 2) AS pct_ptp_cumplida,
    SUM(g.monto_recuperado)                                        AS recuperado,
    ROUND(SUM(g.monto_recuperado) / NULLIF(COUNT(*), 0), 2)        AS recuperado_por_gestion
FROM fct_gestiones g
JOIN dim_asesor a ON a.asesor_key = g.asesor_key
GROUP BY a.asesor_id;


-- ============================================================================
-- V10. TABLERO RESUMEN (una fila con los KPIs principales)
-- Ideal para las tarjetas (cards) de la parte superior del tablero.
--
-- OJO CON LAS DEFINICIONES: fct_mora_diaria contiene SOLO creditos morosos (es un
-- snapshot de mora, no del portafolio completo). Por eso hay que distinguir:
--   - intensidad_mora_pct: del saldo de los clientes morosos, cuanto ya esta vencido.
--     Mide que tan profunda es la mora de quien ya debe.
--   - pct_mora_cartera_total: del saldo total del portafolio (todos los creditos,
--     vengan de cuotas o del snapshot), cuanto esta vencido. Es el indicador de
--     salud de cartera. Se calcula con fct_cuotas, que SI cubre todo el portafolio.
-- ============================================================================
CREATE OR REPLACE VIEW vw_kpis_principales AS
WITH ultimo_corte AS (
    SELECT MAX(fecha_corte) AS fecha_corte FROM fct_mora_diaria
),
mora AS (
    SELECT
        COUNT(DISTINCT m.credito_id) AS creditos_en_mora,
        SUM(m.saldo_vencido)         AS saldo_vencido_morosos,
        SUM(m.saldo_total)           AS saldo_total_morosos
    FROM fct_mora_diaria m
    JOIN ultimo_corte u ON u.fecha_corte = m.fecha_corte
),
cobranza AS (
    SELECT
        COUNT(*)                              AS gestiones_totales,
        SUM(monto_recuperado)                 AS recuperado_por_gestion,
        SUM(costo_gestion)                    AS costo_cobranza,
        SUM(CASE WHEN es_pago THEN 1 ELSE 0 END) AS pagos_logrados
    FROM fct_gestiones
),
cartera AS (
    -- Toda la cartera: facturado, recaudado y saldo por cobrar
    SELECT
        SUM(monto_cuota)  AS facturado,
        SUM(monto_pagado) AS recaudado,
        SUM(saldo_cuota)  AS saldo_por_cobrar,
        -- Saldo por cobrar EXCLUYENDO la deuda en castigo (>180 dias). La cartera
        -- castigada sigue viva para cobranza, pero se provisiona contablemente;
        -- la mora sobre la cartera vigente es el indicador de gestion.
        SUM(CASE WHEN dias_atraso <= 180 THEN saldo_cuota ELSE 0 END) AS saldo_por_cobrar_sin_castigo
    FROM fct_cuotas
),
castigados AS (
    -- Saldo vencido que corresponde a credito con castigo (>180 dias al corte)
    SELECT SUM(m.saldo_vencido) AS saldo_vencido_castigado
    FROM fct_mora_diaria m
    JOIN ultimo_corte u ON u.fecha_corte = m.fecha_corte
    WHERE m.elegible_castigo = 'SI'
),
ptp AS (
    SELECT
        COUNT(*) AS ptp_total,
        SUM(CASE WHEN ptp_cumplida = 'SI' THEN 1 ELSE 0 END) AS ptp_cumplidas
    FROM fct_gestiones WHERE es_promesa
),
clientes AS (
    SELECT
        COUNT(*) AS clientes_totales,
        SUM(CASE WHEN es_contactable THEN 1 ELSE 0 END) AS clientes_contactables
    FROM dim_cliente
)
SELECT
    u.fecha_corte                                       AS fecha_referencia,
    cl.clientes_totales,
    cl.clientes_contactables,
    ROUND(100.0 * cl.clientes_contactables / NULLIF(cl.clientes_totales, 0), 2) AS pct_contactabilidad,
    mo.creditos_en_mora,
    mo.saldo_vencido_morosos,
    mo.saldo_total_morosos,
    -- salud de la cartera: saldo vencido sobre saldo por cobrar de TODO el portafolio
    ca.saldo_por_cobrar,
    ROUND(100.0 * mo.saldo_vencido_morosos / NULLIF(ca.saldo_por_cobrar, 0), 2) AS pct_mora_cartera_total,
    -- el mismo indicador excluyendo la deuda en castigo (indicador de gestion)
    cas.saldo_vencido_castigado,
    ROUND(100.0 * (mo.saldo_vencido_morosos - COALESCE(cas.saldo_vencido_castigado, 0))
          / NULLIF(ca.saldo_por_cobrar_sin_castigo, 0), 2) AS pct_mora_cartera_sin_castigo,
    -- profundidad de la mora de quienes ya estan en mora
    ROUND(100.0 * mo.saldo_vencido_morosos / NULLIF(mo.saldo_total_morosos, 0), 2) AS pct_intensidad_mora,
    ca.facturado,
    ca.recaudado,
    ROUND(100.0 * ca.recaudado / NULLIF(ca.facturado, 0), 2)       AS pct_recuperacion_cartera,
    co.gestiones_totales,
    co.pagos_logrados,
    co.recuperado_por_gestion,
    co.costo_cobranza,
    ROUND(co.costo_cobranza / NULLIF(co.recuperado_por_gestion, 0), 4) AS costo_por_sol_recuperado,
    p.ptp_total,
    p.ptp_cumplidas,
    ROUND(100.0 * p.ptp_cumplidas / NULLIF(p.ptp_total, 0), 2)     AS pct_cumplimiento_ptp
FROM ultimo_corte u
CROSS JOIN mora mo
CROSS JOIN cobranza co
CROSS JOIN cartera ca
CROSS JOIN castigados cas
CROSS JOIN ptp p
CROSS JOIN clientes cl;


-- ============================================================================
-- VERIFICACION: prueba rapida de cada vista
-- ============================================================================
SELECT 'aging de cartera' AS vista, COUNT(*) AS filas FROM vw_aging_cartera
UNION ALL SELECT 'evolucion mora',       COUNT(*) FROM vw_evolucion_mora
UNION ALL SELECT 'efectividad canal',    COUNT(*) FROM vw_efectividad_canal
UNION ALL SELECT 'cumplimiento PTP',     COUNT(*) FROM vw_cumplimiento_ptp
UNION ALL SELECT 'recuperacion producto', COUNT(*) FROM vw_recuperacion_producto
UNION ALL SELECT 'cobertura gestion',    COUNT(*) FROM vw_cobertura_gestion
UNION ALL SELECT 'roll rate',            COUNT(*) FROM vw_roll_rate
UNION ALL SELECT 'mejor momento',        COUNT(*) FROM vw_mejor_momento_contacto
UNION ALL SELECT 'desempeno asesor',     COUNT(*) FROM vw_desempeno_asesor
UNION ALL SELECT 'kpis principales',     COUNT(*) FROM vw_kpis_principales;

-- Los KPIs de una sola pasada (lo primero que revisas)
SELECT * FROM vw_kpis_principales;

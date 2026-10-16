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

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

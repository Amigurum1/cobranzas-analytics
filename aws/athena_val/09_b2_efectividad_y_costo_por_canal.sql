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

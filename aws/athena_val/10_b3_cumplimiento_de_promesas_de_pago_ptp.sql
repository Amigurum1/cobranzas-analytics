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

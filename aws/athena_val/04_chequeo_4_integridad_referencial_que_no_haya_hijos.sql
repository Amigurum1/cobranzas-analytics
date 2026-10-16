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

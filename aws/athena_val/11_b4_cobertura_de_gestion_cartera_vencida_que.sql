-- B4. Cobertura de gestion: cartera vencida que NO tiene ninguna gestion
-- (el hallazgo que demuestra valor de negocio)
SELECT
    COUNT(DISTINCT c.credito_id)      AS creditos_sin_gestionar,
    ROUND(SUM(c.monto_cuota), 2)      AS saldo_sin_gestionar
FROM analitica_cobranzas.fact_cuotas c
LEFT JOIN analitica_cobranzas.fact_gestiones_cobranza g ON g.cuota_id = c.cuota_id
WHERE c.estado_cuota = 'VENCIDA' AND g.gestion_id IS NULL;

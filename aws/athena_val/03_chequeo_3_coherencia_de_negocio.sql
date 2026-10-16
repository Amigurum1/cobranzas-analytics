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

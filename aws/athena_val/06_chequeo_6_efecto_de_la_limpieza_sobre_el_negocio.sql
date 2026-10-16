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

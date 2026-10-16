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

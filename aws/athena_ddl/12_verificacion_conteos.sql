SELECT 'clientes'            AS tabla, COUNT(*) AS filas FROM analitica_cobranzas.raw_clientes
UNION ALL SELECT 'creditos',            COUNT(*) FROM analitica_cobranzas.raw_creditos
UNION ALL SELECT 'cuotas',              COUNT(*) FROM analitica_cobranzas.raw_cuotas
UNION ALL SELECT 'gestiones_cobranza',  COUNT(*) FROM analitica_cobranzas.raw_gestiones_cobranza
UNION ALL SELECT 'mora_snapshot',       COUNT(*) FROM analitica_cobranzas.raw_mora_snapshot;

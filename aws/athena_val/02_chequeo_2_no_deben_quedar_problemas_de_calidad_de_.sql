-- ===========================================================================
-- CHEQUEO 2: NO deben quedar problemas de calidad de los 7 originales
-- ===========================================================================
SELECT 'emails invalidos que sobrevivieron' AS chequeo, COUNT(*) AS debe_ser_cero
FROM analitica_cobranzas.dim_clientes
WHERE email IS NOT NULL AND NOT regexp_like(email, '^[^@\s]+@[^@\s]+\.[^@\s]+$')
UNION ALL
SELECT 'telefonos invalidos que sobrevivieron', COUNT(*)
FROM analitica_cobranzas.dim_clientes
WHERE telefono IS NOT NULL AND NOT regexp_like(telefono, '^9[0-9]{8}$')
UNION ALL
SELECT 'montos pagados negativos', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE monto_pagado < 0
UNION ALL
SELECT 'fechas de pago en el futuro', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE fecha_pago > current_date
UNION ALL
SELECT 'PAGADAS sin fecha de pago', COUNT(*)
FROM analitica_cobranzas.fact_cuotas
WHERE estado_cuota IN ('PAGADA','PAGADA_CON_ATRASO') AND fecha_pago IS NULL
UNION ALL
SELECT 'canales sin normalizar', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE canal <> upper(trim(canal))
UNION ALL
SELECT 'resultados sin normalizar', COUNT(*)
FROM analitica_cobranzas.fact_gestiones_cobranza
WHERE resultado <> upper(trim(resultado));

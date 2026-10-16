-- Distribucion de clientes segun si se les puede contactar
-- (indicador clave de cobranzas: si no puedes contactar, no puedes cobrar)
SELECT
    es_contactable,
    COUNT(*) AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS porcentaje
FROM analitica_cobranzas.dim_clientes
GROUP BY es_contactable;

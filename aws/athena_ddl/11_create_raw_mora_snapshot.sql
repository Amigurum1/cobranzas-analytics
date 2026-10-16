CREATE EXTERNAL TABLE analitica_cobranzas.raw_mora_snapshot (
    fecha_corte        STRING,
    credito_id         STRING,
    cliente_id         STRING,
    dias_atraso        STRING,
    bucket_mora        STRING,
    saldo_vencido      STRING,
    saldo_total        STRING,
    cuotas_vencidas    STRING,
    score_actual       STRING,
    elegible_castigo   STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/mora_snapshot/'
TBLPROPERTIES ('skip.header.line.count' = '1');

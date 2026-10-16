CREATE EXTERNAL TABLE analitica_cobranzas.raw_creditos (
    credito_id               STRING,
    cliente_id               STRING,
    producto                 STRING,
    producto_desc            STRING,
    monto_desembolsado       STRING,
    plazo_meses              STRING,
    tea                      STRING,
    cuota_mensual            STRING,
    fecha_desembolso         STRING,
    fecha_vencimiento_final  STRING,
    estado_credito           STRING,
    score_desembolso         STRING,
    oficina                  STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/creditos/'
TBLPROPERTIES ('skip.header.line.count' = '1');

CREATE EXTERNAL TABLE analitica_cobranzas.raw_clientes (
    cliente_id        STRING,
    nombre            STRING,
    documento         STRING,
    email             STRING,
    telefono          STRING,
    distrito          STRING,
    ingreso_mensual   STRING,
    score_inicial     STRING,
    fecha_alta        STRING,
    segmento          STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar'      = ',',
    'quoteChar'          = '"',
    'escapeChar'         = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/clientes/'
TBLPROPERTIES ('skip.header.line.count' = '1');

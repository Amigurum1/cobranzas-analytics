CREATE EXTERNAL TABLE analitica_cobranzas.raw_cuotas (
    cuota_id          STRING,
    credito_id        STRING,
    cliente_id        STRING,
    nro_cuota         STRING,
    fecha_vencimiento STRING,
    monto_cuota       STRING,
    monto_pagado      STRING,
    fecha_pago        STRING,
    estado_cuota      STRING,
    dias_atraso       STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/cuotas/'
TBLPROPERTIES ('skip.header.line.count' = '1');

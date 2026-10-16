CREATE EXTERNAL TABLE analitica_cobranzas.raw_gestiones_cobranza (
    gestion_id           STRING,
    credito_id           STRING,
    cliente_id           STRING,
    cuota_id             STRING,
    fecha_gestion        STRING,
    hora_gestion         STRING,
    canal                STRING,
    tipo_gestion         STRING,
    resultado            STRING,
    asesor_id            STRING,
    monto_promesa        STRING,
    fecha_promesa_pago   STRING,
    ptp_cumplida         STRING,
    monto_recuperado     STRING,
    duracion_seg         STRING,
    costo_gestion        STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"',
    'escapeChar'    = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://analitica-cobranzas-bruno-ps57hz/raw/gestiones_cobranza/'
TBLPROPERTIES ('skip.header.line.count' = '1');

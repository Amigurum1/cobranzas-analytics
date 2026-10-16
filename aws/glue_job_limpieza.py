# -*- coding: utf-8 -*-
"""
=============================================================================
JOB DE GLUE — Limpieza de la capa raw a la capa curated
Proyecto: Analitica de cobranzas - pipeline de datos en AWS
=============================================================================

Que hace:
  Lee las 5 tablas CSV de  s3://<bucket>/raw/          (con errores a proposito)
  Aplica las 7 reglas de limpieza + validaciones de coherencia
  Escribe Parquet particionado por anio en  s3://<bucket>/curated/

Por que Parquet: es columnar y comprime ~78% menos que el CSV. Eso reduce los
datos que escanea Athena y por lo tanto el costo (Athena cobra por TB leido).

NOTA IMPORTANTE sobre costos de Glue:
  Glue cobra por DPU-hora con MINIMO 2 DPU = $0.88/hora y redondeo a 1 minuto.
  Por eso este job se disena para correr en MENOS DE 1 MINUTO. Con 129 mil filas
  sobra capacidad. Si tu dataset crece mucho, ahi si sube el numero de workers.

Parametros del job (-- seguido del nombre):
  --JOB_NAME       lo inyecta Glue automaticamente
  --BUCKET         nombre del bucket S3
  --DATABASE       base de datos destino en el Glue Data Catalog
  --HOY            fecha de referencia para detectar pagos futuros (YYYY-MM-DD)

Ejemplo de invocacion:
  aws glue start-job-run --job-name analitica-cobranzas-limpieza \
      --arguments '{"--BUCKET":"mi-bucket","--DATABASE":"analitica_cobranzas","--HOY":"2026-09-28"}'
=============================================================================
"""

import sys
from datetime import date, datetime

from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import (DecimalType, IntegerType, DateType, StringType)

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
args = getResolvedOptions(sys.argv, ["JOB_NAME", "BUCKET", "DATABASE", "HOY"])

BUCKET = args["BUCKET"]
DATABASE = args["DATABASE"]
HOY = datetime.strptime(args["HOY"], "%Y-%m-%d").date()

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.parquet.compression.codec", "snappy")

RAW = "s3://%s/raw" % BUCKET
CURATED = "s3://%s/curated" % BUCKET

print("=" * 78)
print("JOB: %s" % args["JOB_NAME"])
print("ORIGEN : %s" % RAW)
print("DESTINO: %s" % CURATED)
print("FECHA DE REFERENCIA: %s" % HOY)
print("=" * 78)

REPORTE = []
CONTEOS = {}


def log(regla, detalle):
    REPORTE.append((regla, detalle))
    print("  [%s] %s" % (regla, detalle))


def leer_raw(tabla):
    """Lee un CSV de la capa raw: todo como STRING, sin validar (a proposito)."""
    ruta = "%s/%s/%s.csv" % (RAW, tabla, tabla)
    return (spark.read
            .option("header", "true")
            .option("quote", '"')
            .option("escape", '"')
            .option("multiLine", "false")
            .option("mode", "PERMISSIVE")
            .csv(ruta))


def escribir(df, tabla, particion=None):
    """Escribe Parquet en la capa curated (una sola escritura).

    El Glue Crawler es quien registra la tabla en el Data Catalog despues de
    correr este job. NO registramos aqui para no escribir los datos dos veces:
    en Glue eso costaria el doble de tiempo de DPU.
    """
    df = df.withColumn("_fecha_proceso", F.lit(str(HOY)).cast(DateType()))
    destino = "%s/%s/" % (CURATED, tabla)
    writer = df.write.mode("overwrite").format("parquet")
    if particion:
        writer = writer.partitionBy(particion)
    writer.save(destino)
    CONTEOS[tabla] = df.count()
    print("  -> escrito: %s (filas: %d)" % (destino, CONTEOS[tabla]))


# --- helper: convierte columna string a tipo
def a_int(c):
    return F.col(c).cast(IntegerType())


def a_dec(c, p=12, s=2):
    return F.col(c).cast(DecimalType(p, s))


def a_fecha(c):
    return F.to_date(F.col(c), "yyyy-MM-dd")


def norm(c):
    """Normaliza texto: quita espacios y unifica mayusculas."""
    return F.upper(F.trim(F.col(c)))


def nulo_si_vacio(c):
    return F.when(F.trim(F.col(c)) == "", None).otherwise(F.trim(F.col(c)))


# ===========================================================================
# 1. CLIENTES
# ===========================================================================
print("\n" + "=" * 78)
print("1. CLIENTES")
print("=" * 78)

cli = leer_raw("clientes")
n0 = cli.count()

# R1: duplicados exactos de cliente_id
cli = cli.dropDuplicates(["cliente_id"])

# R2 / R3: email y telefono validos -> banderas de calidad y contactabilidad
PATRON_EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
PATRON_TEL = r"^9[0-9]{8}$"

cli = (cli
       .withColumn("email_ok", F.col("email").rlike(PATRON_EMAIL))
       .withColumn("telefono_ok", F.col("telefono").rlike(PATRON_TEL))
       .withColumn("email_valido", F.col("email_ok"))
       .withColumn("telefono_valido", F.col("telefono_ok"))
       .withColumn("es_contactable", F.col("email_ok") | F.col("telefono_ok"))
       .withColumn("email", F.when(F.col("email_ok"), nulo_si_vacio("email")).otherwise(F.lit(None)))
       .withColumn("telefono", F.when(F.col("telefono_ok"), nulo_si_vacio("telefono")).otherwise(F.lit(None)))
       .withColumn("ingreso_mensual", a_dec("ingreso_mensual"))
       .withColumn("score_inicial", a_int("score_inicial"))
       .withColumn("fecha_alta", a_fecha("fecha_alta"))
       .withColumn("segmento", norm("segmento"))
       .drop("email_ok", "telefono_ok"))

n_contactables = cli.filter(F.col("es_contactable")).count()
log("R1", "duplicados de cliente_id: %d -> %d filas" % (n0, cli.count()))
log("R2/R3", "clientes contactables: %d de %d" % (n_contactables, cli.count()))

escribir(cli, "dim_clientes")

# ===========================================================================
# 2. CREDITOS
# ===========================================================================
print("\n" + "=" * 78)
print("2. CREDITOS")
print("=" * 78)

cre = leer_raw("creditos")
n0 = cre.count()

cre = (cre
       .dropDuplicates(["credito_id"])
       .withColumn("monto_desembolsado", a_dec("monto_desembolsado"))
       .withColumn("cuota_mensual", a_dec("cuota_mensual"))
       .withColumn("tea", a_dec("tea", 8, 4))
       .withColumn("plazo_meses", a_int("plazo_meses"))
       .withColumn("score_desembolso", a_int("score_desembolso"))
       .withColumn("fecha_desembolso", a_fecha("fecha_desembolso"))
       .withColumn("fecha_vencimiento_final", a_fecha("fecha_vencimiento_final"))
       .withColumn("estado_credito", norm("estado_credito"))
       .withColumn("producto", norm("producto")))

antes = cre.count()
cre = cre.filter(F.col("monto_desembolsado") > 0)
log("regla de negocio", "creditos con monto <= 0 descartados: %d" % (antes - cre.count()))

cre = cre.withColumn("anio", F.year("fecha_desembolso"))
escribir(cre, "fact_creditos", particion="anio")

# ===========================================================================
# 3. CUOTAS
# ===========================================================================
print("\n" + "=" * 78)
print("3. CUOTAS")
print("=" * 78)

cuo = leer_raw("cuotas")
n0 = cuo.count()

cuo = (cuo
       .withColumn("nro_cuota", a_int("nro_cuota"))
       .withColumn("monto_cuota", a_dec("monto_cuota"))
       .withColumn("monto_pagado", a_dec("monto_pagado"))
       .withColumn("dias_atraso", a_int("dias_atraso"))
       .withColumn("fecha_vencimiento", a_fecha("fecha_vencimiento"))
       .withColumn("fecha_pago", a_fecha("fecha_pago"))
       .withColumn("estado_cuota", norm("estado_cuota")))

# --- R5: monto_pagado negativo (error de signo) -> valor absoluto + bandera
cuo = (cuo
       .withColumn("monto_pagado_corregido", F.col("monto_pagado") < 0)
       .withColumn("monto_pagado", F.abs(F.col("monto_pagado"))))
neg = cuo.filter(F.col("monto_pagado_corregido")).count()
log("R5", "montos negativos corregidos con valor absoluto: %d" % neg)

# --- R4: fecha_pago en el futuro -> el pago todavia no ocurrio
#
# CUIDADO (bug real encontrado en Athena el 2026-09-30): la bandera se materializa
# como COLUMNA antes de usarla. Si en su lugar se reutiliza la expresion perezosa
# (F.col("fecha_pago") > HOY) en varios withColumn encadenados, Spark la reevalua
# contra el estado YA modificado: al dejar fecha_pago en NULL en el primer
# withColumn, la condicion pasa a NULL y los withColumn siguientes NO se aplican.
# Resultado que produjo: 137 cuotas con pago futuro quedaron con estado PAGADA y
# monto_pagado != 0 (S/ 67,501.45 contados como recaudados) y R6 les imputo fecha,
# dando 206 imputadas en lugar de 69. El ETL de pandas NO tenia el bug porque su
# mascara booleana ya estaba calculada.
cuo = cuo.withColumn("fecha_pago_futura_corregida",
                     F.col("fecha_pago") > F.lit(HOY).cast(DateType()))

cuo = (cuo
       .withColumn("fecha_pago", F.when(F.col("fecha_pago_futura_corregida"),
                                        F.lit(None).cast(DateType())).otherwise(F.col("fecha_pago")))
       .withColumn("monto_pagado", F.when(F.col("fecha_pago_futura_corregida"),
                                          F.lit(0).cast(DecimalType(12, 2))).otherwise(F.col("monto_pagado")))
       .withColumn("estado_cuota", F.when(F.col("fecha_pago_futura_corregida"),
                                          F.lit("VENCIDA")).otherwise(F.col("estado_cuota"))))
nf = cuo.filter(F.col("fecha_pago_futura_corregida")).count()
log("R4", "pagos futuros anulados y reclasificados a VENCIDA: %d" % nf)

# --- R6: PAGADA sin fecha de pago -> imputar vencimiento + dias_atraso
sin_fecha = (F.col("fecha_pago").isNull() &
             F.col("estado_cuota").isin("PAGADA", "PAGADA_CON_ATRASO"))
imputada = F.date_add(F.col("fecha_vencimiento"), F.coalesce(F.col("dias_atraso"), F.lit(0)))
cuo = (cuo
       .withColumn("fecha_pago_imputada", sin_fecha)
       .withColumn("fecha_pago", F.when(sin_fecha, imputada).otherwise(F.col("fecha_pago"))))
sf = cuo.filter(F.col("fecha_pago_imputada")).count()
log("R6", "fechas de pago imputadas: %d" % sf)

# --- Coherencia: recalcular dias_atraso desde las fechas (fuente de verdad)
dias_calc = F.datediff(F.coalesce(F.col("fecha_pago"), F.lit(HOY).cast(DateType())),
                       F.col("fecha_vencimiento"))
cuo = cuo.withColumn("dias_atraso_calculado", dias_calc)

cuo = (cuo
       .withColumn("pagada", F.col("estado_cuota").isin("PAGADA", "PAGADA_CON_ATRASO"))
       .withColumn("anio", F.year("fecha_vencimiento")))

escribir(cuo, "fact_cuotas", particion="anio")

# ===========================================================================
# 4. GESTIONES DE COBRANZA
# ===========================================================================
print("\n" + "=" * 78)
print("4. GESTIONES DE COBRANZA")
print("=" * 78)

ges = leer_raw("gestiones_cobranza")
n0 = ges.count()

# --- R7: normalizar canal y resultado
ges = (ges
       .withColumn("canal_formato_corregido",
                   F.col("canal") != F.upper(F.trim(F.col("canal"))))
       .withColumn("resultado_formato_corregido",
                   F.col("resultado") != F.upper(F.trim(F.col("resultado"))))
       .withColumn("canal", norm("canal"))
       .withColumn("resultado", norm("resultado")))

n_canal = ges.filter(F.col("canal_formato_corregido")).count()
n_res = ges.filter(F.col("resultado_formato_corregido")).count()
log("R7", "canal normalizados: %d | resultado normalizados: %d" % (n_canal, n_res))

ges = (ges
       .withColumn("fecha_gestion", a_fecha("fecha_gestion"))
       .withColumn("fecha_promesa_pago", a_fecha("fecha_promesa_pago"))
       .withColumn("monto_promesa", a_dec("monto_promesa"))
       .withColumn("monto_recuperado", F.coalesce(a_dec("monto_recuperado"), F.lit(0).cast(DecimalType(12, 2))))
       .withColumn("costo_gestion", F.coalesce(a_dec("costo_gestion"), F.lit(0).cast(DecimalType(12, 2))))
       .withColumn("duracion_seg", a_int("duracion_seg"))
       .withColumn("ptp_cumplida", norm("ptp_cumplida")))

# --- Coherencias de negocio
ptp_sin_fecha = ((F.col("resultado") == "PROMESA_PAGO") & F.col("fecha_promesa_pago").isNull())
log("coherencia PTP", "PROMESA_PAGO sin fecha de promesa: %d" % ges.filter(ptp_sin_fecha).count())

recup_sin_pago = ((F.col("monto_recuperado") > 0) &
                  ~F.col("resultado").isin("PAGO_TOTAL", "PAGO_PARCIAL"))
log("coherencia recuperacion", "monto recuperado sin resultado de pago: %d" % ges.filter(recup_sin_pago).count())

ges = (ges
       .withColumn("es_gestion_efectiva",
                   F.col("resultado").isin("PAGO_TOTAL", "PAGO_PARCIAL", "PROMESA_PAGO"))
       .withColumn("es_pago", F.col("resultado").isin("PAGO_TOTAL", "PAGO_PARCIAL"))
       .withColumn("anio", F.year("fecha_gestion")))

escribir(ges, "fact_gestiones_cobranza", particion="anio")

# ===========================================================================
# 5. MORA SNAPSHOT
# ===========================================================================
print("\n" + "=" * 78)
print("5. MORA SNAPSHOT")
print("=" * 78)

mor = leer_raw("mora_snapshot")
n0 = mor.count()

mor = (mor
       .dropDuplicates(["fecha_corte", "credito_id"])
       .withColumn("fecha_corte", a_fecha("fecha_corte"))
       .withColumn("dias_atraso", a_int("dias_atraso"))
       .withColumn("saldo_vencido", a_dec("saldo_vencido"))
       .withColumn("saldo_total", a_dec("saldo_total"))
       .withColumn("cuotas_vencidas", a_int("cuotas_vencidas"))
       .withColumn("score_actual", a_int("score_actual")))
log("duplicados", "por (fecha_corte, credito_id): %d -> %d" % (n0, mor.count()))

# --- Bucket recalculado desde los dias de atraso (el dato manda)
bucket_ok = (F.when(F.col("dias_atraso") <= 0, "PREVENTIVO")
             .when(F.col("dias_atraso") <= 30, "0-30")
             .when(F.col("dias_atraso") <= 60, "31-60")
             .when(F.col("dias_atraso") <= 90, "61-90")
             .when(F.col("dias_atraso") <= 180, "91-180")
             .otherwise("180+"))

incoherente = norm("bucket_mora") != bucket_ok
mor = (mor
       .withColumn("bucket_incoherente", incoherente)
       .withColumn("bucket_mora", bucket_ok))
log("coherencia bucket", "buckets recalculados: %d" % mor.filter(F.col("bucket_incoherente")).count())

# --- El saldo vencido no puede superar el saldo total
mor = mor.withColumn("saldo_incoherente", F.col("saldo_vencido") > F.col("saldo_total"))
log("coherencia saldos", "saldo_vencido > saldo_total: %d" % mor.filter(F.col("saldo_incoherente")).count())

# --- Elegibilidad de castigo derivada (>180 dias)
mor = mor.withColumn("elegible_castigo",
                     F.when(F.col("dias_atraso") > 180, "SI").otherwise("NO"))
mor = mor.withColumn("anio", F.year("fecha_corte"))

escribir(mor, "fact_mora_snapshot", particion="anio")

# ===========================================================================
# CIERRE
# ===========================================================================
print("\n" + "=" * 78)
print("REPORTE DE LIMPIEZA")
print("=" * 78)
for regla, detalle in REPORTE:
    print("  %-22s %s" % (regla, detalle))

print("\nTABLAS ESCRITAS EN LA CAPA CURATED")
print("-" * 78)
for tabla, filas in CONTEOS.items():
    print("  %-26s %8d filas" % (tabla, filas))
print("  %-26s %8d filas" % ("TOTAL", sum(CONTEOS.values())))

print("\nSIGUIENTE PASO: correr el Glue Crawler sobre s3://%s/curated/" % BUCKET)
print("para registrar las 5 tablas en el Data Catalog y consultarlas desde Athena.")
print("\nJob finalizado correctamente.")
job.commit()

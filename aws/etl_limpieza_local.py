# -*- coding: utf-8 -*-
"""
ETL de limpieza — PROTOTIPO LOCAL (pandas)
==========================================

Este script hace exactamente lo mismo que el job de Glue (PySpark), pero en local.
Se usa para PROBAR Y DEPURAR la logica de limpieza antes de subirla a AWS.

Por que importa: si depuras reglas de negocio dentro de Glue, cada iteracion cuesta
tiempo y dinero (2 DPU minimo, redondeo a 1 minuto). Depuras en local gratis.

Entrada : raw/*.csv            (capa raw, con errores a proposito)
Salida  : curated/<tabla>/     (Parquet, tipado correcto, particionado por anio)

Uso:
    python etl_limpieza_local.py
    python etl_limpieza_local.py --raw ..\\raw --out ..\\curated
"""

import argparse
import os
import shutil
import sys
from datetime import date

import pandas as pd

# ----------------------------------------------------------------------------- 
P = argparse.ArgumentParser()
P.add_argument("--raw", default="")
P.add_argument("--out", default="")
A = P.parse_args()

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
RAW = A.raw or os.path.join(ROOT, "raw")
OUT = A.out or os.path.join(ROOT, "curated")

HOY = pd.Timestamp(date.today())

# ----------------------------------------------------------------------------- 
# Utilidades
# ----------------------------------------------------------------------------- 
def leer(nombre):
    """Lee un CSV de la capa raw como texto puro (sin inferencia de tipos)."""
    return pd.read_csv(os.path.join(RAW, nombre + ".csv"), dtype=str, keep_default_na=False)


def a_fecha(serie):
    return pd.to_datetime(serie.replace("", None), errors="coerce")


def a_decimal(serie):
    return pd.to_numeric(serie.replace("", None), errors="coerce")


def normalizar(serie):
    """R7: unifica mayusculas, minusculas y espacios sobrantes."""
    return serie.str.strip().str.upper().replace("", None)


REPORTE = []


def registrar(regla, antes, despues, detalle=""):
    REPORTE.append({
        "regla": regla,
        "filas_antes": antes,
        "filas_despues": despues,
        "filas_afectadas": antes - despues if despues is not None else None,
        "detalle": detalle,
    })


def guardar(df, tabla, particion=None):
    """Escribe Parquet particionado (mismo esquema que escribira Glue).

    IDEMPOTENCIA: se borra la carpeta destino antes de escribir. Es obligatorio
    porque pandas genera un nombre de archivo con UUID distinto en cada corrida:
    sin el borrado, cada ejecucion ACUMULA archivos y los conteos se duplican
    silenciosamente. Es el mismo motivo por el que el job de Glue usa
    mode("overwrite").
    """
    destino = os.path.join(OUT, tabla)
    if os.path.isdir(destino):
        shutil.rmtree(destino)
    os.makedirs(destino, exist_ok=True)
    if particion and particion in df.columns:
        df.to_parquet(destino, engine="pyarrow", index=False,
                      partition_cols=[particion])
    else:
        df.to_parquet(os.path.join(destino, "part-0000.parquet"),
                      engine="pyarrow", index=False)
    return destino


# =============================================================================
# 1. CLIENTES
# =============================================================================
print("=" * 78)
print("LIMPIANDO: clientes")
print("=" * 78)

cli = leer("clientes")
n0 = len(cli)

# R1: duplicados exactos -> quedarse con una fila por cliente_id
cli = cli.drop_duplicates(subset=["cliente_id"], keep="first")
registrar("R1 duplicados exactos de cliente_id", n0, len(cli),
          "se conserva 1 fila por cliente")

# R2: email invalido -> NULL + bandera
PATRON_EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
email_ok = cli["email"].str.match(PATRON_EMAIL, na=False)
cli["email_valido"] = email_ok
cli.loc[~email_ok, "email"] = None

# R3: telefono invalido -> NULL + bandera de contactabilidad
PATRON_TEL = r"^9\d{8}$"
tel_ok = cli["telefono"].str.match(PATRON_TEL, na=False)
cli["telefono_valido"] = tel_ok
cli["es_contactable"] = tel_ok | email_ok
cli.loc[~tel_ok, "telefono"] = None

registrar("R2/R3 email y telefono invalidos", len(cli), len(cli),
          "email invalidos=%d | telefonos invalidos=%d | contactables=%d"
          % ((~email_ok).sum(), (~tel_ok).sum(), cli.es_contactable.sum()))

# Tipado
cli["ingreso_mensual"] = a_decimal(cli["ingreso_mensual"])
cli["score_inicial"] = pd.to_numeric(cli["score_inicial"], errors="coerce").astype("Int32")
cli["fecha_alta"] = a_fecha(cli["fecha_alta"])
cli["segmento"] = normalizar(cli["segmento"])

guardar(cli, "dim_clientes")
print("  filas: %d -> %d" % (n0, len(cli)))

# =============================================================================
# 2. CREDITOS
# =============================================================================
print("=" * 78)
print("LIMPIANDO: creditos")
print("=" * 78)

cre = leer("creditos")
n0 = len(cre)
cre = cre.drop_duplicates(subset=["credito_id"], keep="first")

cre["monto_desembolsado"] = a_decimal(cre["monto_desembolsado"])
cre["cuota_mensual"] = a_decimal(cre["cuota_mensual"])
cre["tea"] = a_decimal(cre["tea"])
cre["plazo_meses"] = pd.to_numeric(cre["plazo_meses"], errors="coerce").astype("Int32")
cre["score_desembolso"] = pd.to_numeric(cre["score_desembolso"], errors="coerce").astype("Int32")
cre["fecha_desembolso"] = a_fecha(cre["fecha_desembolso"])
cre["fecha_vencimiento_final"] = a_fecha(cre["fecha_vencimiento_final"])
cre["estado_credito"] = normalizar(cre["estado_credito"])
cre["producto"] = normalizar(cre["producto"])

# Regla de negocio: un monto desembolsado no puede ser <= 0
malos = cre["monto_desembolsado"] <= 0
registrar("creditos con monto <= 0", len(cre), len(cre) - malos.sum(),
          "se descartan %d filas inviables" % malos.sum())
cre = cre[~malos]

# Particion por anio de desembolso
cre["anio"] = cre["fecha_desembolso"].dt.year
guardar(cre, "fact_creditos", particion="anio")
print("  filas: %d -> %d" % (n0, len(cre)))

# =============================================================================
# 3. CUOTAS  (aqui estan las reglas mas delicadas)
# =============================================================================
print("=" * 78)
print("LIMPIANDO: cuotas")
print("=" * 78)

cuo = leer("cuotas")
n0 = len(cuo)

cuo["nro_cuota"] = pd.to_numeric(cuo["nro_cuota"], errors="coerce").astype("Int32")
cuo["monto_cuota"] = a_decimal(cuo["monto_cuota"])
cuo["monto_pagado"] = a_decimal(cuo["monto_pagado"])
cuo["dias_atraso"] = pd.to_numeric(cuo["dias_atraso"], errors="coerce").astype("Int32")
cuo["fecha_vencimiento"] = a_fecha(cuo["fecha_vencimiento"])
cuo["fecha_pago"] = a_fecha(cuo["fecha_pago"])
cuo["estado_cuota"] = normalizar(cuo["estado_cuota"])

# --- R5: monto_pagado negativo -> error de signo, se corrige con abs() + bandera
neg = cuo["monto_pagado"] < 0
cuo["monto_pagado_corregido"] = neg
cuo.loc[neg, "monto_pagado"] = cuo.loc[neg, "monto_pagado"].abs()
registrar("R5 monto_pagado negativo", n0, n0,
          "%d filas: se aplica valor absoluto y se marca la bandera" % neg.sum())

# --- R4: fecha_pago en el futuro -> el pago NO ha ocurrido todavia
fut = cuo["fecha_pago"] > HOY
cuo["fecha_pago_futura_corregida"] = fut
cuo.loc[fut, "fecha_pago"] = pd.NaT
cuo.loc[fut, "monto_pagado"] = 0.0
cuo.loc[fut, "estado_cuota"] = "VENCIDA"
registrar("R4 fecha_pago en el futuro", n0, n0,
          "%d filas: se anula el pago y se reclasifica a VENCIDA" % fut.sum())

# --- R6: PAGADA sin fecha de pago -> imputar con vencimiento + dias_atraso
sin_fecha = cuo["fecha_pago"].isna() & cuo["estado_cuota"].isin(["PAGADA", "PAGADA_CON_ATRASO"])
imputada = cuo["fecha_vencimiento"] + pd.to_timedelta(cuo["dias_atraso"].fillna(0), unit="D")
cuo.loc[sin_fecha, "fecha_pago"] = imputada[sin_fecha]
cuo["fecha_pago_imputada"] = sin_fecha
registrar("R6 PAGADA sin fecha_pago", n0, n0,
          "%d filas: fecha imputada = vencimiento + dias_atraso" % sin_fecha.sum())

# --- Coherencia final: recalcular dias_atraso desde las fechas (fuente de verdad)
dias_calc = (cuo["fecha_pago"].fillna(HOY) - cuo["fecha_vencimiento"]).dt.days
cuo["dias_atraso_calculado"] = dias_calc.astype("Int32")
desv = (cuo["dias_atraso"] - cuo["dias_atraso_calculado"]).abs() > 1
registrar("coherencia dias_atraso vs fechas", n0, n0,
          "%d filas con desviacion > 1 dia" % desv.sum())

cuo["pagada"] = cuo["estado_cuota"].isin(["PAGADA", "PAGADA_CON_ATRASO"])
cuo["anio"] = cuo["fecha_vencimiento"].dt.year
guardar(cuo, "fact_cuotas", particion="anio")
print("  filas: %d" % len(cuo))

# =============================================================================
# 4. GESTIONES DE COBRANZA
# =============================================================================
print("=" * 78)
print("LIMPIANDO: gestiones_cobranza")
print("=" * 78)

ges = leer("gestiones_cobranza")
n0 = len(ges)

# --- R7: normalizar canal y resultado (mayusculas/minusculas/espacios)
canal_mal = ges["canal"] != ges["canal"].str.strip().str.upper()
res_mal = ges["resultado"] != ges["resultado"].str.strip().str.upper()
ges["canal_formato_corregido"] = canal_mal
ges["resultado_formato_corregido"] = res_mal
ges["canal"] = normalizar(ges["canal"])
ges["resultado"] = normalizar(ges["resultado"])
registrar("R7 formato de canal/resultado", n0, n0,
          "%d canales y %d resultados normalizados" % (canal_mal.sum(), res_mal.sum()))

ges["fecha_gestion"] = a_fecha(ges["fecha_gestion"])
ges["fecha_promesa_pago"] = a_fecha(ges["fecha_promesa_pago"])
ges["monto_promesa"] = a_decimal(ges["monto_promesa"])
ges["monto_recuperado"] = a_decimal(ges["monto_recuperado"]).fillna(0.0)
ges["costo_gestion"] = a_decimal(ges["costo_gestion"]).fillna(0.0)
ges["duracion_seg"] = pd.to_numeric(ges["duracion_seg"], errors="coerce").astype("Int32")
ges["ptp_cumplida"] = normalizar(ges["ptp_cumplida"])

# --- Coherencia de negocio: solo hay PTP si hay fecha de promesa
incoherente = (ges["resultado"] == "PROMESA_PAGO") & ges["fecha_promesa_pago"].isna()
registrar("coherencia PROMESA_PAGO vs fecha_promesa", n0, n0,
          "%d filas con PROMESA_PAGO sin fecha de promesa" % incoherente.sum())

# --- Recuperacion: solo puede haber monto recuperado si el resultado es un pago
incoherente2 = (ges["monto_recuperado"] > 0) & ~ges["resultado"].isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
registrar("coherencia monto_recuperado vs resultado", n0, n0,
          "%d filas con monto recuperado sin resultado de pago" % incoherente2.sum())

ges["es_gestion_efectiva"] = ges["resultado"].isin(["PAGO_TOTAL", "PAGO_PARCIAL", "PROMESA_PAGO"])
ges["es_pago"] = ges["resultado"].isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
ges["anio"] = ges["fecha_gestion"].dt.year
guardar(ges, "fact_gestiones_cobranza", particion="anio")
print("  filas: %d" % len(ges))

# =============================================================================
# 5. MORA SNAPSHOT
# =============================================================================
print("=" * 78)
print("LIMPIANDO: mora_snapshot")
print("=" * 78)

mor = leer("mora_snapshot")
n0 = len(mor)

# La fecha de corte es la clave de particion logica del snapshot
mor = mor.drop_duplicates(subset=["fecha_corte", "credito_id"], keep="first")
registrar("duplicados por (fecha_corte, credito_id)", n0, len(mor), "")

mor["fecha_corte"] = a_fecha(mor["fecha_corte"])
mor["dias_atraso"] = pd.to_numeric(mor["dias_atraso"], errors="coerce").astype("Int32")
mor["saldo_vencido"] = a_decimal(mor["saldo_vencido"])
mor["saldo_total"] = a_decimal(mor["saldo_total"])
mor["cuotas_vencidas"] = pd.to_numeric(mor["cuotas_vencidas"], errors="coerce").astype("Int32")
mor["score_actual"] = pd.to_numeric(mor["score_actual"], errors="coerce").astype("Int32")
mor["bucket_mora"] = normalizar(mor["bucket_mora"])
mor["elegible_castigo"] = normalizar(mor["elegible_castigo"])

# --- Regla: el bucket debe ser coherente con los dias de atraso
def bucket_de(d):
    if pd.isna(d):
        return None
    if d <= 0:
        return "PREVENTIVO"
    if d <= 30:
        return "0-30"
    if d <= 60:
        return "31-60"
    if d <= 90:
        return "61-90"
    if d <= 180:
        return "91-180"
    return "180+"

bucket_ok = mor.apply(lambda r: bucket_de(r["dias_atraso"]), axis=1)
incoherente = bucket_ok != mor["bucket_mora"]
mor["bucket_recalculado"] = incoherente
mor["bucket_mora"] = bucket_ok
registrar("coherencia bucket_mora vs dias_atraso", n0, len(mor),
          "%d filas con bucket incorrecto, recalculado" % incoherente.sum())

# --- Regla: el saldo vencido no puede superar el saldo total
excede = mor["saldo_vencido"] > mor["saldo_total"]
mor["saldo_incoherente"] = excede
registrar("saldo_vencido > saldo_total", n0, len(mor),
          "%d filas incoherentes" % excede.sum())

# --- Regla: elegible_castigo debe derivarse de los dias (>180)
castigo_ok = mor["dias_atraso"] > 180
mor["elegible_castigo"] = castigo_ok.map({True: "SI", False: "NO"})

mor["anio"] = mor["fecha_corte"].dt.year
guardar(mor, "fact_mora_snapshot", particion="anio")
print("  filas: %d -> %d" % (n0, len(mor)))

# =============================================================================
# REPORTE DE CALIDAD
# =============================================================================
print()
print("=" * 78)
print("REPORTE DE CALIDAD DEL DATO (raw -> curated)")
print("=" * 78)

rep = pd.DataFrame(REPORTE)
print(rep.to_string(index=False))
rep.to_csv(os.path.join(ROOT, "reporte_calidad.csv"), index=False, encoding="utf-8")

print()
print("=" * 78)
print("RESUMEN DE SALIDA")
print("=" * 78)
for t in ["dim_clientes", "fact_creditos", "fact_cuotas",
          "fact_gestiones_cobranza", "fact_mora_snapshot"]:
    d = os.path.join(OUT, t)
    if not os.path.isdir(d):
        continue
    total = 0
    partes = 0
    for raiz, _, archivos in os.walk(d):
        for a in archivos:
            if a.endswith(".parquet"):
                partes += 1
                total += os.path.getsize(os.path.join(raiz, a))
    print("  %-26s %6d archivos  %8.2f MB" % (t, partes, total / 1024 / 1024))

raw_mb = sum(os.path.getsize(os.path.join(RAW, f)) for f in os.listdir(RAW)) / 1024 / 1024
cur_mb = sum(os.path.getsize(os.path.join(r, a))
             for r, _, fs in os.walk(OUT) for a in fs) / 1024 / 1024
print()
print("  CSV crudo   : %6.2f MB" % raw_mb)
print("  Parquet     : %6.2f MB   (%.0f%% menos)" % (cur_mb, 100 * (1 - cur_mb / raw_mb)))
print()
print("  Reporte guardado en: reporte_calidad.csv")
print("  Datos curados en   : %s" % OUT)

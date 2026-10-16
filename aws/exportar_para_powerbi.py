# -*- coding: utf-8 -*-
"""
Exporta el modelo estrella en formato Power BI y CALCULA lo que devolveran las
10 vistas de negocio.

Dos usos:
  1. Permite montar el tablero en Power BI Desktop GRATIS y hoy, sin esperar a
     tener Redshift encendido (que cuesta $1.50/hora).
  2. Verifica que la logica de las vistas 07_redshift_vistas_negocio.sql sea
     correcta: los numeros de aqui deben coincidir con los que devuelva Redshift.

Salida: ../powerbi/  con un CSV por tabla y un resumen de KPIs en texto.

Uso: python exportar_para_powerbi.py
"""

import glob
import os
from datetime import timedelta

import pandas as pd

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
CUR = os.path.join(ROOT, "curated")
OUT = os.path.join(ROOT, "powerbi")
os.makedirs(OUT, exist_ok=True)

RESUMEN = []


def titulo(t):
    print("\n" + "=" * 78)
    print(t)
    print("=" * 78)
    RESUMEN.append("\n" + "=" * 78 + "\n" + t + "\n" + "=" * 78)


def leer(tabla):
    archivos = glob.glob(os.path.join(CUR, tabla, "**", "*.parquet"), recursive=True)
    if not archivos:
        raise SystemExit("Falta curated/%s. Corre etl_limpieza_local.py primero." % tabla)
    return pd.concat([pd.read_parquet(a) for a in archivos], ignore_index=True)


def guardar(df, nombre):
    ruta = os.path.join(OUT, nombre + ".csv")
    df.to_csv(ruta, index=False, encoding="utf-8-sig")   # utf-8-sig: Excel y Power BI lo leen bien
    print("  %-28s %7d filas" % (nombre + ".csv", len(df)))


# =============================================================================
# 1. DIMENSIONES
# =============================================================================
titulo("1. DIMENSIONES")

cli = leer("dim_clientes")
cre = leer("fact_creditos")
cuo = leer("fact_cuotas")
ges = leer("fact_gestiones_cobranza")
mor = leer("fact_mora_snapshot")

dim_cliente = cli[["cliente_id", "nombre", "documento", "distrito", "segmento",
                   "ingreso_mensual", "score_inicial", "fecha_alta",
                   "es_contactable", "email_valido", "telefono_valido"]].copy()
dim_cliente.insert(0, "cliente_key", range(1, len(dim_cliente) + 1))
dim_cliente["rango_ingreso"] = pd.cut(
    dim_cliente.ingreso_mensual, bins=[-1, 1500, 2500, 4000, 10**9],
    labels=["MENOS DE 1.5K", "1.5K A 2.5K", "2.5K A 4K", "MAS DE 4K"]).astype(str)
dim_cliente["rango_score"] = pd.cut(
    dim_cliente.score_inicial, bins=[-1, 500, 600, 700, 1000],
    labels=["MUY BAJO (<500)", "BAJO (500-599)", "MEDIO (600-699)", "BUENO (700+)"]).astype(str)
guardar(dim_cliente, "dim_cliente")

dim_credito = cre[["credito_id", "cliente_id", "producto", "producto_desc", "oficina",
                   "plazo_meses", "tea", "monto_desembolsado", "cuota_mensual",
                   "fecha_desembolso", "estado_credito", "score_desembolso"]].copy()
dim_credito.insert(0, "credito_key", range(1, len(dim_credito) + 1))
dim_credito["anio_desembolso"] = pd.to_datetime(dim_credito.fecha_desembolso).dt.year
dim_credito["rango_plazo"] = pd.cut(
    dim_credito.plazo_meses, bins=[0, 6, 12, 24, 100],
    labels=["CORTO (<=6)", "MEDIO (7-12)", "LARGO (13-24)", "MUY LARGO (25+)"]).astype(str)
dim_credito["rango_monto"] = pd.cut(
    dim_credito.monto_desembolsado, bins=[-1, 1000, 3000, 7000, 10**9],
    labels=["MENOS DE 1K", "1K A 3K", "3K A 7K", "MAS DE 7K"]).astype(str)
guardar(dim_credito, "dim_credito")

# --- dim_fecha: cubre todo el rango presente en los datos
# OJO: hay que incluir TODAS las columnas de fecha que el modelo relaciona con
# dim_fecha. Si falta una, los hechos de esas fechas quedan huerfanos y en Power BI
# aparecen en blanco. Faltaba fecha_desembolso: dejaba 440 creditos (7.04%) fuera.
fechas = pd.to_datetime(pd.concat([
    pd.to_datetime(cuo.fecha_vencimiento), pd.to_datetime(cuo.fecha_pago),
    pd.to_datetime(ges.fecha_gestion), pd.to_datetime(ges.fecha_promesa_pago),
    pd.to_datetime(mor.fecha_corte),
    pd.to_datetime(dim_credito.fecha_desembolso),
]).dropna().unique())
rango = pd.date_range(fechas.min(), fechas.max(), freq="D")
dim_fecha = pd.DataFrame({"fecha": rango})
dim_fecha["fecha_key"] = dim_fecha.fecha.dt.strftime("%Y%m%d").astype(int)
dim_fecha["anio"] = dim_fecha.fecha.dt.year
dim_fecha["trimestre"] = dim_fecha.fecha.dt.quarter
dim_fecha["mes"] = dim_fecha.fecha.dt.month
dim_fecha["nombre_mes"] = dim_fecha.fecha.dt.month_name()
dim_fecha["dia"] = dim_fecha.fecha.dt.day
# dayofweek en pandas: 0=lunes ... 6=domingo. Redshift usa EXTRACT(DOW), que
# devuelve 0=domingo ... 6=sabado (NO soporta ISODOW). Se alinea a esa escala
# para que el tablero y Redshift den el mismo valor.
dim_fecha["dia_semana"] = (dim_fecha.fecha.dt.dayofweek + 1) % 7
dim_fecha["nombre_dia"] = dim_fecha.fecha.dt.day_name()
dim_fecha["es_fin_semana"] = dim_fecha.dia_semana.isin([0, 6])
dim_fecha["anio_mes"] = dim_fecha.fecha.dt.strftime("%Y-%m")
dim_fecha["fecha"] = dim_fecha.fecha.dt.strftime("%Y-%m-%d")
guardar(dim_fecha, "dim_fecha")

dim_canal = ges[["canal"]].drop_duplicates().sort_values("canal").reset_index(drop=True)
dim_canal.insert(0, "canal_key", range(1, len(dim_canal) + 1))
dim_canal["es_digital"] = dim_canal.canal.isin(["SMS", "EMAIL", "WHATSAPP"])
dim_canal["es_presencial"] = dim_canal.canal.eq("VISITA")
dim_canal["es_autogestionado"] = dim_canal.canal.isin(["SMS", "EMAIL", "CARTA"])
dim_canal["es_bidireccional"] = dim_canal.canal.isin(["LLAMADA", "WHATSAPP", "VISITA"])
guardar(dim_canal, "dim_canal")

dim_resultado = ges[["resultado"]].drop_duplicates().sort_values("resultado").reset_index(drop=True)
dim_resultado.insert(0, "resultado_key", range(1, len(dim_resultado) + 1))


def grupo_resultado(r):
    if r in ("PAGO_TOTAL", "PAGO_PARCIAL"):
        return "PAGO"
    if r == "PROMESA_PAGO":
        return "PROMESA"
    if r == "CONTACTADO":
        return "CONTACTO"
    if r in ("RECHAZA_PAGO", "CLIENTE_MOLESTO"):
        return "RECHAZO"
    if r == "NUMERO_INVALIDO":
        return "DATO_INVALIDO"
    return "SIN_CONTACTO"


dim_resultado["grupo"] = dim_resultado.resultado.map(grupo_resultado)
dim_resultado["es_pago"] = dim_resultado.resultado.isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
dim_resultado["es_promesa"] = dim_resultado.resultado.eq("PROMESA_PAGO")
dim_resultado["es_contacto"] = dim_resultado.resultado.isin(
    ["CONTACTADO", "PAGO_TOTAL", "PAGO_PARCIAL", "PROMESA_PAGO", "RECHAZA_PAGO", "CLIENTE_MOLESTO"])
guardar(dim_resultado, "dim_resultado")

dim_tipo = ges[["tipo_gestion"]].drop_duplicates().sort_values("tipo_gestion").reset_index(drop=True)
dim_tipo.insert(0, "tipo_gestion_key", range(1, len(dim_tipo) + 1))
etapas = {"RECORDATORIO": "PREVENTIVA", "GESTION_PREVENTIVA": "PREVENTIVA",
          "GESTION_TEMPRANA": "TEMPRANA", "GESTION_MORA": "MORA",
          "NEGOCIACION": "NEGOCIACION", "COBRANZA_JUDICIAL": "JUDICIAL"}
dim_tipo["etapa"] = dim_tipo.tipo_gestion.map(etapas).fillna("OTRA")
guardar(dim_tipo, "dim_tipo_gestion")

dim_asesor = ges[["asesor_id"]].dropna().drop_duplicates().sort_values("asesor_id").reset_index(drop=True)
dim_asesor.insert(0, "asesor_key", range(1, len(dim_asesor) + 1))
guardar(dim_asesor, "dim_asesor")

# =============================================================================
# 2. HECHOS
# =============================================================================
titulo("2. TABLAS DE HECHOS")

fct_ges = (ges
           .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
           .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left")
           .merge(dim_canal[["canal", "canal_key"]], on="canal", how="left")
           .merge(dim_resultado[["resultado", "resultado_key"]], on="resultado", how="left")
           .merge(dim_tipo[["tipo_gestion", "tipo_gestion_key"]], on="tipo_gestion", how="left")
           .merge(dim_asesor[["asesor_id", "asesor_key"]], on="asesor_id", how="left"))
fct_ges["fecha_key"] = pd.to_datetime(fct_ges.fecha_gestion).dt.strftime("%Y%m%d").astype("Int64")
fct_ges["hora_del_dia"] = pd.to_numeric(fct_ges.hora_gestion.str.split(":").str[0], errors="coerce")
fct_ges["dias_para_promesa"] = (
    pd.to_datetime(fct_ges.fecha_promesa_pago) - pd.to_datetime(fct_ges.fecha_gestion)).dt.days
fct_ges["es_pago"] = fct_ges.resultado.isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
fct_ges["es_promesa"] = fct_ges.resultado.eq("PROMESA_PAGO")
fct_ges = fct_ges[["gestion_id", "credito_key", "cliente_key", "fecha_key", "canal_key",
                   "resultado_key", "tipo_gestion_key", "asesor_key", "credito_id", "cuota_id",
                   "fecha_gestion", "hora_gestion", "hora_del_dia", "monto_promesa",
                   "fecha_promesa_pago", "dias_para_promesa", "ptp_cumplida",
                   "monto_recuperado", "costo_gestion", "duracion_seg",
                   "es_pago", "es_promesa", "es_gestion_efectiva"]]
guardar(fct_ges, "fct_gestiones")

fct_mor = (mor
           .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
           .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left"))
fct_mor["fecha_key"] = pd.to_datetime(fct_mor.fecha_corte).dt.strftime("%Y%m%d").astype("Int64")
fct_mor["orden_bucket"] = fct_mor.bucket_mora.map(
    {"0-30": 1, "31-60": 2, "61-90": 3, "91-180": 4, "180+": 5}).fillna(0).astype(int)
fct_mor = fct_mor[["credito_key", "cliente_key", "fecha_key", "credito_id", "cliente_id",
                   "fecha_corte", "dias_atraso", "bucket_mora", "saldo_vencido", "saldo_total",
                   "cuotas_vencidas", "score_actual", "elegible_castigo", "orden_bucket"]]
guardar(fct_mor, "fct_mora_diaria")

fct_cuo = (cuo
           .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
           .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left"))
fct_cuo["fecha_vencimiento_key"] = pd.to_datetime(
    fct_cuo.fecha_vencimiento).dt.strftime("%Y%m%d").astype("Int64")
fct_cuo["fecha_pago_key"] = pd.to_datetime(
    fct_cuo.fecha_pago).dt.strftime("%Y%m%d").astype("Int64")
fct_cuo["saldo_cuota"] = fct_cuo.monto_cuota - fct_cuo.monto_pagado
fct_cuo["pago_puntual"] = fct_cuo.pagada & (fct_cuo.dias_atraso <= 0)
fct_cuo = fct_cuo[["cuota_id", "credito_key", "cliente_key", "fecha_vencimiento_key",
                   "fecha_pago_key", "credito_id", "nro_cuota", "fecha_vencimiento",
                   "fecha_pago", "monto_cuota", "monto_pagado", "saldo_cuota", "dias_atraso",
                   "estado_cuota", "pagada", "pago_puntual", "monto_pagado_corregido",
                   "fecha_pago_futura_corregida", "fecha_pago_imputada"]]
guardar(fct_cuo, "fct_cuotas")

# =============================================================================
# 3. LO QUE DEVOLVERAN LAS 10 VISTAS (verificacion de la logica SQL)
# =============================================================================
titulo("3. VISTAS DE NEGOCIO — valores esperados en Redshift")

# --- V1 aging
ultimo = fct_mor.fecha_corte.max()
aging = (fct_mor[fct_mor.fecha_corte == ultimo]
         .groupby(["bucket_mora", "orden_bucket"])
         .agg(creditos=("credito_id", "nunique"),
              clientes=("cliente_id", "nunique"),
              saldo_vencido=("saldo_vencido", "sum"),
              saldo_total=("saldo_total", "sum"),
              promedio_dias=("dias_atraso", "mean"),
              max_dias=("dias_atraso", "max"))
         .reset_index().sort_values("orden_bucket"))
aging["pct_participacion"] = (100 * aging.saldo_vencido / aging.saldo_vencido.sum()).round(2)
aging["fecha_corte"] = ultimo
guardar(aging, "vw_aging_cartera")
titulo("V1 AGING DE CARTERA  (corte %s)" % str(ultimo)[:10])
for _, r in aging.iterrows():
    print("  %-9s %4d creditos  S/ %11s  %5.2f%%  dias prom %3.0f"
          % (r.bucket_mora, r.creditos, "{:,.0f}".format(r.saldo_vencido),
             r.pct_participacion, r.promedio_dias))

# --- V2 evolucion diaria
evol = (fct_mor.groupby("fecha_corte")
        .agg(creditos_en_mora=("credito_id", "nunique"), saldo_vencido=("saldo_vencido", "sum"))
        .reset_index().sort_values("fecha_corte"))
for b in ["0-30", "31-60", "61-90", "91-180", "180+"]:
    col = "s_" + b.replace("-", "_").replace("+", "_mas")
    sub = fct_mor[fct_mor.bucket_mora == b].groupby("fecha_corte").saldo_vencido.sum()
    evol[col] = evol.fecha_corte.map(sub).fillna(0)
evol["pct_mora_mayor_60d"] = (100 * evol[["s_61_90", "s_91_180", "s_180_mas"]].sum(axis=1)
                              / evol.saldo_vencido.replace(0, pd.NA)).round(2)
guardar(evol, "vw_evolucion_mora")
titulo("V2 EVOLUCION DE LA MORA (ultimos 5 cortes)")
for _, r in evol.tail(5).iterrows():
    print("  %s  %4d creditos  S/ %11s  mora>60d: %5.2f%%"
          % (str(r.fecha_corte)[:10], r.creditos_en_mora,
             "{:,.0f}".format(r.saldo_vencido), r.pct_mora_mayor_60d))

# --- V3 efectividad por canal
canal = (fct_ges.merge(dim_canal, on="canal_key")
         .groupby(["canal", "es_digital", "es_bidireccional"])
         .agg(gestiones=("gestion_id", "count"),
              creditos=("credito_id", "nunique"),
              asesores=("asesor_key", "nunique"),
              contactos=("resultado_key", lambda s: 0),
              pagos=("es_pago", "sum"),
              promesas=("es_promesa", "sum"),
              costo=("costo_gestion", "sum"),
              recuperado=("monto_recuperado", "sum"),
              duracion=("duracion_seg", "mean"))
         .reset_index())
canal["pct_pago"] = (100 * canal.pagos / canal.gestiones).round(2)
canal["pct_promesa"] = (100 * canal.promesas / canal.gestiones).round(2)
canal["costo_por_sol"] = (canal.costo / canal.recuperado.replace(0, pd.NA)).round(4)
guardar(canal, "vw_efectividad_canal")
titulo("V3 EFECTIVIDAD Y COSTO POR CANAL")
print("  %-9s %9s %8s %9s %11s %13s" % ("canal", "gestiones", "% pago", "% promesa", "recuperado", "S/ por sol"))
for _, r in canal.sort_values("costo_por_sol").iterrows():
    print("  %-9s %9d %7.2f%% %8.2f%% %11s %13s"
          % (r.canal, r.gestiones, r.pct_pago, r.pct_promesa,
             "{:,.0f}".format(r.recuperado), r.costo_por_sol))

# --- V4 cumplimiento PTP por canal
ptp = fct_ges[fct_ges.es_promesa]
cum = (ptp.groupby("canal_key")
       .agg(ptp=("gestion_id", "count"),
            cumplidas=("ptp_cumplida", lambda s: (s == "SI").sum()),
            incumplidas=("ptp_cumplida", lambda s: (s == "NO").sum()),
            monto_prometido=("monto_promesa", "sum"),
            dias_prom=("dias_para_promesa", "mean"))
       .reset_index())
cum = cum.merge(dim_canal[["canal_key", "canal"]], on="canal_key")
cum["pct_cumplimiento"] = (100 * cum.cumplidas / cum.ptp).round(2)
guardar(cum, "vw_cumplimiento_ptp")
titulo("V4 CUMPLIMIENTO DE PROMESAS DE PAGO")
print("  %-9s %7s %10s %12s %14s" % ("canal", "PTP", "cumplidas", "incumplidas", "% cumplimiento"))
for _, r in cum.sort_values("pct_cumplimiento", ascending=False).iterrows():
    print("  %-9s %7d %10d %12d %13.2f%%"
          % (r.canal, r.ptp, r.cumplidas, r.incumplidas, r.pct_cumplimiento))

# --- V5 recuperacion por producto
rec = (fct_cuo.merge(dim_credito[["credito_key", "producto_desc", "rango_monto"]], on="credito_key")
       .merge(dim_cliente[["cliente_key", "rango_score"]], on="cliente_key")
       .groupby(["producto_desc", "rango_monto", "rango_score"])
       .agg(creditos=("credito_id", "nunique"),
            facturado=("monto_cuota", "sum"),
            recaudado=("monto_pagado", "sum"),
            por_cobrar=("saldo_cuota", "sum"),
            pagos_con_atraso=("pago_puntual", lambda s: (~s).sum()))
       .reset_index())
rec["pct_recuperacion"] = (100 * rec.recaudado / rec.facturado).round(2)
guardar(rec, "vw_recuperacion_producto")
titulo("V5 RECUPERACION POR PRODUCTO, MONTO Y SCORE")
print("  %-16s %-13s %-18s %9s %10s" % ("producto", "rango monto", "rango score", "facturado", "% recup"))
for _, r in rec.sort_values("pct_recuperacion", ascending=False).head(10).iterrows():
    print("  %-16s %-13s %-18s %9s %9.2f%%"
          % (r.producto_desc[:16], r.rango_monto[:13], r.rango_score[:18],
             "{:,.0f}".format(r.facturado), r.pct_recuperacion))

# --- V6 cobertura de gestion
venc = fct_cuo[fct_cuo.estado_cuota == "VENCIDA"].copy()
venc["dias_desde_vencimiento"] = (
    pd.Timestamp.today().normalize() - pd.to_datetime(venc.fecha_vencimiento)).dt.days
venc["bucket"] = pd.cut(venc.dias_desde_vencimiento, bins=[-1, 30, 60, 90, 180, 10**6],
                        labels=["0-30", "31-60", "61-90", "91-180", "180+"])
con_gestion = set(fct_ges.cuota_id)
venc["tiene_gestion"] = venc.cuota_id.isin(con_gestion)
cob = (venc.groupby("bucket", observed=True)
       .agg(cuotas_vencidas=("cuota_id", "count"),
            cuotas_sin_gestion=("tiene_gestion", lambda s: (~s).sum()),
            saldo_vencido=("monto_cuota", "sum"))
       .reset_index())
cob["saldo_sin_gestionar"] = venc[~venc.tiene_gestion].groupby("bucket", observed=True).monto_cuota.sum().reindex(cob.bucket).fillna(0).values
cob["pct_sin_cobertura"] = (100 * cob.cuotas_sin_gestion / cob.cuotas_vencidas).round(2)
guardar(cob, "vw_cobertura_gestion")
titulo("V6 COBERTURA DE GESTION (cartera vencida sin gestionar)")
for _, r in cob.iterrows():
    print("  %-9s %6d cuotas vencidas  %5d sin gestion  %6.2f%%  S/ %s sin gestionar"
          % (r.bucket, r.cuotas_vencidas, r.cuotas_sin_gestion,
             r.pct_sin_cobertura, "{:,.0f}".format(r.saldo_sin_gestionar)))

# --- V7 roll rate
fm = fct_mor.sort_values(["credito_id", "fecha_corte"]).copy()
fm["bucket_ant"] = fm.groupby("credito_id").bucket_mora.shift(1)
fm["orden_ant"] = fm.groupby("credito_id").orden_bucket.shift(1)
fm["corte_ant"] = fm.groupby("credito_id").fecha_corte.shift(1)
fm["dias_entre"] = (pd.to_datetime(fm.fecha_corte) - pd.to_datetime(fm.corte_ant)).dt.days
tr = fm[(fm.bucket_ant.notna()) & (fm.dias_entre.between(1, 10))].copy()
tr["movimiento"] = tr.apply(
    lambda r: "DETERIORO" if r.orden_bucket > r.orden_ant
    else ("SE MANTIENE" if r.orden_bucket == r.orden_ant else "RECUPERA"), axis=1)
roll = (tr.groupby(["bucket_ant", "bucket_mora", "movimiento"])
        .size().reset_index(name="creditos")
        .rename(columns={"bucket_ant": "bucket_anterior", "bucket_mora": "bucket_actual"}))
guardar(roll, "vw_roll_rate")
titulo("V7 ROLL RATE (transiciones entre cortes consecutivos)")
print("  %-10s -> %-10s %-12s %8s" % ("anterior", "actual", "movimiento", "creditos"))
for _, r in roll.sort_values(["bucket_anterior", "bucket_actual"]).iterrows():
    print("  %-10s -> %-10s %-12s %8d"
          % (r.bucket_anterior, r.bucket_actual, r.movimiento, r.creditos))
tot_mov = tr.movimiento.value_counts()
print("\n  Resumen: %s" % ", ".join("%s=%d" % (k, v) for k, v in tot_mov.items()))

# --- V8 mejor momento de contacto
gf = fct_ges.merge(dim_fecha[["fecha_key", "nombre_dia", "dia_semana", "es_fin_semana"]],
                   on="fecha_key", how="left")
gf = gf[(gf.hora_del_dia.notna()) & (~gf.es_fin_semana)]
mom = (gf.groupby(["nombre_dia", "dia_semana", "hora_del_dia"])
       .agg(gestiones=("gestion_id", "count"),
            efectivas=("es_gestion_efectiva", "sum"),
            pagos=("es_pago", "sum"))
       .reset_index())
mom["pct_efectividad"] = (100 * mom.efectivas / mom.gestiones).round(2)
mom["pct_pago"] = (100 * mom.pagos / mom.gestiones).round(2)
guardar(mom, "vw_mejor_momento_contacto")
titulo("V8 MEJOR MOMENTO DE CONTACTO (top 8 por efectividad, min 30 gestiones)")
top = mom[mom.gestiones >= 30].sort_values("pct_efectividad", ascending=False).head(8)
for _, r in top.iterrows():
    print("  %-10s %02dh  %5d gestiones  %6.2f%% efectividad  %5.2f%% pago"
          % (r.nombre_dia, r.hora_del_dia, r.gestiones, r.pct_efectividad, r.pct_pago))

# --- V9 desempeno asesor
ase = (fct_ges.groupby("asesor_key")
       .agg(gestiones=("gestion_id", "count"),
            creditos=("credito_id", "nunique"),
            efectivas=("es_gestion_efectiva", "sum"),
            pagos=("es_pago", "sum"),
            promesas=("es_promesa", "sum"),
            recuperado=("monto_recuperado", "sum"),
            ptp_cumplidas=("ptp_cumplida", lambda s: (s == "SI").sum()))
       .reset_index())
ase = ase.merge(dim_asesor, on="asesor_key")
ase["pct_efectividad"] = (100 * ase.efectivas / ase.gestiones).round(2)
ase["pct_ptp_cumplida"] = (100 * ase.ptp_cumplidas / ase.promesas.replace(0, pd.NA)).round(2)
ase["recuperado_por_gestion"] = (ase.recuperado / ase.gestiones).round(2)
guardar(ase, "vw_desempeno_asesor")
titulo("V9 DESEMPENO POR ASESOR (top 5 por recuperado)")
for _, r in ase.sort_values("recuperado", ascending=False).head(5).iterrows():
    print("  %-6s %5d gestiones  %6.2f%% efectividad  %6.2f%% PTP  S/ %s recuperado"
          % (r.asesor_id, r.gestiones, r.pct_efectividad, r.pct_ptp_cumplida,
             "{:,.0f}".format(r.recuperado)))

# --- V10 KPIs principales
# OJO: fct_mora_diaria solo contiene creditos MOROSOS. Por eso se calculan dos
# indicadores distintos, que no deben confundirse en un tablero:
#   pct_intensidad_mora     -> del saldo de los morosos, cuanto ya esta vencido
#   pct_mora_cartera_total  -> del saldo por cobrar de TODO el portafolio, cuanto esta vencido
snap = fct_mor[fct_mor.fecha_corte == ultimo]
saldo_por_cobrar = float(fct_cuo.saldo_cuota.sum())
saldo_sin_castigo = float(fct_cuo[fct_cuo.dias_atraso <= 180].saldo_cuota.sum())
saldo_vencido_castigado = float(snap[snap.elegible_castigo == "SI"].saldo_vencido.sum())
kpi = {
    "fecha_referencia": str(ultimo)[:10],
    "clientes_totales": len(dim_cliente),
    "clientes_contactables": int(dim_cliente.es_contactable.sum()),
    "pct_contactabilidad": round(100 * dim_cliente.es_contactable.mean(), 2),
    "creditos_en_mora": int(snap.credito_id.nunique()),
    "saldo_vencido_morosos": round(float(snap.saldo_vencido.sum()), 2),
    "saldo_total_morosos": round(float(snap.saldo_total.sum()), 2),
    "saldo_por_cobrar": round(saldo_por_cobrar, 2),
    "saldo_vencido_castigado": round(saldo_vencido_castigado, 2),
    "pct_mora_cartera_total": round(
        100 * snap.saldo_vencido.sum() / saldo_por_cobrar, 2) if saldo_por_cobrar else None,
    "pct_mora_cartera_sin_castigo": round(
        100 * (snap.saldo_vencido.sum() - saldo_vencido_castigado) / saldo_sin_castigo, 2)
    if saldo_sin_castigo else None,
    "pct_intensidad_mora": round(
        100 * snap.saldo_vencido.sum() / snap.saldo_total.sum(), 2),
    "facturado": round(fct_cuo.monto_cuota.sum(), 2),
    "recaudado": round(fct_cuo.monto_pagado.sum(), 2),
    "pct_recuperacion_cartera": round(100 * fct_cuo.monto_pagado.sum() / fct_cuo.monto_cuota.sum(), 2),
    "gestiones_totales": len(fct_ges),
    "pagos_logrados": int(fct_ges.es_pago.sum()),
    "recuperado_por_gestion": round(fct_ges.monto_recuperado.sum(), 2),
    "costo_cobranza": round(fct_ges.costo_gestion.sum(), 2),
    "costo_por_sol_recuperado": round(fct_ges.costo_gestion.sum() / fct_ges.monto_recuperado.sum(), 4),
    "ptp_total": len(ptp),
    "ptp_cumplidas": int((ptp.ptp_cumplida == "SI").sum()),
    "pct_cumplimiento_ptp": round(100 * (ptp.ptp_cumplida == "SI").mean(), 2),
}
kpi_df = pd.DataFrame([kpi])
guardar(kpi_df, "vw_kpis_principales")

titulo("V10 KPIs PRINCIPALES (las tarjetas del tablero)")
for k, v in kpi.items():
    if isinstance(v, float) and k == "costo_por_sol_recuperado":
        print("  %-28s %.4f" % (k, v))
    elif isinstance(v, float):
        print("  %-28s %s" % (k, "{:,.2f}".format(v)))
    else:
        print("  %-28s %s" % (k, v))
print()
print("  NOTA: el snapshot de mora solo trae creditos morosos (%d de %d)."
      % (snap.credito_id.nunique(), len(dim_credito)))
print("        %-28s = %s%%  (profundidad de la mora de quien ya debe)"
      % ("pct_intensidad_mora", kpi["pct_intensidad_mora"]))
print("        %-28s = %s%%  (mora sobre saldo por cobrar de todo el portafolio)"
      % ("pct_mora_cartera_total", kpi["pct_mora_cartera_total"]))
print("        %-28s = %s%%  (el indicador de gestion: excluye deuda en castigo)"
      % ("pct_mora_cartera_sin_castigo", kpi["pct_mora_cartera_sin_castigo"]))

# =============================================================================
# RESUMEN FINAL
# =============================================================================
titulo("ARCHIVOS GENERADOS PARA POWER BI")
for f in sorted(os.listdir(OUT)):
    if f.endswith(".csv"):
        ruta = os.path.join(OUT, f)
        print("  %-34s %8.1f KB" % (f, os.path.getsize(ruta) / 1024))

with open(os.path.join(OUT, "RESUMEN_KPIS.txt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(RESUMEN))

print("\nTodo listo en: %s" % OUT)
print("Estos numeros deben coincidir con los que devuelvan las vistas en Redshift.")

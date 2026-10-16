# -*- coding: utf-8 -*-
"""
Verifica LOCALMENTE la logica del modelo estrella, antes de tocar Redshift.

Que hace: replicia en pandas las mismas transformaciones que hacen los INSERT de
06_redshift_carga.sql (claves subrogadas, atributos derivados, joins) y corre los
chequeos de la PARTE D de auditoria.

Para que sirve: si un JOIN queda mal o una columna derivada esta mal escrita, se
detecta aqui, gratis e instantaneo, en lugar de dentro de Redshift (que cobra por
hora encendida).

Uso: python verificar_modelo_estrella.py
"""

import glob
import os

import pandas as pd

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
CUR = os.path.join(ROOT, "curated")
HOY = pd.Timestamp.today().normalize()


def leer(tabla):
    archivos = glob.glob(os.path.join(CUR, tabla, "**", "*.parquet"), recursive=True)
    if not archivos:
        raise SystemExit("No hay Parquet en curated/%s. Corre primero etl_limpieza_local.py" % tabla)
    return pd.concat([pd.read_parquet(a) for a in archivos], ignore_index=True)


print("=" * 78)
print("CONSTRUYENDO EL MODELO ESTRELLA EN LOCAL")
print("=" * 78)

stg_cli = leer("dim_clientes")
stg_cre = leer("fact_creditos")
stg_cuo = leer("fact_cuotas")
stg_ges = leer("fact_gestiones_cobranza")
stg_mor = leer("fact_mora_snapshot")

# --------------------------------------------------------------- dimensiones
dim_cliente = stg_cli[["cliente_id", "nombre", "documento", "distrito", "segmento",
                       "ingreso_mensual", "score_inicial", "fecha_alta",
                       "es_contactable", "email_valido", "telefono_valido"]].copy()
dim_cliente["rango_ingreso"] = pd.cut(
    dim_cliente.ingreso_mensual, bins=[-1, 1500, 2500, 4000, 10**9],
    labels=["MENOS DE 1.5K", "1.5K A 2.5K", "2.5K A 4K", "MAS DE 4K"])
dim_cliente["rango_score"] = pd.cut(
    dim_cliente.score_inicial, bins=[-1, 500, 600, 700, 1000],
    labels=["MUY BAJO (<500)", "BAJO (500-599)", "MEDIO (600-699)", "BUENO (700+)"])
dim_cliente = dim_cliente.reset_index(drop=True)
dim_cliente["cliente_key"] = dim_cliente.index + 1

dim_credito = stg_cre[["credito_id", "cliente_id", "producto", "producto_desc", "oficina",
                       "plazo_meses", "tea", "monto_desembolsado", "cuota_mensual",
                       "fecha_desembolso", "estado_credito", "score_desembolso"]].copy()
dim_credito["anio_desembolso"] = pd.to_datetime(dim_credito.fecha_desembolso).dt.year
dim_credito["rango_plazo"] = pd.cut(
    dim_credito.plazo_meses, bins=[0, 6, 12, 24, 100],
    labels=["CORTO (<=6)", "MEDIO (7-12)", "LARGO (13-24)", "MUY LARGO (25+)"])
dim_credito["rango_monto"] = pd.cut(
    dim_credito.monto_desembolsado, bins=[-1, 1000, 3000, 7000, 10**9],
    labels=["MENOS DE 1K", "1K A 3K", "3K A 7K", "MAS DE 7K"])
dim_credito = dim_credito.reset_index(drop=True)
dim_credito["credito_key"] = dim_credito.index + 1

dim_canal = stg_ges[["canal"]].drop_duplicates().reset_index(drop=True)
dim_canal["canal_key"] = dim_canal.index + 1
dim_canal["es_digital"] = dim_canal.canal.isin(["SMS", "EMAIL", "WHATSAPP"])
dim_canal["es_bidireccional"] = dim_canal.canal.isin(["LLAMADA", "WHATSAPP", "VISITA"])

dim_resultado = stg_ges[["resultado"]].drop_duplicates().reset_index(drop=True)
dim_resultado["resultado_key"] = dim_resultado.index + 1
dim_resultado["es_pago"] = dim_resultado.resultado.isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
dim_resultado["es_promesa"] = dim_resultado.resultado.eq("PROMESA_PAGO")
dim_resultado["es_contacto"] = dim_resultado.resultado.isin(
    ["CONTACTADO", "PAGO_TOTAL", "PAGO_PARCIAL", "PROMESA_PAGO", "RECHAZA_PAGO", "CLIENTE_MOLESTO"])

dim_asesor = stg_ges[["asesor_id"]].dropna().drop_duplicates().reset_index(drop=True)
dim_asesor["asesor_key"] = dim_asesor.index + 1

dim_tipo = stg_ges[["tipo_gestion"]].drop_duplicates().reset_index(drop=True)
dim_tipo["tipo_gestion_key"] = dim_tipo.index + 1

# ------------------------------------------------------------------- hechos
print("\nCruces (joins) del modelo:")
fct_gestiones = (stg_ges
                 .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
                 .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left")
                 .merge(dim_canal, on="canal", how="left")
                 # dim_resultado trae es_pago/es_promesa/es_contacto, que YA existen en
                 # stg_ges. Se renombran para evitar columnas duplicadas (_x / _y).
                 # En el SQL de Redshift esto se resuelve calificando con g.
                 .merge(dim_resultado.rename(columns={
                     "es_pago": "res_es_pago",
                     "es_promesa": "res_es_promesa",
                     "es_contacto": "res_es_contacto"}), on="resultado", how="left")
                 .merge(dim_tipo, on="tipo_gestion", how="left")
                 .merge(dim_asesor, on="asesor_id", how="left"))
fct_gestiones["hora_del_dia"] = pd.to_numeric(
    fct_gestiones.hora_gestion.str.split(":").str[0], errors="coerce")
fct_gestiones["dias_para_promesa"] = (
    pd.to_datetime(fct_gestiones.fecha_promesa_pago)
    - pd.to_datetime(fct_gestiones.fecha_gestion)).dt.days
# El SQL de Redshift deriva estas dos banderas del resultado (no dependen de la
# capa curada, que no siempre las trae). Aqui se replican igual.
fct_gestiones["es_pago"] = fct_gestiones.resultado.isin(["PAGO_TOTAL", "PAGO_PARCIAL"])
fct_gestiones["es_promesa"] = fct_gestiones.resultado.eq("PROMESA_PAGO")

fct_mora = (stg_mor
            .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
            .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left"))
fct_mora["orden_bucket"] = fct_mora.bucket_mora.map(
    {"0-30": 1, "31-60": 2, "61-90": 3, "91-180": 4, "180+": 5}).fillna(0)

fct_cuotas = (stg_cuo
              .merge(dim_credito[["credito_id", "credito_key"]], on="credito_id", how="left")
              .merge(dim_cliente[["cliente_id", "cliente_key"]], on="cliente_id", how="left"))
fct_cuotas["saldo_cuota"] = fct_cuotas.monto_cuota - fct_cuotas.monto_pagado
fct_cuotas["pago_puntual"] = fct_cuotas.pagada & (fct_cuotas.dias_atraso <= 0)

print("  fct_gestiones     %6d filas | credito_key nulo: %d | canal_key nulo: %d"
      % (len(fct_gestiones), fct_gestiones.credito_key.isna().sum(),
         fct_gestiones.canal_key.isna().sum()))
print("  fct_mora_diaria   %6d filas | credito_key nulo: %d"
      % (len(fct_mora), fct_mora.credito_key.isna().sum()))
print("  fct_cuotas        %6d filas | credito_key nulo: %d"
      % (len(fct_cuotas), fct_cuotas.credito_key.isna().sum()))

# --------------------------------------------------------------- auditoria
print()
print("=" * 78)
print("AUDITORIA DE CALIDAD DEL MODELO (PARTE D de 06_redshift_carga.sql)")
print("=" * 78)

resultados = []


def check(nombre, valor, esperado=0):
    resultados.append((nombre, int(valor), esperado, int(valor) == esperado))
    estado = "OK " if int(valor) == esperado else "FALLA"
    print("  [%s] %-48s %s (esperado %s)" % (estado, nombre, int(valor), esperado))


check("gestiones: staging vs hecho", abs(len(stg_ges) - len(fct_gestiones)))
check("cuotas: staging vs hecho", abs(len(stg_cuo) - len(fct_cuotas)))
check("mora: staging vs hecho", abs(len(stg_mor) - len(fct_mora)))
print()
check("gestiones sin credito_key", fct_gestiones.credito_key.isna().sum())
check("gestiones sin cliente_key", fct_gestiones.cliente_key.isna().sum())
check("gestiones sin canal_key", fct_gestiones.canal_key.isna().sum())
check("gestiones sin resultado_key", fct_gestiones.resultado_key.isna().sum())
check("gestiones sin asesor_key", fct_gestiones.asesor_key.isna().sum())
check("cuotas sin credito_key", fct_cuotas.credito_key.isna().sum())
check("mora sin credito_key", fct_mora.credito_key.isna().sum())
print()
check("cuadre recaudado (cuotas)",
      abs(round(stg_cuo.monto_pagado.sum()) - round(fct_cuotas.monto_pagado.sum())))
check("cuadre recuperado (gestiones)",
      abs(round(stg_ges.monto_recuperado.sum()) - round(fct_gestiones.monto_recuperado.sum())))
check("cuadre saldo vencido (mora)",
      abs(round(stg_mor.saldo_vencido.sum()) - round(fct_mora.saldo_vencido.sum())))
print()
check("PTP marcada sin fecha de promesa",
      int((fct_gestiones.es_promesa & fct_gestiones.fecha_promesa_pago.isna()).sum()))
check("pagos con monto recuperado en cero",
      int((fct_gestiones.es_pago & (fct_gestiones.monto_recuperado == 0)).sum()))
check("saldo_cuota negativo (pago de mas)",
      int((fct_cuotas.saldo_cuota < 0).sum()))

# --------------------------------------------------------- vistas de negocio
print()
print("=" * 78)
print("VISTAS DE NEGOCIO — resultados esperados")
print("=" * 78)

ultimo = fct_mora.fecha_corte.max()
aging = (fct_mora[fct_mora.fecha_corte == ultimo]
         .groupby("bucket_mora")
         .agg(creditos=("credito_id", "nunique"), saldo=("saldo_vencido", "sum"))
         .reset_index())
aging["pct"] = (100 * aging.saldo / aging.saldo.sum()).round(2)
print("\n  V1 AGING DE CARTERA (corte %s)" % str(ultimo)[:10])
for _, r in aging.iterrows():
    print("    %-9s %5d creditos  S/ %12s  %5.2f%%"
          % (r.bucket_mora, r.creditos, "{:,.0f}".format(r.saldo), r.pct))

canal = (fct_gestiones.groupby("canal")
         .agg(gestiones=("gestion_id", "count"),
              pagos=("es_pago", "sum"),
              recuperado=("monto_recuperado", "sum"),
              costo=("costo_gestion", "sum"))
         .reset_index())
canal["pct_pago"] = (100 * canal.pagos / canal.gestiones).round(2)
canal["costo_por_sol"] = (canal.costo / canal.recuperado.replace(0, pd.NA)).round(4)
print("\n  V3 EFECTIVIDAD Y COSTO POR CANAL")
print("    %-9s %9s %8s %9s %13s" % ("canal", "gestiones", "% pago", "recuperado", "S/ por sol"))
for _, r in canal.sort_values("costo_por_sol").iterrows():
    print("    %-9s %9d %7.2f%% %9s %13s"
          % (r.canal, r.gestiones, r.pct_pago, "{:,.0f}".format(r.recuperado), r.costo_por_sol))

ptp = fct_gestiones[fct_gestiones.es_promesa]
print("\n  V4 CUMPLIMIENTO DE PTP")
print("    PTP registradas : %d" % len(ptp))
print("    PTP cumplidas   : %d (%.1f%%)"
      % ((ptp.ptp_cumplida == "SI").sum(),
         100 * (ptp.ptp_cumplida == "SI").mean()))

print("\n  V10 KPIs PRINCIPALES")
print("    clientes totales        : %d" % len(dim_cliente))
print("    clientes contactables   : %d (%.1f%%)"
      % (dim_cliente.es_contactable.sum(), 100 * dim_cliente.es_contactable.mean()))
print("    creditos en mora        : %d" % fct_mora[fct_mora.fecha_corte == ultimo].credito_id.nunique())
print("    saldo vencido           : S/ %s"
      % "{:,.0f}".format(fct_mora[fct_mora.fecha_corte == ultimo].saldo_vencido.sum()))
print("    facturado               : S/ %s" % "{:,.0f}".format(fct_cuotas.monto_cuota.sum()))
print("    recaudado               : S/ %s" % "{:,.0f}".format(fct_cuotas.monto_pagado.sum()))
print("    recuperacion de cartera : %.2f%%"
      % (100 * fct_cuotas.monto_pagado.sum() / fct_cuotas.monto_cuota.sum()))
print("    costo por sol recuperado: %.4f"
      % (fct_gestiones.costo_gestion.sum() / fct_gestiones.monto_recuperado.sum()))

# ------------------------------------------------------------------ cierre
print()
print("=" * 78)
fallidos = [r for r in resultados if not r[3]]
if not fallidos:
    print(" RESULTADO: %d chequeos, TODOS OK — el modelo estrella es correcto" % len(resultados))
else:
    print(" RESULTADO: %d de %d chequeos FALLARON" % (len(fallidos), len(resultados)))
    for n, v, e, _ in fallidos:
        print("   - %s: %s (esperado %s)" % (n, v, e))
print("=" * 78)

# Guardar el resumen para el reporte del portafolio
res = pd.DataFrame(resultados, columns=["chequeo", "resultado", "esperado", "cumple"])
ruta = os.path.join(ROOT, "reporte_modelo_estrella.csv")
res.to_csv(ruta, index=False, encoding="utf-8")
print("\nReporte guardado en: %s" % ruta)

# -*- coding: utf-8 -*-
"""
Verifica en LOCAL que los chequeos del archivo 02_athena_validacion_curated.sql
dan cero sobre la capa curated. Es la comprobacion cruzada del ETL: si aqui todo
da 0, el job de Glue deberia dar lo mismo en Athena.

Uso: python verificar_curated.py
"""

import os
import glob
import pandas as pd

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
CUR = os.path.join(ROOT, "curated")


def leer(tabla):
    ruta = os.path.join(CUR, tabla)
    archivos = glob.glob(os.path.join(ruta, "**", "*.parquet"), recursive=True)
    if not archivos:
        raise SystemExit("No hay Parquet en %s. Corre primero etl_limpieza_local.py" % ruta)
    return pd.concat([pd.read_parquet(a) for a in archivos], ignore_index=True)


cli = leer("dim_clientes")
cre = leer("fact_creditos")
cuo = leer("fact_cuotas")
ges = leer("fact_gestiones_cobranza")
mor = leer("fact_mora_snapshot")

hoy = pd.Timestamp.today().normalize()
resultados = []


def check(nombre, valor):
    resultados.append((nombre, int(valor)))
    estado = "OK " if valor == 0 else "REVISAR"
    print("  [%s] %-52s %s" % (estado, nombre, valor))


print("=" * 78)
print("CHEQUEO 1 - CLAVES DUPLICADAS")
print("=" * 78)
check("dim_clientes: cliente_id duplicado",
      (cli.cliente_id.value_counts() > 1).sum())
check("fact_creditos: credito_id duplicado",
      (cre.credito_id.value_counts() > 1).sum())
check("fact_mora_snapshot: (fecha_corte, credito_id) duplicado",
      (mor.groupby(["fecha_corte", "credito_id"]).size() > 1).sum())

print()
print("=" * 78)
print("CHEQUEO 2 - PROBLEMAS DE CALIDAD QUE NO DEBEN SOBREVIVIR")
print("=" * 78)
mail = cli["email"].notna() & ~cli["email"].fillna("").str.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", na=False)
tel = cli["telefono"].notna() & ~cli["telefono"].fillna("").str.match(r"^9\d{8}$", na=False)
check("emails invalidos que sobrevivieron", mail.sum())
check("telefonos invalidos que sobrevivieron", tel.sum())
check("montos pagados negativos", (cuo.monto_pagado < 0).sum())
check("fechas de pago en el futuro",
      (pd.to_datetime(cuo.fecha_pago, errors="coerce") > hoy).sum())
check("PAGADAS sin fecha de pago",
      (cuo.estado_cuota.isin(["PAGADA", "PAGADA_CON_ATRASO"]) & cuo.fecha_pago.isna()).sum())
check("canales sin normalizar", (ges.canal != ges.canal.str.upper().str.strip()).sum())
check("resultados sin normalizar", (ges.resultado != ges.resultado.str.upper().str.strip()).sum())

print()
print("=" * 78)
print("CHEQUEO 3 - COHERENCIA DE NEGOCIO")
print("=" * 78)


def bucket(d):
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


b_calc = mor.dias_atraso.map(bucket)
check("bucket_mora inconsistente con dias_atraso", (b_calc != mor.bucket_mora).sum())
check("saldo_vencido mayor que saldo_total", (mor.saldo_vencido > mor.saldo_total).sum())
check("PROMESA_PAGO sin fecha de promesa",
      ((ges.resultado == "PROMESA_PAGO") & ges.fecha_promesa_pago.isna()).sum())
check("monto recuperado sin resultado de pago",
      ((ges.monto_recuperado > 0) & ~ges.resultado.isin(["PAGO_TOTAL", "PAGO_PARCIAL"])).sum())
check("creditos con monto desembolsado <= 0", (cre.monto_desembolsado <= 0).sum())
cast = mor.dias_atraso.gt(180).map({True: "SI", False: "NO"})
check("elegible_castigo inconsistente", (cast != mor.elegible_castigo).sum())

print()
print("=" * 78)
print("CHEQUEO 4 - INTEGRIDAD REFERENCIAL")
print("=" * 78)
check("cuotas sin credito en fact_creditos",
      (~cuo.credito_id.isin(cre.credito_id)).sum())
check("gestiones sin credito en fact_creditos",
      (~ges.credito_id.isin(cre.credito_id)).sum())
check("gestiones sin cuota en fact_cuotas",
      (~ges.cuota_id.isin(cuo.cuota_id)).sum())
check("mora_snapshot sin credito en fact_creditos",
      (~mor.credito_id.isin(cre.credito_id)).sum())

print()
print("=" * 78)
print("CHEQUEO 5 - VOLUMENES")
print("=" * 78)
for t, d in [("dim_clientes", cli), ("fact_creditos", cre), ("fact_cuotas", cuo),
             ("fact_gestiones_cobranza", ges), ("fact_mora_snapshot", mor)]:
    print("  %-26s %8d filas" % (t, len(d)))

print()
print("=" * 78)
print("CHEQUEO 6 - EFECTO DE LA LIMPIEZA (para el reporte del portafolio)")
print("=" * 78)
print("  montos negativos corregidos      :", int(cuo.monto_pagado_corregido.sum()))
print("  pagos futuros anulados           :", int(cuo.fecha_pago_futura_corregida.sum()))
print("  fechas de pago imputadas         :", int(cuo.fecha_pago_imputada.sum()))
print("  canales con formato corregido    :", int(ges.canal_formato_corregido.sum()))
print("  resultados con formato corregido :", int(ges.resultado_formato_corregido.sum()))
print()
print("  Contactabilidad de la cartera:")
cont = cli.es_contactable.value_counts()
for v, n in cont.items():
    print("    es_contactable=%-6s %6d clientes  (%.2f%%)" % (v, n, 100.0 * n / len(cli)))

print()
print("=" * 78)
total_revisar = sum(1 for _, v in resultados if v != 0)
if total_revisar == 0:
    print(" RESULTADO: TODOS LOS CHEQUEOS EN 0 - la capa curated esta limpia")
else:
    print(" RESULTADO: %d chequeos requieren revision" % total_revisar)
    for n, v in resultados:
        if v != 0:
            print("   - %s: %s" % (n, v))
print("=" * 78)

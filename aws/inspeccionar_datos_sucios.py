# -*- coding: utf-8 -*-
"""Inspecciona los datos sucios reales para definir reglas de limpieza precisas."""
import pandas as pd
import os

BASE = os.path.dirname(os.path.abspath(__file__))
# la carpeta raw vive en la raiz del proyecto (un nivel arriba de aws/)
RAW = os.path.join(BASE, "raw")
if not os.path.isdir(RAW):
    RAW = os.path.join(os.path.dirname(BASE), "raw")

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 30)

cli = pd.read_csv(os.path.join(RAW, "clientes.csv"), dtype=str, keep_default_na=False)
cre = pd.read_csv(os.path.join(RAW, "creditos.csv"), dtype=str, keep_default_na=False)
cuo = pd.read_csv(os.path.join(RAW, "cuotas.csv"), dtype=str, keep_default_na=False)
ges = pd.read_csv(os.path.join(RAW, "gestiones_cobranza.csv"), dtype=str, keep_default_na=False)
mor = pd.read_csv(os.path.join(RAW, "mora_snapshot.csv"), dtype=str, keep_default_na=False)

print("=" * 78)
print("R1 / R2 / R3 — CLIENTES: duplicados, emails, telefonos")
print("=" * 78)
dup = cli[cli.duplicated("cliente_id", keep=False)].sort_values("cliente_id")
print("  filas duplicadas por cliente_id:", len(dup), "| ids afectados:", dup.cliente_id.nunique())
print("  ejemplo:")
print(dup.head(4).to_string(index=False))

bad_mail = cli[~cli.email.str.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")]
print("\n  emails invalidos:", len(bad_mail), "| valores unicos:",
      sorted(bad_mail.email.unique())[:6])

bad_tel = cli[~cli.telefono.str.match(r"^9\d{8}$")]
print("  telefonos invalidos:", len(bad_tel), "| valores unicos:",
      sorted(bad_tel.telefono.unique())[:8])

print("\n  ingreso_mensual con problemas:",
      len(cli[~cli.ingreso_mensual.str.match(r"^\d+$")]))

print()
print("=" * 78)
print("R4 / R5 / R6 — CUOTAS: fechas futuras, montos negativos, PAGADA sin fecha")
print("=" * 78)
hoy = pd.Timestamp("2026-09-28")
cuo["_fp"] = pd.to_datetime(cuo.fecha_pago, errors="coerce")
fut = cuo[cuo._fp > hoy]
print("  fechas de pago en el futuro:", len(fut))
print(fut[["cuota_id", "fecha_vencimiento", "fecha_pago", "estado_cuota", "monto_pagado"]].head(4).to_string(index=False))

cuo["_mp"] = pd.to_numeric(cuo.monto_pagado, errors="coerce")
neg = cuo[cuo._mp < 0]
print("\n  montos pagados negativos:", len(neg))
print(neg[["cuota_id", "monto_cuota", "monto_pagado", "estado_cuota"]].head(4).to_string(index=False))

sinf = cuo[(cuo.estado_cuota == "PAGADA") & (cuo.fecha_pago == "")]
print("\n  PAGADAS sin fecha de pago:", len(sinf))
print(sinf[["cuota_id", "fecha_vencimiento", "monto_cuota", "monto_pagado", "estado_cuota", "dias_atraso"]].head(4).to_string(index=False))

print("\n  estados de cuota:", cuo.estado_cuota.value_counts().to_dict())
print("  monto_pagado vacio y estado PAGADA_CON_ATRASO:",
      len(cuo[(cuo.estado_cuota == "PAGADA_CON_ATRASO") & (cuo.monto_pagado == "")]))

print()
print("=" * 78)
print("R7 — GESTIONES: variantes de canal y resultado")
print("=" * 78)
print("  canal crudo, valores unicos:")
print("   ", sorted(ges.canal.unique()))
print("  resultado crudo, valores unicos:")
print("   ", sorted(ges.resultado.unique()))
print("\n  filas afectadas por formato no normalizado:",
      len(ges[ges.canal != ges.canal.str.strip().str.upper()]),
      "+", len(ges[ges.resultado != ges.resultado.str.strip().str.upper()]))

print("\n  fecha_promesa_pago vacia:", (ges.fecha_promesa_pago == "").sum())
print("  ptp_cumplida valores:", ges.ptp_cumplida.value_counts().to_dict())
print("  monto_recuperado vacio:", (ges.monto_recuperado == "").sum())

print()
print("=" * 78)
print("MORA_SNAPSHOT y CREDITOS: rangos y nulos")
print("=" * 78)
print("  buckets:", mor.bucket_mora.value_counts().to_dict())
print("  fecha_corte min/max:", mor.fecha_corte.min(), mor.fecha_corte.max())
print("  dias_atraso no numericos:", len(mor[~mor.dias_atraso.str.match(r"^\d+$")]))
print("  estado_credito:", cre.estado_credito.value_counts().to_dict())
print("  creditos con plazo invalido:", len(cre[~cre.plazo_meses.str.match(r"^\d+$")]))

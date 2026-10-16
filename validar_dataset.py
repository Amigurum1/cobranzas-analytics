# -*- coding: utf-8 -*-
"""Valida el dataset generado y calcula las metricas de negocio clave."""
import csv, os
from collections import Counter, defaultdict
from datetime import date, timedelta

RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")

def load(nombre, limite=None):
    with open(os.path.join(RAW, nombre + ".csv"), encoding="utf-8") as f:
        r = csv.DictReader(f)
        filas = []
        for i, row in enumerate(r):
            if limite and i >= limite:
                break
            filas.append(row)
    return filas

clientes = load("clientes")
creditos = load("creditos")
cuotas = load("cuotas")
gestiones = load("gestiones_cobranza")
snap = load("mora_snapshot")

print("=" * 70)
print("1) VOLUMEN DEL DATASET")
print("=" * 70)
for n, t in [("clientes", clientes), ("creditos", creditos), ("cuotas", cuotas),
             ("gestiones_cobranza", gestiones), ("mora_snapshot", snap)]:
    print("  %-22s %8d filas" % (n, len(t)))

print()
print("=" * 70)
print("2) PROBLEMAS DE CALIDAD DETECTADOS (lo que deberas limpiar)")
print("=" * 70)

ids = [c["cliente_id"] for c in clientes]
dup = [k for k, v in Counter(ids).items() if v > 1]
print("  - clientes con ID duplicado: %d" % len(dup))

emails_malos = [c for c in clientes if not c["email"] or "@" not in c["email"]
                or c["email"].count("@") != 1 or c["email"].startswith("correo@@")]
print("  - emails invalidos o vacios: %d" % len(emails_malos))

tel_malos = [c for c in clientes if len(c["telefono"]) != 9 or not c["telefono"].isdigit()]
print("  - telefonos mal formados: %d" % len(tel_malos))

hoy = date.today()
futuras = [q for q in cuotas if q["fecha_pago"]
           and date.fromisoformat(q["fecha_pago"]) > hoy]
print("  - fechas de pago en el futuro: %d" % len(futuras))

negativos = [q for q in cuotas if float(q["monto_pagado"]) < 0]
print("  - montos pagados negativos: %d" % len(negativos))

pagada_sin_fecha = [q for q in cuotas if q["estado_cuota"] == "PAGADA" and not q["fecha_pago"]]
print("  - cuotas PAGADAS sin fecha de pago: %d" % len(pagada_sin_fecha))

canales = Counter(g["canal"] for g in gestiones)
variantes = [k for k in canales if k != k.strip().upper()]
print("  - variantes de mayusculas/espacios en canal: %d (%s...)" % (len(variantes), variantes[:3]))

print()
print("=" * 70)
print("3) METRICAS DE NEGOCIO (respuestas que podras dar en la entrevista)")
print("=" * 70)

# aging actual
ultima_fecha = max(s["fecha_corte"] for s in snap)
corte = [s for s in snap if s["fecha_corte"] == ultima_fecha]
por_bucket = defaultdict(lambda: [0, 0.0])
for s in corte:
    por_bucket[s["bucket_mora"]][0] += 1
    por_bucket[s["bucket_mora"]][1] += float(s["saldo_vencido"])
print("\n  AGING DE CARTERA al %s" % ultima_fecha)
print("    %-12s %8s %16s" % ("bucket", "creditos", "saldo vencido S/"))
orden = ["PREVENTIVO", "0-30", "31-60", "61-90", "91-180", "180+"]
total_saldo = sum(v[1] for v in por_bucket.values())
for b in orden:
    if b in por_bucket:
        n, s = por_bucket[b]
        print("    %-12s %8d %16s   %5.1f%%" % (b, n, "{:,.0f}".format(s), 100 * s / total_saldo))
print("    %-12s %8d %16s" % ("TOTAL", sum(v[0] for v in por_bucket.values()),
                              "{:,.0f}".format(total_saldo)))

# efectividad por canal
print("\n  EFECTIVIDAD POR CANAL")
print("    (contacto = CONTACTADO; promesa = PROMESA_PAGO; pago = PAGO_TOTAL o PAGO_PARCIAL)")
por_canal = defaultdict(lambda: [0, 0, 0, 0])
for g in gestiones:
    c = g["canal"].strip().upper()
    r = g["resultado"].strip().upper()
    por_canal[c][0] += 1
    if r == "CONTACTADO":
        por_canal[c][1] += 1
    if r == "PROMESA_PAGO":
        por_canal[c][2] += 1
    if r in ("PAGO_TOTAL", "PAGO_PARCIAL"):
        por_canal[c][3] += 1
print("    %-10s %8s %10s %10s %10s" % ("canal", "gestiones", "contacto", "promesa", "pago"))
for c, (tot, con, pro, pag) in sorted(por_canal.items(), key=lambda x: -x[1][3] / max(1, x[1][0])):
    print("    %-10s %8d %9.1f%% %9.1f%% %9.1f%%"
          % (c, tot, 100.0 * con / tot, 100.0 * pro / tot, 100.0 * pag / tot))

# tasa de recuperacion
print("\n  TASA DE RECUPERACION")
pagado = sum(float(q["monto_pagado"]) for q in cuotas if float(q["monto_pagado"]) > 0)
facturado = sum(float(q["monto_cuota"]) for q in cuotas)
print("    facturado total:  S/ {:,.0f}".format(facturado))
print("    recaudado total:  S/ {:,.0f}".format(pagado))
print("    tasa recuperacion: %.1f%%" % (100.0 * pagado / facturado))

# cumplimiento de PTP
ptp = [g for g in gestiones if g["fecha_promesa_pago"]]
print("\n  PROMESAS DE PAGO (PTP)")
print("    PTP registradas: %d" % len(ptp))
cuota_por_id = {q["cuota_id"]: q for q in cuotas}
directo = [g for g in ptp if g.get("ptp_cumplida")]
si = [g for g in directo if g["ptp_cumplida"] == "SI"]
print("    PTP con marca de cumplimiento: %d -> %d cumplidas (%.1f%%)"
      % (len(directo), len(si), 100.0 * len(si) / len(directo) if directo else 0))

# distribucion de estados
print("\n  ESTADO DE CREDITOS")
for k, v in Counter(c["estado_credito"] for c in creditos).most_common():
    print("    %-14s %6d" % (k, v))

print("\n  ESTADO DE CUOTAS")
for k, v in Counter(q["estado_cuota"] for q in cuotas).most_common():
    print("    %-20s %6d" % (k, v))

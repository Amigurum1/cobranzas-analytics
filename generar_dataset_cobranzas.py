#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Generador de dataset sintetico de COBRANZAS para una fintech peruana de credito de consumo.

Por que sintetico: ningun dataset publico real contiene el ciclo de vida de
cobranza (gestiones, promesas de pago, pagos parciales, aging diario). Los
publicos (Lending Club, Home Credit) solo tienen desembolso + desempeno final.
Este generador produce un dataset que SI cubre todos los desafios de la oferta.

Salida: archivos CSV en la carpeta ./raw, simulando la capa RAW de un data lake
en S3 (particionados por fecha de extraccion) e incluye problemas de calidad
deliberados para que practiques validacion y limpieza.

Uso:
    python generar_dataset_cobranzas.py
    python generar_dataset_cobranzas.py --clientes 20000 --seed 7 --out C:\\ruta\\raw
"""

import argparse
import os
import random
import csv
from datetime import date, timedelta

# ---------------------------------------------------------------- parametros
P = argparse.ArgumentParser(description="Genera dataset sintetico de cobranzas")
P.add_argument("--clientes", type=int, default=5000, help="numero de clientes")
P.add_argument("--meses", type=int, default=18, help="meses de historia")
P.add_argument("--seed", type=int, default=42, help="semilla aleatoria")
P.add_argument("--out", type=str, default="raw", help="carpeta de salida")
P.add_argument("--sucio", action="store_true", default=True,
               help="inyectar problemas de calidad de datos (por defecto activo)")
P.add_argument("--limpio", dest="sucio", action="store_false",
               help="generar datos sin problemas de calidad")
A = P.parse_args()

rnd = random.Random(A.seed)
HOY = date.today()
INICIO = HOY - timedelta(days=30 * A.meses)

# ---------------------------------------------------------------- catalogos
REGIONES = ["Lima", "Arequipa", "Trujillo", "Cusco", "Piura",
            "Chiclayo", "Huancayo", "Iquitos"]
PRODUCTOS = [
    ("TECNO_CEL", "Celulares",      300,  4500),
    ("TECNO_TV",  "Televisores",    800,  9000),
    ("TECNO_LINEA_BLANCA", "Linea blanca", 600, 7000),
    ("MOTO",      "Motocicletas",  3500, 20000),
    ("COMPUTO",   "Computo",        900, 12000),
]
CANALES = ["LLAMADA", "SMS", "WHATSAPP", "EMAIL", "CARTA", "VISITA"]
TIPOS_GESTION = ["RECORDATORIO", "GESTION_TEMPRANA", "GESTION_PREVENTIVA",
                 "GESTION_MORA", "NEGOCIACION", "COBRANZA_JUDICIAL"]
RESULTADOS = ["CONTACTADO", "NO_CONTACTADO", "PROMESA_PAGO", "PAGO_TOTAL",
              "PAGO_PARCIAL", "RECHAZA_PAGO", "NUMERO_INVALIDO",
              "CLIENTE_MOLESTO", "ACUERDO_REFINANCIACION"]
ASESORES = ["A%03d" % i for i in range(1, 41)]

BUCKETS = ["PREVENTIVO", "0-30", "31-60", "61-90", "91-180", "180+"]


def bucket(dias):
    if dias <= 0:
        return "PREVENTIVO"
    if dias <= 30:
        return "0-30"
    if dias <= 60:
        return "31-60"
    if dias <= 90:
        return "61-90"
    if dias <= 180:
        return "91-180"
    return "180+"


def r2(x):
    return round(x, 2)


def fecha_iso(d):
    return d.isoformat()


def _fila_gestion(cred_id, cliente_id, cuota, f_gestion, canal, tipo, resultado,
                  fecha_pago_cuota="", forzar_prom="", resultado_si_no_hay_prom=""):
    """Construye una fila de gestion. La PTP se resuelve contra el pago real de la cuota.

    Integridad de negocio: una PROMESA_PAGO SIEMPRE debe tener fecha de promesa.
    Si no se puede registrar (la promesa caeria en el futuro, o el pago esta
    demasiado cerca), se degrada el resultado a un valor coherente.
    """
    fecha_prom = monto_prom = cumple = ""
    monto_recuperado = 0.0
    if resultado == "PROMESA_PAGO" or forzar_prom:
        fp = fecha_pago_cuota or forzar_prom
        if not fp:
            fp = fecha_iso(f_gestion + timedelta(days=rnd.choice([3, 5, 7, 10, 15])))
        if date.fromisoformat(fp) <= HOY:
            fecha_prom = fecha_iso(date.fromisoformat(fp)) if isinstance(fp, str) else fecha_iso(fp)
            monto_prom = r2(cuota["monto_cuota"])
            cumple = "SI" if fecha_pago_cuota else "NO"
        else:
            # no se puede registrar la promesa -> se degrada el resultado
            resultado = resultado_si_no_hay_prom or "NO_CONTACTADO"
    elif resultado == "PAGO_TOTAL":
        monto_recuperado = r2(cuota["monto_cuota"])
    elif resultado == "PAGO_PARCIAL":
        monto_recuperado = r2(cuota["monto_cuota"] * rnd.uniform(0.2, 0.8))
    return {
        "gestion_id": "GES%09d" % (len(gestiones) + 1),
        "credito_id": "CRE%07d" % cred_id,
        "cliente_id": cliente_id,
        "cuota_id": cuota["cuota_id"],
        "fecha_gestion": fecha_iso(f_gestion),
        "hora_gestion": "%02d:%02d:00" % (rnd.randint(8, 19), rnd.randint(0, 59)),
        "canal": canal,
        "tipo_gestion": tipo,
        "resultado": resultado,
        "asesor_id": rnd.choice(ASESORES),
        "monto_promesa": monto_prom,
        "fecha_promesa_pago": fecha_prom,
        "ptp_cumplida": cumple,
        "monto_recuperado": r2(monto_recuperado),
        "duracion_seg": rnd.randint(30, 600) if canal == "LLAMADA" else "",
        "costo_gestion": r2(rnd.choice([0.0, 0.15, 0.35, 2.5, 8.0])),
    }


def resultado_por_canal(canal, pago_pct):
    """Sorteo de resultado contingente al canal y a si la cuota termino pagandose."""
    if canal in ("SMS", "EMAIL", "CARTA"):
        if rnd.random() < pago_pct:
            return rnd.choices(["PAGO_TOTAL", "PAGO_PARCIAL"], weights=[60, 40])[0]
        return rnd.choices(["NO_CONTACTADO", "PROMESA_PAGO", "NUMERO_INVALIDO"],
                           weights=[68, 18, 14])[0]
    if rnd.random() < pago_pct:
        return rnd.choices(["PAGO_TOTAL", "PAGO_PARCIAL", "PROMESA_PAGO"],
                           weights=[40, 30, 30])[0]
    return rnd.choices(["NO_CONTACTADO", "CONTACTADO", "PROMESA_PAGO", "RECHAZA_PAGO",
                        "CLIENTE_MOLESTO", "NUMERO_INVALIDO"],
                       weights=[16, 44, 16, 12, 7, 5])[0]


def fechas_gestion(f_venc, d, n):
    """Fechas de gestion dentro de la ventana de mora."""
    out = []
    for _ in range(n):
        f = f_venc + timedelta(days=rnd.randint(1, max(2, d)))
        if f <= HOY:
            out.append(f)
    return sorted(out)


# ---------------------------------------------------------------- generacion
N = A.clientes
clientes, creditos, cuotas, gestiones, snapshots = [], [], [], [], []

nombres = ["Juan", "Maria", "Carlos", "Ana", "Luis", "Rosa", "Jose", "Carmen",
           "Miguel", "Elena", "Pedro", "Lucia", "Jorge", "Sofia", "Raul",
           "Patricia", "Victor", "Gloria", "Cesar", "Silvia"]
apellidos = ["Quispe", "Mamani", "Flores", "Huaman", "Rojas", "Vargas",
             "Castro", "Chavez", "Ramos", "Salazar", "Paredes", "Condori",
             "Rios", "Torres", "Aguilar", "Espinoza"]

for cid in range(1, N + 1):
    nombre = "%s %s %s" % (rnd.choice(nombres), rnd.choice(apellidos),
                           rnd.choice(apellidos))
    distrito = rnd.choice(REGIONES)
    ingreso = rnd.choice([1200, 1500, 1800, 2200, 2500, 3000, 3500, 4500, 6000])
    score = int(min(850, max(300, rnd.gauss(620, 90))))
    clientes.append({
        "cliente_id": "CLI%06d" % cid,
        "nombre": nombre,
        "documento": "%08d" % rnd.randint(10000000, 79999999),
        "email": (nombre.split()[0].lower() + str(rnd.randint(1, 99)) + "@mail.com"),
        "telefono": "9%08d" % rnd.randint(0, 99999999),
        "distrito": distrito,
        "ingreso_mensual": ingreso,
        "score_inicial": score,
        "fecha_alta": fecha_iso(INICIO - timedelta(days=rnd.randint(0, 900))),
        "segmento": rnd.choices(["A", "B", "C", "D"], weights=[10, 30, 40, 20])[0],
    })

cidx = 0
cred_id = 0
for cl in clientes:
    cidx += 1
    for _ in range(rnd.choices([1, 2], weights=[75, 25])[0]):
        cred_id += 1
        cod, desc, pmin, pmax = rnd.choice(PRODUCTOS)
        monto = rnd.randint(pmin, pmax)
        plazo = rnd.choice([6, 12, 18, 24, 36])
        tea = rnd.choice([0.35, 0.42, 0.48, 0.55, 0.62])
        tem = (1 + tea) ** (1 / 12.0) - 1
        cuota_teorica = monto * tem / (1 - (1 + tem) ** -plazo)
        cuota = r2(cuota_teorica)
        # ventana de desembolso: el credito debe tener al menos 2 cuotas vencidas
        techo_dias = (30 * A.meses) - (plazo * 30) - 5
        if techo_dias > 0:
            f_desembolso = INICIO + timedelta(days=rnd.randint(0, techo_dias))
        else:
            f_desembolso = INICIO + timedelta(days=rnd.randint(0, max(1, 30 * A.meses // 2)))
        if f_desembolso > HOY - timedelta(days=60):
            f_desembolso = HOY - timedelta(days=rnd.randint(60, 120))
        score = cl["score_inicial"] + rnd.randint(-40, 40)

        # probabilidad de deterioro segun score
        p_mora = 0.05 if score >= 700 else 0.18 if score >= 600 else 0.38 if score >= 500 else 0.60
        entra_mora = rnd.random() < p_mora
        mes_quiebre = rnd.randint(1, plazo) if entra_mora else None
        # modelo de cura: cada mes en mora hay prob. de regularizarse (mora real)
        p_curar = 0.22 if score >= 600 else 0.15 if score >= 500 else 0.10
        mes_cura = None
        if entra_mora:
            m = mes_quiebre
            while m < plazo:
                if rnd.random() < p_curar:
                    mes_cura = m
                    break
                m += 1

        creditos.append({
            "credito_id": "CRE%07d" % cred_id,
            "cliente_id": cl["cliente_id"],
            "producto": cod,
            "producto_desc": desc,
            "monto_desembolsado": r2(monto),
            "plazo_meses": plazo,
            "tea": tea,
            "cuota_mensual": cuota,
            "fecha_desembolso": fecha_iso(f_desembolso),
            "fecha_vencimiento_final": fecha_iso(f_desembolso + timedelta(days=30 * plazo)),
            "estado_credito": "VIGENTE",
            "score_desembolso": score,
            "oficina": rnd.choice(REGIONES),
        })

        cuotas_credito = []
        for k in range(1, plazo + 1):
            f_venc = f_desembolso + timedelta(days=30 * k)
            if f_venc > HOY:
                break
            en_mora = entra_mora and k >= mes_quiebre

            atraso = 0
            if en_mora:
                f_pago = None
                if mes_cura is not None and k >= mes_cura:
                    # regularizacion: paga con atraso (cubre PTP cumplidas)
                    atraso = rnd.choice([15, 22, 35, 60, 90, 120])
                else:
                    atraso = rnd.choice([3, 7, 15, 22, 35, 60])
                if f_venc + timedelta(days=atraso) <= HOY:
                    f_pago = f_venc + timedelta(days=atraso)
                monto_pagado = cuota if f_pago else 0.0
                estado = "PAGADA_CON_ATRASO" if f_pago else "VENCIDA"
            else:
                # cliente al dia: mayoria puntual, 4% se atrasa levemente
                if rnd.random() < 0.04:
                    atraso = rnd.choice([2, 4, 7, 12, 18, 25])
                else:
                    atraso = rnd.choice([0, 0, 0, 0, 0, 1, 2, -6, -12])
                if f_venc + timedelta(days=atraso) <= HOY:
                    f_pago = f_venc + timedelta(days=atraso)
                    monto_pagado = cuota
                    estado = "PAGADA_CON_ATRASO" if atraso > 0 else "PAGADA"
                else:
                    # la cuota aun no vence o el pago aun no ocurre
                    f_pago, monto_pagado, estado = None, 0.0, "VENCIDA"

            dias_atraso = (HOY - f_venc).days if estado == "VENCIDA" else (f_pago - f_venc).days

            fila = {
                "cuota_id": "CUO%09d" % (len(cuotas) + 1),
                "credito_id": "CRE%07d" % cred_id,
                "cliente_id": cl["cliente_id"],
                "nro_cuota": k,
                "fecha_vencimiento": fecha_iso(f_venc),
                "monto_cuota": cuota,
                "monto_pagado": r2(monto_pagado),
                "fecha_pago": fecha_iso(f_pago) if f_pago else "",
                "estado_cuota": estado,
                "dias_atraso": dias_atraso,
            }
            cuotas.append(fila)
            cuotas_credito.append(fila)

        # ---- gestiones de cobranza (el resultado depende del canal y del pago real)
        vencidas = [c for c in cuotas_credito if c["estado_cuota"] == "VENCIDA"]
        pagadas_tarde = [c for c in cuotas_credito if c["estado_cuota"] == "PAGADA_CON_ATRASO"]
        if vencidas:
            peor = max(c["dias_atraso"] for c in vencidas)
            creditos[-1]["estado_credito"] = ("CASTIGADO" if peor > 180 else "EN_COBRANZA")
            mala = rnd.random() < 0.12

        # 1) cuotas que se pagaron con atraso: gestiones que SI dieron resultado
        for c in pagadas_tarde:
            f_venc = date.fromisoformat(c["fecha_vencimiento"])
            f_pago = date.fromisoformat(c["fecha_pago"])
            n = rnd.randint(1, 3)
            f_ges = fechas_gestion(f_venc, min(c["dias_atraso"], 200), n)
            for i, f in enumerate(f_ges):
                if f >= f_pago:
                    break
                canal = rnd.choices(CANALES, weights=[38, 24, 22, 8, 4, 4])[0]
                ultima = (i == len(f_ges) - 1)
                if ultima:
                    # la ultima gestion es la que gatilla el pago
                    if rnd.random() < 0.45:
                        # hubo promesa y el cliente la cumplio
                        res = "PROMESA_PAGO"
                        gestiones.append(_fila_gestion(cred_id, cl["cliente_id"], c, f, canal,
                                                       "GESTION_MORA", res, c["fecha_pago"],
                                                       resultado_si_no_hay_prom="CONTACTADO"))
                    else:
                        res = "PAGO_TOTAL" if rnd.random() < 0.6 else "PAGO_PARCIAL"
                        gestiones.append(_fila_gestion(cred_id, cl["cliente_id"], c, f, canal,
                                                       "GESTION_MORA", res))
                else:
                    res = rnd.choices(["NO_CONTACTADO", "CONTACTADO", "PROMESA_PAGO",
                                       "RECHAZA_PAGO"], weights=[22, 38, 26, 14])[0]
                    gestiones.append(_fila_gestion(cred_id, cl["cliente_id"], c, f, canal,
                                                   "GESTION_TEMPRANA", res,
                                                   resultado_si_no_hay_prom="CONTACTADO"))

        # 2) cuotas que siguen impagas: gestiones sin pago (PTP incumplidas)
        for c in vencidas:
            d = min(c["dias_atraso"], 240)
            f_venc = date.fromisoformat(c["fecha_vencimiento"])
            n_ges = 1 if d <= 15 else rnd.randint(2, 6)
            for f in fechas_gestion(f_venc, d, n_ges):
                canal = rnd.choices(CANALES, weights=[35, 25, 20, 8, 5, 7])[0]
                tipo = TIPOS_GESTION[min(len(TIPOS_GESTION) - 1, d // 30 + rnd.randint(0, 1))]
                res = resultado_por_canal(canal, 0.0)
                if mala and res in ("PAGO_TOTAL", "PAGO_PARCIAL"):
                    res = rnd.choice(["NO_CONTACTADO", "CLIENTE_MOLESTO", "RECHAZA_PAGO"])
                gestiones.append(_fila_gestion(cred_id, cl["cliente_id"], c, f, canal, tipo, res,
                                               resultado_si_no_hay_prom="NO_CONTACTADO"))

# ---- snapshots diarios de mora (una fila por credito con saldo vencido)
#
# OPTIMIZACION: antes esto filtraba la lista completa de cuotas dentro de un
# doble bucle (creditos x 90 dias) = ~1.9 millones de recorridos de 71 mil filas.
# Ahora se precalcula UNA VEZ, por credito, la lista ordenada de cuotas vencidas
# y su suma acumulada. Luego cada corte se resuelve con busqueda binaria.
import bisect
from collections import defaultdict

VENC_POR_CREDITO = defaultdict(list)   # credito_id -> [(fecha_vencimiento, monto), ...]
for q in cuotas:
    if q["estado_cuota"] == "VENCIDA":
        VENC_POR_CREDITO[q["credito_id"]].append(
            (date.fromisoformat(q["fecha_vencimiento"]), float(q["monto_cuota"]))
        )
for cid in VENC_POR_CREDITO:
    VENC_POR_CREDITO[cid].sort(key=lambda x: x[0])

# fechas de vencimiento (para bisect) y suma acumulada de montos
FECHAS = {}
ACUM = {}
for cid, lst in VENC_POR_CREDITO.items():
    FECHAS[cid] = [f for f, _ in lst]
    acum = [0.0]
    for _, m in lst:
        acum.append(acum[-1] + m)
    ACUM[cid] = acum

mora_creditos = [c for c in creditos if c["estado_credito"] in ("EN_COBRANZA", "CASTIGADO")]
for d in range(0, 90):
    f_snap = HOY - timedelta(days=d)
    if f_snap.weekday() == 6:
        continue
    for c in mora_creditos:
        cid = c["credito_id"]
        fechas = FECHAS.get(cid)
        if not fechas:
            continue
        # cuantas cuotas vencidas ya vencieron a la fecha del corte
        n = bisect.bisect_right(fechas, f_snap)
        if n == 0:
            continue
        primera = fechas[0]
        dias = max(0, (f_snap - primera).days)
        if dias == 0:
            continue
        saldo_v = r2(ACUM[cid][n])   # suma de las primeras n cuotas vencidas
        snapshots.append({
            "fecha_corte": fecha_iso(f_snap),
            "credito_id": cid,
            "cliente_id": c["cliente_id"],
            "dias_atraso": dias,
            "bucket_mora": bucket(dias),
            "saldo_vencido": saldo_v,
            "saldo_total": r2(saldo_v * rnd.uniform(1.2, 2.5)),
            "cuotas_vencidas": n,
            "score_actual": max(300, min(850, c["score_desembolso"] - dias // 3)),
            "elegible_castigo": "SI" if dias > 180 else "NO",
        })

# ------------------------------------------------- inyeccion de suciedad
SUCIO = A.sucio
if SUCIO:
    # 1) duplicados exactos en clientes
    for _ in range(max(5, N // 200)):
        clientes.append(dict(rnd.choice(clientes)))
    # 2) emails invalidos y nulos
    for _ in range(max(5, N // 100)):
        cl = rnd.choice(clientes)
        cl["email"] = rnd.choice(["", "sin-email", "correo@@mal.com", None])
    # 3) fechas de pago futuras
    for _ in range(max(5, len(cuotas) // 500)):
        q = rnd.choice(cuotas)
        if q["fecha_pago"]:
            q["fecha_pago"] = fecha_iso(HOY + timedelta(days=rnd.randint(5, 400)))
    # 4) montos negativos o cero
    for _ in range(max(3, len(cuotas) // 800)):
        q = rnd.choice(cuotas)
        q["monto_pagado"] = r2(rnd.choice([-1, 0, -q["monto_cuota"]]))
    # 5) inconsistencias de mayusculas en enums
    for _ in range(max(5, len(gestiones) // 300)):
        g = rnd.choice(gestiones)
        g["canal"] = rnd.choice([g["canal"].lower(), g["canal"].title(), " " + g["canal"]])
        g["resultado"] = rnd.choice([g["resultado"].lower(), g["resultado"].title()])
    # 6) telefono mal formado
    for _ in range(max(5, N // 150)):
        rnd.choice(clientes)["telefono"] = rnd.choice(["", "999", "000000000", "+51 9 99 99"])
    # 6b) clientes SIN NINGUN canal de contacto valido (~4% de la cartera)
    #     Esto es realista y hace util el indicador de contactabilidad: en cobranzas
    #     hay clientes a los que simplemente no se les puede ubicar por los canales
    #     registrados (telefono y correo malos), y van a gestion presencial o judicial.
    N_INCONTACTABLES = max(10, N // 25)
    for cl in rnd.sample(clientes, N_INCONTACTABLES):
        cl["telefono"] = rnd.choice(["", "999", "000000000"])
        cl["email"] = rnd.choice(["", "sin-email", "correo@@mal.com"])
    # 7) cuota pagada sin fecha de pago
    for _ in range(max(3, len(cuotas) // 700)):
        q = rnd.choice(cuotas)
        if q["estado_cuota"] == "PAGADA":
            q["fecha_pago"] = ""

# ---------------------------------------------------------------- escritura
os.makedirs(A.out, exist_ok=True)
TABLAS = [("clientes", clientes), ("creditos", creditos), ("cuotas", cuotas),
          ("gestiones_cobranza", gestiones), ("mora_snapshot", snapshots)]

for nombre, filas in TABLAS:
    if not filas:
        continue
    ruta = os.path.join(A.out, nombre + ".csv")
    campos = list(filas[0].keys())
    with open(ruta, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        for fila in filas:
            w.writerow(fila)
    tam = os.path.getsize(ruta) / 1024.0
    print("  %-22s %8d filas  %9.1f KB" % (nombre + ".csv", len(filas), tam))

print("\nDataset generado en: %s" % os.path.abspath(A.out))
print("Periodo: %s a %s   |   Semilla: %d   |   Datos sucios: %s"
      % (INICIO, HOY, A.seed, "SI" if SUCIO else "NO"))

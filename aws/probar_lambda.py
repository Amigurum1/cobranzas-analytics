# -*- coding: utf-8 -*-
"""
Prueba el Lambda disparador SIN AWS, simulando boto3.

Verifica:
  1. Que filtre correctamente los eventos que NO deben disparar el pipeline
  2. Que dispare cuando llega un CSV nuevo a raw/
  3. Que la proteccion anti-tormenta funcione (no lanzar dos jobs a la vez)

Uso: python probar_lambda.py
"""

import json
import sys
import types

# ---------------------------------------------------------------------------
# Simulacion de boto3 ANTES de importar el modulo del Lambda
# ---------------------------------------------------------------------------
llamadas = {"start_job_run": [], "get_job_runs": 0}
JOB_ACTIVO = {"valor": False}   # se cambia para probar la proteccion


class FakeGlue:
    def get_job_runs(self, JobName, MaxResults=10):
        llamadas["get_job_runs"] += 1
        if JOB_ACTIVO["valor"]:
            return {"JobRuns": [{"Id": "jr-activo-123", "JobRunState": "RUNNING"}]}
        return {"JobRuns": [{"Id": "jr-viejo", "JobRunState": "SUCCEEDED"}]}

    def start_job_run(self, JobName, Arguments):
        llamadas["start_job_run"].append({"JobName": JobName, "Arguments": Arguments})
        return {"JobRunId": "jr-nuevo-456"}


class FakeS3:
    pass


fake_boto3 = types.ModuleType("boto3")
fake_boto3.client = lambda servicio: FakeGlue() if servicio == "glue" else FakeS3()

sys.modules["boto3"] = fake_boto3

# botocore no esta instalado en local (solo existe en el runtime de Lambda),
# asi que se simula el unico objeto que usa el handler.
fake_botocore = types.ModuleType("botocore")
fake_excepciones = types.ModuleType("botocore.exceptions")


class ClientError(Exception):
    def __init__(self, response, operation_name="op"):
        self.response = response
        super().__init__(str(response))


fake_excepciones.ClientError = ClientError
fake_botocore.exceptions = fake_excepciones
sys.modules["botocore"] = fake_botocore
sys.modules["botocore.exceptions"] = fake_excepciones

# ---------------------------------------------------------------------------
# Importar el handler ya con boto3 simulado
# ---------------------------------------------------------------------------
sys.path.insert(0, ".")
import lambda_disparador as lam   # noqa: E402


def evento(clave, bucket="mi-bucket"):
    return {"Records": [{"s3": {"bucket": {"name": bucket},
                                "object": {"key": clave}}}]}


def correr(descripcion, ev, esperado_ejecutado, esperado_motivo=None):
    llamadas["start_job_run"].clear()
    lam.HOY = "2026-09-28"
    resultado = lam.lambda_handler(ev, None)
    ejecutado = resultado.get("ejecutado")
    ok = (ejecutado == esperado_ejecutado)
    if esperado_motivo:
        ok = ok and resultado.get("motivo") == esperado_motivo
    estado = "OK   " if ok else "FALLA"
    print("  [%s] %-52s ejecutado=%s%s"
          % (estado, descripcion, ejecutado,
             ("  motivo=" + str(resultado.get("motivo"))) if resultado.get("motivo") else ""))
    return ok


print("=" * 78)
print("PRUEBAS DEL LAMBDA DISPARADOR (sin AWS)")
print("=" * 78)
fallos = 0

print("\n1. Eventos que NO deben disparar el pipeline")
JOB_ACTIVO["valor"] = False
casos_ignorar = [
    ("archivo fuera de raw/ (curated)", "curated/fact_cuotas/anio=2026/part.parquet"),
    ("el propio script del job", "scripts/glue_job_limpieza.py"),
    ("resultados de Athena", "athena-results/consulta.csv"),
    ("logs del pipeline", "logs/ejecucion.txt"),
    ("marcador de finalizacion de Glue", "raw/_SUCCESS"),
    ("archivo temporal", "raw/cuotas/cuotas.csv.tmp"),
    ("evento de creacion de carpeta", "raw/clientes/"),
]
for desc, clave in casos_ignorar:
    if not correr(desc, evento(clave), False):
        fallos += 1

print("\n2. Eventos que SI deben disparar el pipeline")
for desc, clave in [
    ("CSV nuevo en raw/cuotas/", "raw/cuotas/cuotas.csv"),
    ("CSV nuevo en raw/clientes/", "raw/clientes/clientes.csv"),
    ("CSV nuevo en raw/gestiones_cobranza/", "raw/gestiones_cobranza/gestiones_cobranza.csv"),
]:
    if not correr(desc, evento(clave), True):
        fallos += 1

print("\n3. Argumentos que la Lambda le pasa al job de Glue")
if llamadas["start_job_run"]:
    args = llamadas["start_job_run"][0]["Arguments"]
    print("    JobName  : %s" % llamadas["start_job_run"][0]["JobName"])
    for k, v in args.items():
        print("    %-10s: %s" % (k, v))
    requeridos = ["--BUCKET", "--DATABASE", "--HOY"]
    faltan = [r for r in requeridos if r not in args]
    if faltan:
        print("  [FALLA] faltan argumentos requeridos por el job: %s" % faltan)
        fallos += 1
    else:
        print("  [OK  ] estan los 3 argumentos requeridos por el job de Glue")
else:
    print("  [FALLA] no se registro ninguna llamada a start_job_run")
    fallos += 1

print("\n4. Proteccion anti-tormenta (job ya en ejecucion)")
JOB_ACTIVO["valor"] = True
if not correr("no lanza otro job si ya hay uno corriendo",
              evento("raw/cuotas/cuotas.csv"), False, "job_ya_en_ejecucion"):
    fallos += 1

print("\n5. Invocacion manual de prueba")
JOB_ACTIVO["valor"] = False
ejecutado = lam.lambda_handler({"forzar_ejecucion": True}, None).get("ejecutado")
print("  [%s] con forzar_ejecucion y sin archivos -> ejecutado=%s"
      % ("OK   " if ejecutado else "FALLA", ejecutado))
if not ejecutado:
    fallos += 1

print("\n" + "=" * 78)
if fallos == 0:
    print(" RESULTADO: todas las pruebas pasaron")
else:
    print(" RESULTADO: %d pruebas fallaron" % fallos)
print("=" * 78)
sys.exit(1 if fallos else 0)

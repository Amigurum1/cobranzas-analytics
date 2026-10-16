# -*- coding: utf-8 -*-
"""
=============================================================================
LAMBDA DE AUTOMATIZACION DEL PIPELINE
Proyecto: Analitica de cobranzas - pipeline de datos en AWS
=============================================================================

Que hace
--------
Se dispara cuando llega un archivo nuevo a  s3://<bucket>/raw/  y arranca el job
de Glue que limpia y construye la capa curated. Es el "gatillo" del pipeline:
nadie tiene que entrar a la consola a apretar un boton.

Flujo completo:
    archivo nuevo en raw/  ->  S3 (evento)  ->  Lambda  ->  Glue job  ->  curated/

Por que la Lambda NO transforma los datos ella misma
----------------------------------------------------
Se podria hacer, pero implicaria empaquetar pandas + pyarrow en un Layer y
mantener el ETL duplicado en dos lugares. Es mas fragil y mas caro de mantener.
La Lambda hace UNA cosa bien: orquestar. El trabajo pesado lo hace Glue, que
esta hecho para eso.

Protecciones que implementa
---------------------------
1. Anti-tormenta: si el job ya esta corriendo, no lanza otro (evita costos
   duplicados y escrituras simultaneas sobre la capa curated).
2. Filtra eventos irrelevantes: ignora carpetas, archivos temporales de Athena
   y el marcador de la propia ejecucion.
3. Ignora el marcador de finalizacion que el propio Glue job deja en raw/.

Variables de entorno
--------------------
    GLUE_JOB_NAME   nombre del job de Glue        (ej. analitica-cobranzas-limpieza)
    BUCKET          nombre del bucket S3
    HOY             fecha de referencia YYYY-MM-DD (si no se define, usa la del dia)

=============================================================================
"""

import json
import logging
import os
from datetime import date

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

glue = boto3.client("glue")
s3 = boto3.client("s3")

GLUE_JOB_NAME = os.environ.get("GLUE_JOB_NAME", "analitica-cobranzas-limpieza")
BUCKET = os.environ.get("BUCKET", "")
HOY = os.environ.get("HOY") or date.today().isoformat()

# Archivos/patrones que NO deben disparar el pipeline
IGNORAR = (
    "_SUCCESS",
    "_marcador",
    ".tmp",
    "/athena-results/",
    "/curated/",
    "/scripts/",
    "/logs/",
)


def _decodificar_clave(registro):
    """Extrae la clave del objeto desde un evento de S3."""
    return registro["s3"]["object"]["key"]


def _eventos_relevantes(evento):
    """Filtra el evento de S3 y devuelve solo las claves que importan."""
    claves = []
    for registro in evento.get("Records", []):
        try:
            clave = _decodificar_clave(registro)
        except (KeyError, TypeError):
            logger.warning("Registro de S3 con formato inesperado, se omite")
            continue

        # s3:ObjectCreated:* incluye eventos de carpetas (clave terminada en /)
        if clave.endswith("/"):
            continue
        if any(patron in clave for patron in IGNORAR):
            logger.info("Se ignora (patron excluido): %s", clave)
            continue
        # Solo la capa raw dispara el pipeline
        if not clave.startswith("raw/"):
            logger.info("Se ignora (no es capa raw): %s", clave)
            continue
        claves.append(clave)

    return claves


def _job_en_ejecucion():
    """Devuelve True si el job de Glue ya tiene una corrida activa."""
    respuesta = glue.get_job_runs(JobName=GLUE_JOB_NAME, MaxResults=10)
    activos = {"STARTING", "RUNNING", "WAITING", "STOPPING"}
    for corrida in respuesta.get("JobRuns", []):
        if corrida.get("JobRunState") in activos:
            return corrida.get("Id")
    return None


def lambda_handler(event, contexto):
    """Punto de entrada. Se invoca desde un evento de S3 o manualmente."""
    logger.info("Evento recibido: %s", json.dumps(event)[:2000])

    claves = _eventos_relevantes(event)

    # Invocacion manual (por ejemplo desde la consola, para probar)
    if not claves:
        if event.get("forzar_ejecucion"):
            logger.info("Ejecucion forzada manualmente, sin archivo asociado")
        else:
            logger.info("No hay archivos relevantes en el evento. Nada que hacer.")
            return {"ejecutado": False, "motivo": "sin_archivos_relevantes"}

    logger.info("Archivos detectados: %s", claves)

    # --- Proteccion anti-tormenta: no lanzar un job si ya hay uno corriendo ---
    run_activo = _job_en_ejecucion()
    if run_activo:
        logger.warning(
            "Ya hay una corrida de Glue activa (JobRunId=%s). No se lanza otra.",
            run_activo,
        )
        return {
            "ejecutado": False,
            "motivo": "job_ya_en_ejecucion",
            "job_run_id": run_activo,
            "archivos_detectados": claves,
        }

    # --- Lanzar el job de Glue ---
    argumentos = {
        "--BUCKET": BUCKET,
        "--DATABASE": "analitica_cobranzas",
        "--HOY": HOY,
        "--origen": "lambda",
        "--archivos": ",".join(claves)[:1000],
    }

    try:
        respuesta = glue.start_job_run(JobName=GLUE_JOB_NAME, Arguments=argumentos)
        run_id = respuesta["JobRunId"]
        logger.info("Job de Glue lanzado. JobRunId=%s", run_id)
        return {
            "ejecutado": True,
            "job_run_id": run_id,
            "archivos_detectados": claves,
            "fecha_referencia": HOY,
        }
    except ClientError as e:
        codigo = e.response["Error"]["Code"]
        logger.error("No se pudo lanzar el job de Glue: %s - %s", codigo, e)
        # Si el job no existe, es un error de configuracion, no un fallo transitorio
        if codigo in ("EntityNotFoundException", "InvalidInputException"):
            raise
        return {"ejecutado": False, "motivo": "error_glue", "detalle": str(e)}

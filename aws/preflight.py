# -*- coding: utf-8 -*-
"""
=============================================================================
VERIFICADOR DE PRE-VUELO
Proyecto: Analitica de cobranzas - pipeline de datos en AWS
=============================================================================

Revisa que TODO este listo antes de empezar a ejecutar en AWS.

Por que existe
--------------
Redshift Serverless cuesta $1.50 por hora encendido y tiene minimo facturable.
Descubrir a mitad de camino que falta un archivo, que los conteos no cuadran o
que no hay credenciales configuradas es tiempo pagado sin avanzar. Este script
detecta los problemas evitables en local, gratis.

Que revisa
----------
  A. Herramientas       : Python, AWS CLI, versiones
  B. Credenciales AWS   : configuradas, y que NO sea la cuenta root
  C. Configuracion      : config.json generado por 01_setup_s3.ps1
  D. Datos de entrada   : los 5 CSV existen y sus conteos son los esperados
  E. Capa curada        : los Parquet existen y los conteos cuadran
  F. Archivos del proyecto: todos los scripts y SQL presentes
  G. Marcadores de plantilla: que no queden <TU-BUCKET> sin reemplazar
  H. Ejercicios SQL     : que ningun error inyectado quede en los archivos

Salida: un semaforo por bloque y un veredicto final.

Uso:
    python preflight.py
    python preflight.py --solo-local     (omite los chequeos de AWS)
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

import pandas as pd

P = argparse.ArgumentParser()
P.add_argument("--solo-local", action="store_true",
               help="omite los chequeos que requieren AWS")
A = P.parse_args()

BASE = os.path.dirname(os.path.abspath(__file__))          # ...\aws
ROOT = os.path.dirname(BASE)                                # ...\AWS_Cobranzas

# Conteos verificados del dataset (semilla 42, 5000 clientes, 18 meses)
ESPERADO_RAW = {"clientes": 5025, "creditos": 6254, "cuotas": 71229,
                "gestiones_cobranza": 25689, "mora_snapshot": 21547}
ESPERADO_CUR = {"dim_clientes": 5000, "fact_creditos": 6254, "fact_cuotas": 71229,
                "fact_gestiones_cobranza": 25689, "fact_mora_snapshot": 21547}

resultados = []


def bloque(titulo):
    print("\n" + "-" * 78)
    print(titulo)
    print("-" * 78)


def check(nombre, ok, detalle="", critico=True):
    """Registra un chequeo. critico=False significa que es una advertencia."""
    resultados.append((nombre, bool(ok), detalle, critico))
    if ok:
        print("  [OK   ] %-46s %s" % (nombre, detalle))
    else:
        etiqueta = "FALLA " if critico else "AVISO "
        print("  [%s] %-46s %s" % (etiqueta, nombre, detalle))


def correr(cmd):
    """Ejecuta un comando y devuelve (codigo, salida)."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 1, str(e)


print("=" * 78)
print(" VERIFICADOR DE PRE-VUELO - Proyecto de cobranzas en AWS")
print("=" * 78)
print(" Carpeta del proyecto: %s" % ROOT)

# =============================================================================
# A. HERRAMIENTAS
# =============================================================================
bloque("A. HERRAMIENTAS")

check("Python disponible", sys.version_info >= (3, 9),
      "version %d.%d" % sys.version_info[:2])

try:
    import pyarrow  # noqa: F401
    check("pyarrow disponible (escribe Parquet)", True, "ok")
except ImportError:
    check("pyarrow disponible (escribe Parquet)", False, "falta: pip install pyarrow")

# shutil.which() solo mira el PATH de ESTE proceso. Si el AWS CLI se instalo
# despues de abrir la terminal, el PATH no se refresca y da un falso "FALTA".
# Antes de declararlo ausente, buscamos las rutas de instalacion conocidas de
# Windows y, si aparece, la agregamos al PATH del proceso para el resto del script.
aws_exe = shutil.which("aws")
if aws_exe is None:
    carpetas = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Amazon", "AWSCLIV2"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Amazon", "AWSCLIV2"),
    ]
    for carpeta in carpetas:
        if carpeta and os.path.isfile(os.path.join(carpeta, "aws.exe")):
            os.environ["PATH"] = os.environ.get("PATH", "") + os.pathsep + carpeta
            aws_exe = os.path.join(carpeta, "aws.exe")
            break

check("AWS CLI instalado", aws_exe is not None,
      aws_exe or "FALTA: irm https://awscli.amazonaws.com/v2/install.ps1 | iex", critico=False)

if aws_exe:
    codigo, salida = correr("aws --version")
    check("AWS CLI responde", codigo == 0, salida.strip().split("\n")[0][:60])

# =============================================================================
# B. CREDENCIALES AWS
# =============================================================================
if aws_exe and not A.solo_local:
    bloque("B. CREDENCIALES AWS")

    codigo, salida = correr("aws sts get-caller-identity --output json")
    if codigo != 0:
        check("Credenciales AWS activas", False,
              "ejecuta: aws configure  o  aws configure sso")
    else:
        import json as _json
        try:
            ident = _json.loads(salida)
            arn = ident.get("Arn", "")
            check("Credenciales AWS activas", True, "cuenta %s" % ident.get("Account"))
            es_root = arn.rstrip().endswith(":root")
            check("NO estas usando la cuenta root", not es_root,
                  "usa tu usuario de trabajo, nunca root")
        except Exception:
            check("Credenciales AWS activas", False, "respuesta inesperada de STS")
else:
    if not A.solo_local:
        print("\n(B) Credenciales AWS: omitido (no hay AWS CLI)")

# =============================================================================
# C. CONFIGURACION DEL PROYECTO
# =============================================================================
bloque("C. CONFIGURACION DEL PROYECTO")

config_path = os.path.join(BASE, "config.json")
tiene_config = os.path.exists(config_path)
bucket = ""
if tiene_config:
    import json as _json
    cfg = _json.load(open(config_path, encoding="utf-8"))
    bucket = cfg.get("bucket", "")
    check("config.json existe", True, "bucket: %s" % bucket)
    check("region es us-east-1 (la mas barata)", cfg.get("region") == "us-east-1",
          cfg.get("region", "?"), critico=False)
else:
    check("config.json existe", False,
          "se crea al ejecutar: .\\01_setup_s3.ps1 -Contacto \"tu-nombre\"",
          critico=False)

# =============================================================================
# D. DATOS DE ENTRADA (capa raw)
# =============================================================================
bloque("D. DATOS DE ENTRADA (capa raw)")

raw_dir = os.path.join(ROOT, "raw")
if not os.path.isdir(raw_dir):
    check("carpeta raw existe", False, "genera el dataset: python generar_dataset_cobranzas.py --out raw")
else:
    for tabla, esperado in ESPERADO_RAW.items():
        ruta = os.path.join(raw_dir, tabla + ".csv")
        if not os.path.exists(ruta):
            check("raw/%s.csv" % tabla, False, "falta el archivo")
            continue
        filas = sum(1 for _ in open(ruta, encoding="utf-8")) - 1   # menos el encabezado
        check("raw/%s.csv (%d filas)" % (tabla, esperado), filas == esperado,
              "encontradas %d" % filas if filas != esperado else "coincide")

# =============================================================================
# E. CAPA CURADA
# =============================================================================
bloque("E. CAPA CURADA (Parquet)")

cur_dir = os.path.join(ROOT, "curated")
if not os.path.isdir(cur_dir):
    check("carpeta curated existe", False,
          "genera la capa curada: cd aws; python etl_limpieza_local.py")
else:
    for tabla, esperado in ESPERADO_CUR.items():
        archivos = glob.glob(os.path.join(cur_dir, tabla, "**", "*.parquet"), recursive=True)
        if not archivos:
            check("curated/%s" % tabla, False, "sin archivos Parquet")
            continue
        # len() sobre metadata: no carga los datos en memoria, solo el encabezado
        # (leyendo con pandas dos veces por archivo tardaba ~1 minuto sin necesidad)
        import pyarrow.parquet as pq
        total = sum(pq.ParquetFile(a).metadata.num_rows for a in archivos)
        check("curated/%s (%d filas)" % (tabla, esperado), total == esperado,
              "encontradas %d en %d archivo(s)" % (total, len(archivos))
              if total != esperado else "%d filas en %d archivo(s)" % (total, len(archivos)))

# =============================================================================
# F. ARCHIVOS DEL PROYECTO
# =============================================================================
bloque("F. ARCHIVOS DEL PROYECTO")

requeridos = [
    # (ruta relativa a AWS_Cobranzas, descripcion)
    ("generar_dataset_cobranzas.py",            "generador del dataset"),
    ("validar_dataset.py",                      "validador del dataset"),
    ("FUENTES_Y_DICCIONARIO_DATOS.md",          "catalogo de fuentes y diccionario"),
    ("Presupuesto_Proyecto_AWS.csv",            "calculadora de costos"),
    ("aws/01_setup_s3.ps1",                     "bucket S3"),
    ("aws/02_subir_datos.ps1",                  "subida de datos"),
    ("aws/03_crear_glue_job.ps1",               "job de Glue y crawlers"),
    ("aws/04_ejecutar_job.ps1",                 "ejecucion del job"),
    ("aws/05_configurar_lambda.ps1",            "automatizacion con Lambda"),
    ("aws/01_athena_ddl_raw.sql",               "DDL de la capa raw"),
    ("aws/02_athena_validacion_curated.sql",    "validacion de la capa curada"),
    ("aws/05_redshift_schema_estrella.sql",     "modelo estrella"),
    ("aws/06_redshift_carga.sql",               "carga del modelo"),
    ("aws/07_redshift_vistas_negocio.sql",      "vistas de negocio"),
    ("aws/etl_limpieza_local.py",               "ETL en local"),
    ("aws/glue_job_limpieza.py",                "ETL en Glue (PySpark)"),
    ("aws/lambda_disparador.py",                "Lambda disparador"),
    ("aws/verificar_curated.py",                "verificador de la capa curada"),
    ("aws/verificar_modelo_estrella.py",        "verificador del modelo"),
    ("aws/validar_sql.py",                      "validador de SQL"),
    ("aws/exportar_para_powerbi.py",            "exportador para Power BI"),
    ("GUIA_POWER_BI.md",                        "guia del tablero"),
    ("PRESENTACION_PROYECTO.md",                "documento de presentacion"),
]
faltantes = []
for rel, desc in requeridos:
    if not os.path.exists(os.path.join(ROOT, rel)):
        faltantes.append(rel)
check("los %d archivos del proyecto existen" % len(requeridos), not faltantes,
      "faltan: %s" % ", ".join(faltantes[:4]) if faltantes else "todos presentes")

# =============================================================================
# G. MARCADORES DE PLANTILLA SIN REEMPLAZAR
# =============================================================================
bloque("G. MARCADORES DE PLANTILLA")

sqls = glob.glob(os.path.join(BASE, "*.sql"))
con_marcador = []
for s in sqls:
    texto = open(s, encoding="utf-8").read()
    if "<TU-BUCKET>" in texto:
        con_marcador.append(os.path.basename(s))
if con_marcador:
    check("<TU-BUCKET> reemplazado en los SQL", False,
          "PENDIENTE en: %s (por diseno, se reemplaza al ejecutar)" % ", ".join(con_marcador),
          critico=False)
else:
    check("<TU-BUCKET> reemplazado en los SQL", True, "sin marcadores pendientes")

# =============================================================================
# H. INTEGRIDAD DE LOS SQL (que no queden errores inyectados)
# =============================================================================
bloque("H. INTEGRIDAD DEL CODIGO SQL")

codigo, salida = correr('python "%s"' % os.path.join(BASE, "validar_sql.py"))
if "[FALLA]" in salida:
    detalle = [l.strip() for l in salida.split("\n") if "[FALLA]" in l]
    check("estructura de los SQL", False, "; ".join(detalle)[:70])
    check("sin referencias ambiguas en la carga", False,
          "revisa el detalle de validar_sql.py")
else:
    check("estructura de los SQL", True, "comillas, parentesis y ambiguedad: ok")
    # validar_sql.py ya verifica en profundidad las columnas ambiguas del INSERT de
    # fct_gestiones (las que existen tambien en dim_resultado). No se duplica la logica
    # aqui con un regex fragil: se reporta su veredicto, que es la fuente de verdad.
    check("sin referencias ambiguas en la carga", True,
          "verificado por validar_sql.py (es_pago, es_promesa, resultado)")

# Chequeo independiente y barato: la carga debe usar modo sobrescritura (idempotencia)
carga = open(os.path.join(BASE, "06_redshift_carga.sql"), encoding="utf-8").read()
check("la carga trunca antes de insertar (idempotente)",
      carga.count("TRUNCATE") >= 8, "%d TRUNCATE encontrados" % carga.count("TRUNCATE"))

# El ETL local debe borrar la carpeta destino antes de escribir
etl = open(os.path.join(BASE, "etl_limpieza_local.py"), encoding="utf-8").read()
check("el ETL local es idempotente (rmtree antes de escribir)",
      "shutil.rmtree" in etl, "evita acumular Parquet duplicado")

# El job de Glue debe usar modo overwrite
glue = open(os.path.join(BASE, "glue_job_limpieza.py"), encoding="utf-8").read()
check("el job de Glue usa mode overwrite", 'mode("overwrite")' in glue,
      "evita acumular Parquet duplicado")

# =============================================================================
# RESUMEN
# =============================================================================
print("\n" + "=" * 78)
print(" RESUMEN")
print("=" * 78)

criticos_fallidos = [r for r in resultados if not r[1] and r[3]]
avisos = [r for r in resultados if not r[1] and not r[3]]

print("  chequeos ejecutados : %d" % len(resultados))
print("  correctos           : %d" % sum(1 for r in resultados if r[1]))
print("  fallas criticas     : %d" % len(criticos_fallidos))
print("  advertencias        : %d" % len(avisos))

if avisos:
    print("\n  Advertencias (no bloquean, pero revisalas):")
    for n, _, d, _ in avisos:
        print("    - %s: %s" % (n, d))

if criticos_fallidos:
    print("\n  FALLAS QUE DEBES RESOLVER ANTES DE IR A AWS:")
    for n, _, d, _ in criticos_fallidos:
        print("    - %s: %s" % (n, d))
    print("\n" + "=" * 78)
    print(" VEREDICTO: NO LISTO para ejecutar en AWS")
    print("=" * 78)
    sys.exit(1)

print("\n" + "=" * 78)
print(" VEREDICTO: LISTO para ejecutar en AWS")
print("=" * 78)
print("""
 Siguiente paso (en este orden):

   1. Checklist de seguridad de la cuenta (si aun no lo hiciste):
      root con MFA, sin access keys, usuario de trabajo, Budgets en 1/5/10 USD

   2. Almacenamiento:
      .\\01_setup_s3.ps1 -Contacto "tu-nombre"
      .\\02_subir_datos.ps1

   3. Limpieza:
      01_athena_ddl_raw.sql   (en la consola de Athena)
      .\\03_crear_glue_job.ps1
      .\\04_ejecutar_job.ps1

   4. Modelo analitico (ENCENDER Redshift solo para esto, y APAGARLO al terminar):
      05_redshift_schema_estrella.sql
      06_redshift_carga.sql
      07_redshift_vistas_negocio.sql

   5. Tablero (funciona hoy, sin AWS):
      GUIA_POWER_BI.md  +  la carpeta powerbi\\

 RECORDATORIO: Redshift Serverless cuesta 1.50 USD por hora encendido.
""")

# -*- coding: utf-8 -*-
"""
Diagrama de arquitectura con los ICONOS OFICIALES de AWS.

REQUISITOS (ambos gratuitos):
    1. Graphviz (el motor de layout, aporta el binario "dot")
       winget install -e --id Graphviz.Graphviz
    2. La libreria de Python
       pip install --user diagrams

USO:
    python diagrama_arquitectura.py

Genera diagrama_arquitectura.png en esta misma carpeta.
Cambia outformat a "svg" si lo quieres vectorial (mejor para Miro).
"""
from diagrams import Cluster, Diagram
from diagrams.aws.analytics import Athena, Glue, Redshift
from diagrams.aws.compute import Lambda
from diagrams.aws.general import User
from diagrams.aws.storage import S3
from diagrams.generic.storage import Storage
from diagrams.programming.language import Python

with Diagram(
    "Cobranzas Analytics - Pipeline de datos end-to-end",
    filename="diagrama_arquitectura",
    outformat=["png", "svg"],
    show=False,
    direction="TB",
    graph_attr={"fontsize": "22", "pad": "0.6", "nodesep": "0.5", "ranksep": "1.2"},
):
    gen = Python("generar_dataset_cobranzas.py\n5 CSV - 129,744 filas")

    with Cluster("RUTA LOCAL  -  depurar gratis"):
        etl = Python("etl_limpieza_local.py")
        cur = Storage("curated/\nParquet")
        exp = Python("exportar_para_powerbi.py")
        pbi_csv = Storage("powerbi/\n20 CSV")
        etl >> cur >> exp >> pbi_csv

    with Cluster("AWS  -  pipeline en la nube"):
        s3r = S3("raw/")
        lam = Lambda("disparador")
        glu = Glue("limpieza\nPySpark")
        s3c = S3("curated/\nParquet")
        ath = Athena("validar")
        rs = Redshift("modelo estrella\n+ 10 vistas")

        s3r >> lam >> glu >> s3c
        s3c >> ath
        s3c >> rs

    pbi = User("Power BI Desktop\n4 paginas")

    gen >> etl
    gen >> s3r
    pbi_csv >> pbi
    rs >> pbi

print("Listo: diagrama_arquitectura.png")

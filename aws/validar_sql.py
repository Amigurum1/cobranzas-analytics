# -*- coding: utf-8 -*-
"""
Valida los archivos SQL del modelo estrella de forma estructural:
  1. Comillas balanceadas (detecta literales sin cerrar)
  2. Sentencias bien formadas
  3. Ambiguedad de columnas en los INSERT ... SELECT de fct_gestiones
     (columnas que existen tanto en la tabla de hechos como en una dimension)

No es un parser de SQL completo: es un chequeo de las trampas que ya causaron
un bug real (es_pago / es_promesa presentes en hechos y en dim_resultado).
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
ARCHIVOS = sys.argv[1:] or [
    "05_redshift_schema_estrella.sql",
    "06_redshift_carga.sql",
    "07_redshift_vistas_negocio.sql",
]

# columnas que existen en dim_resultado y tambien en fct_gestiones
AMBIGUAS = ["es_pago", "es_promesa", "es_contacto", "resultado"]

fallos = 0

for nombre in ARCHIVOS:
    ruta = os.path.join(BASE, nombre)
    sql = open(ruta, encoding="utf-8").read()
    print("=" * 78)
    print(nombre)
    print("=" * 78)

    # --- 1. comillas simples balanceadas ---
    n_comillas = sql.count("'")
    if n_comillas % 2 == 0:
        print("  [OK ] comillas simples balanceadas (%d)" % n_comillas)
    else:
        print("  [FALLA] comillas simples IMPARES (%d) -> hay un literal sin cerrar" % n_comillas)
        fallos += 1

    # --- 2. sentencias (quitando comentarios y separando por ;) ---
    sin_comentarios = re.sub(r"--[^\n]*", "", sql)
    sin_comentarios = re.sub(r"/\*.*?\*/", "", sin_comentarios, flags=re.S)
    sentencias = [s.strip() for s in sin_comentarios.split(";") if s.strip()]
    print("  [OK ] sentencias detectadas: %d" % len(sentencias))

    # --- 3. parentesis balanceados ---
    abre, cierra = sql.count("("), sql.count(")")
    if abre == cierra:
        print("  [OK ] parentesis balanceados (%d)" % abre)
    else:
        print("  [FALLA] parentesis desbalanceados: %d abren, %d cierran" % (abre, cierra))
        fallos += 1

    # --- 4. ambiguedad en el INSERT de fct_gestiones ---
    # Se decide por CONTENIDO, no por nombre de archivo: asi la validacion tambien
    # funciona sobre una copia de prueba (necesario para el test negativo).
    if "INSERT INTO fct_gestiones" in sql:
        m = re.search(r"INSERT INTO fct_gestiones\s*\((.*?)\)\s*\nWITH\s+(\w+)\s+AS\s*\(", sql, re.S)
        if m:
            insert_cols = [c.strip() for c in m.group(1).replace("\n", " ").split(",")]

            # Extraer el cuerpo de la CTE con un escaner de parentesis BALANCEADOS.
            # Un regex no sirve: el cuerpo tiene parentesis anidados (SPLIT_PART(...)),
            # y ".*?\)" cortaria en el primero, dejando fuera los CASE del final.
            inicio = m.end() - 1
            nivel, pos = 0, inicio
            while pos < len(sql):
                if sql[pos] == "(":
                    nivel += 1
                elif sql[pos] == ")":
                    nivel -= 1
                    if nivel == 0:
                        break
                pos += 1
            cte_part = sql[inicio + 1:pos]

            # El SELECT final es lo que sigue al cierre de la CTE
            resto = sql[pos + 1:]
            sel = re.search(r"\bSELECT\b(.*?);", resto, re.S)
            select_part = sel.group(1) if sel else ""

            # quitar comentarios: si no, el propio texto explicativo ('resultado',
            # 'es_pago') se cuenta como si fuera codigo.
            cte_part = re.sub(r"--[^\n]*", "", cte_part)
            problematicas = []
            # Normalizacion antes de buscar nombres de columna:
            #   1. Quitar los ALIAS de salida "END AS <columna>": ese nombre es la
            #      etiqueta del resultado, no una referencia a una columna.
            #   2. Quitar los comentarios.
            # Los bloques CASE no se eliminan completos a proposito: dentro de un CASE
            # puede haber referencias sin calificar (ese fue el bug real), y queremos
            # que el chequeo las detecte. Lo unico que sobra del CASE es "CASE WHEN" y
            # los literales, que no coinciden con los nombres buscados.
            sin_alias = re.sub(r"END\s+AS\s+\w+", " ", cte_part, flags=re.I)
            sin_comentarios = re.sub(r"--[^\n]*", "", sin_alias)
            for col in AMBIGUAS:
                sin_calificar = re.findall(r"(?<![\w.])" + col + r"(?![\w])", sin_comentarios)
                if sin_calificar:
                    problematicas.append((col, len(sin_calificar)))
            if problematicas:
                print("  [FALLA] columnas ambiguas sin calificar en el SELECT:")
                for c, n in problematicas:
                    print("            %s (%d veces) -> usar g.%s" % (c, n, c))
                fallos += 1
            else:
                print("  [OK ] sin columnas ambiguas en el INSERT de fct_gestiones")
            print("  [OK ] columnas del INSERT: %d" % len(insert_cols))
            # contar expresiones del SELECT de primer nivel
            nivel, exprs, buf = 0, [], []
            for ch in select_part:
                if ch == "(":
                    nivel += 1
                elif ch == ")":
                    nivel -= 1
                if ch == "," and nivel == 0:
                    exprs.append("".join(buf).strip())
                    buf = []
                else:
                    buf.append(ch)
            if "".join(buf).strip():
                exprs.append("".join(buf).strip())
            print("  [OK ] expresiones del SELECT: %d" % len(exprs))
            if len(exprs) != len(insert_cols):
                print("  [FALLA] DESCUADRE: %d columnas en el INSERT vs %d en el SELECT"
                      % (len(insert_cols), len(exprs)))
                fallos += 1
            else:
                print("  [OK ] columnas y expresiones coinciden")
        else:
            print("  [FALLA] no pude ubicar el INSERT de fct_gestiones")
            fallos += 1
    print()

print("=" * 78)
if fallos == 0:
    print(" RESULTADO: estructura valida, sin problemas detectados")
else:
    print(" RESULTADO: %d problemas detectados" % fallos)
print("=" * 78)

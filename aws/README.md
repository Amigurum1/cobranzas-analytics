# Proyecto AWS — Entorno de datos de cobranzas

Guía de ejecución del proyecto de portafolio. Arquitectura objetivo (la "Arquitectura C"
que definimos por costo): **S3 → Glue/Lambda → Athena → Redshift Serverless → Power BI Desktop**.

---

## Estado actual

| Elemento | Estado |
|---|---|
| Dataset sintético (5 CSV, 129,744 filas) | ✅ Generado y validado |
| Verificación de integridad de los CSV | ✅ 5/5 sin filas mal formadas |
| **Seguridad de la cuenta (root, IAM, MFA, Budgets)** | ✅ **Completado** (`00_seguridad_cuenta.md`) |
| AWS CLI instalado | ✅ v2.37.6 |
| Scripts de creación de S3 | ✅ (`01_setup_s3.ps1`) |
| Script de carga de datos | ✅ (`02_subir_datos.ps1`) |
| **Bucket S3 creado** | ✅ **`analitica-cobranzas-<sufijo>` con 11.37 MB en `raw/`** |
| DDL de la capa raw para Athena | ✅ 5 tablas (`athena_ddl/`, 12 archivos) |
| **ETL de limpieza (prototipo local)** | ✅ Probado (`etl_limpieza_local.py`) |
| **Job de Glue en PySpark** | ✅ **Ejecutado en AWS**, conteos idénticos (`glue_job_limpieza.py`) |
| **Scripts de despliegue del job** | ✅ (`03_crear_glue_job.ps1`, `04_ejecutar_job.ps1`) |
| **Validación de la capa curada** | ✅ **17 chequeos en 0** + validación en Athena (`athena_val/`, 11 archivos) |
| **Redshift Serverless: modelo estrella + 10 vistas** | ✅ **14/14 auditoría · workgroup eliminado** |
| **Tablero Power BI (4 páginas, 38 medidas)** | ✅ Montado y verificado contra Redshift |
| Lambda de automatización | ⏳ Código listo y 10 pruebas pasando, pendiente de desplegar |

**El pipeline está ejecutado de punta a punta.** Los pasos de abajo se conservan como guía para
reproducirlo desde cero, y siguen siendo válidos en su orden.

### Resultado de la limpieza (medido en local)

La capa `curated` se genero y **los 17 chequeos de calidad dieron 0**. Efecto real:

| Problema corregido | Filas |
|---|---|
| Montos de pago negativos (error de signo) | 61 |
| Pagos con fecha futura (anulados y reclasificados) | 137 |
| Fechas de pago imputadas (vencimiento + dias de atraso) | 69 |
| Variantes de formato en `canal` | 85 |
| Variantes de formato en `resultado` | 85 |
| Clientes duplicados eliminados | 25 |

Y un hallazgo de negocio: **197 clientes (3.94%) no tienen ningun canal de contacto valido**.
En cobranzas eso importa: si no puedes contactar al cliente, no puedes cobrar, y esa cartera
se deriva a gestion presencial o judicial.

**Compresion lograda:** 11.37 MB de CSV -> 2.46 MB de Parquet columnar (**78% menos**).
Eso es lo que hace que Athena cueste centavos en lugar de dolares.

**Antes de empezar:** completa el checklist de seguridad de la cuenta. La guía paso a paso, con
el porqué de cada decisión, los enlaces oficiales y la política IAM ya escrita, está en
**`00_seguridad_cuenta.md`**. Resumen: root sin access keys, MFA en root, usuario de trabajo con
MFA, Budgets con alertas en $1/$5/$10 y región fija en **us-east-1**.

---

## Paso 0 — Verificar que todo esté listo (gratis, antes de tocar AWS)

```powershell
cd aws
python preflight.py
```

Revisa **21 chequeos** en menos de 2 segundos: herramientas, credenciales de AWS (y que **no
seas la cuenta root**), `config.json`, que los 5 CSV tengan los conteos correctos, que la capa
curada cuadre, que estén todos los archivos del proyecto, y la integridad de los SQL.

Termina con un veredicto claro: **LISTO** o **NO LISTO** con la lista de lo que falta.
Usa `--solo-local` si todavía no instalaste AWS CLI.

**Por qué existe:** Redshift cuesta $1.50/hora encendido. Descubrir a mitad de camino que falta
un archivo o que los conteos no cuadran es tiempo pagado sin avanzar. Esto lo detecta gratis.

---

## Paso 0b — Instalar AWS CLI

La doc oficial de AWS recomienda el **install script**, que instala para tu usuario y **no requiere
permisos de administrador**:

```powershell
irm https://awscli.amazonaws.com/v2/install.ps1 | iex
```

Alternativa con `winget` (también válida):

```powershell
winget install -e --id Amazon.AWSCLI
```

Luego **cierra y reabre la terminal** —el PATH no se refresca en la sesión abierta— y verifica:

```powershell
aws --version
```

Configura tus credenciales con **tu usuario de trabajo** (nunca el root):

```powershell
# Si usas IAM Identity Center
aws configure sso

# Si usas usuario IAM con access key
aws configure
```

Verifica quién eres:

```powershell
aws sts get-caller-identity
```

El script aborta solo si detecta que estás usando la cuenta root.

---

## Paso 1 — Crear el bucket y la estructura

```powershell
cd aws
.\01_setup_s3.ps1 -Contacto "bruno"
```

Qué hace, en orden:

1. Verifica que AWS CLI exista y que **no seas root**.
2. Genera un nombre de bucket único (o usa el que le pases con `-Bucket`).
3. Fija la región en `us-east-1`.
4. Crea el bucket.
5. **Bloquea los 4 niveles de acceso público.**
6. Activa cifrado por defecto (SSE-S3, sin costo extra).
7. Crea la estructura de capas:

```
s3://<bucket>/
├── raw/                     ← datos crudos (CSV tal como llegan)
│   ├── clientes/
│   ├── creditos/
│   ├── cuotas/
│   ├── gestiones_cobranza/
│   └── mora_snapshot/
├── curated/                 ← datos limpios (Parquet, particionado)
├── athena-results/          ← salidas de consultas de Athena
├── scripts/                 ← jobs de Glue / Lambda
└── logs/                    ← logs de ejecución
```

Guarda la configuración en `aws/config.json` para los pasos siguientes.

---

## Paso 2 — Subir los datos

```powershell
.\02_subir_datos.ps1
```

Sube los 5 CSV a sus prefijos en `raw/` y **verifica byte a byte** que S3 recibió cada archivo
completo (compara el tamaño local contra `ContentLength` en S3). No asumas que la subida salió bien.

---

## Paso 3 — Crear las tablas en Athena

1. Consola de Athena en **us-east-1**.
2. **Settings → Manage → Query result location**: `s3://<tu-bucket>/athena-results/`
   ⚠️ **Sin esto Athena no ejecuta nada.** Es el error #1 de quien empieza.
3. Abre `01_athena_ddl_raw.sql`, reemplaza `<TU-BUCKET>` por tu bucket y ejecútalo.
4. Corre la consulta de verificación al final del archivo.

**Conteos esperados:**

| Tabla | Filas |
|---|---|
| clientes | 5,025 |
| creditos | 6,254 |
| cuotas | 71,229 |
| gestiones_cobranza | 25,689 |
| mora_snapshot | 21,547 |

### Decisión de diseño importante

Todas las columnas de la capa raw están declaradas como **STRING**, no como DECIMAL ni DATE.
No es un descuido: `raw` contiene errores a propósito (montos negativos, fechas de pago en el
futuro). Si declaras tipos estrictos, **la consulta falla** al toparse con una fila sucia.

La regla profesional es: **raw = todo texto, sin validación; curated = tipos correctos, ya
validado.** Esa conversión es justamente el trabajo del job de limpieza.

---

## Paso 4 — Probar la limpieza en local (gratis, antes de tocar Glue)

```powershell
cd aws
python etl_limpieza_local.py      # genera la carpeta ..\curated\
python verificar_curated.py       # los 17 chequeos deben dar 0
```

**Por qué este paso va antes de Glue:** depurar reglas de negocio dentro de Glue cuesta
tiempo y dinero (2 DPU mínimo, redondeo a 1 minuto por corrida). En local es gratis e
instantáneo. Cuando la lógica esté probada, se replica en Glue.

`etl_limpieza_local.py` aplica **exactamente las mismas reglas** que el job de PySpark, así
que lo que funcione aquí funcionará allá.

---

## Paso 5 — Desplegar y ejecutar el job de Glue

```powershell
.\03_crear_glue_job.ps1    # sube el script, crea el IAM role, el job y los 2 crawlers
.\04_ejecutar_job.ps1      # lanza el job, espera, corre el crawler y reporta el costo
```

El script 03 crea:

| Recurso | Nombre |
|---|---|
| Job de Glue | `analitica-cobranzas-limpieza` (Glue 4.0, 2 workers G.1X) |
| Crawler raw | `analitica-cobranzas-crawler-raw` |
| Crawler curated | `analitica-cobranzas-crawler-curated` |
| IAM role | `AWSGlueServiceRole-analitica-cobranzas` |
| Base de datos | `analitica_cobranzas` |

El script 04 te muestra el **tiempo de ejecución y el costo estimado** de cada corrida.
Vigílalo: si el job pasa de 5 minutos, algo está mal (con 129 mil filas debe correr en menos de 1).

**Las 7 reglas que aplica el job:**

1. Duplicados de `cliente_id` → se conserva una fila
2. Email inválido → `NULL` + bandera `email_valido`
3. Teléfono inválido → `NULL` + bandera `telefono_valido` y `es_contactable`
4. Fecha de pago futura → se anula el pago y se reclasifica a `VENCIDA`
5. Monto pagado negativo → valor absoluto + bandera `monto_pagado_corregido`
6. `PAGADA` sin fecha → se imputa `vencimiento + dias_atraso`
7. `canal` y `resultado` → `TRIM(UPPER(...))` + bandera de corrección

Más validaciones de coherencia: bucket de mora recalculado desde los días de atraso,
`saldo_vencido <= saldo_total`, `elegible_castigo` derivado, y `PROMESA_PAGO` siempre con fecha.

**Sobre costos de Glue:** cobra por DPU-hora con mínimo de 2 DPU = **$0.88/hora** y redondeo
a 1 minuto. Una corrida de 1 minuto cuesta ~$0.015. El job no deja nada encendido.

---

## Paso 6 — Validar la capa curada en Athena

```powershell
# Registrar las tablas curadas (si no corrió el crawler)
aws glue start-crawler --name analitica-cobranzas-crawler-curated --region us-east-1
```

Luego abre `02_athena_validacion_curated.sql` y ejecuta cada bloque.
**Todos los chequeos deben dar 0.** Ese resultado es tu evidencia de calidad de datos.

---

## Paso 7 — Redshift Serverless (solo cuando la capa curated funcione)

⚠️ **El paso más riesgoso en costo.** Mínimo 4 RPU × $0.375/RPU-hora = **$1.50 por hora**
encendido. La secuencia obligatoria:

1. Crear el namespace con **auto-pause en 60 segundos**.
2. Cargar con `COPY` desde `s3://<bucket>/curated/`.
3. Crear el modelo estrella.
4. Consultar / conectar Power BI.
5. **Eliminar el namespace al terminar.**

Referencia de costos: `Presupuesto_Proyecto_AWS.csv` (en la raíz del workspace).

---

## Reglas de costo para no llevarte sorpresas

| Regla | Por qué |
|---|---|
| Todo en **us-east-1** | Es la región más barata y el tráfico entre regiones se cobra |
| Sin **NAT Gateway** | Cuesta ~$32/mes solo por existir. Lambda fuera de VPC |
| Retención de logs en **7 días** | Por defecto son "nunca expiran" y se acumulan |
| Redshift con **auto-pause 60 s** y eliminarlo al terminar | Es el 95% del riesgo de costo |
| Revisar **Cost Explorer** cada semana | Detecta recursos huérfanos |

---

## Orden de trabajo recomendado

**Primero limpia en Python local** (con `validar_dataset.py`), y solo cuando la lógica de
limpieza esté probada, replica esa misma lógica en Glue. Así no pagas Redshift ni Glue
mientras todavía estás depurando reglas de negocio.

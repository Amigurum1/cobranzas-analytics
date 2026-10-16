# AWS_Cobranzas — Pipeline de datos de cobranzas

> **Empieza aquí.** Este documento te dice qué hay en la carpeta y cómo reproducirlo.
> Para la **arquitectura, el diagrama y las decisiones de diseño**: `ARQUITECTURA.md`.
> Para la **presentación de portafolio**: `PRESENTACION_PROYECTO.md`.
> Para **montar el tablero**: `GUIA_POWER_BI.md`.

Pipeline analítico **end-to-end** de cobranzas: 5 CSV sintéticos con errores inyectados →
limpieza → modelo dimensional → tablero de 4 páginas. Todo verificado contra la nube.

---

## Estado

| Capa | Estado |
|---|---|
| Dataset sintético (129,744 filas, 7 errores inyectados) | ✅ |
| Limpieza local (pandas) | ✅ 17 chequeos en 0 |
| S3 · `raw/` + `curated/` | ✅ 11.37 MB |
| Glue (PySpark) | ✅ ejecutado, conteos idénticos |
| Athena | ✅ 6 validaciones + 4 consultas de negocio |
| Redshift: modelo estrella + 10 vistas | ✅ **14/14 auditoría · workgroup apagado** |
| Tablero Power BI (4 páginas, 38 medidas) | ✅ montado |
| Lambda de automatización | ⏳ desplegada en código, sin activar |

**Costo real del proyecto: menos de $1.** Ver la sección de costos.

---

## El tablero

| | |
|---|---|
| ![Resumen ejecutivo](capturas/pagina1_resumen_ejecutivo.png) | ![Aging y evolución](capturas/pagina2_aging_evolucion.png) |
| **1 · Resumen ejecutivo** | **2 · Aging y evolución de la mora** |
| ![Efectividad de la gestión](capturas/pagina3_efectividad_gestion.png) | ![Priorización de la cartera](capturas/pagina4_priorizacion.png) |
| **3 · Efectividad de la gestión** | **4 · Priorización de la cartera** |

El archivo es `Proyecto.pbix`. Abre con **Power BI Desktop** (gratis) y **no necesita AWS**:
consume los 20 CSV de `powerbi\`.

---

## Cómo reproducirlo paso a paso

### Fase 0 — Seguridad de la cuenta (solo la primera vez)

Lee `aws\00_seguridad_cuenta.md` y completa el checklist: usuario IAM con permisos mínimos,
MFA, y **Budgets con alerta** antes de crear cualquier recurso que cobre.

### Fase 1 — Generar y limpiar los datos (local, gratis)

```powershell
cd "D:\Proyectos Data Analist\Proyectos Data Analist\AWS_Cobranzas"

python generar_dataset_cobranzas.py --out raw     # 2.6 segundos
cd aws
python etl_limpieza_local.py                      # genera ..\curated\
python verificar_curated.py                       # los 17 chequeos deben dar 0
python preflight.py                               # 25 chequeos de entorno
```

### Fase 2 — Pipeline en AWS

```powershell
cd aws
.\01_setup_s3.ps1 -Contacto "bruno"   # bucket + cifrado + bloqueo público
.\02_subir_datos.ps1                  # sube y verifica byte a byte
.\03_crear_glue_job.ps1               # rol IAM + job + crawler de curated
.\04_ejecutar_job.ps1                 # ejecuta, espera y reporta el costo
```

**Athena:** ejecuta los archivos de `aws\athena_ddl\` (12, una sentencia cada uno) y después
los de `aws\athena_val\` (11). Están divididos así porque **la consola de Athena solo acepta
una sentencia por ejecución**.

**Redshift** (crea el workgroup antes y **elimínalo al terminar**):

```powershell
.\08_ejecutar_redshift.ps1 -Sql "05_redshift_schema_estrella.sql"
.\08_ejecutar_redshift.ps1 -Sql "06_redshift_carga_ejecutar.sql"
.\08_ejecutar_redshift.ps1 -Sql "07_redshift_vistas_negocio.sql"
```

Si un SQL falla, añade `-UnaPorUna`: ejecuta cada sentencia en su propia sesión y aísla el error.

### Fase 3 — Exportar y montar el tablero

```powershell
python exportar_para_powerbi.py       # genera ..\powerbi\ (20 CSV)
```

Luego sigue `GUIA_POWER_BI.md`: 10 CSV → 14 relaciones → 38 medidas DAX → 4 páginas.

⚠️ **Los `vw_*.csv` no se cargan en el modelo.** Son resultados ya calculados, para **contrastar**
las medidas DAX. Si los metes, tendrás dos caminos al mismo número.

---

## Verificaciones (lo que debe cuadrar)

| Comprobación | Valor |
|---|---|
| Filas en las 3 capas (raw, curated, Redshift) | 5,000 / 6,254 / 71,229 / 25,689 / 21,547 |
| Chequeos de la capa curada | **17 en 0** |
| Auditoría del modelo estrella | **14/14 `cumple: true`** |
| Saldo por cobrar | **S/ 529,563.89** |
| Saldo vencido (último corte) | **S/ 410,836.49** |
| Costo por sol recuperado | **S/ 0.0268** |
| Cartera vencida sin gestionar | **S/ 87,770.20** (195 créditos) |

---

## Costos

| Servicio | Uso real | Costo |
|---|---|---|
| Glue | 276 DPU-segundos | ~$0.034 |
| Crawler | 40.4 s | ~$0.01 |
| S3 + Athena | 13.6 MB | ~$0.0001 |
| Redshift Serverless | minutos, **workgroup eliminado** | según uso |
| Lambda | free tier | $0 |

**Disciplina aplicada:** sin NAT Gateway (~$32/mes solo por existir), Lambda fuera de la VPC,
logs con retención corta, Redshift con auto-pause y **workgroup eliminado al terminar**.

**Nota:** el namespace de Redshift conserva los datos y, con él, un secreto de Secrets Manager
de unos céntimos al mes. Para costo cero absoluto hay que eliminar también el namespace.

---

## Estructura de la carpeta

```
AWS_Cobranzas\
├── README.md                    <- este archivo
├── ARQUITECTURA.md              <- diagrama, capas y decisiones de diseno
├── PRESENTACION_PROYECTO.md     <- documento de portafolio
├── GUIA_POWER_BI.md             <- relaciones, DAX y las 4 paginas
├── FUENTES_Y_DICCIONARIO_DATOS.md
├── capturas\                    <- las 4 paginas del tablero
├── raw\  curated\  powerbi\     <- datos crudos, Parquet y CSV del tablero
├── Proyecto.pbix                <- el tablero
├── generar_dataset_cobranzas.py
├── validar_dataset.py
└── aws\                         <- todo lo de AWS (empieza por 00_seguridad_cuenta.md)
```

---

## Las trampas que ya están resueltas

Están documentadas con su causa y su arreglo en `PROMPT_PROYECTO_AWS.md`. Las seis que costaron
más tiempo:

1. **PowerShell 5.1 borra las comillas dobles** al pasar JSON a ejecutables nativos → usar `file://`
2. **`fct_mora_diaria` es un snapshot diario** (77 cortes): sumar sin `LASTDATE` da 30× el valor
3. **Power BI interpreta el punto como separador de miles** → todos los importes ×100
4. **Power BI autodetecta relaciones** entre columnas del mismo nombre y crea ciclos → solo 14 relaciones por `*_key`
5. **Redshift no soporta `ISODOW` ni `RESTART IDENTITY`** → usar `DOW` y quitar el `RESTART`
6. **`COPY` mapea columnas por posición**, no por nombre → staging intermedio obligatorio

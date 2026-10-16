# Pipeline de datos de cobranzas en AWS
### Proyecto de portafolio — Analítica de cobranzas

**Bruno** · Pipeline end-to-end de un entorno analítico de cobranzas sobre AWS:
5 tablas relacionadas, 129,744 registros sintéticos calibrados, 2 capas de datos,
3 tablas de hechos, 7 dimensiones, 10 vistas de negocio y 33 chequeos de calidad automatizados.

**Ejecutado de punta a punta en AWS** (S3 → Glue → Athena → Redshift), con los conteos idénticos
en las tres capas, **14/14 auditorías del modelo** en verde y un **tablero de 4 páginas** montado
en Power BI sobre 38 medidas DAX verificadas contra la nube.

---

## 1. El problema de negocio

El escenario es una **fintech peruana de crédito de consumo**: crédito en cuotas sin tarjeta,
**evaluación inmediata y solo con DNI**, para comprar en tiendas físicas. Al aprobar al instante
y con poca información, la **mora temprana es el riesgo crítico** y la **cobranza es rentabilidad
directa**, no un área de soporte.

El área de Riesgo y Cobranzas necesita responder preguntas como:

- ¿Cómo se deteriora la cartera y en qué banda se concentra el saldo vencido?
- ¿Qué canal de gestión recupera más por cada sol invertido?
- ¿Los clientes cumplen las promesas de pago (PTP) que hacen?
- **¿Qué cartera vencida se está quedando sin gestionar?**

Responder esto exige un entorno de datos que hoy no existe: la información de cobranzas está
repartida entre sistemas y los reportes se arman a mano.

---

## 2. Arquitectura de la solución

```
   FUENTES DE DATOS
   (core financiero, CRM, archivos de pagos y mora)
                    |
                    v
   +--------------------------------------------------+
   |  S3  —  DATA LAKE POR CAPAS                      |
   |                                                  |
   |   raw/       CSV tal como llegan (con errores)   |
   |   curated/   Parquet limpio, particionado        |
   +--------------------------------------------------+
        |                            ^
        | 1. llega archivo           | 4. escribe
        v                            |
   +-------------+  2. dispara  +-------------+
   |   LAMBDA    |------------->|    GLUE     |
   | (evento S3) |              |  (ETL)      |
   +-------------+              +-------------+
                                     |
                                     v  3. consulta / modela
   +-------------------------------+     +---------------------------+
   |  ATHENA                       |     |  REDSHIFT SERVERLESS      |
   |  SQL sobre S3                 |     |  Modelo estrella          |
   |  (exploracion y validacion)   |     |  7 dims + 3 hechos        |
   +-------------------------------+     +---------------------------+
                                                     |
                                                     v  5. visualiza
                                          +-----------------------+
                                          |  POWER BI DESKTOP     |
                                          |  4 paginas de tablero |
                                          +-----------------------+
```

**Stack:** S3 · Lambda · Glue (PySpark) · Athena · Redshift Serverless · Power BI Desktop
**Alcance actual:** todo el pipeline está implementado y verificado en local; la ejecución
en la cuenta de AWS es el siguiente paso.

---

## 3. Los datos

No existe dataset público con el ciclo de vida de cobranza: los disponibles (Lending Club,
Home Credit) solo traen originación y resultado final, porque las gestiones y promesas de pago
son información sensible. **Solución:** generador propio con comportamiento calibrado,
más un catálogo de 7 fuentes públicas reales para enriquecer.

| Tabla | Filas | Qué representa |
|---|---:|---|
| `clientes` | 5,025 | Maestro de clientes |
| `creditos` | 6,254 | Operaciones desembolsadas |
| `cuotas` | 71,229 | Cronograma de pagos y desempeño real |
| `gestiones_cobranza` | 25,689 | Cada acción de cobranza (llamada, SMS, visita…) |
| `mora_snapshot` | 21,547 | Foto diaria de la cartera vencida (90 días) |
| **Total** | **129,744** | 11.4 MB CSV → 2.5 MB Parquet |

**El dataset es realista, no aleatorio.** Los indicadores se calibraron hasta que fueran
creíbles: cumplimiento de PTP de 52.5%, efectividad de pago por canal entre 17% y 21%, y
canales unidireccionales (SMS, carta) con contacto efectivo casi nulo.

---

## 4. Calidad del dato: el corazón del proyecto

El dataset trae **8 problemas inyectados a propósito**, porque validar la calidad es parte del
trabajo ("extraer, validar y analizar información" está en la oferta).

| # | Problema | Filas | Tratamiento aplicado |
|---|---|---:|---|
| R1 | `cliente_id` duplicado | 25 ids | conservar una fila por cliente |
| R2 | Email inválido o vacío | 48 | `NULL` + bandera `email_valido` |
| R3 | Teléfono mal formado | 33 | `NULL` + bandera `telefono_valido` |
| R4 | `fecha_pago` en el futuro | 137 | anular el pago y reclasificar a `VENCIDA` |
| R5 | `monto_pagado` negativo | 61 | valor absoluto + bandera de corrección |
| R6 | `PAGADA` sin `fecha_pago` | 69 | imputar `vencimiento + dias_atraso` |
| R7 | `canal`/`resultado` sin normalizar | 85 / 85 | `TRIM(UPPER(...))` + bandera |
| R8 | Sin ningún canal de contacto válido | 197 | bandera `es_contactable` |

**Resultado verificado:**

```
17 chequeos de calidad de la capa curada  →  TODOS EN 0
16 chequeos del modelo estrella           →  TODOS OK
 8 pruebas del Lambda disparador          →  TODAS OK
```

Los chequeos cubren claves duplicadas, huérfanos referenciales, coherencia de reglas de negocio
y **cuadres de soles**: la suma de los hechos debe igualar exactamente la del origen.

**Compresión lograda: 11.37 MB CSV → 2.46 MB Parquet columnar (78% menos).** Eso es lo que hace
que Athena cueste centavos en lugar de dólares.

---

## 5. Hallazgos de negocio

### Hallazgo 1 — 197 clientes (3.94%) no tienen ningún canal de contacto válido

En cobranzas, **si no puedes contactar al cliente, no puedes cobrar**. Esta cartera se cae del
embudo de gestión telefónica y digital, y debe derivarse a visita presencial o gestión judicial
—las dos opciones más caras.

### Hallazgo 2 — La cartera sin gestionar se concentra en la mora más profunda

| Banda | Cuotas vencidas | Sin gestionar | % sin cobertura |
|---|---:|---:|---:|
| 0-30 | 586 | 83 | 14.2% |
| 31-60 | 251 | 3 | 1.2% |
| 61-90 | 141 | 11 | 7.8% |
| 91-180 | 103 | 28 | 27.2% |
| **180+** | **84** | **70** | **83.3%** |

**S/ 87,770 de cartera vencida sin ninguna gestión registrada.** Y el patrón es el peor posible:
el **83% de las cuotas de más de 180 días no tiene ninguna gestión**. Son casos que se
abandonaron sin intentar recuperarlos. La banda 31-60 está bien cubierta (1.2% sin gestión),
lo que confirma que el problema no es general: es específico de la mora profunda.

### Hallazgo 3 — La carta es el canal más eficiente y la visita el más caro

| Canal | Gestiones | % de pago | Costo por sol recuperado |
|---|---:|---:|---:|
| CARTA | 1,098 | 19.85% | **S/ 0.0230** |
| WHATSAPP | 5,538 | 20.53% | S/ 0.0259 |
| SMS | 6,299 | 19.72% | S/ 0.0264 |
| EMAIL | 2,053 | 19.78% | S/ 0.0272 |
| LLAMADA | 9,586 | 20.62% | S/ 0.0273 |
| VISITA | 1,115 | 17.40% | **S/ 0.0339** |

La **visita domiciliaria cuesta 47% más por sol recuperado que la carta**, y es además el canal
con menor tasa de pago. La lectura no es "eliminar la visita" (es el único canal posible para
los 197 clientes sin contacto), sino **reservarla para los casos donde ningún canal remoto
funciona**.

### Los números del tablero

| Métrica | Valor |
|---|---|
| Saldo por cobrar (todo el portafolio) | S/ 529,564 |
| Saldo vencido (cartera morosa) | S/ 410,836 |
| Créditos en mora | 619 de 6,254 |
| Intensidad de mora (del moroso, cuánto venció) | 53.81% |
| Mora sobre cartera total | 77.58% |
| Tasa de recuperación de cartera | 98.47% |
| Cumplimiento de promesas de pago | 52.55% |
| **Costo por sol recuperado** | **S/ 0.0268** |
| Cartera vencida sin gestionar | **S/ 87,770** |

**Nota metodológica:** separo *intensidad de mora* (del saldo de quien ya debe, cuánto venció)
de *mora sobre cartera total* (del saldo por cobrar de todo el portafolio, cuánto venció).
Mezclarlos da un número engañoso, porque el snapshot de mora solo contiene clientes morosos.
El nivel absoluto es alto porque el dataset es sintético y simulé una cartera estresada; lo que
importa es la metodología.

---

## 6. Decisiones técnicas que puedo defender

**Capa `raw` con todas las columnas como `STRING`.** No es descuido: la capa cruda contiene
errores a propósito, y declarar tipos estrictos **rompe la consulta** al toparse con una fila
sucia. La regla profesional es *raw = texto sin validar; curated = tipos correctos ya validados*.

**Staging + `INSERT` en lugar de `COPY` directo al modelo estrella.** `COPY` desde Parquet mapea
columnas **por posición**, no por nombre. Cargar directo con un orden distinto **corrompe los
datos en silencio** — el peor tipo de error. Con staging, el `COPY` recibe el orden exacto y el
`INSERT` final usa nombres.

**Dos implementaciones idénticas del ETL** (pandas local + PySpark en Glue). Depurar reglas de
negocio dentro de Glue cuesta tiempo y dinero; en local es gratis e instantáneo. Se valida la
lógica en local y se sube cuando funciona.

**Parquet columnar + particionado por año.** Reduce los datos escaneados en Athena (que cobra
por TB leído) y mejora el performance en Redshift.

**Power BI Desktop en lugar de QuickSight.** QuickSight cobra $24/mes de suscripción fija que no
baja por usar poco; Power BI Desktop es gratis y permite que **el tablero funcione sin AWS**,
consumiendo los CSV exportados.

**Pipeline idempotente.** El ETL borra la carpeta destino antes de escribir y el job de Glue usa
`mode("overwrite")`. Lo detecté porque `pandas.to_parquet` genera un nombre con UUID nuevo en
cada corrida y **acumulaba archivos duplicados**, duplicando los conteos en silencio.

---

## 7. Disciplina de costos

| Servicio | Tarifa | Uso en el proyecto |
|---|---|---|
| S3 | $0.023/GB-mes | ~2.5 MB → centavos |
| Athena | $5.00 por TB escaneado | Consultas sobre Parquet → centavos |
| Lambda | Free tier permanente (1M invocaciones) | $0 |
| Glue | $0.44/DPU-hora (mínimo 2 DPU) | ~$0.015 por corrida |
| **Redshift Serverless** | **$0.375/RPU-hora (mínimo 4 RPU = $1.50/hora)** | 2-3 horas al mes |

**Costo real del proyecto: menos de $1.** Medido: Glue 276 DPU-segundos (~$0.034), crawler 40.4
segundos (~$0.01), y S3 + Athena sobre 13.6 MB (~$0.0001). Redshift con auto-pause de 60 segundos
y **workgroup eliminado al terminar**. Sin NAT Gateway (~$32/mes solo por existir), Lambda fuera
de la VPC, logs con retención corta, y todo en `us-east-1` (la región más barata).

---

## 8. Competencias demostradas

| Competencia | Cómo la demuestra el proyecto |
|---|---|
| Diseñar un entorno de datos escalable en AWS | Data lake en S3 con capas `raw`/`curated`, Parquet particionado y catálogo de tablas |
| Desarrollar y mantener pipelines | Job de Glue en PySpark + Lambda disparado por evento de S3 |
| Extraer, validar y analizar de distintas fuentes | 8 problemas de calidad tratados + 33 chequeos automatizados + cuadres de soles |
| Generar y automatizar reportería | 10 vistas de negocio en Redshift + 4 páginas de tablero en Power BI |
| Elaborar y validar bases de datos | Modelo estrella: 7 dimensiones, 3 hechos con DISTKEY/SORTKEY, claves subrogadas |
| Participar en automatización y mejora continua | Pipeline idempotente, anti-tormenta en Lambda, detección del cuello de botella de 7.5 min → 2.6 s |
| **AWS: S3, Athena, Redshift, DynamoDB, Lambda** | S3, Athena, Redshift y Lambda implementados. DynamoDB: base NoSQL para estado operativo de la gestión |
| **SQL avanzado** | Window functions (`ROW_NUMBER`, `LAG`, `SUM() OVER`), CTEs, `NULLIF`, `USERELATIONSHIP` en DAX, y cálculo de roll rate |
| **Power BI intermedio** | Modelo relacional, medidas DAX, tabla de fechas con rol, tabla de medidas separada |
| **Python intermedio** | pandas para ETL, PySpark para Glue, boto3 para orquestación, scripts de validación |

---

## 9. Qué haría a continuación

1. **Activar la Lambda** de automatización: está escrita, con 10 pruebas pasando y el script de
   despliegue listo, pero sin desplegar. Dispararía el pipeline al subir un archivo a `raw/`.
2. **Automatizar el re-envío a los casos 180+ sin gestión**: es el hallazgo de mayor impacto
   económico del proyecto (S/ 33,352 en esa banda).
3. **Modelo de propensión de pago** con los datos de gestión, para priorizar la cartera por
   probabilidad de recuperación y no solo por antigüedad.
4. **Optimización de costo por canal**: dado que la visita cuesta 47% más por sol recuperado,
   definir una regla de asignación que la reserve para casos donde falló el contacto remoto.
5. **DynamoDB** para el estado operativo de la gestión en tiempo real (cola de casos del día).

---

## 10. Repositorio

| Componente | Archivo |
|---|---|
| Generador del dataset | `generar_dataset_cobranzas.py` |
| ETL de limpieza (local + Glue) | `aws\etl_limpieza_local.py` · `aws\glue_job_limpieza.py` |
| Modelo estrella (esquema, carga, vistas) | `aws\05_redshift_schema_estrella.sql` · `aws\06_redshift_carga.sql` · `aws\07_redshift_vistas_negocio.sql` |
| Automatización | `aws\lambda_disparador.py` · `aws\05_configurar_lambda.ps1` |
| Validación de calidad | `aws\verificar_curated.py` · `aws\verificar_modelo_estrella.py` · `aws\validar_sql.py` · `aws\probar_lambda.py` |
| Tablero | `Proyecto.pbix` · `GUIA_POWER_BI.md` · `powerbi\` (20 CSV) |
| Capturas del tablero | `capturas\` (las 4 páginas) |
| Arquitectura y diagrama | `ARQUITECTURA.md` · `diagrama_arquitectura.py` (iconos oficiales de AWS) |
| Guía de ejecución | `README.md` · `aws\README.md` |

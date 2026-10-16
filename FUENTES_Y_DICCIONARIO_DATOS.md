# Datos para el proyecto de cobranzas — fuentes y diccionario

Proyecto: **Analítica de cobranzas** — pipeline de datos en AWS para una fintech peruana de crédito de consumo.
Objetivo: tener datos con los que construir el pipeline en AWS (S3 → Glue → Redshift/Athena → Power BI).

---

## PARTE 1 — Catálogo de fuentes de datos reales

### 1.1 El problema que debes conocer antes de buscar

Ningún dataset público real contiene el **ciclo de vida de la cobranza**: gestiones, llamadas,
promesas de pago (PTP), pagos parciales y snapshots diarios de mora por operación. Las razones:

- La cobranza es información **sensible** (contacto, deuda, situación del cliente).
- Las entidades financieras no publican su detalle operativo de recuperaciones.
- Lo que sí se publica son datasets de **originación y desempeño final** del crédito
  (se otorgó / se pagó / no se pagó), no la gestión intermedia.

**Conclusión práctica:** usa **datos reales para la parte de crédito y mora**
(Lending Club, Home Credit, Taiwan) y **datos sintéticos para las gestiones de cobranza**.
Esa combinación es defendible en una entrevista y es exactamente lo que hace un equipo real
cuando no puede sacar datos de producción: construye un entorno con datos anonimizados o
simulados que respete los mismos esquemas.

---

### 1.2 Fuentes reales recomendadas (gratuitas y verificadas)

| # | Dataset | Qué contiene | Tamaño | Licencia / acceso |
|---|---|---|---|---|
| 1 | **Lending Club Loan Data** | 2.2M préstamos 2007-2018, 151 columnas: monto, tasa, plazo, grado, ingreso, DTI, estado del préstamo, pagos recibidos | ~1.6 GB CSV | CC0 (dominio público). Kaggle: [kaggle.com/datasets/wordsforthewise/lending-club](https://www.kaggle.com/datasets/wordsforthewise/lending-club) |
| 2 | **Home Credit Default Risk** | 7 tablas relacionadas (application, bureau, previous_application, POS_CASH, installments_payments, credit_card_balance). Es el **mejor ejemplo de modelo relacional** de crédito | ~2.5 GB | Kaggle competition: [kaggle.com/competitions/home-credit-default-risk](https://www.kaggle.com/competitions/home-credit-default-risk/data) |
| 3 | **Default of Credit Card Clients (Taiwan)** | 30,000 clientes, 23 variables, historial de pagos mes a mes (PAY_0..PAY_6), montos facturados y pagados | 5.7 MB | CC BY 4.0. UCI: [archive.ics.uci.edu/dataset/350](https://archive.ics.uci.edu/dataset/350/default+of+credit+card+clients) |
| 4 | **Statlog (German Credit)** | 1,000 registros, 20 variables, clasificación buen/mal riesgo + matriz de costos | 78 KB | CC BY 4.0. UCI: [archive.ics.uci.edu/dataset/144](https://archive.ics.uci.edu/dataset/144/statlog+german+credit+data) |
| 5 | **Give Me Some Credit** | 150,000 registros con morosidad a 90 días, utilización de crédito, ratio deuda-ingreso | 12 MB | Kaggle: [kaggle.com/c/GiveMeSomeCredit](https://www.kaggle.com/c/GiveMeSomeCredit) |
| 6 | **SBS Perú — Estadísticas del Sistema Financiero** | Tasas de morosidad por tipo de crédito y días de incumplimiento (el benchmark regulatorio peruano) | Reportes web | SBS: [sbs.gob.pe — ratiios de morosidad](https://www.sbs.gob.pe/app/stats_net/stats/EstadisticaSistemaFinancieroResultados.aspx?c=B-220512) |
| 7 | **AWS Open Data Registry** | Más de 100 TB de datasets abiertos alojados **directamente en S3** (útil para practicar lectura masiva) | Variable | Gratis: [registry.opendata.aws](https://registry.opendata.aws/) |

**Cómo usarlas con criterio:**

- **Lending Club** → úsalo para calcular tasas de default y recuperación por segmento, y para
  construir tus tablas de `creditos` con volumen real. Es el que más se parece a un portafolio
  de consumo.
- **Home Credit** → úsalo como **referencia de modelado**: mira cómo relacionan
  `installments_payments` con `application`. Es el ejemplo que deberías copiar para tu
  cronograma de cuotas.
- **Taiwan** → úsalo para el semáforo de comportamiento mes a mes; enseña el concepto de
  "roll rate" (cuántos clientes pasan de al día a 30, de 30 a 60 días).
- **SBS Perú** → no es un dataset descargable limpio, pero es tu fuente para **contextualizar
  la mora en el mercado peruano** en la narrativa del proyecto. Es un diferenciador local.
- **Ojo con las licencias**: Lending Club es CC0 (libre). Taiwan y German son CC BY 4.0
  (cita la fuente). Los de Kaggle suelen requerir aceptar reglas de uso; verifica antes de
  publicar el proyecto en GitHub.

---

### 1.3 El dataset sintético que ya te dejé generado

Como las fuentes reales no traen cobranza, incluí un generador propio:

**`generar_dataset_cobranzas.py`** — produce un dataset completo con el ciclo de vida de cobranza,
calibrado con comportamiento realista y **con problemas de calidad inyectados** para que practiques
validación.

`python generar_dataset_cobranzas.py --clientes 5000 --meses 18 --out raw`

Salida actual (semilla 42, 5,000 clientes, 18 meses — **11.2 MB en CSV**, ~1.5 MB en Parquet):

| Tabla | Filas | KB | Qué representa |
|---|---|---|---|
| `clientes.csv` | 5,025 | 476 | Maestro de clientes |
| `creditos.csv` | 6,221 | 640 | Operaciones desembolsadas |
| `cuotas.csv` | 71,268 | 5,967 | Cronograma de pagos y su estado real |
| `gestiones_cobranza.csv` | 25,689 | 3,199 | Cada acción de cobranza (llamada, SMS, visita…) |
| `mora_snapshot.csv` | 21,547 | 1,359 | Foto diaria de la cartera vencida (90 días) |

---

## PARTE 2 — Diccionario de datos

### 2.1 `clientes` — maestro de clientes
| Columna | Tipo | Descripción |
|---|---|---|
| `cliente_id` | texto | PK natural (`CLI000001`) |
| `nombre` | texto | Nombre completo |
| `documento` | texto | DNI |
| `email` | texto | Correo (con nulos e inválidos a propósito) |
| `telefono` | texto | Celular (algunos mal formados) |
| `distrito` | texto | Ciudad de residencia |
| `ingreso_mensual` | decimal | Ingreso declarado en S/ |
| `score_inicial` | entero | Score al momento del alta (300–850) |
| `fecha_alta` | fecha | Alta del cliente |
| `segmento` | texto | A, B, C, D |

### 2.2 `creditos` — operaciones desembolsadas
| Columna | Tipo | Descripción |
|---|---|---|
| `credito_id` | texto | PK (`CRE0000001`) |
| `cliente_id` | texto | FK a `clientes` |
| `producto` / `producto_desc` | texto | Código y nombre del producto (celulares, TV, moto…) |
| `monto_desembolsado` | decimal | Capital en S/ |
| `plazo_meses` | entero | 6, 12, 18, 24, 36 |
| `tea` | decimal | Tasa efectiva anual (0.35–0.62) |
| `cuota_mensual` | decimal | Cuota calculada por sistema francés |
| `fecha_desembolso` | fecha | Fecha de otorgamiento |
| `fecha_vencimiento_final` | fecha | Vencimiento de la última cuota |
| `estado_credito` | texto | `VIGENTE`, `EN_COBRANZA`, `CASTIGADO` |
| `score_desembolso` | entero | Score al desembolsar |
| `oficina` | texto | Agencia de origen |

### 2.3 `cuotas` — cronograma y desempeño de pago
| Columna | Tipo | Descripción |
|---|---|---|
| `cuota_id` | texto | PK (`CUO000000001`) |
| `credito_id` / `cliente_id` | texto | FKs |
| `nro_cuota` | entero | Número de cuota (1..plazo) |
| `fecha_vencimiento` | fecha | Vencimiento contractual |
| `monto_cuota` | decimal | Monto exigible |
| `monto_pagado` | decimal | Pagado (algunos negativos = error de sistema) |
| `fecha_pago` | fecha | Fecha efectiva (vacíos y fechas futuras = errores) |
| `estado_cuota` | texto | `PAGADA`, `PAGADA_CON_ATRASO`, `VENCIDA` |
| `dias_atraso` | entero | Días de atraso (0 si puntual) |

### 2.4 `gestiones_cobranza` — acciones de cobranza (la tabla clave)
| Columna | Tipo | Descripción |
|---|---|---|
| `gestion_id` | texto | PK (`GES000000001`) |
| `credito_id` / `cliente_id` / `cuota_id` | texto | FKs |
| `fecha_gestion` / `hora_gestion` | fecha / hora | Momento de la acción |
| `canal` | texto | `LLAMADA`, `SMS`, `WHATSAPP`, `EMAIL`, `CARTA`, `VISITA` |
| `tipo_gestion` | texto | `RECORDATORIO`, `GESTION_TEMPRANA`, `GESTION_MORA`, `NEGOCIACION`, `COBRANZA_JUDICIAL` |
| `resultado` | texto | `NO_CONTACTADO`, `CONTACTADO`, `PROMESA_PAGO`, `PAGO_TOTAL`, `PAGO_PARCIAL`, `RECHAZA_PAGO`, `CLIENTE_MOLESTO`, `NUMERO_INVALIDO` |
| `asesor_id` | texto | Agente de cobranza (A001–A040) |
| `monto_promesa` | decimal | Monto prometido (solo si hubo PTP) |
| `fecha_promesa_pago` | fecha | Fecha comprometida de pago |
| `ptp_cumplida` | texto | `SI` / `NO` / vacío — **etiqueta para medir efectividad** |
| `monto_recuperado` | decimal | Monto efectivamente recuperado en esa gestión (0 si no hubo pago) |
| `duracion_seg` | entero | Duración de la llamada |
| `costo_gestion` | decimal | Costo unitario del canal en S/ (visita S/8, carta S/2.50…) |

### 2.5 `mora_snapshot` — foto diaria de la cartera vencida
| Columna | Tipo | Descripción |
|---|---|---|
| `fecha_corte` | fecha | Día de la foto (últimos 90 días, sin domingos) |
| `credito_id` / `cliente_id` | texto | FKs |
| `dias_atraso` | entero | Días desde el vencimiento de la cuota impaga más antigua |
| `bucket_mora` | texto | `0-30`, `31-60`, `61-90`, `91-180`, `180+` |
| `saldo_vencido` | decimal | Saldo de cuotas impagas |
| `saldo_total` | decimal | Saldo total de la operación |
| `cuotas_vencidas` | entero | Cuotas impagas acumuladas |
| `score_actual` | entero | Score deteriorado según días de mora |
| `elegible_castigo` | texto | `SI` si supera 180 días |

---

## PARTE 3 — Problemas de calidad inyectados (tu lista de limpieza)

Estos errores están **a propósito**. Encontrarlos y resolverlos es exactamente el desafío
"extraer, validar y analizar información" de la oferta.

| # | Problema | Dónde | Cómo detectarlo |
|---|---|---|---|
| 1 | IDs de cliente duplicados (~25) | `clientes` | `GROUP BY cliente_id HAVING COUNT(*) > 1` |
| 2 | Emails vacíos o inválidos (~50) | `clientes` | validación de formato de correo |
| 3 | Teléfonos mal formados (~20) | `clientes` | largo distinto de 9 o no numérico |
| 4 | Fechas de pago en el futuro (~136) | `cuotas` | `fecha_pago > fecha_corte` |
| 5 | Montos pagados negativos (~55) | `cuotas` | `monto_pagado < 0` |
| 6 | Cuotas PAGADAS sin fecha de pago (~69) | `cuotas` | `estado_cuota='PAGADA' AND fecha_pago IS NULL` |
| 7 | Variantes de escritura en `canal` (~16) | `gestiones_cobranza` | `'llamada'`, `'Llamada'`, `' LLAMADA'` |

---

## PARTE 4 — Las 12 preguntas de negocio que tu proyecto debe responder

Estas son las respuestas que te dan una entrevista sólida. Todas se calculan con este dataset.

1. **Aging de cartera**: ¿cómo se distribuye el saldo vencido por bucket al último corte?
2. **Roll rate**: ¿qué porcentaje de la cartera en bucket 0-30 migra a 31-60, 61-90, 91-180?
3. **Tasa de recuperación**: recaudado / facturado, global y por producto.
4. **Efectividad por canal**: ¿qué canal genera más pagos y promesas por cada S/ gastado?
5. **Costo por sol recuperado**: `SUM(costo_gestion) / SUM(pagos)`, por canal.
6. **Cumplimiento de PTP**: % de `ptp_cumplida = 'SI'` por canal, asesor y bucket.
7. **Ranking de asesores**: pagos y cumplimiento de PTP por `asesor_id`.
8. **Mejor momento de contacto**: ¿en qué días/horas de gestión se logra más contacto efectivo?
9. **Probabilidad de castigo**: qué combinaciones de score, producto y bucket terminan en `CASTIGADO`.
10. **Cuotas incobrables tempranas**: operaciones que se atrasan en las primeras 3 cuotas
    (fuerte señal de fraude o mala originación).
11. **Recuperación por producto**: ¿qué producto (moto, cómputo, línea blanca) se recupera mejor?
12. **Calidad de datos**: volumen y porcentaje de registros con cada uno de los 7 problemas.

---

## PARTE 5 — Cómo subirlo a AWS (Arquitectura C)

```
raw/*.csv   →   S3 (capa raw, particionado por fecha de ingesta)
                    ↓
              Glue (job ETL: limpia los 7 problemas y escribe Parquet)
                    ↓
        S3 curated (Parquet + particiones)  →  Athena (validación y exploración)
                    ↓
              Redshift Serverless (modelo estrella: 1 fact + 3 dims)
                    ↓
              Power BI Desktop (tablero de cobranzas)
```

**Modelo estrella sugerido en Redshift:**
- `fact_gestiones` (gestiones con sus IDs de dimensión y métricas)
- `fact_mora_diaria` (snapshot diario)
- `dim_cliente`, `dim_credito`, `dim_canal`, `dim_tiempo`, `dim_asesor`

**Orden recomendado de trabajo:** primero limpia en Python local, luego replica la limpieza
en Glue, después modela en Redshift, y solo al final conecta Power BI. Así no pagas Redshift
mientras todavía estás depurando la lógica de limpieza.

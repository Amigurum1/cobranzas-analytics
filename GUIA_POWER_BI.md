# Tablero de cobranzas en Power BI Desktop

Guía para montar el tablero del proyecto. Power BI Desktop es **gratis** y además es la
herramienta estándar para este tipo de tablero ("Power BI intermedio" en las ofertas de datos).

---

## Dos caminos para conectarte

### Opción A — Datos locales (empieza por aquí)

Los CSV del modelo estrella ya están generados en `..\powerbi\`. No necesitas encender
Redshift (que cuesta $1.50/hora), no necesitas credenciales, y funciona sin internet.

1. Power BI Desktop → **Inicio → Obtener datos → Texto/CSV**
2. Carga los 10 archivos: `dim_*.csv` y `fct_*.csv`
3. En Power Query, verifica que las columnas de fecha se detecten como **Fecha** y las
   claves (`*_key`) como **Número entero**

### Opción B — Redshift (cuando el entorno ya funcione)

1. Power BI Desktop → **Obtener datos → Amazon Redshift**
2. Servidor: el endpoint del workgroup de Redshift Serverless
   (consola de Redshift → Workgroup → *Endpoint*)
3. Base de datos: `dev` · Modo de conectividad: **Import**
4. Selecciona las vistas `vw_*` y las dimensiones

⚠️ **Apaga el namespace de Redshift al terminar.** Si usas DirectQuery contra Redshift
Serverless, cada interacción del tablero mantiene el clúster despierto y **cobras $1.50/hora**.
Con **Import** el tablero funciona desconectado.

---

## Modelo de datos: las relaciones

En la vista **Modelo**, crea estas relaciones (todas **uno a muchos**, dimensión → hecho,
dirección de filtro **única**):

| Desde (dimensión) | Hacia (hecho) | Columna |
|---|---|---|
| `dim_cliente` | `fct_gestiones` | `cliente_key` |
| `dim_cliente` | `fct_cuotas` | `cliente_key` |
| `dim_cliente` | `fct_mora_diaria` | `cliente_key` |
| `dim_credito` | `fct_gestiones` | `credito_key` |
| `dim_credito` | `fct_cuotas` | `credito_key` |
| `dim_credito` | `fct_mora_diaria` | `credito_key` |
| `dim_canal` | `fct_gestiones` | `canal_key` |
| `dim_resultado` | `fct_gestiones` | `resultado_key` |
| `dim_tipo_gestion` | `fct_gestiones` | `tipo_gestion_key` |
| `dim_asesor` | `fct_gestiones` | `asesor_key` |

**Cuidado con `dim_fecha`:** `fct_gestiones` y `fct_mora_diaria` tienen **una sola** fecha cada
uno (`fecha_key`), así que se relacionan directo. Pero `fct_cuotas` tiene **dos**
(`fecha_vencimiento_key` y `fecha_pago_key`), y Power BI **no permite dos relaciones activas**
entre el mismo par de tablas.

Solución recomendada: **crea una copia de la tabla de fechas** y úsala como rol.

- `dim_fecha` → relación activa con `fct_cuotas[fecha_vencimiento_key]`
- `dim_fecha_pago` (copia) → relación **inactiva** con `fct_cuotas[fecha_pago_key]`

Y en las medidas que analicen por fecha de pago, actívala con `USERELATIONSHIP`:

```dax
Recaudado por fecha de pago =
CALCULATE(
    SUM(fct_cuotas[monto_pagado]),
    USERELATIONSHIP(dim_fecha_pago[fecha_key], fct_cuotas[fecha_pago_key])
)
```

**Marca `dim_fecha` como tabla de fechas** (clic derecho → *Marcar como tabla de fechas* →
columna `fecha`). Eso habilita las jerarquías de tiempo automáticas y las funciones de
inteligencia de tiempo (`SAMEPERIODLASTYEAR`, etc.).

---

## Medidas DAX

Crea una tabla vacía llamada `_Medidas` (Inicio → Especificar datos) y pon ahí todas las
medidas. Así no se mezclan con las columnas y es más fácil de mantener.

### Bloque 1 — Cartera y recuperación

```dax
Facturado = SUM(fct_cuotas[monto_cuota])

Recaudado = SUM(fct_cuotas[monto_pagado])

Saldo por cobrar = SUM(fct_cuotas[saldo_cuota])

Tasa de recuperación % =
DIVIDE([Recaudado], [Facturado])

Cuotas vencidas = CALCULATE(COUNTROWS(fct_cuotas), fct_cuotas[estado_cuota] = "VENCIDA")

Saldo vencido (cuotas) = CALCULATE([Saldo por cobrar], fct_cuotas[estado_cuota] = "VENCIDA")

Pago puntual % =
DIVIDE(
    CALCULATE(COUNTROWS(fct_cuotas), fct_cuotas[pago_puntual] = TRUE),
    CALCULATE(COUNTROWS(fct_cuotas), fct_cuotas[pagada] = TRUE)
)
```

### Bloque 2 — Mora y aging

```dax
-- ⚠️ CRITICO: fct_mora_diaria es un SNAPSHOT DIARIO: cada credito moroso aparece
-- repetido en cada fecha de corte (77 cortes en este dataset). Si se suma la
-- columna sin filtrar, se suman 77 fotografias de la MISMA cartera y el saldo
-- vencido sale 30x mayor (12,530,172 en vez de 410,836).
-- Por eso TODA medida que sume o promedie sobre esta tabla lleva LASTDATE.

Créditos en mora =
CALCULATE(
    DISTINCTCOUNT(fct_mora_diaria[credito_id]),
    LASTDATE(fct_mora_diaria[fecha_corte])
)

Saldo vencido =
CALCULATE(
    SUM(fct_mora_diaria[saldo_vencido]),
    LASTDATE(fct_mora_diaria[fecha_corte])
)

Saldo total en mora =
CALCULATE(
    SUM(fct_mora_diaria[saldo_total]),
    LASTDATE(fct_mora_diaria[fecha_corte])
)

-- Profundidad de la mora de quienes ya están en mora
Intensidad de mora % =
DIVIDE([Saldo vencido], [Saldo total en mora])

-- Salud de la cartera: mora sobre el saldo por cobrar de TODO el portafolio
Mora sobre cartera % =
DIVIDE([Saldo vencido], [Saldo por cobrar])

Días de atraso promedio =
CALCULATE(
    AVERAGE(fct_mora_diaria[dias_atraso]),
    LASTDATE(fct_mora_diaria[fecha_corte])
)

Días de atraso máximo =
CALCULATE(
    MAX(fct_mora_diaria[dias_atraso]),
    LASTDATE(fct_mora_diaria[fecha_corte])
)

Saldo vencido crítico (>60 días) =
CALCULATE(
    SUM(fct_mora_diaria[saldo_vencido]),
    LASTDATE(fct_mora_diaria[fecha_corte]),
    fct_mora_diaria[orden_bucket] >= 3
)
```

### Bloque 3 — Gestión de cobranza

```dax
Gestiones = COUNTROWS(fct_gestiones)

Créditos gestionados = DISTINCTCOUNT(fct_gestiones[credito_id])

Pagos logrados =
CALCULATE(COUNTROWS(fct_gestiones), fct_gestiones[es_pago] = TRUE)

Promesas de pago =
CALCULATE(COUNTROWS(fct_gestiones), fct_gestiones[es_promesa] = TRUE)

Efectividad % =
DIVIDE(
    CALCULATE(COUNTROWS(fct_gestiones), fct_gestiones[es_gestion_efectiva] = TRUE),
    [Gestiones]
)

Efectividad de pago % =
DIVIDE([Pagos logrados], [Gestiones])

Monto recuperado = SUM(fct_gestiones[monto_recuperado])

Costo de cobranza = SUM(fct_gestiones[costo_gestion])

Costo por sol recuperado =
DIVIDE([Costo de cobranza], [Monto recuperado])

Recuperado por gestión =
DIVIDE([Monto recuperado], [Gestiones])

Duración promedio (seg) = AVERAGE(fct_gestiones[duracion_seg])
```

### Bloque 4 — Promesas de pago (PTP)

```dax
PTP registradas =
CALCULATE(COUNTROWS(fct_gestiones), fct_gestiones[es_promesa] = TRUE)

PTP cumplidas =
CALCULATE(
    COUNTROWS(fct_gestiones),
    fct_gestiones[es_promesa] = TRUE,
    fct_gestiones[ptp_cumplida] = "SI"
)

Cumplimiento PTP % =
DIVIDE([PTP cumplidas], [PTP registradas])

Monto prometido = SUM(fct_gestiones[monto_promesa])

Días promedio de promesa = AVERAGE(fct_gestiones[dias_para_promesa])
```

### Bloque 5 — Clientes y contacto

```dax
Clientes = COUNTROWS(dim_cliente)

Clientes contactables =
CALCULATE(COUNTROWS(dim_cliente), dim_cliente[es_contactable] = TRUE)

Contactabilidad % =
DIVIDE([Clientes contactables], [Clientes])

-- Cartera vencida sin ninguna gestión: el hallazgo de valor
Saldo vencido sin gestionar =
VAR CuotasConGestion =
    CALCULATETABLE(VALUES(fct_gestiones[cuota_id]))
RETURN
    CALCULATE(
        SUM(fct_cuotas[monto_cuota]),
        fct_cuotas[estado_cuota] = "VENCIDA",
        NOT fct_cuotas[cuota_id] IN CuotasConGestion
    )
```

### Bloque 6 — Cobertura y comparación temporal

```dax
-- Semáforo de efectividad por canal
Semáforo costo =
VAR Costo = [Costo por sol recuperado]
RETURN
    SWITCH(
        TRUE(),
        ISBLANK(Costo), "Sin datos",
        Costo < 0.025, "🟢 Eficiente",
        Costo < 0.030, "🟡 Aceptable",
        "🔴 Caro"
    )

Recaudado mes anterior =
CALCULATE([Recaudado], DATEADD(dim_fecha[fecha], -1, MONTH))

Variación recaudado % =
DIVIDE([Recaudado] - [Recaudado mes anterior], [Recaudado mes anterior])
```

---

## Las 4 páginas del tablero

### Página 1 — Resumen ejecutivo
**Para qué:** que en 10 segundos se entienda el estado de la cobranza.

- **6 tarjetas (cards)** arriba: `Saldo por cobrar`, `Saldo vencido`, `Mora sobre cartera %`,
  `Tasa de recuperación %`, `Cumplimiento PTP %`, `Costo por sol recuperado`
- **Gráfico de líneas:** `Saldo vencido` por `dim_fecha[fecha]` (mes) → ¿la mora sube o baja?
- **Gráfico de anillo:** `Saldo vencido` por `bucket_mora`
- **Segmentación (slicer):** `dim_credito[producto_desc]`, `dim_fecha[anio_mes]`

### Página 2 — Aging y evolución de la mora
**Para qué:** ver el deterioro y decidir dónde concentrar el esfuerzo.

- **Barras apiladas al 100%:** `bucket_mora` por mes (composición del aging)
- **Barras:** `Saldo vencido` por `bucket_mora`, con `Créditos en mora` como tooltip
- **Tarjeta:** `Saldo vencido crítico (>60 días)`
- **Matriz:** `bucket_mora` × `rango_score` con `Saldo vencido` (¿la mora se concentra en mal score?)

### Página 3 — Efectividad de la gestión
**Para qué:** decidir en qué canal y con qué asesor invertir.

- **Tabla con barras de datos:** `canal` con `Gestiones`, `Pagos logrados`, `Efectividad de
  pago %`, `Costo por sol recuperado` y la medida `Semáforo costo`
- **Dispersión (scatter):** eje X `Costo por sol recuperado`, eje Y `Efectividad de pago %`,
  tamaño `Gestiones`, detalle `canal` → el cuadrante superior-izquierdo es el canal ideal
- **Barras:** `Cumplimiento PTP %` por canal
- **Barras horizontales:** `Recuperado por gestión` por `dim_asesor[asesor_id]` (top 10)

### Página 4 — Priorización de la cartera
**Para qué:** la página *accionable*: a quién contactar hoy.

- **Matriz:** filas `cliente_id` / `nombre`, valores `Saldo vencido`, `Días de atraso`,
  último resultado de gestión. Filtrada a `Días de atraso > 30`.
- **Tarjeta grande:** `Saldo vencido sin gestionar` (la cartera que nadie está tocando)
- **Columnas:** `Gestiones` por `hora_del_dia` y por `nombre_dia` → el mejor momento de contacto
- **Segmentación:** `dim_cliente[es_contactable]` → ver la cartera que se cae por falta de datos
  de contacto

---

## Formato y buenas prácticas

- **Los KPI van como tarjetas, no dentro de gráficos.** El número primero, el detalle después.
- **Tema de color único** para las bandas de mora: verde (0-30) → ámbar (31-60) → naranja
  (61-90) → rojo (91-180+). El color debe comunicar gravedad.
- **Poner el contexto en los títulos**: en lugar de "Saldo vencido", poner
  "Saldo vencido — S/ 410,836 al 28/09/2026".
- **`DIVIDE` en lugar de `/`**: maneja la división por cero sin devolver error.
- **Formato de fecha largo** en las tarjetas de fecha (`dd/mm/yyyy`).
- Etiqueta los ejes en **soles (S/)** y los porcentajes con **1 decimal**.

---

## Nota honesta sobre los números de este dataset

El dataset es **sintético y deliberadamente estresado en mora**, así que el nivel absoluto de
`Mora sobre cartera %` (≈ 78%) es mucho más alto que el de una cartera real. **Lo que importa
para el portafolio es la metodología del cálculo, no el nivel sintético.** Si en una entrevista
te preguntan por esa cifra, la respuesta correcta es:

> "El dataset es sintético y simulé una cartera estresada para que hubiera suficiente volumen
> en todas las bandas de mora. Lo que quiero mostrar es la lógica: separo la intensidad de mora
> (cuánto del saldo del moroso ya venció) del ratio de mora sobre la cartera total, porque
> mezclarlos da un número engañoso."

Esa distinción —intensidad vs. ratio de cartera— es exactamente el tipo de rigor que se espera
de un analista de riesgo. La mayoría de practicantes no la hace.

---

## Checklist de montaje

- [ ] Cargar los 10 CSV desde `..\powerbi\`
- [ ] Crear las 10 relaciones del modelo
- [ ] Marcar `dim_fecha` como tabla de fechas
- [ ] Crear `dim_fecha_pago` como copia, con relación inactiva
- [ ] Crear la tabla `_Medidas` y pegar los 6 bloques de DAX
- [ ] Montar las 4 páginas
- [ ] Revisar que `Saldo vencido` coincida con `vw_kpis_principales.csv`
- [ ] Guardar el `.pbix` en esta carpeta
- [ ] **Si usaste Redshift: apagar el namespace**

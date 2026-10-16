# =============================================================================
# PROYECTO: Analitica de cobranzas - entorno de datos en AWS
# PASO 4: ejecutar el job de limpieza y registrar las tablas curadas
#
# QUE HACE:
#   1. Lanza el job de Glue y espera a que termine
#   2. Muestra el resultado y el tiempo de ejecucion (para vigilar el costo)
#   3. Corre el crawler de la capa curated
#   4. Muestra las tablas registradas y un resumen de costos
#
# USO:
#   .\04_ejecutar_job.ps1
#   .\04_ejecutar_job.ps1 -SinCrawler     (no corre el crawler al final)
# =============================================================================

param(
    [switch]$SinCrawler
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$JOB_NAME = "analitica-cobranzas-limpieza"
$CRAWLER_CUR = "analitica-cobranzas-crawler-curated"

function Paso($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok($t)       { Write-Host "    OK  $t" -ForegroundColor Green }
function Aviso($t)    { Write-Host "    !!  $t" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 0. Configuracion
# -----------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "No encuentro config.json. Ejecuta primero: .\01_setup_s3.ps1" -ForegroundColor Red
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json
$Bucket = $config.bucket
$Region = $config.region
$Database = "analitica_cobranzas"

Paso 0 "Lanzando el job de limpieza"
Ok "Job: $JOB_NAME | bucket: $Bucket"

# El job usa --HOY para detectar pagos con fecha futura. Lo pasamos actualizado.
# El JSON va por archivo (file://): PowerShell 5.1 rompe las comillas dobles inline.
$hoy = Get-Date -Format "yyyy-MM-dd"
$argsJob = '{"--BUCKET":"' + $Bucket + '","--DATABASE":"' + $Database + '","--HOY":"' + $hoy + '"}'
$archivoArgs = Join-Path $env:TEMP "cobranzas_glue_args.json"
Set-Content -Path $archivoArgs -Value $argsJob -Encoding ASCII

$runId = aws glue start-job-run --job-name $JOB_NAME --region $Region `
    --arguments "file://$archivoArgs" `
    --query "JobRunId" --output text
Remove-Item $archivoArgs -Force -ErrorAction SilentlyContinue

if (-not $runId -or $runId -eq "None") {
    Write-Host "No se pudo lanzar el job. Revisa que exista: .\03_crear_glue_job.ps1" -ForegroundColor Red
    exit 1
}
Ok "JobRunId: $runId"

# -----------------------------------------------------------------------------
# 1. Esperar a que termine
# -----------------------------------------------------------------------------
Paso 1 "Esperando a que termine (esto puede tardar 2-5 minutos)"

$inicio = Get-Date
$estado = "STARTING"
while ($estado -in @("STARTING", "RUNNING", "WAITING")) {
    Start-Sleep -Seconds 15
    $info = aws glue get-job-run --job-name $JOB_NAME --run-id $runId --region $Region --output json | ConvertFrom-Json
    $estado = $info.JobRun.JobRunState
    $seg = [int]((Get-Date) - $inicio).TotalSeconds
    Write-Host ("    [{0,4}s] {1}" -f $seg, $estado)
}

$info = aws glue get-job-run --job-name $JOB_NAME --run-id $runId --region $Region --output json | ConvertFrom-Json
$ejecucion = [int]$info.JobRun.ExecutionTime
$dpuSegundos = [int]$info.JobRun.ExecutionTime  # segundos de ejecucion
$dpuHoras = $ejecucion / 3600.0
# 2 workers G.1X = 2 DPU; minimo facturable 1 minuto
$minutosFacturados = [Math]::Max(1, [Math]::Ceiling($ejecucion / 60.0))
$costo = $minutosFacturados / 60.0 * 2 * 0.44

Write-Host ""
if ($estado -eq "SUCCEEDED") {
    Ok "El job termino correctamente"
} else {
    Aviso "El job termino con estado: $estado"
    Write-Host "`n    Ultimas lineas del log de error:" -ForegroundColor Yellow
    try {
        $logGroup = "/aws-glue/jobs/error"
        aws logs describe-log-streams --log-group-name $logGroup --order-by LastEventTime --descending --max-items 1 --region $Region --query "logStreams[0].logStreamName" --output text 2>$null
    } catch { }
    Write-Host "    Revisa la consola de Glue -> Jobs -> Runs para el detalle."
}

# -----------------------------------------------------------------------------
# 2. Resumen de ejecucion y costo
# -----------------------------------------------------------------------------
Paso 2 "Resumen de ejecucion"
Write-Host "    Estado              : $estado"
Write-Host ("    Tiempo de ejecucion : {0}s" -f $ejecucion)
Write-Host ("    Minutos facturados  : {0} (Glue redondea a 1 min, minimo 2 DPU)" -f $minutosFacturados)
Write-Host ("    Costo estimado      : `$ {0:N4}" -f $costo) -ForegroundColor Green

if ($ejecucion -gt 300) {
    Aviso "El job tardo mas de 5 minutos. Revisa si necesitas mas workers."
    Aviso "Cada minuto extra con 2 DPU cuesta aproximadamente `$0.0147"
}

# -----------------------------------------------------------------------------
# 3. Crawler de la capa curated
# -----------------------------------------------------------------------------
if (-not $SinCrawler -and $estado -eq "SUCCEEDED") {
    Paso 3 "Registrando las tablas curadas en el Data Catalog"

    aws glue start-crawler --name $CRAWLER_CUR --region $Region | Out-Null
    Ok "Crawler lanzado: $CRAWLER_CUR"

    $estadoCrawler = "STARTING"
    $inicioC = Get-Date
    while ($estadoCrawler -in @("STARTING", "RUNNING", "STOPPING")) {
        Start-Sleep -Seconds 10
        $c = aws glue get-crawler --name $CRAWLER_CUR --region $Region --output json | ConvertFrom-Json
        $estadoCrawler = $c.Crawler.State
        $seg = [int]((Get-Date) - $inicioC).TotalSeconds
        if ($seg -gt 300) { Aviso "El crawler tarda mas de lo esperado, sigo sin bloquear"; break }
    }
    Ok "Crawler finalizado: $estadoCrawler"

    Write-Host "`n    Tablas registradas en la base $Database :"
    aws glue get-tables --database-name $Database --region $Region `
        --query "TableList[].{Tabla:Name,Ubicacion:StorageDescriptor.Location}" --output table
} else {
    Paso 3 "Crawler omitido"
    Aviso "Correlo manualmente cuando quieras: aws glue start-crawler --name $CRAWLER_CUR"
}

# -----------------------------------------------------------------------------
# RESUMEN FINAL
# -----------------------------------------------------------------------------
Write-Host "`n=============================================================" -ForegroundColor Cyan
Write-Host " PROCESO TERMINADO" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " SIGUIENTE PASO - validar la calidad desde Athena:"
Write-Host "   Abre: aws\02_athena_validacion_curated.sql"
Write-Host "   Ejecuta los bloques y verifica que TODOS los chequeos den 0."
Write-Host ""
Write-Host " Recordatorio de costo:"
Write-Host "   El job de Glue y el crawler cobran por tiempo de ejecucion."
Write-Host "   No hay nada encendido 24/7 en este paso, asi que no hay riesgo de fuga."
Write-Host "=============================================================" -ForegroundColor Cyan

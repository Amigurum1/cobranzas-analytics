# =============================================================================
# PROYECTO: Analitica de cobranzas - entorno de datos en AWS
# PASO 3: crear el job de Glue y los crawlers que registran las tablas
#
# QUE HACE:
#   1. Verifica que el bucket exista
#   2. Sube el script del job a s3://<bucket>/scripts/
#   3. Crea (o actualiza) el IAM role que Glue necesita
#   4. Crea (o actualiza) el job de Glue
#   5. Crea (o actualiza) los 2 crawlers: raw y curated
#
# USO:
#   .\03_crear_glue_job.ps1
#
# Requiere: .\01_setup_s3.ps1 ejecutado antes (genera config.json)
# =============================================================================

param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ROLE_NAME  = "AWSGlueServiceRole-analitica-cobranzas"
$JOB_NAME   = "analitica-cobranzas-limpieza"
$CRAWLER_RAW = "analitica-cobranzas-crawler-raw"
$CRAWLER_CUR = "analitica-cobranzas-crawler-curated"

function Paso($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok($t)       { Write-Host "    OK  $t" -ForegroundColor Green }
function Aviso($t)    { Write-Host "    !!  $t" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 0. Verificaciones previas
# -----------------------------------------------------------------------------
Paso 0 "Verificando prerequisitos"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI no esta instalado. Ejecuta: winget install -e --id Amazon.AWSCLI" -ForegroundColor Red
    exit 1
}

$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "No encuentro config.json. Ejecuta primero: .\01_setup_s3.ps1 -Contacto `"tu-nombre`"" -ForegroundColor Red
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json
$Bucket = $config.bucket
$Region = $config.region
$Database = "analitica_cobranzas"

$identidad = aws sts get-caller-identity --output json | ConvertFrom-Json
if ($identidad.Arn -match ":root$") {
    Write-Host "ESTAS USANDO LA CUENTA ROOT. Usa tu usuario de trabajo. Abortando." -ForegroundColor Red
    exit 1
}
Ok "Cuenta $($identidad.Account) | bucket: $Bucket | region: $Region"

# Confirmar que el bucket existe
$existe = $true
try { aws s3api head-bucket --bucket $Bucket 2>$null } catch { $existe = $false }
if (-not $existe) {
    Write-Host "El bucket $Bucket no existe. Ejecuta primero: .\01_setup_s3.ps1" -ForegroundColor Red
    exit 1
}
Ok "Bucket verificado"

# -----------------------------------------------------------------------------
# 1. Subir el script del job a S3
# -----------------------------------------------------------------------------
Paso 1 "Subiendo el script del job de Glue"

$scriptLocal = Join-Path $PSScriptRoot "glue_job_limpieza.py"
if (-not (Test-Path $scriptLocal)) {
    Write-Host "No encuentro glue_job_limpieza.py" -ForegroundColor Red
    exit 1
}
aws s3 cp $scriptLocal "s3://$Bucket/scripts/glue_job_limpieza.py" --only-show-errors
if ($LASTEXITCODE -eq 0) {
    Ok "Script en s3://$Bucket/scripts/glue_job_limpieza.py"
} else {
    Write-Host "FALLO la subida del script del job. Abortando: sin el script el job no puede correr." -ForegroundColor Red
    exit 1
}

# -----------------------------------------------------------------------------
# 2. IAM role para Glue
# -----------------------------------------------------------------------------
Paso 2 "Creando el IAM role de Glue"

$roleArn = ""
try {
    $roleArn = aws iam get-role --role-name $ROLE_NAME --query "Role.Arn" --output text 2>$null
} catch { }

if ($roleArn -and $roleArn -ne "None") {
    Aviso "El role ya existe: $roleArn"
} else {
    $trust = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "glue.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
'@
    $trustFile = Join-Path $env:TEMP "glue_trust.json"
    Set-Content -Path $trustFile -Value $trust -Encoding ASCII

    $roleArn = aws iam create-role --role-name $ROLE_NAME `
        --assume-role-policy-document "file://$trustFile" `
        --query "Role.Arn" --output text
    if ($LASTEXITCODE -eq 0 -and $roleArn) {
        Ok "Role creado: $roleArn"
    } else {
        Write-Host "FALLO al crear el role de Glue. Abortando." -ForegroundColor Red
        exit 1
    }

    # Politica administrada de Glue (incluye permisos de logs)
    aws iam attach-role-policy --role-name $ROLE_NAME `
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Ok "Politica AWSGlueServiceRole adjuntada"
    } else {
        Write-Host "FALLO al adjuntar AWSGlueServiceRole: el job quedaria sin permisos. Abortando." -ForegroundColor Red
        exit 1
    }
}

# Politica de acceso al bucket del proyecto (idempotente)
$bucketPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$Bucket",
        "arn:aws:s3:::$Bucket/*"
      ]
    }
  ]
}
"@
$bpFile = Join-Path $env:TEMP "glue_bucket_policy.json"
Set-Content -Path $bpFile -Value $bucketPolicy -Encoding ASCII

aws iam put-role-policy --role-name $ROLE_NAME `
    --policy-name "analitica-cobranzas-s3-access" `
    --policy-document "file://$bpFile" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Ok "Politica de acceso al bucket aplicada"
} else {
    Write-Host "FALLO la politica del bucket: el job no podria leer ni escribir S3. Abortando." -ForegroundColor Red
    exit 1
}

Aviso "IAM tarda unos segundos en propagar el role. Si el job falla por permisos, espera 30s y reintenta."

# -----------------------------------------------------------------------------
# 3. Crear o actualizar el job de Glue
# -----------------------------------------------------------------------------
Paso 3 "Creando el job de Glue: $JOB_NAME"

$jobCommand = @{
    Name            = "glueetl"
    ScriptLocation  = "s3://$Bucket/scripts/glue_job_limpieza.py"
    PythonVersion   = "3"
} | ConvertTo-Json -Compress

$defaultArgs = @{
    "--BUCKET"   = $Bucket
    "--DATABASE" = $Database
    "--HOY"      = (Get-Date -Format "yyyy-MM-dd")
    "--job-language" = "python"
} | ConvertTo-Json -Compress

$existeJob = $true
try { aws glue get-job --job-name $JOB_NAME 2>$null | Out-Null } catch { $existeJob = $false }

# El JSON va por archivo (file://): PowerShell 5.1 elimina las comillas dobles al
# pasar argumentos a ejecutables nativos y el JSON llega roto a la CLI.
$jobCuerpo = @"
  "Role": "$roleArn",
  "Command": $jobCommand,
  "DefaultArguments": $defaultArgs,
  "GlueVersion": "4.0",
  "WorkerType": "G.1X",
  "NumberOfWorkers": 2,
  "Timeout": 10,
  "MaxRetries": 0,
  "ExecutionProperty": { "MaxConcurrentRuns": 1 }
"@

# update-job usa --job-update, que espera SOLO el cuerpo (el objeto JobUpdate).
$archivoJobUpdate = Join-Path $env:TEMP "cobranzas_job_update.json"
Set-Content -Path $archivoJobUpdate -Value ("{`n" + $jobCuerpo + "`n}") -Encoding ASCII

# create-job NO tiene parametro --job: sus parametros son planos y hay que anadir
# "Name". Se pasa con --cli-input-json. Estructura verificada con --generate-cli-skeleton.
$archivoJobCreate = Join-Path $env:TEMP "cobranzas_job_create.json"
Set-Content -Path $archivoJobCreate -Value ('{' + "`n" + '  "Name": "' + $JOB_NAME + '",' + "`n" + $jobCuerpo + "`n}") -Encoding ASCII

if ($existeJob) {
    aws glue update-job --job-name $JOB_NAME --job-update "file://$archivoJobUpdate" --region $Region
    if ($LASTEXITCODE -eq 0) {
        Ok "Job actualizado (Glue 4.0, 2 workers G.1X, timeout 10 min)"
    } else {
        Aviso "FALLO al actualizar el job: revisa el error de la CLI mas arriba"
    }
} else {
    aws glue create-job --cli-input-json "file://$archivoJobCreate" --region $Region
    if ($LASTEXITCODE -eq 0) {
        Ok "Job creado (Glue 4.0, 2 workers G.1X, timeout 10 min)"
    } else {
        Aviso "FALLO al crear el job: revisa el error de la CLI mas arriba"
    }
}
Remove-Item $archivoJobUpdate,$archivoJobCreate -Force -ErrorAction SilentlyContinue

Aviso "2 workers G.1X = 2 DPU = 0.88 USD/hora, con minimo de 1 minuto de facturacion."
Aviso "Con 129 mil filas el job corre en menos de 1 minuto. Vigila el tiempo en cada corrida."

# -----------------------------------------------------------------------------
# 4. Crawlers
# -----------------------------------------------------------------------------
Paso 4 "Creando los crawlers del Data Catalog"

# Base de datos destino
$existeDb = $true
try { aws glue get-database --name $Database --region $Region 2>$null | Out-Null } catch { $existeDb = $false }
if (-not $existeDb) {
    $dbDef = '{"Name":"' + $Database + '","Description":"Datos de cobranzas - proyecto de portafolio"}'
    $archivoDb = Join-Path $env:TEMP "cobranzas_database.json"
    Set-Content -Path $archivoDb -Value $dbDef -Encoding ASCII
    aws glue create-database --database-input "file://$archivoDb" --region $Region
    if ($LASTEXITCODE -eq 0) {
        Ok "Base de datos creada: $Database"
    } else {
        Aviso "FALLO al crear la base de datos: revisa el error de la CLI mas arriba"
    }
    Remove-Item $archivoDb -Force -ErrorAction SilentlyContinue
} else {
    Aviso "La base de datos $Database ya existe"
}

function Crear-Crawler($nombre, $prefijo, $tablaPrefijo) {
    $existe = $true
    try { aws glue get-crawler --name $nombre --region $Region 2>$null | Out-Null } catch { $existe = $false }
    # Ni create-crawler ni update-crawler tienen un parametro --crawler: sus
    # parametros son planos y el JSON debe incluir "Name". Se pasa con --cli-input-json.
    # Estructura verificada con --generate-cli-skeleton.
    $cfg = @"
{
  "Name": "$nombre",
  "Role": "$roleArn",
  "DatabaseName": "$Database",
  "Targets": { "S3Targets": [ { "Path": "s3://$Bucket/$prefijo" } ] },
  "TablePrefix": "$tablaPrefijo",
  "SchemaChangePolicy": { "UpdateBehavior": "UPDATE_IN_DATABASE", "DeleteBehavior": "DEPRECATE_IN_DATABASE" }
}
"@
    # El JSON va por archivo (file://): PowerShell 5.1 rompe las comillas dobles inline.
    $archivoCrawler = Join-Path $env:TEMP "cobranzas_crawler_$nombre.json"
    Set-Content -Path $archivoCrawler -Value $cfg -Encoding ASCII
    if ($existe) {
        aws glue update-crawler --cli-input-json "file://$archivoCrawler" --region $Region
        if ($LASTEXITCODE -eq 0) { Aviso "Crawler $nombre actualizado" } else { Aviso "FALLO al actualizar $nombre" }
    } else {
        aws glue create-crawler --cli-input-json "file://$archivoCrawler" --region $Region
        if ($LASTEXITCODE -eq 0) { Ok "Crawler creado: $nombre" } else { Aviso "FALLO al crear $nombre" }
    }
    Remove-Item $archivoCrawler -Force -ErrorAction SilentlyContinue
}

Crear-Crawler $CRAWLER_RAW "raw/" "raw_"
Crear-Crawler $CRAWLER_CUR "curated/" ""

# -----------------------------------------------------------------------------
# 5. VERIFICACION FINAL: comprobar que los recursos EXISTEN de verdad
#    (antes este resumen decia "GLUE LISTO" aunque el job no se hubiera creado)
# -----------------------------------------------------------------------------
Paso 5 "Verificacion final (preguntando a AWS, no asumiendo)"

$jobOk = $true
try { aws glue get-job --job-name $JOB_NAME --region $Region 2>$null | Out-Null } catch { $jobOk = $false }

$crawlerRawOk = $true
try { aws glue get-crawler --name $CRAWLER_RAW --region $Region 2>$null | Out-Null } catch { $crawlerRawOk = $false }

$crawlerCurOk = $true
try { aws glue get-crawler --name $CRAWLER_CUR --region $Region 2>$null | Out-Null } catch { $crawlerCurOk = $false }

if ($jobOk) { Ok "Job existe: $JOB_NAME" } else { Aviso "El job NO existe: $JOB_NAME" }
if ($crawlerRawOk) { Ok "Crawler raw existe" } else { Aviso "El crawler raw NO existe" }
if ($crawlerCurOk) { Ok "Crawler curated existe" } else { Aviso "El crawler curated NO existe" }

# -----------------------------------------------------------------------------
# RESUMEN
# -----------------------------------------------------------------------------
$todoOk = $jobOk -and $crawlerRawOk -and $crawlerCurOk

Write-Host "`n=============================================================" -ForegroundColor Cyan
if ($todoOk) {
    Write-Host " GLUE LISTO (verificado contra AWS)" -ForegroundColor Green
} else {
    Write-Host " GLUE INCOMPLETO - revisa los FALLO de arriba" -ForegroundColor Red
}
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " Job         : $JOB_NAME            $(if ($jobOk) { 'OK' } else { 'FALTA' })"
Write-Host " Crawlers    : $CRAWLER_RAW (raw)    $(if ($crawlerRawOk) { 'OK' } else { 'FALTA' })"
Write-Host "               $CRAWLER_CUR (curated) $(if ($crawlerCurOk) { 'OK' } else { 'FALTA' })"
Write-Host " Database    : $Database"
Write-Host ""
if (-not $todoOk) {
    Write-Host " Corrige los FALLO antes de seguir: el paso 04 fallara si falta el job." -ForegroundColor Yellow
    Write-Host ""
}
Write-Host " SIGUIENTE PASO - ejecutar el job de limpieza:"
Write-Host "   .\04_ejecutar_job.ps1"
Write-Host ""
Write-Host " NO ejecutes el crawler de raw ($CRAWLER_RAW):" -ForegroundColor Yellow
Write-Host "   Las tablas raw ya existen (las creo el DDL de Athena, todas STRING). El"
Write-Host "   crawler generaria esos MISMOS nombres con tipos inferidos y sobreescribiria"
Write-Host "   el esquema. Tampoco hace falta: el job lee los CSV directo de S3."
Write-Host "   El crawler de curated SI lo lanza el 04 automaticamente."
Write-Host "=============================================================" -ForegroundColor Cyan

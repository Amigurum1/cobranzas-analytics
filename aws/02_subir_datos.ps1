# =============================================================================
# PROYECTO: Analitica de cobranzas - entorno de datos en AWS
# PASO 2: subir los 5 CSV a la capa raw de S3 y verificar
#
# USO:
#   .\02_subir_datos.ps1
#   .\02_subir_datos.ps1 -RawDir "C:\otra\ruta\raw"
#
# Requiere haber ejecutado antes: .\01_setup_s3.ps1
# =============================================================================

param(
    [string]$RawDir = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Paso($n, $texto) { Write-Host "`n[$n] $texto" -ForegroundColor Cyan }
function Ok($texto)        { Write-Host "    OK  $texto" -ForegroundColor Green }
function Aviso($texto)     { Write-Host "    !!  $texto" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 1. Verificar AWS CLI (fallar temprano, no a mitad de la subida)
# -----------------------------------------------------------------------------
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCmd) {
    Write-Host "AWS CLI no esta instalado. Instalalo con:" -ForegroundColor Red
    Write-Host "  winget install -e --id Amazon.AWSCLI"
    Write-Host "Luego cierra y reabre la terminal."
    exit 1
}

$identidad = $null
try { $identidad = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json } catch { }
if (-not $identidad) {
    Write-Host "No hay credenciales de AWS activas. Ejecuta 'aws configure' o 'aws configure sso'." -ForegroundColor Red
    exit 1
}
if ($identidad.Arn -match ":root$") {
    Write-Host "ESTAS USANDO LA CUENTA ROOT. Usa tu usuario de trabajo. Abortando." -ForegroundColor Red
    exit 1
}

# -----------------------------------------------------------------------------
# 2. Leer la configuracion del paso anterior
# -----------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host ('No encuentro config.json. Ejecuta primero: .\01_setup_s3.ps1 -Contacto "tu-nombre"') -ForegroundColor Red
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json
$Bucket = $config.bucket
Paso 1 "Configuracion cargada - bucket: s3://$Bucket"

# -----------------------------------------------------------------------------
# 2. Ubicar la carpeta raw
# -----------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($RawDir)) {
    $RawDir = Join-Path (Split-Path $PSScriptRoot -Parent) "raw"
}
if (-not (Test-Path $RawDir)) {
    Write-Host "No existe la carpeta: $RawDir" -ForegroundColor Red
    Write-Host "Genera el dataset primero: python generar_dataset_cobranzas.py --out raw"
    exit 1
}
Ok "Carpeta origen: $RawDir"

# -----------------------------------------------------------------------------
# 3. Subir cada archivo a su prefijo
# -----------------------------------------------------------------------------
$archivos = @(
    @{ Local = "clientes.csv";            Key = "raw/clientes/clientes.csv" },
    @{ Local = "creditos.csv";            Key = "raw/creditos/creditos.csv" },
    @{ Local = "cuotas.csv";              Key = "raw/cuotas/cuotas.csv" },
    @{ Local = "gestiones_cobranza.csv";  Key = "raw/gestiones_cobranza/gestiones_cobranza.csv" },
    @{ Local = "mora_snapshot.csv";       Key = "raw/mora_snapshot/mora_snapshot.csv" }
)

Paso 2 "Subiendo archivos a la capa raw"

$totalMB = 0
foreach ($a in $archivos) {
    $ruta = Join-Path $RawDir $a.Local
    if (-not (Test-Path $ruta)) {
        Aviso "Falta el archivo $($a.Local) - se omite"
        continue
    }
    $mb = (Get-Item $ruta).Length / 1MB
    $totalMB += $mb
    Write-Host ("    -> {0,-24} {1,7:N2} MB" -f $a.Local, $mb) -NoNewline
    # El comando va en SU PROPIA LINEA. Si se deja en la misma linea que Write-Host,
    # PowerShell lo toma como argumentos del Write-Host y NUNCA se ejecuta.
    aws s3 cp $ruta "s3://$Bucket/$($a.Key)" --only-show-errors
    if ($LASTEXITCODE -eq 0) { Write-Host "  subido" -ForegroundColor Green }
    else { Write-Host "  ERROR" -ForegroundColor Red }
}

Ok ("Total transferido: {0:N2} MB" -f $totalMB)

# -----------------------------------------------------------------------------
# 4. Verificar que S3 los recibio completos
# -----------------------------------------------------------------------------
Paso 3 "Verificando en S3"

Write-Host "`n    Objetos en el bucket:"
aws s3 ls "s3://$Bucket/" --recursive --human-readable

Write-Host "`n    Comparacion de tamanos (local vs S3):"
$ok = $true
foreach ($a in $archivos) {
    $ruta = Join-Path $RawDir $a.Local
    if (-not (Test-Path $ruta)) { continue }
    $local = (Get-Item $ruta).Length
    # try/catch: si el objeto no existe, el error nativo abortaria el script
    # con $ErrorActionPreference = "Stop" (comportamiento verificado en PS 5.1).
    $s3 = $null
    try { $s3 = aws s3api head-object --bucket $Bucket --key $a.Key --query "ContentLength" --output text 2>$null } catch { $s3 = $null }
    if ($s3 -and $local -eq [long]$s3) {
        Write-Host ("    OK   {0,-24} {1} bytes" -f $a.Local, $local) -ForegroundColor Green
    } else {
        $visto = "NO EXISTE en S3"
        if ($s3) { $visto = "$s3 bytes" }
        Write-Host ("    DIFF {0,-24} local={1} s3={2}" -f $a.Local, $local, $visto) -ForegroundColor Red
        $ok = $false
    }
}

# -----------------------------------------------------------------------------
# 5. Instrucciones para el paso siguiente
# -----------------------------------------------------------------------------
Write-Host "`n=============================================================" -ForegroundColor Cyan
if ($ok) {
    Write-Host " DATOS EN S3 - VERIFICADO" -ForegroundColor Green
} else {
    Write-Host " ATENCION: hay diferencias de tamano, revisa arriba" -ForegroundColor Yellow
}
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " SIGUIENTE PASO - crear las tablas en Athena:"
Write-Host ""
Write-Host "  1. Abre la consola de Athena en us-east-1"
Write-Host "  2. Settings -> Manage -> Query result location:"
Write-Host "       s3://$Bucket/athena-results/"
Write-Host "     (sin esto Athena NO ejecuta nada - es el error #1 al empezar)"
Write-Host "  3. Editor -> abre el archivo: aws\01_athena_ddl_raw.sql"
Write-Host "  4. Reemplaza TODAS las apariciones de <TU-BUCKET> por:"
Write-Host "       $Bucket"
Write-Host "  5. Ejecuta el script y al final corre la consulta de verificacion"
Write-Host ""
Write-Host " Conteos esperados:"
Write-Host "   clientes 5,025 | creditos 6,254 | cuotas 71,229"
Write-Host "   gestiones_cobranza 25,689 | mora_snapshot 21,547"
Write-Host "=============================================================" -ForegroundColor Cyan

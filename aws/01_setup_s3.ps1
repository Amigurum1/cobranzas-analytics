# =============================================================================
# PROYECTO: Analitica de cobranzas - entorno de datos en AWS
# PASO 1: verificar la cuenta y crear el bucket S3 con su estructura
#
# REQUISITOS PREVIOS (no los saltes):
#   1. AWS CLI v2 instalado
#   2. Usuario de trabajo con MFA habilitado (NO el root)
#   3. Budgets configurados con alertas en $1 / $5 / $10
#   4. Region us-east-1 (Norte de Virginia)
#
# USO:
#   .\01_setup_s3.ps1 -Contacto "bruno"
#   .\01_setup_s3.ps1 -Contacto "bruno" -Bucket "mi-nombre-unico-123"
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Contacto,

    [string]$Bucket = "",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Paso($n, $texto) { Write-Host "`n[$n] $texto" -ForegroundColor Cyan }
function Ok($texto)        { Write-Host "    OK  $texto" -ForegroundColor Green }
function Aviso($texto)     { Write-Host "    !!  $texto" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 0. Verificar que AWS CLI existe
# -----------------------------------------------------------------------------
Paso 0 "Verificando AWS CLI"
try {
    $ver = (aws --version 2>&1) -join " "
    Ok $ver
} catch {
    Write-Host "`nAWS CLI no esta instalado." -ForegroundColor Red
    Write-Host "Instalalo con una de estas opciones:"
    Write-Host "  winget install -e --id Amazon.AWSCLI"
    Write-Host "  o descarga: https://awscli.amazonaws.com/AWSCLIV2.msi"
    exit 1
}

# -----------------------------------------------------------------------------
# 1. Verificar identidad (que NO seas root y que tengas MFA)
# -----------------------------------------------------------------------------
Paso 1 "Verificando identidad de la cuenta"
try {
    $identidad = aws sts get-caller-identity --output json | ConvertFrom-Json
} catch {
    Write-Host "`nNo hay credenciales configuradas. Ejecuta primero:" -ForegroundColor Red
    Write-Host "  aws configure sso          (si usas IAM Identity Center)"
    Write-Host "  aws configure              (si usas usuario IAM con access key)"
    exit 1
}

Write-Host "    Account : $($identidad.Account)"
Write-Host "    ARN     : $($identidad.Arn)"

if ($identidad.Arn -match ":root$") {
    Aviso "ESTAS USANDO LA CUENTA ROOT. Es una mala practica."
    Aviso "Crea tu usuario de trabajo y vuelve a ejecutar. Abortando."
    exit 1
}
Ok "No eres la cuenta root."

# -----------------------------------------------------------------------------
# 2. Definir el nombre del bucket
# -----------------------------------------------------------------------------
Paso 2 "Definiendo el nombre del bucket"

$configPath = Join-Path $PSScriptRoot "config.json"

# Reutilizar el bucket ya configurado. Sin esto, cada corrida genera un nombre
# aleatorio NUEVO, deja el bucket anterior huerfano y sobrescribe config.json;
# los scripts 02-05 apuntarian al nuevo y el viejo quedaria para siempre.
if ($Bucket -eq "" -and (Test-Path $configPath)) {
    $previo = Get-Content $configPath | ConvertFrom-Json
    if ($previo.bucket) {
        $Bucket = $previo.bucket
        Aviso "Reutilizando el bucket de config.json: $Bucket"
    }
}

if ([string]::IsNullOrWhiteSpace($Bucket)) {
    $aleatorio = -join ((1..6) | ForEach-Object { "0123456789abcdefghijklmnopqrstuvwxyz"[(Get-Random -Maximum 36)] })
    $Bucket = "analitica-cobranzas-$($Contacto.ToLower())-$aleatorio"
    Aviso "Nombre generado automaticamente: $Bucket"
}
Ok "Bucket: $Bucket"

# Guardar la configuracion para los siguientes scripts
@{ bucket = $Bucket; region = $Region; contacto = $Contacto } | ConvertTo-Json | Set-Content $configPath
Ok "Configuracion guardada en config.json"

# -----------------------------------------------------------------------------
# 3. Configurar la region por defecto
# -----------------------------------------------------------------------------
Paso 3 "Configurando la region por defecto: $Region"
aws configure set region $Region
Ok "Region configurada (us-east-1 es la mas barata; manten todo aqui)"

# -----------------------------------------------------------------------------
# 4. Crear el bucket
# -----------------------------------------------------------------------------
Paso 4 "Creando el bucket S3"

$existe = $true
try { aws s3api head-bucket --bucket $Bucket 2>$null } catch { $existe = $false }

if ($existe) {
    Aviso "El bucket ya existe, no se crea de nuevo."
} else {
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $Bucket --region $Region | Out-Null
    } else {
        aws s3api create-bucket --bucket $Bucket --region $Region `
            --create-bucket-configuration LocationConstraint=$Region | Out-Null
    }
    Ok "Bucket creado: s3://$Bucket"
}

# -----------------------------------------------------------------------------
# 5. Bloquear TODO acceso publico
# -----------------------------------------------------------------------------
Paso 5 "Bloqueando acceso publico (critico)"
aws s3api put-public-access-block --bucket $Bucket --public-access-block-configuration `
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null
Ok "Acceso publico bloqueado en los 4 niveles"
Aviso "Un bucket publico con datos de cobranzas seria una fuga de datos. Dejalo siempre bloqueado."

# -----------------------------------------------------------------------------
# 6. Cifrado por defecto
# -----------------------------------------------------------------------------
Paso 6 "Activando cifrado por defecto (SSE-S3, sin costo adicional)"
# El JSON va por archivo (file://), NO inline: PowerShell 5.1 elimina las comillas
# dobles al pasar argumentos a ejecutables nativos y el JSON llega roto a la CLI.
$reglaCifrado = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
$archivoCifrado = Join-Path $env:TEMP "cobranzas_encryption.json"
Set-Content -Path $archivoCifrado -Value $reglaCifrado -Encoding ASCII

aws s3api put-bucket-encryption --bucket $Bucket `
    --server-side-encryption-configuration "file://$archivoCifrado"
if ($LASTEXITCODE -eq 0) {
    Ok "Cifrado activado"
} else {
    Aviso "FALLO el cifrado: revisa el error de la CLI mas arriba"
}
Remove-Item $archivoCifrado -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# 7. Crear la estructura de carpetas (capas del data lake)
# -----------------------------------------------------------------------------
Paso 7 "Creando la estructura de capas del data lake"

$carpetas = @(
    "raw/clientes/",
    "raw/creditos/",
    "raw/cuotas/",
    "raw/gestiones_cobranza/",
    "raw/mora_snapshot/",
    "curated/",
    "athena-results/",
    "scripts/",
    "logs/"
)

foreach ($c in $carpetas) {
    aws s3api put-object --bucket $Bucket --key $c | Out-Null
    Write-Host "    + $c"
}
Ok "$($carpetas.Count) prefijos creados"
Aviso "La estructura es: raw (crudo) -> curated (limpio en Parquet) -> athena-results (salidas)"

# -----------------------------------------------------------------------------
# 8. Verificacion final
# -----------------------------------------------------------------------------
Paso 8 "Verificacion final"

Write-Host "`n    Contenido del bucket:"
aws s3 ls "s3://$Bucket/" --recursive

Write-Host "`n    Configuracion aplicada:"
aws s3api get-public-access-block --bucket $Bucket --query "PublicAccessBlockConfiguration" --output json
aws s3api get-bucket-encryption --bucket $Bucket --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault" --output json

# -----------------------------------------------------------------------------
# RESUMEN
# -----------------------------------------------------------------------------
Write-Host "`n=============================================================" -ForegroundColor Cyan
Write-Host " BUCKET LISTO" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " Bucket : s3://$Bucket"
Write-Host " Region : $Region"
Write-Host " Config : $configPath"
Write-Host ""
Write-Host " Siguiente paso:"
Write-Host "   .\02_subir_datos.ps1"
Write-Host "=============================================================" -ForegroundColor Cyan

# =============================================================================
# PROYECTO: Analitica de cobranzas - entorno de datos en AWS
# PASO 5 (OPCIONAL): automatizar el pipeline con Lambda + evento de S3
#
# QUE HACE:
#   1. Empaqueta y publica la funcion Lambda
#   2. Crea el rol IAM con permisos minimos (solo lo que necesita)
#   3. Configura la notificacion de S3: archivo nuevo en raw/ -> dispara Lambda
#   4. Verifica la configuracion con una invocacion de prueba
#
# RESULTADO: al subir un archivo a raw/, el pipeline corre solo. Nadie aprieta
# un boton.
#
# COSTO: Lambda es gratis en este volumen (free tier permanente: 1M invocaciones
# y 400,000 GB-segundo al mes). El costo real lo sigue teniendo el job de Glue.
#
# USO:
#   .\05_configurar_lambda.ps1 -Simular     (muestra que haria, sin crear nada)
#   .\05_configurar_lambda.ps1              (crea todo)
#   .\05_configurar_lambda.ps1 -Probar      (solo invoca la funcion para probar)
#
# Requiere: haber ejecutado 01_setup_s3.ps1 y 03_crear_glue_job.ps1
# =============================================================================

param(
    [switch]$Simular,
    [switch]$Probar
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$FUNCION       = "analitica-cobranzas-disparador"
$ROL           = "analitica-cobranzas-lambda-role"
$JOB_GLUE      = "analitica-cobranzas-limpieza"
$HOY           = (Get-Date -Format "yyyy-MM-dd")

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

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI no esta instalado." -ForegroundColor Red
    exit 1
}

Paso 0 "Configuracion"
Write-Host "    bucket : $Bucket"
Write-Host "    region : $Region"
Write-Host "    funcion: $FUNCION"

# -----------------------------------------------------------------------------
# Modo PRUEBA: solo invocar la funcion existente
# -----------------------------------------------------------------------------
if ($Probar) {
    Paso "PROBAR" "Invocando la funcion con un evento simulado"
    $tmp = Join-Path $env:TEMP "evento_lambda.json"
    @"
{"Records":[{"s3":{"bucket":{"name":"$Bucket"},"object":{"key":"raw/cuotas/cuotas.csv"}}}]}
"@ | Set-Content -Path $tmp -Encoding ASCII

    $salida = Join-Path $env:TEMP "salida_lambda.json"
    aws lambda invoke --function-name $FUNCION --payload "fileb://$tmp" `
        --region $Region $salida | Out-Null
    Write-Host "    Respuesta de la funcion:"
    Get-Content $salida -Raw
    exit 0
}

# -----------------------------------------------------------------------------
# 1. Rol IAM con permisos minimos
# -----------------------------------------------------------------------------
Paso 1 "Creando el rol IAM de la Lambda (permisos minimos)"

$roleArn = ""
try { $roleArn = aws iam get-role --role-name $ROL --query "Role.Arn" --output text 2>$null } catch { }

if ($Simular) {
    Aviso "SIMULACION: se crearia o reutilizaria el rol $ROL"
} elseif ($roleArn -and $roleArn -ne "None") {
    Aviso "El rol ya existe: $roleArn"
} else {
    if (-not $roleArn -or $roleArn -eq "None") {
        # El JSON va por archivo (file://): PowerShell 5.1 elimina las comillas dobles
        # al pasar argumentos a ejecutables nativos y el JSON llega roto a la CLI.
        $trustLambda = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        $archivoTrust = Join-Path $env:TEMP "cobranzas_lambda_trust.json"
        Set-Content -Path $archivoTrust -Value $trustLambda -Encoding ASCII
        $roleArn = aws iam create-role --role-name $ROL `
            --assume-role-policy-document "file://$archivoTrust" `
            --query "Role.Arn" --output text
        Remove-Item $archivoTrust -Force -ErrorAction SilentlyContinue
        Ok "Rol creado: $roleArn"
    }
    aws iam attach-role-policy --role-name $ROL `
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" | Out-Null
    Ok "Politica de logs adjuntada (CloudWatch)"
}

# Politica minima: solo puede lanzar ESE job y consultar su estado
# Se arma con concatenacion, no con here-string: en PowerShell "arn:...:$Region:*"
# se parsea mal porque ':' despues de un nombre de variable no es valido.
$arnJob = "arn:aws:glue:" + $Region + ":*:job/" + $JOB_GLUE

$politica = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LanzarSoloElJobDelProyecto",
      "Effect": "Allow",
      "Action": ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"],
      "Resource": "$arnJob"
    }
  ]
}
"@
$polFile = Join-Path $env:TEMP "analitica_cobranzas_lambda_policy.json"
Set-Content -Path $polFile -Value $politica -Encoding ASCII

if ($Simular) {
    Aviso "SIMULACION: se aplicaria la politica que solo permite lanzar $JOB_GLUE"
    Aviso "Nota: el permiso se limita al ARN de ESE job, no a todos los jobs de Glue."
} else {
    aws iam put-role-policy --role-name $ROL `
        --policy-name "analitica-cobranzas-lanzar-glue" `
        --policy-document "file://$polFile" | Out-Null
    Ok "Politica adjuntada: solo puede lanzar $JOB_GLUE"
}

# -----------------------------------------------------------------------------
# 2. Empaquetar y publicar la funcion
# -----------------------------------------------------------------------------
Paso 2 "Empaquetando y publicando la funcion Lambda"

$zipPath = Join-Path $PSScriptRoot "lambda_disparador.zip"
$srcPath = Join-Path $PSScriptRoot "lambda_disparador.py"

if (-not (Test-Path $srcPath)) {
    Write-Host "No encuentro lambda_disparador.py" -ForegroundColor Red
    exit 1
}

if ($Simular) {
    Aviso "SIMULACION: se empaquetaria lambda_disparador.py en $zipPath"
    Aviso "SIMULACION: se publicaria como $FUNCION (python3.12, 128 MB, timeout 30 s)"
} else {
    # Comprimir solo el .py (sin dependencias externas: boto3 ya viene en el runtime)
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path $srcPath -DestinationPath $zipPath -Force
    Ok "Empaquetado: $(Split-Path $zipPath -Leaf) ($([math]::Round((Get-Item $zipPath).Length/1KB,1)) KB)"

    # El JSON va por archivo (file://): PowerShell 5.1 rompe las comillas dobles inline.
    $envDef = '{"Variables":{"GLUE_JOB_NAME":"' + $JOB_GLUE + '","BUCKET":"' + $Bucket + '","HOY":"' + $HOY + '"}}'
    $archivoEnv = Join-Path $env:TEMP "cobranzas_lambda_env.json"
    Set-Content -Path $archivoEnv -Value $envDef -Encoding ASCII

    $existe = $true
    try { aws lambda get-function --function-name $FUNCION --region $Region 2>$null | Out-Null } catch { $existe = $false }

    if ($existe) {
        aws lambda update-function-code --function-name $FUNCION `
            --zip-file "fileb://$zipPath" --region $Region | Out-Null
        Start-Sleep -Seconds 5
        aws lambda update-function-configuration --function-name $FUNCION `
            --environment "file://$archivoEnv" --region $Region | Out-Null
        Ok "Funcion actualizada"
    } else {
        Aviso "Esperando 10 s a que IAM propague el rol nuevo..."
        Start-Sleep -Seconds 10
        aws lambda create-function --function-name $FUNCION `
            --runtime python3.12 --role $roleArn `
            --handler "lambda_disparador.lambda_handler" `
            --zip-file "fileb://$zipPath" `
            --timeout 30 --memory-size 128 `
            --environment "file://$archivoEnv" `
            --region $Region | Out-Null
        Ok "Funcion creada (python3.12, 128 MB, timeout 30 s)"
    }
    Remove-Item $archivoEnv -Force -ErrorAction SilentlyContinue
    Aviso "128 MB y 30 s es de sobra: la funcion solo llama a la API de Glue."
}

# -----------------------------------------------------------------------------
# 3. Notificacion de S3 -> Lambda
# -----------------------------------------------------------------------------
Paso 3 "Configurando el evento de S3"

$cuentaId = ""
if (-not $Simular) {
    $cuentaId = (aws sts get-caller-identity --query "Account" --output text)
}
# El ARN se arma con concatenacion en lugar de plantilla: dentro de un here-string
# de PowerShell, "$Region`:$cuenta" y "${Region}" se parsean mal.
$arnLambda = "arn:aws:lambda:" + $Region + ":" + $cuentaId + ":function:" + $FUNCION

$notificacion = @"
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "raw-nuevo-archivo",
      "LambdaFunctionArn": "$arnLambda",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "raw/" },
            { "Name": "suffix", "Value": ".csv" }
          ]
        }
      }
    }
  ]
}
"@

if ($Simular) {
    Aviso "SIMULACION: se agregaria la notificacion 'raw-nuevo-archivo'"
    Aviso "  prefijo raw/  +  sufijo .csv  +  evento ObjectCreated"
    Aviso "Nota: un sufijo .csv evita que se dispare con los .parquet de curated"
} else {
    $notifFile = Join-Path $env:TEMP "analitica_cobranzas_s3_notificacion.json"
    Set-Content -Path $notifFile -Value $notificacion -Encoding ASCII

    try {
        aws s3api put-bucket-notification-configuration --bucket $Bucket `
            --notification-configuration "file://$notifFile" --region $Region
        Ok "Notificacion configurada: raw/*.csv -> $FUNCION"
    } catch {
        Aviso "No se pudo configurar la notificacion automaticamente."
        Aviso "Causa tipica: falta el permiso lambda:AddPermission para S3."
        Aviso "Agrega el permiso manualmente asi:"
        Write-Host ""
        Write-Host "  aws lambda add-permission --function-name $FUNCION ``"
        Write-Host "    --statement-id s3-invoke --action lambda:InvokeFunction ``"
        Write-Host "    --principal s3.amazonaws.com ``"
        Write-Host "    --source-arn arn:aws:s3:::$Bucket --region $Region"
        Write-Host ""
        Aviso "Luego vuelve a ejecutar este script."
    }
}

# -----------------------------------------------------------------------------
# 4. Verificacion
# -----------------------------------------------------------------------------
if (-not $Simular) {
    Paso 4 "Verificando la configuracion"

    Write-Host "    Funcion Lambda:"
    aws lambda get-function-configuration --function-name $FUNCION --region $Region `
        --query "{Nombre:FunctionName,Runtime:Runtime,MemoriaMB:MemorySize,TimeoutSeg:Timeout}" `
        --output table

    Write-Host "    Notificacion del bucket:"
    aws s3api get-bucket-notification-configuration --bucket $Bucket --region $Region

    Write-Host "    Prueba de invocacion (con un evento simulado):"
    $tmp = Join-Path $env:TEMP "evento_lambda.json"
    @"
{"Records":[{"s3":{"bucket":{"name":"$Bucket"},"object":{"key":"raw/cuotas/cuotas.csv"}}}]}
"@ | Set-Content -Path $tmp -Encoding ASCII
    $salida = Join-Path $env:TEMP "salida_lambda.json"
    aws lambda invoke --function-name $FUNCION --payload "fileb://$tmp" `
        --region $Region $salida | Out-Null
    Write-Host "    Respuesta:"
    Get-Content $salida -Raw
    Aviso "Si la respuesta dice ejecutado=true, el pipeline ya esta automatizado."
    Aviso "Recuerda: la prueba LANZA el job de Glue real (aproximadamente `$0.015)."
}

# -----------------------------------------------------------------------------
# RESUMEN
# -----------------------------------------------------------------------------
Write-Host "`n=============================================================" -ForegroundColor Cyan
if ($Simular) {
    Write-Host " SIMULACION COMPLETADA - no se creo nada" -ForegroundColor Yellow
} else {
    Write-Host " PIPELINE AUTOMATIZADO" -ForegroundColor Green
}
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " Flujo: archivo .csv en s3://$Bucket/raw/  ->  Lambda  ->  Glue  ->  curated/"
Write-Host ""
Write-Host " Proteccion anti-tormenta: si el job ya corre, la Lambda no lanza otro."
Write-Host "   (evita costos duplicados y escrituras simultaneas sobre curated)"
Write-Host ""
Write-Host " Para probar el flujo completo de verdad:"
Write-Host "   1. Sube un CSV:  aws s3 cp ..\raw\cuotas.csv s3://$Bucket/raw/cuotas/"
Write-Host "   2. Mira los logs: aws logs tail /aws/lambda/$FUNCION --follow --region $Region"
Write-Host "   3. Mira el job:   aws glue get-job-runs --job-name $JOB_GLUE --region $Region"
Write-Host ""
Write-Host " RECORDATORIO DE COSTO: Lambda es gratis en este volumen."
Write-Host "   El gasto lo hace el job de Glue (aproximadamente `$0.015 por corrida)."
Write-Host "=============================================================" -ForegroundColor Cyan

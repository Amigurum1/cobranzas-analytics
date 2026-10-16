# =============================================================================
# PROYECTO: Analitica de cobranzas
# EJECUTOR DE SQL EN REDSHIFT SERVERLESS (por API redshift-data)
#
# Por que existe: el workgroup es PRIVADO, asi que no se conecta desde fuera.
# La API redshift-data va por la red de AWS y no necesita acceso publico.
#
# USO:
#   .\08_ejecutar_redshift.ps1 -Sql "05_redshift_schema_estrella.sql"
#   .\08_ejecutar_redshift.ps1 -Sql "06_redshift_carga_ejecutar.sql"
#   .\08_ejecutar_redshift.ps1 -Sql "07_redshift_vistas_negocio.sql"
#   .\08_ejecutar_redshift.ps1 -Consulta "SELECT COUNT(*) FROM cobranzas.fct_cuotas;"
#
# AVISO DE COSTO: Redshift Serverless cobra $1.50/hora encendido (4 RPU).
# Al terminar: elimina el workgroup (el namespace conserva los datos).
# =============================================================================

param(
    [string]$Sql = "",
    [string]$Consulta = "",
    [string]$Database = "dev",
    [string]$Workgroup = "cobranzas-wg",
    [string]$Region = "us-east-1",
    [string]$Schema = "cobranzas",
    [switch]$UnaPorUna
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Paso($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok($t)       { Write-Host "    OK  $t" -ForegroundColor Green }
function Aviso($t)    { Write-Host "    !!  $t" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 0. Verificaciones
# -----------------------------------------------------------------------------
if (-not $Sql -and -not $Consulta) {
    Write-Host "Indica -Sql <archivo> o -Consulta <sentencia>" -ForegroundColor Red
    exit 1
}

Paso 0 "Verificando AWS CLI y el workgroup"

try {
    $ident = aws sts get-caller-identity --output json | ConvertFrom-Json
    Ok "Cuenta $($ident.Account)"
} catch {
    Write-Host "No hay credenciales de AWS activas." -ForegroundColor Red
    exit 1
}

$estadoWg = aws redshift-serverless get-workgroup --workgroup-name $Workgroup --region $Region --query "workgroup.status" --output text 2>$null
if ($estadoWg -ne "AVAILABLE") {
    Write-Host "El workgroup $Workgroup no esta AVAILABLE (estado: $estadoWg)" -ForegroundColor Red
    exit 1
}
Ok "Workgroup $Workgroup disponible"

# -----------------------------------------------------------------------------
# 1. Modo consulta (una sentencia, devuelve resultado)
# -----------------------------------------------------------------------------
if ($Consulta) {
    Paso 1 "Ejecutando consulta"

    $body = @{
        WorkgroupName = $Workgroup
        Database      = $Database
        Sql           = $Consulta
        ResultFormat  = "JSON"
    }
    $jsonFile = Join-Path $env:TEMP "redshift_consulta.json"
    $json = $body | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($jsonFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $id = aws redshift-data execute-statement --cli-input-json "file://$jsonFile" --region $Region --query "Id" --output text
    Ok "Id: $id"

    $estado = "SUBMITTED"
    while ($estado -in @("SUBMITTED", "PICKED", "STARTED")) {
        Start-Sleep -Seconds 2
        $estado = aws redshift-data describe-statement --id $id --region $Region --query "Status" --output text
    }

    if ($estado -eq "FINISHED") {
        Ok "Consulta terminada"
        aws redshift-data get-statement-result --id $id --region $Region --output json
    } else {
        Aviso "Estado: $estado"
        aws redshift-data describe-statement --id $id --region $Region --query "Error" --output text
    }
    Remove-Item $jsonFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# -----------------------------------------------------------------------------
# 2. Modo archivo (varias sentencias en lote)
# -----------------------------------------------------------------------------
Paso 1 "Leyendo $Sql"

if (-not (Test-Path $Sql)) {
    Write-Host "No encuentro el archivo: $Sql" -ForegroundColor Red
    exit 1
}

$texto = [System.IO.File]::ReadAllText((Resolve-Path $Sql).Path)

# Quitar los comentarios de linea (empiezan con --)
$limpio = ($texto -split "`r?`n" | Where-Object { -not $_.Trim().StartsWith("--") }) -join "`n"

# Separar por ";" y descartar trozos vacios
$sentencias = @()
foreach ($trozo in ($limpio -split ";")) {
    $t = $trozo.Trim()
    if ($t -ne "") { $sentencias += $t }
}

if ($sentencias.Count -eq 0) {
    Write-Host "El archivo no contiene sentencias ejecutables." -ForegroundColor Red
    exit 1
}
Ok "$($sentencias.Count) sentencias"

# -----------------------------------------------------------------------------
# 3. Modo "una por una": aisla los errores.
#    Util cuando un lote falla y no se sabe CUAL sentencia es la culpable
#    (el lote se detiene en el primer error y oculta los demas).
# -----------------------------------------------------------------------------
if ($UnaPorUna) {
    Paso 2 "Ejecutando una por una (para aislar errores)"
    $fallos = 0
    $jf = Join-Path $env:TEMP "rs_una.json"

    # El SET search_path no se hereda entre llamadas (cada una abre sesion nueva),
    # asi que se quita de la lista y se manda como primera sentencia de cada mini-lote.
    $aProbar = @($sentencias | Where-Object { $_.Trim().ToUpper() -notlike "SET SEARCH_PATH*" })
    Ok "$($aProbar.Count) sentencias a probar (el SET search_path se manda en cada lote)"

    for ($i = 0; $i -lt $aProbar.Count; $i++) {
        $s = $aProbar[$i]
        $corta = ($s -replace "\s+", " ").Trim()
        if ($corta.Length -gt 58) { $corta = $corta.Substring(0, 58) }

        $sqls = @("SET search_path TO $Schema", $s)
        $body = @{ WorkgroupName = $Workgroup; Database = $Database; Sqls = $sqls; ResultFormat = "JSON" }
        [System.IO.File]::WriteAllText($jf, ($body | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

        $id1 = aws redshift-data batch-execute-statement --cli-input-json "file://$jf" --region $Region --query "Id" --output text
        $est = "SUBMITTED"
        while ($est -in @("SUBMITTED", "PICKED", "STARTED")) {
            Start-Sleep -Seconds 2
            $est = aws redshift-data describe-statement --id $id1 --region $Region --query "Status" --output text
        }

        if ($est -eq "FINISHED") {
            Write-Host ("    [{0,2}] OK    {1}" -f ($i + 1), $corta) -ForegroundColor Green
        } else {
            $fallos++
            Write-Host ("    [{0,2}] FALLO {1}" -f ($i + 1), $corta) -ForegroundColor Red
            $err = aws redshift-data describe-statement --id $id1 --region $Region --query "Error" --output text
            Write-Host ("         -> $err") -ForegroundColor Red
        }
    }

    Remove-Item $jf -Force -ErrorAction SilentlyContinue
    Write-Output ""
    if ($fallos -eq 0) { Ok "Las $($aProbar.Count) sentencias pasaron" }
    else { Aviso "$fallos de $($aProbar.Count) sentencias fallaron" }
    Write-Output ""
    Write-Host "RECORDATORIO: al terminar, elimina el workgroup para dejar de facturar." -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# 4. Lanzar el lote
# -----------------------------------------------------------------------------
Paso 2 "Ejecutando en $Database (workgroup $Workgroup)"

# DOS REGLAS DE LA API (verificadas contra el servicio):
#   1. batch-execute-statement acepta MAXIMO 40 sentencias por lote
#      ("Member must have length less than or equal to 40").
#   2. Cada lote abre una SESION NUEVA, asi que el SET search_path del archivo
#      NO se hereda: hay que repetirlo al inicio de cada lote.
# Por eso se trocea en lotes de 39 y cada uno lleva su SET delante (39+1 = 40).
$tamanoLote = 39
$lotes = @()
for ($i = 0; $i -lt $sentencias.Count; $i += $tamanoLote) {
    $fin = [Math]::Min($i + $tamanoLote - 1, $sentencias.Count - 1)
    $lotes += ,@($sentencias[$i..$fin])
}
Ok "$($lotes.Count) lote(s) de maximo $tamanoLote sentencias"

$jsonFile = Join-Path $env:TEMP "redshift_lote.json"
$fallidos = 0

for ($k = 0; $k -lt $lotes.Count; $k++) {
    $lote = @("SET search_path TO $Schema") + $lotes[$k]
    Write-Host "`n  Lote $($k + 1)/$($lotes.Count) ($($lote.Count) sentencias)"

    $body = @{
        WorkgroupName = $Workgroup
        Database      = $Database
        Sqls          = $lote
        ResultFormat  = "JSON"
    }
    $json = $body | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($jsonFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $id = aws redshift-data batch-execute-statement --cli-input-json "file://$jsonFile" --region $Region --query "Id" --output text
    if (-not $id -or $id -eq "None") {
        Write-Host "    No se pudo lanzar el lote $($k + 1)." -ForegroundColor Red
        $fallidos++
        continue
    }
    Write-Host "    Id: $id"

    $estado = "SUBMITTED"
    $inicio = Get-Date
    while ($estado -in @("SUBMITTED", "PICKED", "STARTED")) {
        Start-Sleep -Seconds 3
        $estado = aws redshift-data describe-statement --id $id --region $Region --query "Status" --output text
        $seg = [int]((Get-Date) - $inicio).TotalSeconds
        Write-Host ("    [{0,4}s] {1}" -f $seg, $estado)
        if ($seg -gt 900) { Aviso "Mas de 15 minutos, corto la espera"; break }
    }

    if ($estado -eq "FINISHED") {
        Ok "Lote $($k + 1) OK"
    } else {
        $fallidos++
        Aviso "Lote $($k + 1) termino en $estado"
        Write-Host ""
        aws redshift-data describe-statement --id $id --region $Region --query "Error" --output text
        Write-Host ""
        Aviso "Se detiene aqui: los lotes siguientes podrian depender de este."
        break
    }
}

Paso 3 "Resultado"

if ($fallidos -eq 0) {
    Ok "Las $($sentencias.Count) sentencias se ejecutaron sin error"
} else {
    Aviso "$fallidos lote(s) fallaron. Revisa el error de arriba antes de continuar."
}

Remove-Item $jsonFile -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Host "RECORDATORIO: al terminar, elimina el workgroup para dejar de facturar." -ForegroundColor Yellow
Write-Host "  aws redshift-serverless delete-workgroup --workgroup-name $Workgroup --region $Region"

# ==========================================================
# HERMES AGENT + LM STUDIO  Windows PowerShell 5.1+
# Turvallinen kaynnistys / uudelleenluonti
#
# Dashboard: http://127.0.0.1:9119
# LM Studio: http://127.0.0.1:1234
# Pysyva data: Docker volume hermes-data
#
# HUOM:
# - Ei poista hermes-data-volumea.
# - Ei liita Docker-socketia Hermes-konttiin.
# - Kayttaa dokumentoituja LM Studio- ja dashboard-ymparistomuuttujia.
# ==========================================================

$ErrorActionPreference = "Continue"

$IMAGE_NAME = "nousresearch/hermes-agent:latest"
$CONTAINER  = "hermes"
$VOLUME     = "hermes-data"
$MODEL_NAME = "google/gemma-4-12b"

$LM_URL         = "http://127.0.0.1:1234"
$LM_DOCKER_URL  = "http://host.docker.internal:1234/v1"
$DASHBOARD_URL  = "http://127.0.0.1:9119"

$DOCKER_PATHS = @(
    "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
    "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"
)

function Stop-WithError {
    param([string]$Message)
    Write-Host "`nVIRHE: $Message" -ForegroundColor Red
    Read-Host "Paina Enter lopettaaksesi"
    exit 1
}

function Test-Docker {
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-LMStudio {
    try {
        $r = Invoke-RestMethod -Uri "$LM_URL/v1/models" -TimeoutSec 5
        return ($null -ne $r.data)
    } catch {
        return $false
    }
}

# ----------------------------------------------------------
# 1. Docker Desktop ja Linux Engine
# ----------------------------------------------------------
Write-Host "`n[1/5] TARKISTETAAN DOCKER" -ForegroundColor Cyan

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-WithError "Docker CLI ei loydy PATH-ymparistomuuttujasta."
}

if (-not (Test-Docker)) {
    Write-Host "Docker Engine ei vastaa. Kaynnistetaan Docker Desktop..." -ForegroundColor Yellow

    $dockerExe = $DOCKER_PATHS |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if (-not $dockerExe) {
        Stop-WithError "Docker Desktop.exe:ta ei loydy. Kaynnista Docker Desktop kasin."
    }

    Start-Process -FilePath $dockerExe

    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Docker) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        Stop-WithError "Docker Linux Engine ei kaynnistynyt 180 sekunnissa. Tarkista Docker Desktopin tila."
    }
}
Write-Host "Docker Engine toimii." -ForegroundColor Green
docker context show

# ----------------------------------------------------------
# 2. LM Studio API
# ----------------------------------------------------------
Write-Host "`n[2/5] TARKISTETAAN LM STUDIO" -ForegroundColor Cyan

if (-not (Test-LMStudio)) {
    if (Get-Command lms -ErrorAction SilentlyContinue) {
        Write-Host "LM Studio API ei vastaa. Yritetaan kaynnistaa palvelin..." -ForegroundColor Yellow
        & lms server start --bind 0.0.0.0
        Start-Sleep -Seconds 3
    }
}

if (-not (Test-LMStudio)) {
    Stop-WithError "LM Studio API ei vastaa osoitteessa $LM_URL. Avaa LM Studio, kaynnista Local Server porttiin 1234 ja salli LAN-yhteydet."
}

$models = Invoke-RestMethod -Uri "$LM_URL/v1/models" -TimeoutSec 10
Write-Host "LM Studio API vastaa. API:n ilmoittamat mallit:" -ForegroundColor Green
$models.data | ForEach-Object { Write-Host " - $($_.id)" }

$matchingModel = $models.data | Where-Object { $_.id -eq $MODEL_NAME } | Select-Object -First 1
if (-not $matchingModel) {
    Write-Host "Huomio: API ei ilmoittanut tasmalleen mallia '$MODEL_NAME'." -ForegroundColor Yellow
    Write-Host "Valitse Hermesissa LM Studio -providerin malliksi API:n listassa nakyva mallin tunniste."
}

# ----------------------------------------------------------
# 3. Sailytetaan tietovolume
# ----------------------------------------------------------
Write-Host "`n[3/5] TARKISTETAAN PYSYVA DATA" -ForegroundColor Cyan

& docker volume inspect $VOLUME *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Luodaan Docker-volume $VOLUME..." -ForegroundColor Yellow
    & docker volume create $VOLUME | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Docker-volumen luonti epaonnistui."
    }
}
Write-Host "Volume $VOLUME on kaytettavissa." -ForegroundColor Green

# ----------------------------------------------------------
# 4. Hermes-kontti (gateway + dashboard)
# ----------------------------------------------------------
Write-Host "`n[4/5] KAYNNISTETAAN HERMES" -ForegroundColor Cyan

$existing = & docker ps -a --filter "name=^/$CONTAINER$" --format "{{.Names}}"
$running  = & docker ps --filter "name=^/$CONTAINER$" --format "{{.Names}}"

if (-not $existing) {
    $envFile = Join-Path $PSScriptRoot "hermes_dashboard.env"
    if (-not (Test-Path $envFile)) {
        Stop-WithError "Tiedostoa $envFile ei loydy. Luo se ohjeen mukaan (dashboardin salasana)."
    }
    Write-Host "Luodaan kontti $CONTAINER..." -ForegroundColor Yellow
    & docker run -d --name $CONTAINER --restart unless-stopped `
        -v "${VOLUME}:/opt/data" `
        -p 127.0.0.1:9119:9119 `
        --env-file $envFile `
        -e HERMES_DASHBOARD=1 `
        $IMAGE_NAME gateway run | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Kontin luonti epaonnistui. Tarkista, ettei portti 9119 ole varattu."
    }
}
elseif (-not $running) {
    Write-Host "Kaynnistetaan pysahtynyt kontti..." -ForegroundColor Yellow
    & docker start $CONTAINER | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Kontin kaynnistys epaonnistui."
    }
}
else {
    Write-Host "Kontti on jo kaynnissa." -ForegroundColor Green
}

# Odotetaan, etta dashboard vastaa (max 60 s) ja kontti pysyy pystyssa
$dashboardUp = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2

    $stillRunning = & docker ps --filter "name=^/$CONTAINER$" --format "{{.Names}}"
    if (-not $stillRunning) {
        Write-Host "`nKontti sammui. Lokin viimeiset rivit:" -ForegroundColor Red
        & docker logs --tail 40 $CONTAINER
        Stop-WithError "Hermes-kontti ei pysy kaynnissa."
    }

    try {
        Invoke-WebRequest -Uri $DASHBOARD_URL -UseBasicParsing -TimeoutSec 3 | Out-Null
        $dashboardUp = $true
        break
    } catch {
        # Mika tahansa HTTP-vastaus (esim. 401) tarkoittaa etta palvelin elaa
        if ($_.Exception.Response) {
            $dashboardUp = $true
            break
        }
    }
}

if (-not $dashboardUp) {
    Write-Host "`nDashboard ei vastannut 60 sekunnissa. Lokin viimeiset rivit:" -ForegroundColor Yellow
    & docker logs --tail 40 $CONTAINER
}
else {
    Write-Host "Dashboard vastaa." -ForegroundColor Green
}

# ----------------------------------------------------------
# 5. Selain
# ----------------------------------------------------------
Write-Host "`n[5/5] AVATAAN DASHBOARD" -ForegroundColor Cyan
Start-Process $DASHBOARD_URL

Write-Host "`nValmis. Hermes: $DASHBOARD_URL" -ForegroundColor Green
Write-Host "LM Studio (kontista kasin): $LM_DOCKER_URL"
Read-Host "Paina Enter sulkeaksesi"
# servers.conf의 group 컬럼별로 resources.json/incident-response.json 사본을 만들어
# config/grafana/provisioning/dashboards/<group>/ 에 생성한다 (전체 대시보드 2개는 그대로 유지).
# JSON을 파싱하지 않고 문자열 리터럴 치환(.Replace)만 쓴다 — PowerShell 문자열은 sed와 달리
# 정규식이 아니라서 백슬래시·따옴표를 그대로 매칭/치환할 수 있어 별도 이스케이프가 필요 없다.

$ScriptsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root        = Split-Path -Parent $ScriptsDir
$DashDir     = Join-Path $Root "config\grafana\provisioning\dashboards"
$ServersConf = Join-Path $Root "servers.conf"

if (-not (Test-Path $ServersConf)) {
    Write-Host "[generate-dashboards] servers.conf 없음 → 그룹별 대시보드 생성 건너뜀 (전체 대시보드만 사용)"
    exit 0
}

# 1) servers.conf에서 distinct group 목록 추출 (등장 순서 유지)
$ServerGroups = [System.Collections.ArrayList]@()
Get-Content $ServersConf | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '\s+'
        $group = if ($parts.Length -ge 4) { $parts[3] } else { 'default' }
        if (-not $ServerGroups.Contains($group)) {
            [void]$ServerGroups.Add($group)
        }
    }
}

if ($ServerGroups.Count -eq 0) {
    Write-Host "[generate-dashboards] servers.conf에 그룹이 없어 그룹별 대시보드를 생성하지 않습니다."
    exit 0
}

# 2) 이전에 생성된 그룹 폴더 정리 (전체 대시보드 2개 파일은 DashDir 바로 아래에 있어 영향 없음)
Get-ChildItem $DashDir -Directory | Remove-Item -Recurse -Force

function Get-Slug {
    param($Group)
    $slug = ($Group.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
    if (-not $slug) { $slug = 'group' }
    return $slug
}

function New-GroupDashboard {
    param($BaseFile, $OutFile, $Group, $OrigUid, $OrigTitle, $QueryFrom, $QueryTo)

    $slug    = Get-Slug $Group
    $content = [System.IO.File]::ReadAllText($BaseFile)

    $content = $content.Replace('"uid": "' + $OrigUid + '"', '"uid": "' + $OrigUid + '-' + $slug + '"')
    $content = $content.Replace('"title": "' + $OrigTitle + '"', '"title": "' + $OrigTitle + ' - ' + $Group + '"')
    $content = $content.Replace($QueryFrom, $QueryTo)
    $content = $content.Replace('server=~\"$server\"', 'group=\"' + $Group + '\",server=~\"$server\"')
    $content = $content.Replace('by (group, server)', 'by (server)')
    $content = $content.Replace('{{group}}/{{server}}', '{{server}}')

    # UTF8 BOM 없이 저장 (Grafana의 JSON 파서가 BOM을 인식하지 못해 프로비저닝이 깨질 수 있음)
    [System.IO.File]::WriteAllText($OutFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($group in $ServerGroups) {
    if ($group -notmatch '^[A-Za-z0-9_-]+$') {
        Write-Host ('[generate-dashboards] 경고: group "' + $group + '"에 영문/숫자/하이픈 이외의 문자가 있습니다. ' +
                     'JSON 특수문자(\, " 등)가 섞이면 대시보드가 깨질 수 있으니 영문 kebab-case로 바꾸는 걸 권장합니다.')
    }

    $groupDir = Join-Path $DashDir $group
    New-Item -ItemType Directory -Path $groupDir -Force | Out-Null

    New-GroupDashboard `
        -BaseFile (Join-Path $DashDir "resources.json") `
        -OutFile (Join-Path $groupDir "resources.json") `
        -Group $group -OrigUid "server-resources" -OrigTitle "서버 리소스" `
        -QueryFrom 'label_values(server_cpu_usage_percent, server)' `
        -QueryTo ('label_values(server_cpu_usage_percent{group=\"' + $group + '\"}, server)')

    New-GroupDashboard `
        -BaseFile (Join-Path $DashDir "incident-response.json") `
        -OutFile (Join-Path $groupDir "incident-response.json") `
        -Group $group -OrigUid "spring-boot-incident" -OrigTitle "로그 모니터링" `
        -QueryFrom 'label_values({job=\"logs\"}, server)' `
        -QueryTo ('label_values({job=\"logs\", group=\"' + $group + '\"}, server)')

    Write-Host "[generate-dashboards] $group 폴더 생성 완료 (resources.json, incident-response.json)"
}

Write-Host "[generate-dashboards] 총 $($ServerGroups.Count)개 그룹 대시보드 생성 완료 (전체 대시보드는 그대로 유지)"

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $projectRoot 'HistorySync.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-project-sync-$([guid]::NewGuid().ToString('N'))"

function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
function Invoke-HistoryTool {
    param([string]$Action,[string]$CodexHomePath,[string]$Config,[string]$Machine,[string]$VaultBase,[string]$ProjectId,[string]$ProjectName,[string]$LocalPath,[string]$CodexProjectId)
    $args=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$syncScript,'-Action',$Action,'-Json','-CodexHomeOverride',$CodexHomePath,'-ConfigPathOverride',$Config,'-MachineIdOverride',$Machine,'-SkipProcessCheck')
    if($VaultBase){$args+=@('-VaultPath',$VaultBase)}; if($ProjectId){$args+=@('-ProjectId',$ProjectId)}; if($ProjectName){$args+=@('-ProjectName',$ProjectName)}; if($LocalPath){$args+=@('-LocalPath',$LocalPath)}; if($CodexProjectId){$args+=@('-CodexProjectId',$CodexProjectId)}
    $out=& powershell.exe $args; if($LASTEXITCODE -ne 0){throw "HistorySync $Action failed: $out"}; $out|ConvertFrom-Json
}
function Write-CodexState {
    param([string]$CodexHomePath,[hashtable]$Projects,[hashtable]$Assignments)
    $state=[ordered]@{ 'electron-persisted-atom-state'=[ordered]@{}; 'local-projects'=[ordered]@{}; 'thread-project-assignments'=[ordered]@{}; 'projectless-thread-ids'=@() }
    foreach($key in $Projects.Keys){$state['local-projects'][$key]=$Projects[$key]}; foreach($key in $Assignments.Keys){$state['thread-project-assignments'][$key]=$Assignments[$key]}
    New-Item -ItemType Directory -Path $CodexHomePath -Force|Out-Null
    $path=Join-Path $CodexHomePath '.codex-global-state.json'; [IO.File]::WriteAllText($path,(($state|ConvertTo-Json -Depth 32)+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function New-TestSession {
    param([string]$CodexHomePath,[string]$Id,[string]$Cwd,[string]$Title)
    $date=[DateTimeOffset]::UtcNow; $dir=Join-Path $CodexHomePath ('sessions\'+$date.ToString('yyyy\MM\dd')); New-Item -ItemType Directory -Path $dir -Force|Out-Null
    $path=Join-Path $dir ('rollout-'+$date.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$Id+'.jsonl')
    $meta=[ordered]@{timestamp=$date.ToString('o');type='session_meta';payload=[ordered]@{id=$Id;timestamp=$date.ToString('o');cwd=$Cwd;originator='test';cli_version='test';source='vscode';model_provider='openai'}}
    $event=[ordered]@{timestamp=$date.ToString('o');type='event_msg';payload=[ordered]@{type='user_message';message=$Title}}
    [IO.File]::WriteAllText($path,(($meta|ConvertTo-Json -Compress)+"`n"+(($event|ConvertTo-Json -Compress))+"`n"),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::AppendAllText((Join-Path $CodexHomePath 'session_index.jsonl'),((([ordered]@{id=$Id;thread_name=$Title;updated_at=$date.ToString('o')}|ConvertTo-Json -Compress))+"`n"),(New-Object Text.UTF8Encoding($false)))
    $path
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $vault=Join-Path $testRoot 'vault'; $homeA=Join-Path $testRoot 'a\.codex'; $homeB=Join-Path $testRoot 'b\.codex'; $configA=Join-Path $testRoot 'a.json'; $configB=Join-Path $testRoot 'b.json'
    $rootA1=Join-Path $testRoot 'a\workspace\src'; $rootA2=Join-Path $testRoot 'a\workspace\docs'; $rootB1=Join-Path $testRoot 'b\workspace\src'; $rootB2=Join-Path $testRoot 'b\workspace\docs'
    $codexA='10000000-0000-4000-8000-000000000001'; $codexA2='10000000-0000-4000-8000-000000000002'; $codexB='20000000-0000-4000-8000-000000000001'
    $threadA='30000000-0000-4000-8000-000000000001'; $threadA2='30000000-0000-4000-8000-000000000002'
    New-Item -ItemType Directory -Path $vault,$rootA1,$rootA2,$rootB1,$rootB2 -Force|Out-Null
    Invoke-HistoryTool -Action Configure -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -VaultBase $vault|Out-Null
    Invoke-HistoryTool -Action Enable -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'|Out-Null
    Write-CodexState -CodexHomePath $homeA -Projects @{
        $codexA=[ordered]@{id=$codexA;name='Workspace';rootPaths=@($rootA1,$rootA2);createdAt=1;updatedAt=1}
        $codexA2=[ordered]@{id=$codexA2;name='Shared Root';rootPaths=@($rootA1);createdAt=1;updatedAt=1}
    } -Assignments @{
        $threadA=[ordered]@{projectKind='local';projectId=$codexA}; $threadA2=[ordered]@{projectKind='local';projectId=$codexA2}
    }
    New-TestSession -CodexHomePath $homeA -Id $threadA -Cwd $rootA2 -Title 'multi-root session'|Out-Null
    New-TestSession -CodexHomePath $homeA -Id $threadA2 -Cwd $rootA1 -Title 'shared-root project'|Out-Null
    $created=Invoke-HistoryTool -Action CreateProject -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -CodexProjectId $codexA -ProjectName 'logical workspace'
    $logicalA=[string]($created.Projects|Select-Object -First 1 -ExpandProperty ProjectId)
    $created2=Invoke-HistoryTool -Action CreateProject -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -CodexProjectId $codexA2 -ProjectName 'shared root project'
    $logicalA2=[string]($created2.Projects|Where-Object Name -eq 'shared root project'|Select-Object -First 1 -ExpandProperty ProjectId)
    Assert-True ($created2.LocalDirectories.Count -ge 2) 'Codex project catalog should expose both projects even when roots overlap.'
    $statusA=Invoke-HistoryTool -Action Status -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($statusA.SelectedProjectCount -eq 2 -and $statusA.Ready) 'Status should count modern Codex project bindings.'
    $syncA=Invoke-HistoryTool -Action Sync -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($syncA.Exported -eq 2) 'Both Codex projects should export independently.'
    $vaultRoot=Join-Path $vault '.codex-history-vault'; $refs=@(Get-ChildItem -LiteralPath (Join-Path $vaultRoot 'refs') -Recurse -Filter '*.json'|ForEach-Object{Get-Content -Raw $_.FullName|ConvertFrom-Json})
    Assert-True (@($refs|Where-Object{[string]$_.ProjectId -eq $logicalA -and [string]$_.CodexProjectId -eq $codexA}).Count -eq 1) 'Thread assignment must determine the logical project, not cwd.'
    $obj=Get-ChildItem -LiteralPath (Join-Path $vaultRoot 'objects') -Recurse -Filter '*.jsonl'|Where-Object{(Get-Content -LiteralPath $_.FullName -TotalCount 1 -Encoding UTF8) -match 'codex-project://'}|Select-Object -First 1
    Assert-True ((Get-Content -LiteralPath $obj.FullName -TotalCount 1 -Encoding UTF8) -match ('codex-project://'+$logicalA+'/r1')) 'The canonical cwd should preserve the Codex root index.'
    Invoke-HistoryTool -Action Configure -CodexHomePath $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -VaultBase $vault|Out-Null
    Write-CodexState -CodexHomePath $homeB -Projects @{
        $codexB=[ordered]@{id=$codexB;name='Workspace';rootPaths=@($rootB1,$rootB2);createdAt=2;updatedAt=2}
    } -Assignments @{}
    $bound=Invoke-HistoryTool -Action BindProject -CodexHomePath $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -ProjectId $logicalA -CodexProjectId $codexB
    Invoke-HistoryTool -Action Enable -CodexHomePath $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'|Out-Null
    $syncB=Invoke-HistoryTool -Action Sync -CodexHomePath $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($syncB.Imported -eq 1) 'A project bound by Codex project id should import its sessions.'
    $imported=Get-ChildItem -LiteralPath (Join-Path $homeB 'sessions') -Recurse -Filter '*.jsonl'|Select-Object -First 1
    $importedMeta=Get-Content -LiteralPath $imported.FullName -TotalCount 1 -Encoding UTF8|ConvertFrom-Json
    Assert-True ([string]$importedMeta.payload.cwd -eq $rootB2) 'Imported cwd should use the corresponding root on this computer.'
    $stateB=Get-Content -Raw (Join-Path $homeB '.codex-global-state.json')|ConvertFrom-Json
    Assert-True ($null -ne $stateB.'thread-project-assignments'.$threadA -and [string]$stateB.'thread-project-assignments'.$threadA.projectId -eq $codexB) 'Imported thread should be assigned to the local Codex project.'
    $codexA3='10000000-0000-4000-8000-000000000003'
    Write-CodexState -CodexHomePath $homeA -Projects @{
        $codexA=[ordered]@{id=$codexA;name='Workspace';rootPaths=@($rootA1,$rootA2);createdAt=1;updatedAt=1}
        $codexA2=[ordered]@{id=$codexA2;name='Shared Root';rootPaths=@($rootA1);createdAt=1;updatedAt=1}
        $codexA3=[ordered]@{id=$codexA3;name='Workspace Variant';rootPaths=@($rootA2);createdAt=1;updatedAt=1}
    } -Assignments @{
        $threadA=[ordered]@{projectKind='local';projectId=$codexA}; $threadA2=[ordered]@{projectKind='local';projectId=$codexA2}
    }
    Invoke-HistoryTool -Action BindProject -CodexHomePath $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -ProjectId $logicalA -CodexProjectId $codexA3|Out-Null
    $configAfterMulti=Get-Content -Raw -Encoding UTF8 $configA|ConvertFrom-Json
    Assert-True (@($configAfterMulti.CodexProjectBindings|Where-Object ProjectId -eq $logicalA).Count -eq 2) 'One logical project should allow multiple local Codex project members.'
    Write-Host 'Codex project history sync tests passed.' -ForegroundColor Green
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }

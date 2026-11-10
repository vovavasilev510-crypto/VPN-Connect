param([string]$Root=(Get-Location).Path,[switch]$StageChanges)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SubscriptionTools.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AutoUpdateTools.psm1') -Force
$Root=(Resolve-Path -LiteralPath $Root).Path
$profiles=New-Object 'System.Collections.Generic.List[object]'
$profilesDir=Join-Path $Root '.vpn-connect/profiles'
if(Test-Path -LiteralPath $profilesDir) {
    foreach($dir in (Get-ChildItem -LiteralPath $profilesDir -Directory | Sort-Object Name)) {
        $configPath=Join-Path $dir.FullName 'config.json'
        if(-not (Test-Path -LiteralPath $configPath)){continue}
        $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $layout=Get-AutomationLayout $config.OutputFile
        if((Split-Path $layout.Profile -Leaf) -ne $dir.Name){throw 'Папка профиля не соответствует выходному файлу.'}
        $profiles.Add(@{Config=$config; Template=(Join-Path $dir.FullName 'template.txt'); Output=$config.OutputFile})
    }
}
# Keep a previous 1.9 installation running when adding another subscription.
if((Test-Path -LiteralPath (Join-Path $Root 'sources.json')) -and -not @($profiles | Where-Object {$_.Output -ieq 'sub2'}).Count) {
    $profiles.Add(@{Config=(Get-Content -LiteralPath (Join-Path $Root 'sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json); Template=(Join-Path $Root 'template.txt'); Output='sub2'})
}
if(-not $profiles.Count){throw 'Не найдены настройки подписок. Установите автоматику из редактора.'}
$outputs=@{}; $cache=@{}
foreach($profile in $profiles) {
    $name=[string]$profile.Output
    foreach($existing in $outputs.Keys){
        if($name -ieq $existing -or $name.StartsWith($existing + '/', [StringComparison]::OrdinalIgnoreCase) -or $existing.StartsWith($name + '/', [StringComparison]::OrdinalIgnoreCase)){throw 'Конфликт выходных файлов подписок.'}
    }
    $config=$profile.Config
    $template=Get-SubscriptionDocument (Get-Content -LiteralPath $profile.Template -Raw -Encoding UTF8)
    $sources=@($config.Sources)
    $documents=@(foreach($source in $sources){
        if(-not $cache.ContainsKey($source.Url)){$cache[$source.Url]=Get-SubscriptionSource $source.Url -PublicOnly}
        $cache[$source.Url]
    })
    $merged=Merge-PublicSubscriptions $template $sources $documents @($config.Excluded)
    $outputs[$name]=$merged['sub']
}
# Validate all profiles before writing any subscription.
foreach($name in $outputs.Keys){
    $target=Join-Path $Root $name
    $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    [IO.File]::WriteAllText($target,$outputs[$name],(New-Object Text.UTF8Encoding($false)))
}
if($StageChanges){
    & git -C $Root add -- @($outputs.Keys)
    if($LASTEXITCODE -ne 0){throw 'Не удалось подготовить файлы подписок к коммиту.'}
}
Write-Output ('Обновлены подписки: ' + (($outputs.Keys | Sort-Object) -join ', '))

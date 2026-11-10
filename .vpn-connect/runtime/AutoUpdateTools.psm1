Set-StrictMode -Version 2
$ErrorActionPreference='Stop'

function Get-PublicSources {
    @(
        [pscustomobject]@{Name=''; File='sub-black'; Url='https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/BLACK_VLESS_RUS_mobile.txt'},
        [pscustomobject]@{Name=''; File='sub-white'; Url='https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt'}
    )
}

function Get-ConnectionIdentity([string]$Link) {
    if($Link.StartsWith('vmess://')) {
        $obj=ConvertFrom-SubscriptionBase64 (($Link.Substring(8) -split '#',2)[0]) | ConvertFrom-Json
        $obj.PSObject.Properties.Remove('ps'); $obj.PSObject.Properties.Remove('serverDescription')
        return 'vmess://' + (ConvertTo-Json $obj -Depth 100 -Compress)
    }
    return ($Link -split '#',2)[0]
}

function Merge-PublicSubscriptions($Template, [object[]]$Sources, [object[]]$Documents, [string[]]$Excluded=@()) {
    if($Sources.Count -ne $Documents.Count -or -not $Sources.Count){throw 'Неполный набор источников.'}
    $edits=@{}; foreach($server in $Template.Servers){$edits[(Get-ConnectionIdentity $server.Original)]=$server}
    $metadata=@{}
    foreach($key in @('profile-title','announce','support-url','profile-web-page-url','profile-update-interval','providerid')) {
        $metadata[$key]=Get-SubscriptionMetadataValue $Template $key
    }
    $outputs=@{}; $all=New-Object 'System.Collections.Generic.List[string]'
    $seen=@{}
    for($i=0;$i -lt $Sources.Count;$i++) {
        $lines=New-Object 'System.Collections.Generic.List[string]'
        foreach($server in $Documents[$i].Servers) {
            $identity=Get-ConnectionIdentity $server.Original
            if($identity -in $Excluded){continue}
            $name=$server.Name
            if($Sources[$i].Name){$name=$Sources[$i].Name + ' | ' + $name}
            $description=''
            if($edits.ContainsKey($identity)){$name=$edits[$identity].Name; $description=$edits[$identity].Description}
            $link=Set-ServerDescription (Set-ServerDisplayName $server.Original $name) $description
            $lines.Add($link)
            if(-not $seen.ContainsKey($identity)){$all.Add($link); $seen[$identity]=$true}
        }
        if(-not $lines.Count){throw 'Источник не содержит серверов после фильтрации. Старые файлы сохранены.'}
        $doc=Get-SubscriptionDocument ($lines -join "`n")
        $outputs[$Sources[$i].File]=Edit-Subscription $doc $metadata @($doc.Servers | ForEach-Object {$_.Name})
    }
    $doc=Get-SubscriptionDocument ($all -join "`n")
    $outputs['sub']=Edit-Subscription $doc $metadata @($doc.Servers | ForEach-Object {$_.Name})
    return $outputs
}

function Get-AutomationLayout([string]$FilePath) {
    if($FilePath -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*(?:\.[A-Za-z0-9_-]+)?$') {throw 'Файл: например sub, sub2 или subscriptions/family.txt. Используйте латиницу, цифры, дефис и подчёркивание.'}
    if(($FilePath -split '/')[0] -in @('SubscriptionTools.psm1','AutoUpdateTools.psm1','Update-PublicSubscriptions.ps1','sources.json','template.txt','AUTOUPDATE.html','Start.cmd')){throw 'Этот путь зарезервирован для файлов программы.'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$id=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($FilePath.ToLowerInvariant())))).Replace('-','').ToLowerInvariant()}
    finally {$hash.Dispose()}
    return [pscustomobject]@{Profile=('.vpn-connect/profiles/' + $id); Runtime='.vpn-connect/runtime'; FilePath=$FilePath}
}

function Get-CombinedPublicSource {
    $sources=@(Get-PublicSources)
    $docs=@(foreach($source in $sources){Get-SubscriptionSource $source.Url -PublicOnly})
    $merged=Merge-PublicSubscriptions $docs[0] $sources $docs
    return Get-SubscriptionDocument $merged['sub']
}

function Get-AutomationFiles([string]$Template,[string[]]$Excluded,[string]$FilePath) {
    $layout=Get-AutomationLayout $FilePath
    $files=@{}
    $files[$layout.Profile + '/template.txt']=$Template
    $files[$layout.Profile + '/config.json']=(@{OutputFile=$FilePath; Sources=@(Get-PublicSources); Excluded=@($Excluded)} | ConvertTo-Json -Depth 10)
    foreach($file in @('SubscriptionTools.psm1','AutoUpdateTools.psm1','Update-PublicSubscriptions.ps1')){
        $files[$layout.Runtime + '/' + $file]=[string][char]0xFEFF + [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file))
    }
    $files['.github/workflows/update-subscriptions.yml']=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'update-subscriptions.yml'))
    $files['AUTOUPDATE.html']=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AUTOUPDATE.html'))
    return $files
}

function Export-AutoUpdatePackage([string]$Destination,[string]$Template,[string[]]$Excluded=@(),[string]$FilePath='sub') {
    $null=Get-SubscriptionDocument $Template
    $files=Get-AutomationFiles $Template $Excluded $FilePath
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('vpn-update-' + [guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path (Join-Path $stage '.github/workflows') -Force
    try {
        foreach($path in $files.Keys){
            $target=Join-Path $stage $path
            $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
            [IO.File]::WriteAllText($target,$files[$path],(New-Object Text.UTF8Encoding($false)))
        }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::Open($Destination,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach($file in (Get-ChildItem -LiteralPath $stage -Recurse -File -Force)) {
                $entry=$file.FullName.Substring($stage.Length+1).Replace('\','/')
                $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$entry)
            }
        } finally {$archive.Dispose()}
    } finally {
        # Only the unique directory created above, under the system temp directory.
        if((Split-Path $stage -Parent) -eq ([IO.Path]::GetTempPath()).TrimEnd('\','/')){Remove-Item -LiteralPath $stage -Recurse -Force}
    }
}
function Invoke-AutoGitHubRequest([string]$Token,[string]$Method,[string]$Path,$Body=$null) {
    & (Get-Module SubscriptionTools) {param($t,$m,$p,$b) Invoke-GitHubRequest $t $m $p $b} $Token $Method $Path $Body
}

function Install-SubscriptionAutomation([string]$Token,[string]$Repository,[string]$Template,[string[]]$Excluded=@(),[bool]$AllowOverwrite=$false,[string]$FilePath='sub',[bool]$CreateIfMissing=$false) {
    if(-not $Token.Trim()){throw 'Введите токен владельца или участника с доступом к репозиторию.'}
    if($Repository -match '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') {
        try {$account=Invoke-AutoGitHubRequest $Token GET '/user'; $Repository=[string]$account.login + '/' + $Repository}
        catch {throw 'Не удалось определить аккаунт GitHub. Проверьте токен и соединение.'}
    }
    if($Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$' -or ($Repository -split '/')[1] -in @('.','..')){throw 'Укажите репозиторий в формате владелец/имя.'}
    $layout=Get-AutomationLayout $FilePath
    if(-not $AllowOverwrite){throw 'Отметьте разрешение замены подписки и файлов автоматики.'}
    $templateDoc=Get-SubscriptionDocument $Template
    $sources=@(Get-PublicSources)
    # Validate both public sources before making any GitHub changes.
    $docs=@(foreach($source in $sources){Get-SubscriptionSource $source.Url -PublicOnly})
    $outputs=Merge-PublicSubscriptions $templateDoc $sources $docs $Excluded
    $files=Get-AutomationFiles $Template $Excluded $FilePath
    $files[$FilePath]=$outputs['sub']
    $base='/repos/' + $Repository
    try {
        try {$repo=Invoke-AutoGitHubRequest $Token GET $base}
        catch {
            if($_.Exception.Data['Status'] -ne 404 -or -not $CreateIfMissing){throw}
            $owner,$repoName=$Repository -split '/',2
            $user=Invoke-AutoGitHubRequest $Token GET '/user'
            if($owner -ine $user.login){throw 'Новый личный репозиторий можно создать только в аккаунте владельца токена. Для другого владельца используйте существующий репозиторий.'}
            $repo=Invoke-AutoGitHubRequest $Token POST '/user/repos' @{name=$repoName; private=$false; auto_init=$true; description='VPN Connect automatic subscriptions'}
        }
        if($repo.private){throw 'Нужен публичный репозиторий для ссылки Happ.'}
        if($Token.StartsWith('github_pat_') -and $repo.PSObject.Properties['owner'] -and $repo.owner.type -eq 'User') {
            $account=Invoke-AutoGitHubRequest $Token GET '/user'
            if($account.login -ine $repo.owner.login){throw 'Fine-grained токен не поддерживает запись в чужой личный репозиторий как collaborator. Используйте токен владельца репозитория либо classic-токен участника с правами public_repo и workflow.'}
        }
        if($repo.PSObject.Properties['permissions'] -and $repo.permissions.PSObject.Properties['push'] -and -not $repo.permissions.push){throw 'У аккаунта токена нет права записи в этот репозиторий. Нужен доступ владельца или участника с правом Write.'}
        if($repo.archived){throw 'Репозиторий архивирован. Сначала снимите архивирование в GitHub.'}
        $branch=[string]$repo.default_branch
        if(-not $branch){throw 'В репозитории нет основной ветки. Создайте README в GitHub.'}
        $branchPath=(($branch -split '/') | ForEach-Object {[Uri]::EscapeDataString($_)}) -join '/'
        $head=Invoke-AutoGitHubRequest $Token GET ($base + '/git/ref/heads/' + $branchPath)
        $parent=Invoke-AutoGitHubRequest $Token GET ($base + '/git/commits/' + $head.object.sha)
        $existingTree=Invoke-AutoGitHubRequest $Token GET ($base + '/git/trees/' + $parent.tree.sha + '?recursive=1')
        if($existingTree.truncated){throw 'Слишком большой репозиторий для проверки путей. Выберите отдельный репозиторий подписок.'}
        foreach($entry in $existingTree.tree) {
            $existingPath=[string]$entry.path
            if(($existingPath -ieq $FilePath -and ($entry.type -eq 'tree' -or $existingPath -cne $FilePath)) -or
                $existingPath.StartsWith($FilePath + '/', [StringComparison]::OrdinalIgnoreCase) -or
                ($entry.type -ne 'tree' -and $FilePath.StartsWith($existingPath + '/', [StringComparison]::OrdinalIgnoreCase))){
                throw 'Выходной путь конфликтует с существующей папкой, файлом или регистром имени. Выберите другой путь.'
            }
        }
        $entries=@(foreach($path in ($files.Keys | Sort-Object)) {@{path=$path; mode='100644'; type='blob'; content=$files[$path]}})
        $tree=Invoke-AutoGitHubRequest $Token POST ($base + '/git/trees') @{base_tree=$parent.tree.sha; tree=$entries}
        $commit=Invoke-AutoGitHubRequest $Token POST ($base + '/git/commits') @{message='Install or update VPN subscription automation'; tree=$tree.sha; parents=@($head.object.sha)}
        # Fast-forward only: a concurrent update must never be overwritten.
        $null=Invoke-AutoGitHubRequest $Token PATCH ($base + '/git/refs/heads/' + $branchPath) @{sha=$commit.sha; force=$false}
    } catch {
        $failure=$_.Exception
        $diagnostic=''
        if($_.Exception.Data['Diagnostic']){$diagnostic="`nОтвет GitHub: " + $_.Exception.Data['Diagnostic']}
        if($_.Exception.Data['Operation']){$diagnostic+="`nЗапрос: " + $_.Exception.Data['Operation']}
        switch($failure.Data['Status']) {
            401 {throw 'GitHub не принял токен. Проверьте его срок и значение.'}
            403 {
                $hint='Проверьте доступ токена к нужному репозиторию и Contents + Workflows: Read and write. Для личного репозитория друга используйте его fine-grained токен. Токен участника: classic с public_repo + workflow.'
                if($diagnostic -match '(?i)rate limit'){$hint='GitHub временно ограничил частоту запросов. Дождитесь сброса лимита перед повтором.'}
                elseif($diagnostic -match '(?i)protected branch|repository rule|rule violation|GH006|GH013'){$hint='Запись заблокирована правилами ветки. Владелец должен проверить способ разрешённой установки через GitHub.'}
                throw ("GitHub отказал в установке (HTTP 403).`n" + $hint + $diagnostic)
            }
            404 {throw 'Репозиторий или основная ветка недоступны токену. Проверьте владельца и выбранный репозиторий.'}
            409 {throw 'Основная ветка изменилась. Повторите установку.'}
            422 {throw 'GitHub отклонил установку. Проверьте права Workflows, защиту ветки; при одновременном обновлении повторите установку.'}
            default {
                if($null -eq $failure.Data['Status']){throw $failure.Message}
                throw 'Установка не завершена. Проверьте соединение и файлы в репозитории перед повтором.'
            }
        }
    }
    $started=$false; $detail=''
    $workflow=$base + '/actions/workflows/update-subscriptions.yml'
    try {
        # New workflows can take a moment to become visible to the Actions API.
        for($attempt=0;$attempt -lt 3;$attempt++) {
            try {$state=Invoke-AutoGitHubRequest $Token GET $workflow; break}
            catch {if($_.Exception.Data['Status'] -ne 404 -or $attempt -eq 2){throw}; Start-Sleep -Milliseconds 700}
        }
        if($state.state -ne 'active'){$null=Invoke-AutoGitHubRequest $Token PUT ($workflow + '/enable')}
        $null=Invoke-AutoGitHubRequest $Token POST ($workflow + '/dispatches') @{ref=$branch}
        $started=$true
    } catch {$detail='Файлы и свежая подписка установлены, но запуск Actions не подтверждён. Проверьте, что Actions включены, а у токена есть Actions: Read and write. Откройте Actions для проверки.'}
    return [pscustomobject]@{
        Url=('https://raw.githubusercontent.com/' + $Repository + '/' + $branch + '/' + $FilePath)
        ActionsUrl=('https://github.com/' + $Repository + '/actions/workflows/update-subscriptions.yml')
        Started=$started; Detail=$detail; Commit=$commit.sha
    }
}
Export-ModuleMember -Function Get-PublicSources,Get-ConnectionIdentity,Merge-PublicSubscriptions,Get-AutomationLayout,Get-CombinedPublicSource,Export-AutoUpdatePackage,Install-SubscriptionAutomation

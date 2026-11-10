Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function ConvertFrom-SubscriptionBase64([string]$Text) {
    $value = ($Text -replace '\s', '').Replace('-', '+').Replace('_', '/')
    if ($value.Length % 4 -eq 1) { throw 'Некорректная строка Base64.' }
    $value = $value.PadRight($value.Length + ((4 - $value.Length % 4) % 4), '=')
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return $utf8.GetString([Convert]::FromBase64String($value))
}

function Get-ServerFragment([string]$Link) {
    $fragment = ''
    if ($Link.Contains('#')) { $fragment = $Link.Substring($Link.IndexOf('#') + 1) }
    $parts = $fragment -split '\?', 2
    $suffix = ''; $description = ''
    if ($parts.Count -gt 1) {
        $suffix = '?' + $parts[1]
        foreach ($pair in ($parts[1] -split '&')) {
            $kv = $pair -split '=', 2
            if ([Uri]::UnescapeDataString($kv[0]) -eq 'serverDescription' -and $kv.Count -eq 2) {
                try { $description = ConvertFrom-SubscriptionBase64 ([Uri]::UnescapeDataString($kv[1])) }
                catch { throw 'Не удалось декодировать подпись serverDescription. Исходные данные не изменены.' }
            }
        }
    }
    return [pscustomobject]@{Title=$parts[0]; Suffix=$suffix; Description=$description}
}

function Get-SubscriptionDocument([string]$Text) {
    $textValue = $Text.TrimStart([char]0xFEFF).Trim()
    if (-not $textValue) { throw 'Подписка пустая.' }
    if ($textValue -match '^\s*[\[{<]') { throw 'Нужен текстовый список ссылок или Base64. JSON, HTML и Clash YAML эта версия не редактирует.' }
    $decoded = $false
    if ($textValue -notmatch '(?im)^\s*(#|vless://|vmess://|trojan://|ss://|socks://|socks5://|hysteria2://|hy2://|tuic://)') {
        try { $textValue = ConvertFrom-SubscriptionBase64 $textValue; $decoded = $true }
        catch { throw 'Формат не распознан. Вставьте обычную подписку со списком ссылок или Base64.' }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $servers = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rawLine in ($textValue -split '\r?\n')) {
        $line = $rawLine.Trim()
        $lineIndex = $lines.Count
        $lines.Add($line)
        if ($line -match '^(vless|vmess|trojan|ss|socks|socks5|hysteria2|hy2|tuic)://') {
            $protocol = $Matches[1].ToLowerInvariant()
            $name = ''
            $description = ''
            if ($protocol -eq 'vmess') {
                try {
                    $jsonPart = ($line.Substring(8) -split '#', 2)[0]
                    $config = (ConvertFrom-SubscriptionBase64 $jsonPart) | ConvertFrom-Json
                    if ($config -isnot [pscustomobject]) { throw 'Not an object' }
                    if ($config.PSObject.Properties['ps']) { $name = [string]$config.ps }
                    if ($config.PSObject.Properties['serverDescription']) { $description = [string]$config.serverDescription }
                } catch { throw ('Не удалось прочитать VMess в строке ' + ($lineIndex + 1) + '. Исходные данные не изменены.') }
            } elseif ($line.Contains('#')) {
                $fragment = Get-ServerFragment $line
                $name = [Uri]::UnescapeDataString($fragment.Title)
                $description = $fragment.Description
            }
            $servers.Add([pscustomobject]@{Index=$lineIndex; Protocol=$protocol; Name=$name; Description=$description; Original=$line})
        } elseif ($line -and -not $line.StartsWith('#') -and -not $line.StartsWith('happ://routing/')) {
            throw ('Неподдерживаемая строка ' + ($lineIndex + 1) + '. Для сохранности подписки обработка остановлена.')
        }
    }
    if ($servers.Count -eq 0) { throw 'В подписке нет поддерживаемых серверных ссылок.' }
    return [pscustomobject]@{Lines=$lines.ToArray(); Servers=$servers.ToArray(); WasBase64=$decoded}
}

function Set-ServerDisplayName([string]$Link, [string]$Name) {
    if ($Name -match '[\r\n]') { throw 'Название сервера должно занимать одну строку.' }
    if ($Link.StartsWith('vmess://', [StringComparison]::OrdinalIgnoreCase)) {
        $original = ($Link.Substring(8) -split '#', 2)[0]
        $config = (ConvertFrom-SubscriptionBase64 $original) | ConvertFrom-Json
        $config | Add-Member -NotePropertyName ps -NotePropertyValue $Name -Force
        $json = ConvertTo-Json -InputObject $config -Depth 100 -Compress
        return 'vmess://' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    }
    $base = ($Link -split '#', 2)[0]
    $suffix = (Get-ServerFragment $Link).Suffix
    if (-not $Name -and -not $suffix) { return $base }
    return $base + '#' + [Uri]::EscapeDataString($Name) + $suffix
}

function Set-ServerDescription([string]$Link, [string]$Description) {
    if ($Description -match '[\r\n]' -or $Description.Length -gt 30) { throw 'Подпись сервера: одна строка, максимум 30 символов.' }
    if ($Link.StartsWith('vmess://', [StringComparison]::OrdinalIgnoreCase)) {
        $config = (ConvertFrom-SubscriptionBase64 (($Link.Substring(8) -split '#',2)[0])) | ConvertFrom-Json
        if ($Description) { $config | Add-Member -NotePropertyName serverDescription -NotePropertyValue $Description -Force }
        else { $config.PSObject.Properties.Remove('serverDescription') }
        return 'vmess://' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Depth 100 -Compress)))
    }
    $fragment = Get-ServerFragment $Link
    $pairs = New-Object 'System.Collections.Generic.List[string]'
    if ($fragment.Suffix) {
        foreach ($pair in ($fragment.Suffix.Substring(1) -split '&')) {
            if ([Uri]::UnescapeDataString(($pair -split '=',2)[0]) -ne 'serverDescription') {$pairs.Add($pair)}
        }
    }
    if ($Description) { $pairs.Add('serverDescription=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Description))) }
    $suffix = ''
    if ($pairs.Count) {$suffix = '?' + ($pairs -join '&')}
    $base = ($Link -split '#',2)[0]
    if (-not $fragment.Title -and -not $suffix) {return $base}
    return $base + '#' + $fragment.Title + $suffix
}

function Get-SubscriptionMetadataValue($Document, [string]$Key) {
    $value = ''
    $pattern = '^#\s*' + [regex]::Escape($Key) + '\s*:\s*(.*)$'
    if ($Key -eq 'providerid') {$pattern = '^#\s*providerid(?:\s*:\s*|\s+)(.*)$'}
    foreach ($line in $Document.Lines) {
        if ($line -match $pattern) {$value=$Matches[1]; break}
    }
    if ($Key -eq 'announce' -and $value.StartsWith('base64:', [StringComparison]::OrdinalIgnoreCase)) {
        $value = ConvertFrom-SubscriptionBase64 $value.Substring(7)
    }
    return $value
}

function Remove-OldSubscriptionExpiry([string]$Text) {
    $clean=New-Object 'System.Collections.Generic.List[string]'
    foreach($line in ($Text -split '\r?\n')) {
        if($line -match '^#\s*subscription-userinfo\s*:\s*(.*)$') {
            $info=$Matches[1]
            if($info -match '(?:^|;)\s*expire\s*=') {
                $parts=@($info -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_ -and $_ -notmatch '^expire\s*='})
                if($parts.Count){$clean.Add('#subscription-userinfo: ' + ($parts -join '; '))}
                continue
            }
        }
        if($line -match '^#\s*(sub-expire|notification-subs-expire)\s*:') {
            # Явный 0 отключает также уже импортированные настройки Happ.
            $clean.Add('#' + $Matches[1].ToLowerInvariant() + ': 0'); continue
        }
        if($line -match '^#\s*sub-expire-button-link\s*:'){continue}
        if($line -match '^#\s*announce\s*:\s*(.*)$') {
            $announcement=$Matches[1]
            try {
                if($announcement.StartsWith('base64:',[StringComparison]::OrdinalIgnoreCase)){$announcement=ConvertFrom-SubscriptionBase64 $announcement.Substring(7)}
                $withoutDate=$announcement -replace '(?: \| )?Срок до: \d{2}\.\d{2}\.\d{4} \d{2}:\d{2} МСК \| Продление: @[A-Za-z0-9_]+$', ''
                if($withoutDate -cne $announcement) {
                    if($withoutDate){$clean.Add('#announce: base64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($withoutDate)))}
                    continue
                }
            } catch { } # Не изменять неизвестное кодирование исходного объявления.
        }
        $clean.Add($line)
    }
    return ($clean -join "`n").TrimEnd() + "`n"
}

function Edit-Subscription($Document, [hashtable]$Metadata, [string[]]$Names, [string[]]$Descriptions=$null, [int[]]$RemovedServers=@()) {
    if ($Names.Count -ne $Document.Servers.Count) { throw 'Количество имён не совпадает с количеством серверов.' }
    if ($null -ne $Descriptions -and $Descriptions.Count -ne $Document.Servers.Count) { throw 'Количество подписей не совпадает с количеством серверов.' }
    $removedIndices=New-Object 'System.Collections.Generic.HashSet[int]'
    $removedLines=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach($index in $RemovedServers) {
        if($index -lt 0 -or $index -ge $Document.Servers.Count) {throw 'Неверный номер удаляемого сервера.'}
        $null=$removedIndices.Add($index)
        $null=$removedLines.Add([int]$Document.Servers[$index].Index)
    }
    if($removedIndices.Count -ge $Document.Servers.Count) {throw 'Оставьте хотя бы один сервер в подписке.'}
    $allowed = @('profile-title', 'announce', 'support-url', 'profile-web-page-url', 'profile-update-interval', 'providerid')
    foreach ($key in $Metadata.Keys) {
        if ($key -notin $allowed) { throw 'Неизвестное поле подписки.' }
        if ($key -ne 'announce' -and [string]$Metadata[$key] -match '[\r\n]') { throw 'Значения полей должны занимать одну строку.' }
    }
    if ($Metadata.ContainsKey('profile-title') -and ([string]$Metadata['profile-title']).Length -gt 25) { throw 'Название подписки: максимум 25 символов.' }
    if ($Metadata.ContainsKey('announce') -and ([string]$Metadata['announce']).Length -gt 200) { throw 'Объявление: максимум 200 символов.' }
    foreach ($key in @('support-url','profile-web-page-url')) {
        if ($Metadata.ContainsKey($key) -and $Metadata[$key]) {
            $checkUri = $null
            if (-not [Uri]::TryCreate([string]$Metadata[$key], [UriKind]::Absolute, [ref]$checkUri) -or $checkUri.Scheme -notin @('https','http','tg')) { throw 'Сайт и поддержка: укажите полный адрес https://… или tg://…' }
        }
    }
    if ($Metadata.ContainsKey('profile-update-interval') -and $Metadata['profile-update-interval'] -and [string]$Metadata['profile-update-interval'] -notmatch '^[1-9][0-9]{0,3}$') { throw 'Интервал обновления: целое число часов от 1 до 9999.' }
    $lines = @($Document.Lines | ForEach-Object { [string]$_ })
    for ($i=0; $i -lt $Document.Servers.Count; $i++) {
        if($removedIndices.Contains($i)){continue}
        $server = $Document.Servers[$i]
        # Не перекодировать серверы, имена которых не менялись.
        if ($Names[$i] -cne $server.Name) { $lines[$server.Index] = Set-ServerDisplayName $server.Original $Names[$i] }
        if ($null -ne $Descriptions -and $Descriptions[$i] -cne $server.Description) { $lines[$server.Index] = Set-ServerDescription $lines[$server.Index] $Descriptions[$i] }
    }
    $output = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $allowed) {
        if ($Metadata.ContainsKey($key) -and $Metadata[$key]) {
            $value = [string]$Metadata[$key]
            if ($key -eq 'announce') {
                # Happ получает одну строку метаданных, даже если пользователь ввёл несколько строк.
                $value = $value.Replace("`r`n", "`n").Replace("`r", "`n")
                $value = 'base64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
            }
            $separator = ': '
            if ($key -eq 'providerid') {$separator = ' '}
            $output.Add('#' + $key + $separator + $value)
        }
    }
    for($lineIndex=0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if($removedLines.Contains($lineIndex)){continue}
        $line=$lines[$lineIndex]
        if ($Metadata.ContainsKey('providerid') -and $line -match '^#\s*providerid(?:\s|:)') {continue}
        if ($line -match '^#\s*([\w-]+)\s*:' -and $Metadata.ContainsKey($Matches[1].ToLowerInvariant())) { continue }
        $output.Add($line)
    }
    return Remove-OldSubscriptionExpiry (($output -join "`n").TrimEnd() + "`n")
}

function Get-SubscriptionSource([string]$Url, [switch]$PublicOnly) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Укажите полную HTTPS-ссылку на подписку.' }
    if ($uri.Host -eq 'github.com' -and $uri.AbsolutePath -match '^/([^/]+)/([^/]+)/(?:blob|raw)/(.+)$') {
        $Url = 'https://raw.githubusercontent.com/' + $Matches[1] + '/' + $Matches[2] + '/' + $Matches[3] + $uri.Query
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('VPN-Connect-Editor/1.0')
    try {
        $response = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw ('Сайт вернул HTTP ' + [int]$response.StatusCode + '. Проверьте ссылку и доступ к сайту.') }
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Перенаправление на небезопасный HTTP отклонено.' }
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $readTimeout = New-Object Threading.CancellationTokenSource
            $readTimeout.CancelAfter(30000)
            $memory = New-Object IO.MemoryStream
            try {
                $buffer = New-Object byte[] 8192
                while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $readTimeout.Token).GetAwaiter().GetResult()) -gt 0) {
                    if ($memory.Length + $count -gt 5MB) { throw 'Подписка больше 5 МБ. Загрузка остановлена.' }
                    $memory.Write($buffer, 0, $count)
                }
                $body = [Text.Encoding]::UTF8.GetString($memory.ToArray())
            } finally { $stream.Dispose(); $memory.Dispose(); $readTimeout.Dispose() }
            if($PublicOnly) {
                $valid=New-Object 'System.Collections.Generic.List[string]'
                foreach($line in ($body -split '\r?\n')) {
                    if($line.Trim() -notmatch '^(vless|vmess|trojan|ss|socks|socks5|hysteria2|hy2|tuic)://'){continue}
                    try {$item=Get-SubscriptionDocument $line; $valid.Add($item.Servers[0].Original)} catch { }
                }
                $body=$valid -join "`n"
            }
            $doc = Get-SubscriptionDocument $body
            $headerLines = @()
            foreach ($key in @('profile-title','announce','support-url','profile-web-page-url','profile-update-interval','subscription-userinfo','providerid','sub-expire','notification-subs-expire')) {
                if (-not $PublicOnly -and $response.Headers.Contains($key) -and ($doc.Lines -join "`n") -notmatch ('(?im)^#\s*' + [regex]::Escape($key) + '(?:\s|:)')) {
                    $value = ($response.Headers.GetValues($key) -join ', ') -replace '[\r\n]', ''
                    $separator = ': '
                    if ($key -eq 'providerid') {$separator = ' '}
                    $headerLines += '#' + $key + $separator + $value
                }
            }
            if ($headerLines.Count) { $doc = Get-SubscriptionDocument (($headerLines -join "`n") + "`n" + ($doc.Lines -join "`n")) }
            return $doc
        } finally { $response.Dispose() }
    } catch {
        # Исключения .NET могут включать URL с ключом подписки; не показываем их цепочку.
        if ($_.Exception.Message -match '^(Сайт вернул|Перенаправление|Подписка больше|Формат|Нужен|Не удалось прочитать|Неподдерживаемая|В подписке)') { throw $_.Exception.Message }
        throw 'Не удалось загрузить подписку. Проверьте интернет, VPN и доступность ссылки.'
    } finally { $client.Dispose() }
}

function Get-GitHubErrorDiagnostic($Record,[string]$Token) {
    $raw=''
    if($Record.ErrorDetails){$raw=[string]$Record.ErrorDetails.Message}
    try {
        if(-not $raw -and $Record.Exception.Response) {
            $response=$Record.Exception.Response
            if($response.PSObject.Properties['Content']){$raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()}
            elseif($response.PSObject.Methods['GetResponseStream']){
                $reader=New-Object IO.StreamReader($response.GetResponseStream())
                try{$raw=$reader.ReadToEnd()}finally{$reader.Dispose()}
            }
        }
        $parsed=$raw | ConvertFrom-Json
        if(-not $parsed.PSObject.Properties['message']){return ''}
        $message=[string]$parsed.message
    } catch {return ''}
    if($Token){$message=$message.Replace($Token,'[скрыто]')}
    $message=$message -replace '(?i)(github_pat_|gh[pousr]_)[A-Za-z0-9_]+','[скрыто]'
    $message=$message -replace '(?i)Bearer\s+\S+','Bearer [скрыто]'
    $message=($message -replace '\s+',' ').Trim()
    if($message.Length -gt 500){$message=$message.Substring(0,500)}
    return $message
}

function Invoke-GitHubRequest([string]$Token, [string]$Method, [string]$Path, $Body=$null) {
    $headers = @{Authorization=('Bearer ' + $Token); Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28'}
    $params = @{Uri=('https://api.github.com' + $Path); Method=$Method; Headers=$headers; UserAgent='VPN-Connect-Editor/1.0'; TimeoutSec=30; ErrorAction='Stop'; UseBasicParsing=$true}
    if ($null -ne $Body) { $params.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20 -Compress)); $params.ContentType='application/json; charset=utf-8' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { return Invoke-RestMethod @params }
    catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        # Никогда не передавать исходное исключение с заголовками авторизации в интерфейс.
        $exception = New-Object System.Exception ('GitHub: HTTP ' + $status)
        $exception.Data['Status'] = $status
        $exception.Data['Diagnostic']=Get-GitHubErrorDiagnostic $_ $Token
        $exception.Data['Operation']=$Method + ' ' + $Path
        throw $exception
    }
}

function Publish-Subscription([string]$Token, [string]$Repository, [string]$FilePath, [string]$Content, [bool]$CreateIfMissing, [bool]$AllowOverwrite) {
    if (-not $Token.Trim()) { throw 'Введите токен GitHub.' }
    if ($Repository -notmatch '^(?:[A-Za-z0-9-]+/)?[A-Za-z0-9_.-]{1,100}$' -or ($Repository -split '/')[-1] -in @('.','..')) { throw 'Укажите имя репозитория или владелец/имя.' }
    if ($FilePath -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*(?:\.[A-Za-z0-9_-]+)?$') { throw 'Путь файла: например sub или subscriptions/sub.txt.' }
    if ([Text.Encoding]::UTF8.GetByteCount($Content) -gt 5MB) { throw 'Слишком большой файл.' }
    try {
        $userInfo = Invoke-GitHubRequest $Token GET '/user'
        $owner = [Uri]::EscapeDataString([string]$userInfo.login)
        $repoName=$Repository
        if($Repository.Contains('/')){$owner,$repoName=$Repository -split '/',2}
        $repoPath = '/repos/' + $owner + '/' + [Uri]::EscapeDataString($repoName)
        try { $repo = Invoke-GitHubRequest $Token GET $repoPath }
        catch {
            if ($_.Exception.Data['Status'] -ne 404 -or -not $CreateIfMissing) { throw }
            if($owner -ine $userInfo.login){throw 'Новый личный репозиторий можно создать только в аккаунте владельца токена.'}
            $repo = Invoke-GitHubRequest $Token POST '/user/repos' @{name=$repoName; private=$false; auto_init=$true; description='Subscription edited with VPN Connect Editor'}
        }
        if ($repo.private) { throw 'Репозиторий закрытый. Для обычной ссылки Happ нужен публичный репозиторий.' }
        $branch = [string]$repo.default_branch
        if (-not $branch) { $branch = 'main' }
        $encodedPath = (($FilePath -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        $contentPath = $repoPath + '/contents/' + $encodedPath
        $existing = $null
        try { $existing = Invoke-GitHubRequest $Token GET ($contentPath + '?ref=' + [Uri]::EscapeDataString($branch)) }
        catch { if ($_.Exception.Data['Status'] -ne 404) { throw } }
        if ($existing -and -not $AllowOverwrite) { throw 'Файл уже существует. Разрешите замену файла в настройках публикации или выберите другое имя.' }
        if ($existing -and $existing.type -ne 'file') { throw 'Указанный путь занят папкой.' }
        $payload = @{message='Update subscription'; content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content)); branch=$branch}
        if ($existing) { $payload.sha = $existing.sha }
        $null = Invoke-GitHubRequest $Token PUT $contentPath $payload
        return 'https://raw.githubusercontent.com/' + $owner + '/' + [Uri]::EscapeDataString($repoName) + '/' + $branch + '/' + $encodedPath
    } catch {
        $failure=$_.Exception
        $status = $failure.Data['Status']
        switch ($status) {
            401 { throw 'GitHub не принял токен. Проверьте срок действия и правильность токена.' }
            403 { throw 'GitHub отказал в доступе. Проверьте права токена (Contents: read/write), лимит запросов и правила репозитория.' }
            404 { throw 'Репозиторий не найден или токен не имеет доступа. Проверьте выбранные репозитории в настройках токена.' }
            409 { throw 'Файл изменился на GitHub. Повторите публикацию, чтобы загрузить актуальную версию.' }
            422 { throw 'GitHub отклонил запись. Проверьте имя репозитория, путь, ветку и права на создание репозитория.' }
            0 { throw 'Нет ответа GitHub. Проверьте соединение. Если запрос прервался, проверьте файл на GitHub перед повтором.' }
            default { throw $failure.Message }
        }
    }
}

Export-ModuleMember -Function ConvertFrom-SubscriptionBase64,Get-SubscriptionDocument,Set-ServerDisplayName,Set-ServerDescription,Get-SubscriptionMetadataValue,Edit-Subscription,Get-SubscriptionSource,Publish-Subscription

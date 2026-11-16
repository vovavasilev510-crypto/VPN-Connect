function Read-HappJsonDocument([string]$Text){
    try{[object[]]$items=ConvertFrom-Json -InputObject $Text}catch{throw 'Не удалось прочитать JSON Happ.'}
    $servers=New-Object 'System.Collections.Generic.List[object]'
    $metadata=@{}
    for($i=0;$i -lt $items.Count;$i++){
        $profile=$items[$i]
        if(-not $profile.PSObject.Properties['outbounds'] -or -not @($profile.outbounds).Count){throw 'JSON должен содержать полные профили Happ с outbounds.'}
        $remote=@($profile.outbounds|Where-Object {$_.protocol -notin @('freedom','blackhole','dns','loopback')})
        $name=if($profile.PSObject.Properties['remarks']){[string]$profile.remarks}else{'Профиль '+($i+1)}
        $description=''
        if($profile.PSObject.Properties['meta']){
            if($profile.meta.PSObject.Properties['serverDescription']){$description=[string]$profile.meta.serverDescription}
            if($profile.meta.PSObject.Properties['_vpnConnect']){foreach($p in $profile.meta._vpnConnect.PSObject.Properties){$metadata[$p.Name]=[string]$p.Value}}
        }
        $protocol=if($remote.Count -gt 1){'JSON · Автовыбор'}else{(@($remote|ForEach-Object {$_.protocol}) -join ', ')+' · JSON'}
        $servers.Add([pscustomobject]@{Index=$i;Protocol=$protocol;Name=$name;Description=$description;Original=($profile|ConvertTo-Json -Depth 100 -Compress)})
    }
    if(-not $servers.Count){throw 'В JSON нет профилей.'}
    return [pscustomobject]@{Format='HappJson';Profiles=$items;Metadata=$metadata;Lines=@((ConvertTo-Json -InputObject $items -Depth 100 -Compress));Servers=$servers.ToArray();WasBase64=$false}
}
function Edit-HappJsonDocument($Document,[hashtable]$Metadata,[string[]]$Names,[string[]]$Descriptions,[int[]]$RemovedServers){
    $result=New-Object 'System.Collections.Generic.List[object]'
    for($i=0;$i -lt $Document.Servers.Count;$i++){
        if($i -in $RemovedServers){continue}
        $profile=$Document.Servers[$i].Original|ConvertFrom-Json
        $profile|Add-Member -NotePropertyName remarks -NotePropertyValue ([string]$Names[$i]) -Force
        if(-not $profile.PSObject.Properties['meta']){$profile|Add-Member -NotePropertyName meta -NotePropertyValue ([pscustomobject]@{})}
        if($null -ne $Descriptions){$profile.meta|Add-Member -NotePropertyName serverDescription -NotePropertyValue ([string]$Descriptions[$i]) -Force}
        if($profile.meta.PSObject.Properties['_vpnConnect']){$profile.meta.PSObject.Properties.Remove('_vpnConnect')}
        $result.Add($profile)
    }
    if(-not $result.Count){throw 'Нельзя удалить все профили.'}
    $combined=@{};foreach($key in $Document.Metadata.Keys){$combined[$key]=$Document.Metadata[$key]};foreach($key in $Metadata.Keys){$combined[$key]=[string]$Metadata[$key]}
    if(([string]$combined['profile-title']).Length -gt 25 -or ([string]$combined['announce']).Length -gt 200){throw 'Название: до 25 символов, объявление: до 200.'}
    $result[0].meta|Add-Member -NotePropertyName _vpnConnect -NotePropertyValue $combined -Force
    return (ConvertTo-Json -InputObject @($result.ToArray()) -Depth 100 -Compress)
}

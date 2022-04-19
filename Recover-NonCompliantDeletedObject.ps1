#$anr = Read-Host "Enter EDIPI/Display Name of object to restore"
$anrs = @'

'@.Split("`n") | foreach {$_.trim()} | where {$_ -ne ""}
#Time to give them to bring the account into compliance before it gets deleted again
$gracePeriod = 7 #Days

$live = $true
$whatif = !$live

$Restored = @()
$NotFound = @()
$FailedToRestore = @()

$domain = Get-ADDomain -Current LocalComputer | select -ExpandProperty DNSRoot
#$domain = "hickam.pacaf.ds.af.smil.mil"
$DC = Get-ADDomainController -Server $domain | select -ExpandProperty hostname

foreach ($anr in $anrs) {
    #Find deleted object
    $anrLike = $anr + "*"
    $nameDel = $anr + "`nDEL:*"
    [array]$objs = Get-ADObject -server $DC -IncludeDeletedObjects -filter {userPrincipalName -eq $anr -or DisplayName -eq $anr -or name -like $nameDel} -prop LastKnownParent,extensionAttribute9,samaccountname,userprincipalname | where Deleted -eq $true
    if ($objs.count -eq 0) {
        $NotFound += $anr
        "None found for $anr."
        continue
        }
    :obj foreach ($obj in $objs) {
        #Prompt user if we want to restore this account
        $Title = "Restore Account"
        $accountName = $($obj.userprincipalname)
        if (!$accountName) {$accountName = $($obj.name).Split("`n")[0]}
        $Message = "Would you like to restore $accountName`nto $($obj.LastKnownParent)?"
        $Yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes","Restore account"
        $No = New-Object System.Management.Automation.Host.ChoiceDescription "&No","Do NOT restore account"
        $Cancel = New-Object System.Management.Automation.Host.ChoiceDescription "&Cancel","Abort Script"
        $options = [System.Management.Automation.Host.ChoiceDescription[]]($Yes,$No,$Cancel)
        do {
            $result = $host.ui.PromptForChoice($title,$message,$options,0)
            #$result = 0
            $success = $true
            switch ($result) {
                0 {"Do Nothing" | Out-Null}
                1 {continue obj}
                2 {exit}
                default {$success = $false}
                }
            } until ($success -eq $true)

        #Determine Deletion period
        $isAdmin = $obj.LastKnownParent -match "OU=Administration"
        $delPeriod = 90 #days
        if ($isAdmin) {$delPeriod = 45}

        #Generate new EA9 timestamp so it gets re-deleted in $gracePeriod days 
        $newEA9 = (Get-Date).AddDays(-1 * ($delPeriod - $gracePeriod))
        $newEA9String = $newEA9.ToString("yyyyMMdd")

        #Restore, then set new timestamp
        try {
            $ErrorActionPreference = "STOP"
            $obj | Restore-ADObject -server $DC -WhatIf:$whatif
            #$ea7 = "Acct Validated 20220225 by CONTRERAS, EDUARDO SSgt USAF AMC 6 CS/SCXS"

            switch ($obj.ObjectClass) {
                "User" {
                    #Set-ADUser $obj.samaccountname -Enabled $true -Replace @{extensionAttribute9=$newEA9String;extensionAttribute7=$ea7} -WhatIf:$whatif
                    Set-ADUser -server $DC $obj.samaccountname -Enabled $true -Replace @{extensionAttribute9=$newEA9String} -WhatIf:$whatif
                    }
                "Group" {
                    Set-ADGroup -server $DC $obj.samaccountname -Replace @{extensionAttribute9=$newEA9String} -WhatIf:$whatif
                    }
                "Computer" {
                    Set-ADComputer -server $DC $obj.samaccountname -Enabled $true -Replace @{extensionAttribute9=$newEA9String} -WhatIf:$whatif
                    }
                default {
                    "Unhandled object type: $($obj.ObjectClass) - $($obj.samaccountname)"
                    }
                }
            $Restored += $($obj.name).split("`n")[0]
            "Restored $($obj.ObjectClass): $($obj.samaccountname)" | Write-Host -ForegroundColor Green
            }
        catch {
            "Could not restore $($obj.samaccountname)" | Write-Host -ForegroundColor Red
            $FailedToRestore += $($obj.name).split("`n")[0]
            $_.Exception.Message | Write-Host -ForegroundColor Red
            $_.InvocationInfo.PositionMessage | Write-Host -ForegroundColor Red
            }
        $ErrorActionPreference = "Continue"
        }
    }

$outStr = ""

if ($Restored.count -gt 0) {
    $outStr += @"
The following items were restored:
$($Restored -join "`n")

Please update these items to be compliance with MTO 2021-222-001A within $gracePeriod days to prevent them from being automatically deleted.

"@
    }

if ($NotFound.count -gt 0) {
    $outStr += @"
The following items could not be found:
$($NotFound -join "`n")

"@
    }

if ($FailedToRestore.count -gt 0) {
    $outStr += @"
The following items were unable to be restored:
$($FailedToRestore -join "`n")

"@
    }

$outStr | clip
Write-Host "Remedy notes copied to clipboard"
read-host -Prompt "Script Finished.  Press Enter to close window."
Param(
  [string]$ConfigFolder
)
$ErrorActionPreference = "Stop"

if ($env:USERPROFILE.EndsWith("\Default")) {
	# we should be in a the user directory folder, windows 2012 task scheduler messed up with the profile again !
	# we can't generate temp sources files (-TypeDefinition parameter) in c:\windows\temp, no rights
	# FromSource parameters set is the only one providing -Language parameter, and we need it to compile c#3 in ps2 compatibility mode.

	$newprofile = "C:\Users\" + [Environment]::UserName

	Write-Host "Change profile folder to $newprofile"
	$env:USERPROFILE = "C:\Users\" + [Environment]::UserName
	$env:APPDATA = $newprofile + "\AppData\Roaming"
	$env:LOCALAPPDATA = $newprofile + "\AppData\Local"
	$env:TEMP = $env:TMP = $env:LOCALAPPDATA + "\Temp"
    
    Write-Host
    Write-Host "Getting Local Environment Variables:"
    Get-ChildItem Env:
}

Import-Module "C:\Program Files (x86)\Microsoft SDKs\Azure\PowerShell\ServiceManagement\Azure\Azure.psd1"

&{
    Function Write-Log {
        [cmdletbinding()]
        param(
            [Parameter(
                Position=0, 
                Mandatory=$true, 
                ValueFromPipeline=$true,
                ValueFromPipelineByPropertyName=$true)
            ]
            [String[]]$LogEntries
        )
        process {
            foreach($Log in $LogEntries) {
                $Log
                $Log | Out-File -Append $LogFile
            }
        }
    }

    if(!$ConfigFolder) {
        Write-Error "Missing ConfigFolder argument!"
        Exit 1
    }
    
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy("http://wsg-proxy.oecd.org:80/", $true);

    $currentDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    $LogPath = Split-Path -Path $ConfigFolder -Parent

    $LogFile =  "$LogPath\log\$currentDate.log"

    $Failure = $false
    
    try {

        if(Test-Path .\config\tmp\*.azure) {
            Remove-Item .\config\tmp\*.azure
        }


        $ConfigFile = Get-ChildItem $ConfigFolder -Filter prepress.azure

        Write-Log $ConfigFile.Fullname
        Write-Log "#######################"

        $config = Get-Content -Raw -Path $ConfigFile.Fullname | ConvertFrom-Json

        Get-ChildItem $config.LocalStoragePath -Directory | ForEach {

            $_config = $config.psobject.copy()
                
            $dirName = $_.BaseName

            If($dirName -match "^\d{4}$") {

                $remoteDirName = $config.BlobContainer + "-" + $dirName

                $azureContext = New-AzureStorageContext -StorageAccountName $config.AzureStorageAccount -StorageAccountKey $config.AzureStorageKey -Protocol Https

                $containerExist = Get-AzureStorageContainer -Context $azureContext | where-object {$_.Name -eq $remoteDirName}

                If(!$containerExist) {
                    Write-Log ("Creating container: " + $remoteDirName)
                    New-AzureStorageContainer -Context $azureContext -Name $remoteDirName| Set-AzureStorageContainerAcl -Permission Blob 
                }

                $_config.BlobContainer = $remoteDirName
                $_config.LocalStoragePath += "/" + $dirName

                $_config | ConvertTo-Json | Set-Content .\config\tmp\$remoteDirName.azure

                $currentDir = Get-Item -Path ".\"
                $parentDir = Split-Path -Path $currentDir -Parent
                    
                $args = @()
                $args += ("-ConfigFolder", ".\config")

                Invoke-Expression "$parentDir\azurebackup.ps1 $args"
            }
            Else {
                Write-Log ("Folder " + $dirName + " is not valid.")
            }
        }
    }
    catch {
        Write-Log $_.Exception

        $EmailFrom = "noreply-automate@oecd.org"
        $EmailTo = $Config.EmailTo
        $EmailCc = $Config.EmailCc
        $Subject = "AzureBackup Task - [FAILURE] - " + $remoteDirName
        $Body = "Cannot create '" + $remoteDirName + "'. See attached log file for details."

        $SMTPMessage = New-Object System.Net.Mail.MailMessage($EmailFrom, $EmailTo, $Subject, $Body)
        $SMTPMessage.cc.Add($Emailcc)
        $Attachment = New-Object System.Net.Mail.Attachment($LogFile)
        $SMTPMessage.Attachments.Add($Attachment)

        $SMTPClient = New-Object Net.Mail.SmtpClient("mailhost.oecd.org") 
        $SMTPClient.UseDefaultCredentials = $false
        $SMTPClient.Credentials = $null
        $SMTPClient.Send($SMTPMessage)

        Exit 1
    }

    Exit 0
}
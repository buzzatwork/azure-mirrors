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

#Disable-AzureDataCollection

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
    #[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy("http://127.0.0.1:8888/", $true);
    
    $LogFile = "$ConfigFolder\azurebackup.log"
    if(Test-Path $LogFile) {
        Remove-Item $LogFile
    }

    $Failure = $false

    Get-ChildItem $ConfigFolder -Filter *.azure | ForEach {

        try {
            $ConfigFile = $_

            Write-Log $ConfigFile.Fullname
            Write-Log "#######################"

            $config = Get-Content -Raw -Path $ConfigFile.Fullname | ConvertFrom-Json

            Write-Log ("Gather informations locally from " + $config.LocalStoragePath)
            $localFiles = @{}
            Get-ChildItem $config.LocalStoragePath -File | ForEach {
                $localFiles[$_.Name] = $_.Length
            }
        
            Write-Log ("Gather informations from Azure (" + $config.AzureStorageAccount + " - " + $config.BlobContainer + ")")
            $azureContext = New-AzureStorageContext -StorageAccountName $config.AzureStorageAccount -StorageAccountKey $config.AzureStorageKey -Protocol Https
            $azureFiles = @{}
            $azureSize = 0
            Get-AzureStorageBlob -Context $azureContext -Container $config.BlobContainer | ForEach {
                #Write-Log ("  > " + $_.Name +" (" + $_.Length + ")")
                $azureFiles[$_.Name] = $_.Length
                $azureSize += $_.Length
            }

            Write-Log ("  * " + $azureFiles.Keys.Count + " files on Azure (" + $azureSize/1GB + " GB)")

            
            Write-Log "Identify files to send to Azure Storage"
            $hasFilesToUpload = $false
            $localFiles.Keys | ForEach {
                $name = $_
                $azureLength = $azureFiles[$name]
                $localLength = $localFiles[$name]

                if(!$azureLength -or $azureLength -ne $localLength) {
                    $hasFilesToUpload = $true

                    Write-Log ("  * sending " + $name)
                    $localFile = [IO.Path]::Combine($config.LocalStoragePath, $name)

                    $tempfile = [System.IO.Path]::GetTempFileName()
                    Set-Content -Path $tempfile -Value "DELETE ME"

                    #Upload Dummy File first to ensure potential previous uploads failures with dangling uncommitted blocks are purged
                    $dummy = Set-AzureStorageBlobContent -Context $azureContext -Container $config.BlobContainer -File $tempfile -Blob $name -Force                   

                    # Now remove the Dummy file
                    $rem = Remove-AzureStorageBlob -Context $azureContext -Container $config.BlobContainer -Blob $name -Force

                    Remove-Item $tempfile

                    #Run the actual Upload...
                    $azureFile = Set-AzureStorageBlobContent -Context $azureContext -Container $config.BlobContainer -Blob $name -File $localFile -Force -ConcurrentTaskCount 10 -ServerTimeoutPerRequest 90 -ClientTimeoutPerRequest 600
                    #$azureFile = $dummy
                   
                    if($azureFile.Length -ne $localLength) {
                        throw ("Uploaded file size invalid: " + $azureFile.Length + " instead of " + $localLength)
                    }
                }

            }

            if(!$hasFilesToUpload) {
                Write-Log ("  * All up-to-date, no files to upload.")
            }
            
        }
        catch {
            Write-Log $_.Exception

            $EmailFrom = "noreply-automate@oecd.org"
            $EmailTo = $Config.EmailTo
            $EmailCc = $Config.EmailCc
            $Subject = "AzureBackup Task - [FAILURE] - " + $ConfigFile.Name
            $Body = "Failed to process azure backup with the following configuration file '" + $ConfigFile.FullName + "'. See attached log file for details."

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
    }

    Exit 0
}
function Copy-DiskToAzureBlobStorage {
    param (
        [string]$storageAccountName,
        [string]$sasTokenBlob,
        [array]$inclusions = $null,
        [switch]$includeAll,
        [switch]$enableVerbose
    )

    if ($enableVerbose) {
        $VerbosePreference = 'Continue'
    }

    $date = Get-Date -Format "ddMMyyyy-HHmmss"
    $clientContainerName =  $env:COMPUTERNAME.ToLower()
    $logEntries = @()

    $requiredModules = @("Az.Storage")
    Install-RequiredModule -ModuleNames $requiredModules

    $sasTokenContainerName = "sas-token"
    $sasToken = Get-SASToken -storageAccountName $storageAccountName -sasTokenBlob $sasTokenBlob -sasTokenContainerName $sasTokenContainerName

    $clientContext = Deploy-Container -storageAccountName $storageAccountName -containerName $clientContainerName -sasToken $sasToken

    $disks = Get-Disk

    $processedDisks = Invoke-Disk -disks $disks -inclusions $inclusions -includeAll:$includeAll

    $logEntries = Write-File -processedDisks $processedDisks -containerName $clientContainerName -context $clientContext -date $date -inclusions $inclusions -logEntries $logEntries

    $logEntries = Write-Metadatum -containerName $clientContainerName -metadataContext $clientContext -date $date -inclusions $inclusions -logEntries $logEntries

    Write-DiskLog -containerName $clientContainerName -logContext $clientContext -date $date -logEntries $logEntries

    Write-Verbose "Script execution complete."
}

# Function to install required modules
function Install-RequiredModule {
    param (
        [string[]]$ModuleNames
    )

    foreach ($moduleName in $ModuleNames) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            try {
                Install-Module -Name $moduleName -Force -AllowClobber -Scope CurrentUser
            } catch {
                Write-Error "Failed to install module: $moduleName. Please install it manually."
                throw
            }
        }
    }
}

# Function to retrieve SAS token from a blob
function Get-SASToken {
    param (
        [string]$storageAccountName,
        [string]$sasTokenBlob,
        [string]$sasTokenContainerName
    )

    Write-Verbose "Retrieving SAS token:"
    try {
        $context = New-AzStorageContext -StorageAccountName $storageAccountName -Anonymous
        $blob = Get-AzStorageBlob -Container $sasTokenContainerName -Blob $sasTokenBlob -Context $context
        $reader = $blob.ICloudBlob.OpenRead()
        $streamReader = New-Object System.IO.StreamReader($reader)
        $sasToken = $streamReader.ReadToEnd()
        $streamReader.Close()
        $reader.Close()

        if ([string]::IsNullOrEmpty($sasToken)) {
            Write-Error " - Failed to retrieve SAS token: Blob is empty."
            throw " - Blob $sasTokenBlob in container $sasTokenContainerName is empty."
        }

        Write-Verbose " - Successfully retrieved SAS token."
        return $sasToken
    } catch {
        Write-Error " - Error retrieving SAS token from blob: $_"
        return $null
    }
}

# Function to create a client container with subdirectories
function Deploy-Container {
    param (
        [string]$storageAccountName,
        [string]$containerName,
        [string]$sasToken
    )

    try {
        # Create storage context with SAS token
        $context = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken

        Write-Verbose "Creating container:"

        # Attempt to get the container, create if it does not exist
        try {
            Get-AzStorageContainer -Context $context -Name $containerName -ErrorAction Stop | Out-Null
            Write-Verbose " - $containerName already exists."
        } catch {
            Write-Verbose " - $containerName does not exist, creating:"
            New-AzStorageContainer -Name $containerName -Context $context -ErrorAction Stop | Out-Null
            Write-Verbose "  - $containerName created."
        }

        return $context
    } catch {
        Write-Error " - Error: $_"
        throw
    }
}

# Function to get all logical disks
function Get-Disk {
    try {
        Write-Verbose "Retrieving disks:"
        $disks = Get-CimInstance -Query "SELECT * FROM Win32_LogicalDisk WHERE DriveType=3"

        if (-not $disks -or $disks.Count -eq 0) {
            Write-Error " - No logical disks found with DriveType=3. Exiting."
            return @() # Return an empty array if no disks are found
        }

        Write-Verbose " - Retrieved $($disks.Count) disk(s)."
        return $disks
    } catch {
        Write-Error "Error retrieving disks: $_"
        throw
    }
}


# Function to process each disk
function Invoke-Disk {
    param (
        [array]$disks,
        [array]$inclusions,
        [switch]$includeAll
    )

    try {
        Write-Verbose "Processing disks:"

        switch ($includeAll) {
            $true {
                Write-Verbose " - Including all disks. Skipping inclusions."
                return $disks
            }
            default {
                $processedDisks = @()
                foreach ($disk in $disks) {
                    $matchingInclusions = $inclusions | Where-Object { $_.StartsWith($disk.DeviceID) }
                    if ($matchingInclusions.Count -gt 0) {
                        Write-Verbose " - Disk '$($disk.DeviceID)' matches inclusions."
                        $processedDisks += $disk
                    } else {
                        Write-Verbose " - Disk '$($disk.DeviceID)' does not match any inclusions."
                    }
                }

                if ($processedDisks.Count -eq 0) {
                    Write-Error " - No disks matched the inclusions. Exiting disk processing."
                    throw " - No matching disks found for provided inclusions."
                }

                Write-Verbose " - Processed $($processedDisks.Count) disks that match inclusions."
                return $processedDisks
            }
        }
    } catch {
        Write-Error " - Error processing disks: $_"
        throw
    }
}

# Function to upload files from disks to storage
function Write-File {
    param (
        [array]$processedDisks,
        [string]$containerName,
        $context,
        [string]$date,
        [array]$inclusions,
        [array]$logEntries
    )

    try {
        Write-Verbose "Uploading files from processed disks:"
        foreach ($disk in $processedDisks) {
            $diskLetter = $disk.DeviceID.TrimEnd(":")
            $folderPathInContainer = "disks/$diskLetter-$date".ToLower()

            # Get files based on inclusions or full disk
            if (-not $inclusions -or $inclusions.Count -eq 0) {
                Write-Verbose " - No inclusions specified. Uploading all files from disk '$diskLetter'."
                $files = Get-ChildItem -Path "${diskLetter}:\\" -Recurse | Where-Object { -not $_.PSIsContainer }
            } else {
                Write-Verbose " - Uploading files from specified inclusions for disk '$diskLetter'."
                $files = @()
                foreach ($inclusion in $inclusions) {
                    if ($inclusion.StartsWith($disk.DeviceID)) {
                        $files += Get-ChildItem -Path $inclusion -Recurse | Where-Object { -not $_.PSIsContainer }
                    }
                }
            }

            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($disk.DeviceID.Length).TrimStart("\").Replace("\", "/")
                $blobName = "$folderPathInContainer/$relativePath".ToLower()

                try {
                    Set-AzStorageBlobContent -File $file.FullName -Container $containerName -Blob $blobName -Context $context | Out-Null
                    $logEntries += "Uploaded: $($file.FullName)`n"
                } catch {
                    $logEntries += "Failed: $($file.FullName) - Error: $_`n"
                    Write-Error "   - Failed: $($file.FullName). Error: $_"
                }
            }
        }

        Write-Verbose " - File upload completed."
        return $logEntries
    } catch {
        Write-Error " - Error during file upload: $_"
        throw
    }
}


# Function to upload metadata to Azure Blob
function Write-Metadatum {
    param (
        [string]$containerName,
        $metadataContext,
        [string]$date,
        [array]$inclusions,
        [array]$logEntries
    )

    try {
        Write-Verbose "Generating and uploading metadata:"
        $metadata = @()

        foreach ($disk in $processedDisks) {
            if ($inclusions.Count -eq 0) {
                Write-Verbose " - No inclusions specified. Collecting metadata for all files on disk '$($disk.DeviceID)'."
                $items = Get-ChildItem -Path "$($disk.DeviceID):\" -Recurse -Force
            } else {
                Write-Verbose " - Collecting metadata for specified inclusions on disk '$($disk.DeviceID)'."
                foreach ($inclusion in $inclusions) {
                    if ($inclusion.StartsWith($disk.DeviceID)) {
                        $items = Get-ChildItem -Path $inclusion -Recurse -Force
                    }
                }
            }

            foreach ($item in $items) {
                $metadata += [PSCustomObject]@{
                    Path            = $item.FullName
                    Type            = if ($item.PSIsContainer) { "Directory" } else { "File" }
                    Size            = if ($item.PSIsContainer) { 0 } else { $item.Length }
                    CreationTime    = $item.CreationTime
                    LastWriteTime   = $item.LastWriteTime
                    LastAccessTime  = $item.LastAccessTime
                }
            }
        }

        Write-Verbose " - Converting metadata to JSON format."
        $metadataJson = $metadata | ConvertTo-Json -Depth 10

        $metadataFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $metadataFile -Value $metadataJson

        $blobName = "metadata/metadata-$date.json".ToLower()

        try {
            Write-Verbose " - Uploading metadata to blob '$blobName'."
            Set-AzStorageBlobContent -File $metadataFile -Container $containerName -Blob $blobName -Context $metadataContext | Out-Null
            Write-Verbose "   - Metadata uploaded successfully."
            $logEntries += "Uploaded metadata to: $blobName.`n"
        } catch {
            Write-Error "   - Failed to upload metadata to: $blobName. Error: $_"
            $logEntries += "Failed uploading metadata to: $blobName.`n"
        } finally {
            Remove-Item $metadataFile -Force
        }

        return $logEntries
    } catch {
        Write-Error " - Error generating or uploading metadata: $_"
        throw
    }
}

# Function to upload logs to Azure Blob
function Write-DiskLog {
    param (
        [string]$containerName,
        $logContext,
        [string]$date,
        [array]$logEntries
    )

    try {
        Write-Verbose "Uploading logs:"

        # Generate the log content
        $blobName = "logs/logs-$date.txt".ToLower()
        $logContent = $logEntries -join "`n"

        # Create a temporary file for the logs
        $tempLogFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempLogFile -Value $logContent
        Write-Verbose " - Log file created: $tempLogFile"

        # Upload the log file
        try {
            Write-Verbose " - Uploading log file to blob '$blobName'."
            Set-AzStorageBlobContent -File $tempLogFile -Container $containerName -Blob $blobName -Context $logContext | Out-Null
            Write-Verbose "   - Log file uploaded successfully."
        } catch {
            Write-Error "   - Failed to upload log file to: $blobName. Error: $_"
            throw "Log upload failed."
        } finally {
            # Ensure the temporary file is deleted
            Remove-Item $tempLogFile -Force -ErrorAction SilentlyContinue
            Write-Verbose " - Temporary log file removed."
        }
    } catch {
        Write-Error " - Error during log upload: $_"
        throw
    }
}
# DiskToAzureBlobStorage

## Description

A PowerShell module designed to securely copy files from local drives of a Windows client to Azure Blob Storage. It supports directory-based inclusion or full-disk targeting, and captures both metadata and script logs for traceability. The upload is authenticated using a Share Access Signature (SAS) token that is securely retrieved from an Azure Blob, minimizing hardcoded secrets and improving operational security.

## Requirements

- PowerShell 7+ [Install PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.5)
- Write access to the control plane of the Azure Storage Account (e.g. RBAC Role: `Storage Account Contributor`)
- Network access to Azure Storage (e.g. via Service Tag: [Storage](https://www.microsoft.com/en-us/download/details.aspx?id=56519))

## Installation

1. Download the module to a local directory.
2. Open a PowerShell terminal and run the following commands:

```powershell
Import-Module "C:\DiskToAzureBlobStorage\DiskToAzureBlobStorage.psd1"
Get-Command -Module DiskToAzureBlobStorage
```

## Setup
1. Create an Azure Storage Account and a container named `sas-token`.
2. In that container, create a blob named `GUID.txt` (e.g. output from  `New-Guid` in PowerShell).
3. Paste your SAS token into that blob file. It should be the raw token string starting with `sv=` (do not include `https://...` or `BlobEndpoint=`).
  - **SAS token requirements**:
    - **Allowed services**: `Blob`
    - **Allowed resource types**: `Service`, `Container`, `Object`
    - **Allowed permissions**: `Read`, `Write`, `Create`, `List`, `Add`
    - **Allowed blob index permissions**: `None`

## Parameters
- [string] `-storageAccountName`: Name of the Azure Storage Account to upload to.
- [string] `-sasTokenBlob`: Name of the blob containing the SAS token.
- [array] `-inclusions`: List of directory paths to include in the upload.
- [switch] `-includeAll`: Include all detected local disks.
- [switch] `-enableVerbose`: Enable verbose terminal output during execution.

## Usage
### Upload specific directories
```PowerShell
Copy-DiskToAzureBlobStorage -storageAccountName "mystorageaccount" -sasTokenBlob "GUID.txt" -inclusions @("C:\Users\$env:USERNAME\downloads", "G:\") -enableVerbose
```

### Upload all disks
```PowerShell
Copy-DiskToAzureBlobStorage -storageAccountName "mystorageaccount" -sasTokenBlob "GUID.txt" -includeAll -enableVerbose
```

## Tree
```bash
Storage Account
    ├── hostname
    │   ├── disks
    │   │   └── diskletter-date-time
    │   │       └── directory
    │   ├── logs
    │   │   └── logs-date-time.json
    │   └── metadata
    │       └── metadata-date-time.json
    └── sas-token
        └── guid.txt
```
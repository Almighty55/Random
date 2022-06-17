if (Get-Module -ListAvailable -Name Az.Storage){
    Import-Module -Name Az.Storage
}
else {
    Write-Host -BackgroundColor Black -ForegroundColor Red "Please install the Az module - specifically 'Az.Storage'"
    break;
}

if (!(Get-AzAccessToken -ErrorAction SilentlyContinue)){
    throw "Please authenticate to azure - Connect-AzAccount"
}

#script for copy azure storage account, to another storage account.
#* Set these values
$SourceResourceGroup = "" # fill the resource group
$SourceStorageAccount = "" # fill the source storage account
$DestStorageAccount = "" # fill the destination storage account

$SourceStorageKey = (Get-AzStorageAccountKey -ResourceGroupName $SourceResourceGroup -Name $SourceStorageAccount | Where-Object {$_.KeyName -eq "key1"}).value # fill the source storage key
$DestResourceGroup = $SourceResourceGroup # only update if destination group differs from source group
$SourceStorageAccountInfo = Get-AzStorageAccount -ResourceGroupName $DestResourceGroup -Name $SourceStorageAccount

# check if destination storage account needs to be created
if (!(Get-AzStorageAccount -ResourceGroupName $DestResourceGroup | Where-Object {$_.StorageAccountName -eq $DestStorageAccount})){
    
    # check if the destination storage account name is available and create it if so
    if (((Get-AzStorageAccountNameAvailability -Name $DestStorageAccount).NameAvailable)) {  
        Write-Host "Creating new destination Storage Account: $DestStorageAccount"
        New-AzStorageAccount -ResourceGroupName $DestResourceGroup `
            -Name $DestStorageAccount `
            -Location $SourceStorageAccountInfo.Location `
            -SkuName $SourceStorageAccountInfo.Sku.Name `
            -Kind $SourceStorageAccountInfo.Kind | Update-AzStorageBlobServiceProperty -IsVersioningEnabled $true | Out-Null
    }
    else{
        $nameCheck = (Get-AzStorageAccountNameAvailability -Name $DestStorageAccount)
        Write-Host -BackgroundColor Yellow -ForegroundColor Red "!!! Storage Account Creation Failed !!!"
        Write-Host -BackgroundColor Black -ForegroundColor Red "Reason: " -NoNewline; Write-Host -BackgroundColor Black $nameCheck.Reason
        Write-Host -BackgroundColor Black -ForegroundColor Red "Error Message: " -NoNewline; Write-Host -BackgroundColor Black $nameCheck.Message
        break;
    }
}


$DestStorageKey = (Get-AzStorageAccountKey -ResourceGroupName $DestResourceGroup -Name $DestStorageAccount | Where-Object {$_.KeyName -eq "key1"}).value
$SourceStorageContext = New-AzStorageContext -StorageAccountName $SourceStorageAccount -StorageAccountKey $SourceStorageKey
$DestStorageContext = New-AzStorageContext -StorageAccountName $DestStorageAccount -StorageAccountKey $DestStorageKey
$SourceContainers = Get-AzStorageContainer -Context $SourceStorageContext

foreach($Container in $SourceContainers) {
    $ContainerName = $Container.Name
    if (!((Get-AzStorageContainer -Context $DestStorageContext) | Where-Object { $_.Name -eq $ContainerName })) {
        Write-Host "Creating new container: $ContainerName"
        New-AzRmStorageContainer -ResourceGroupName $DestResourceGroup `
            -StorageAccountName $DestStorageAccount `
            -Name $ContainerName `
            -EnableImmutableStorageWithVersioning -ErrorAction Stop | Out-Null
    }

    $Blobs = Get-AzStorageBlob -Context $SourceStorageContext -Container $ContainerName
    $DestBlobs = Get-AzStorageBlob -Context $DestStorageContext -Container $ContainerName

    $BlobCpyAry = @() #Create array of objects

    # Do the copy of everything
    foreach ($Blob in $Blobs) {

        # if the current blob is in the container at all, skip over it
        if ($Blob.name -in $DestBlobs.name){
            # comment this line out if you don't want to see all the skipped files
            Write-Host -ForegroundColor Yellow "Skipping `"$($Blob.name)`" since it was found in $($DestStorageContext.StorageAccountName)/$ContainerName"
        }
        else{
            $BlobName = $Blob.Name
            Write-Host "Copying $BlobName from $ContainerName"
            $BlobCopy = Start-AzStorageBlobCopy -Context $SourceStorageContext -SrcContainer $ContainerName -SrcBlob $BlobName -DestContext $DestStorageContext -DestContainer $ContainerName -DestBlob $BlobName
            $BlobCpyAry += $BlobCopy
        }           
    }

    #Check Status
    foreach ($BlobCopy in $BlobCpyAry) {
        $startDate = Get-Date
        do {
            $CopyState = $BlobCopy | Get-AzStorageBlobCopyState
            if ($CopyState.TotalBytes -gt 0){
                $Message = $CopyState.Source.AbsolutePath + " " + $CopyState.Status + " {0:N2}%" -f (($CopyState.BytesCopied/$CopyState.TotalBytes)*100) 
            }
            else{
                $Message = "$($CopyState.Source.AbsolutePath) Success 100.00%"
            }
        }while($CopyState.Status -ne "Success" -and $startDate.AddMinutes(2) -gt (Get-Date)) # add this in for bigger transfers that are in a pending state time out is 2 mins
        Write-Host -ForegroundColor Green "Copy of $Message"
    }
}
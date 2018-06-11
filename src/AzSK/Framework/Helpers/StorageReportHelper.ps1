Set-StrictMode -Version Latest

class StorageReportHelper
{
    hidden [PSObject] $AzSKResourceGroup = $null;
	hidden [PSObject] $AzSKStorageAccount = $null;
	hidden [PSObject] $AzSKStorageContainer = $null;
	hidden [int] $HasStorageReportReadPermissions = -1;
	hidden [int] $HasStorageReportWritePermissions = -1;
    hidden [int] $retryCount = 3;
    
    StorageReportHelper()
	{
    }
    
    hidden [void] Initialize([bool] $CreateResourcesIfNotExists)
	{
		$this.GetAzSKStorageReportContainer($CreateResourcesIfNotExists)
    }
    
    hidden [void] GetAzSKStorageReportContainer([bool] $createIfNotExists)
	{
		$ContainerName = [Constants]::StorageReportContainerName;
		if($null -eq $this.AzSKStorageAccount)
		{
			$this.GetAzSKStorageAccount($createIfNotExists)
		}
		if($null -eq $this.AzSKStorageAccount)
		{
			#No storage account => no permissions at all
			$this.HasStorageReportReadPermissions = 0
			$this.HasStorageReportWritePermissions = 0
			return;
        }
        
		$this.HasStorageReportReadPermissions = 0					
		$this.HasStorageReportWritePermissions = 0
		$writeTestContainerName = "writetest";

		#see if user can create the test container in the storage account. If yes then user have both RW permissions. 
		try
		{
			$containerObject = Get-AzureStorageContainer -Context $this.AzSKStorageAccount.Context -Name $writeTestContainerName -ErrorAction SilentlyContinue
			if($null -ne $containerObject)
			{
				Remove-AzureStorageContainer -Name $writeTestContainerName -Context  $this.AzSKStorageAccount.Context -ErrorAction Stop -Force
				$this.HasStorageReportWritePermissions = 1
				$this.HasStorageReportReadPermissions = 1
			}
			else
			{
				New-AzureStorageContainer -Context $this.AzSKStorageAccount.Context -Name $writeTestContainerName -ErrorAction Stop
				$this.HasStorageReportWritePermissions = 1
				$this.HasStorageReportReadPermissions = 1
				Remove-AzureStorageContainer -Name $writeTestContainerName -Context  $this.AzSKStorageAccount.Context -ErrorAction SilentlyContinue -Force
			}				
		}
		catch
		{
			$this.HasStorageReportWritePermissions = 0
		}
		if($this.HasStorageReportWritePermissions -eq 1)
		{
			try
			{
				if($createIfNotExists)
				{
					New-AzureStorageContainer -Context $this.AzSKStorageAccount.Context -Name $ContainerName -ErrorAction SilentlyContinue
				}
				$containerObject = Get-AzureStorageContainer -Context $this.AzSKStorageAccount.Context -Name $ContainerName -ErrorAction SilentlyContinue
				$this.AzSKStorageContainer = $containerObject;					
			}
			catch
			{
				# Add retry logic, after 3 unsuccessful attempt throw the exception.
			}
		}
		else
		{
			# If user doesn't have write permission, check at least user have read permission
			try
			{
				#Able to read the container then read permissions are good
				$containerObject = Get-AzureStorageContainer -Context $this.AzSKStorageAccount.Context -Name $ContainerName -ErrorAction Stop
				$this.AzSKStorageContainer = $containerObject;
				$this.HasStorageReportReadPermissions = 1
			}
			catch
			{
				#Resetting permissions in the case of exception
				$this.HasStorageReportReadPermissions = 0			
			}	
		}		
    }
    
    hidden [void] GetAzSKStorageAccount($createIfNotExists)
	{
		if($null -eq $this.AzSKResourceGroup)
		{
			$this.GetAzSKRG($createIfNotExists);
		}
		if($null -ne $this.AzSKResourceGroup)
		{
			$StorageAccount  = $null;
			$loopValue = $this.retryCount;
			while($loopValue -gt 0)
			{
				$loopValue = $loopValue - 1;
				try
				{
					$StorageAccount = Get-AzureRmStorageAccount -ResourceGroupName $this.AzSKResourceGroup.ResourceGroupName -ErrorAction Stop | Where-Object {$_.StorageAccountName -like 'azsk*'} -ErrorAction Stop 
					$loopValue = 0;
				}
				catch
				{
					#eat this exception and retry
				}
			}			

			#if no storage account found then it assumes that there is no control state feature is not used and if there are more than one storage account found it assumes the same
			if($createIfNotExists -and ($null -eq $StorageAccount -or ($StorageAccount | Measure-Object).Count -eq 0))
			{
				$storageAccountName = ("azsk" + (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss"));	
				$storageObject = [Helpers]::NewAzskCompliantStorage($storageAccountName, $this.AzSKResourceGroup.ResourceGroupName, [Constants]::AzSKRGLocation)
				if($null -ne $storageObject -and ($storageObject | Measure-Object).Count -gt 0)
				{
					$loopValue = $this.retryCount;
					while($loopValue -gt 0)
					{
						$loopValue = $loopValue - 1;
						try
						{
							$StorageAccount = Get-AzureRmStorageAccount -ResourceGroupName $this.AzSKResourceGroup.ResourceGroupName -ErrorAction Stop | Where-Object {$_.StorageAccountName -like 'azsk*'} -ErrorAction Stop 					
							$loopValue = 0;
						}
						catch
						{
							#eat this exception and retry
						}
					}					
				}					
			}
			$this.AzSKStorageAccount = $StorageAccount;
		}
    }
    
    hidden [PSObject] GetAzSKRG([bool] $createIfNotExists)
	{
		$azSKConfigData = [ConfigurationManager]::GetAzSKConfigData()

		$resourceGroup = Get-AzureRmResourceGroup -Name $azSKConfigData.AzSKRGName -ErrorAction SilentlyContinue
		if($createIfNotExists -and ($null -eq $resourceGroup -or ($resourceGroup | Measure-Object).Count -eq 0))
		{
			if([Helpers]::NewAzSKResourceGroup($azSKConfigData.AzSKRGName, [Constants]::AzSKRGLocation, ""))
			{
				$resourceGroup = Get-AzureRmResourceGroup -Name $azSKConfigData.AzSKRGName -ErrorAction SilentlyContinue
			}
		}
		$this.AzSKResourceGroup = $resourceGroup
		return $resourceGroup;
    }
    
    hidden [LocalSubscriptionReport] GetLocalSubscriptionScanReport()
	{
		try
		{
            $storageReportBlobName = [Constants]::StorageReportBlobName + ".zip"
            
            #Look of is there is a AzSK RG and AzSK Storage account
            $StorageAccount = $this.AzSKStorageAccount;						
            $containerObject = $this.AzSKStorageContainer
            $ContainerName = ""
            if($null -ne $this.AzSKStorageContainer)
            {
                $ContainerName = $this.AzSKStorageContainer.Name
            }
            else
            {
                return [LocalSubscriptionReport]::new();
            }

            $loopValue = $this.retryCount;
            $StorageReportBlob = $null;
            while($loopValue -gt 0 -and $null -eq $StorageReportBlob)
            {
                $loopValue = $loopValue - 1;
                $StorageReportBlob = Get-AzureStorageBlob -Container $ContainerName -Blob $storageReportBlobName -Context $StorageAccount.Context -ErrorAction SilentlyContinue
            }

            if($null -eq $StorageReportBlob)
            {
                return [LocalSubscriptionReport]::new();
            }
            $AzSKTemp = [Constants]::AzSKAppFolderPath + "\Temp\StorageReport";
            if(-not (Test-Path -Path $AzSKTemp))
            {
                mkdir -Path $AzSKTemp -Force
            }

            $loopValue = $this.retryCount;
            while($loopValue -gt 0)
            {
                $loopValue = $loopValue - 1;
                try
                {
                    Get-AzureStorageBlobContent -CloudBlob $StorageReportBlob.ICloudBlob -Context $StorageAccount.Context -Destination $AzSKTemp -Force -ErrorAction Stop
                    $loopValue = 0;
                }
                catch
                {
                    #eat this exception and retry
                }
            }
            $fileName = $AzSKTemp+"\"+[Constants]::StorageReportBlobName +".json"
			
			try
			{
				# extract file from zip
				$compressedFileName = $AzSKTemp+"\"+[Constants]::StorageReportBlobName +".zip"
				Expand-Archive -Path $compressedFileName -DestinationPath $AzSKTemp -Force

				$StorageReportJson = (Get-ChildItem -Path $fileName -Force | Get-Content | ConvertFrom-Json)
			}
			catch
			{
				#unable to find zip file. return empty object
				return [LocalSubscriptionReport]::new();
			}
			
            
            $storageReport = [LocalSubscriptionReport] $StorageReportJson

			return $storageReport;
		}
		finally{
			$this.CleanTempFolder()
		}
    }

    hidden [LSRSubscription] GetLocalSubscriptionScanReport([string] $subscriptionId)
    {
        $fullScanResult = $this.GetLocalSubscriptionScanReport()
        if([Helpers]::CheckMember($fullScanResult,"Subscriptions") -and ($fullScanResult.Subscriptions | Measure-Object ).Count -gt 0)
        {
            return $fullScanResult.Subscriptions | Where-Object { $_.SubscriptionId -eq $subscriptionId }
        }
        else
        {
            return [LSRSubscription]::new()
        }
        
    }

    hidden [void] SetLocalSubscriptionScanReport([LocalSubscriptionReport] $scanResultForStorage)
	{		
		try
		{
			$AzSKTemp = [Constants]::AzSKAppFolderPath + "\Temp\StorageReport";				
			if(-not (Test-Path "$AzSKTemp"))
			{
				mkdir -Path "$AzSKTemp" -ErrorAction Stop | Out-Null
			}
			else
			{
				Remove-Item -Path "$AzSKTemp\*" -Force -Recurse 
			}

			$fileName = "$AzSKTemp\" + [Constants]::StorageReportBlobName +".json"
			$compressedFileName = "$AzSKTemp\" + [Constants]::StorageReportBlobName +".zip"

			$StorageAccount = $this.AzSKStorageAccount;						
			$containerObject = $this.AzSKStorageContainer
			$ContainerName = ""
			if($null -ne $this.AzSKStorageContainer)
			{
				$ContainerName = $this.AzSKStorageContainer.Name
			}

			[Helpers]::ConvertToJsonCustomCompressed($scanResultForStorage) | Out-File $fileName -Force

			#compress file before store to storage
			Compress-Archive -Path $fileName -CompressionLevel Optimal -DestinationPath $compressedFileName -Update

			$loopValue = $this.retryCount;
			while($loopValue -gt 0)
			{
				$loopValue = $loopValue - 1;
				try
				{
					Set-AzureStorageBlobContent -File $compressedFileName -Container $ContainerName -BlobType Block -Context $StorageAccount.Context -Force -ErrorAction Stop
					$loopValue = 0;
				}
				catch
				{
					#eat this exception and retry
				}
			}
		}
		finally
		{
			$this.CleanTempFolder();
		}
    }
    
    hidden [void] CleanTempFolder()
	{
		$AzSKTemp = [Constants]::AzSKAppFolderPath + "\Temp\StorageReport";				
		if(Test-Path "$AzSKTemp")
		{
			Remove-Item -Path $AzSKTemp -Recurse -Force -ErrorAction Stop | Out-Null
		}

    }
    
    hidden [void] PostServiceScanReport($scanResult)
    {
        $scanReport = $this.SerializeServiceScanReport($scanResult)
        $finalScanReport = $this.MergeScanReport($scanReport)
        $this.SetLocalSubscriptionScanReport($finalScanReport)
    }

    hidden [void] PostSubscriptionScanReport($scanResult)
    {
        $scanReport = $this.SerializeSubscriptionScanReport($scanResult)
        $finalScanReport = $this.MergeScanReport($scanReport)
        $this.SetLocalSubscriptionScanReport($finalScanReport)
    }

    hidden [LSRSubscription] SerializeSubscriptionScanReport($scanResult)
    {
        $storageReport = [LSRSubscription]::new()
        $storageReport.SubscriptionId = $scanResult.SubscriptionId
        $storageReport.SubscriptionName = $scanResult.SubscriptionName 

        $scanDetails = [LSRScanDetails]::new()

        $scanResult.ControlResults | ForEach-Object {
            $serviceControlResult = $_
            
			if($scanResult.IsLatestPSModule -and $serviceControlResult.HasRequiredAccess -and $scanResult.HasAttestationReadPermissions)
			{
				$subscriptionScanResult = [LSRSubscriptionControlResult]::new()
				$subscriptionScanResult.ScannedBy = [Helpers]::GetCurrentRMContext().Account
				$subscriptionScanResult.ScanSource = $scanResult.Source
				$subscriptionScanResult.ScannerVersion = $scanResult.ScannerVersion 
				$subscriptionScanResult.ControlVersion = $scanResult.ControlVersion
				$subscriptionScanResult.ControlId = $serviceControlResult.ControlId 
				$subscriptionScanResult.ControlIntId = $serviceControlResult.ControlIntId 
				$subscriptionScanResult.ControlSeverity = $serviceControlResult.ControlSeverity 
				$subscriptionScanResult.ActualVerificationResult = $serviceControlResult.ActualVerificationResult 
				$subscriptionScanResult.AttestedBy =  $serviceControlResult.AttestedBy 
				$subscriptionScanResult.AttestedDate = $serviceControlResult.AttestedDate
				$subscriptionScanResult.Justification = $serviceControlResult.Justification
				$subscriptionScanResult.AttestationStatus = $serviceControlResult.AttestationStatus
				$subscriptionScanResult.AttestationData = $serviceControlResult.AttestedState
				$subscriptionScanResult.VerificationResult = $serviceControlResult.VerificationResult
				$subscriptionScanResult.ScanKind = $scanResult.ScanKind
				$subscriptionScanResult.ScannerModuleName = [Constants]::AzSKModuleName
				$subscriptionScanResult.IsLatestPSModule = $scanResult.IsLatestPSModule
				$subscriptionScanResult.HasRequiredPermissions = $serviceControlResult.HasRequiredAccess
				$subscriptionScanResult.HasAttestationWritePermissions = $scanResult.HasAttestationWritePermissions
				$subscriptionScanResult.HasAttestationReadPermissions = $scanResult.HasAttestationReadPermissions
				$subscriptionScanResult.UserComments = $serviceControlResult.UserComments
				$subscriptionScanResult.IsBaselineControl = $serviceControlResult.IsBaselineControl
				$subscriptionScanResult.HasOwnerAccessTag = $serviceControlResult.HasOwnerAccessTag

				if($subscriptionScanResult.ActualVerificationResult -ne [VerificationResult]::Passed)
				{
					$subscriptionScanResult.FirstFailedOn = [DateTime]::UtcNow
				}
				if($subscriptionScanResult.AttestationStatus -ne [AttestationStatus]::None)
				{
					$subscriptionScanResult.FirstAttestedOn = [DateTime]::UtcNow
					$subscriptionScanResult.AttestationCounter = 1
				}
				$subscriptionScanResult.FirstScannedOn = [DateTime]::UtcNow
				$subscriptionScanResult.LastResultTransitionOn = [DateTime]::UtcNow
				$subscriptionScanResult.LastScannedOn = [DateTime]::UtcNow
				$scanDetails.SubscriptionScanResult += $subscriptionScanResult
			}
        }
        $storageReport.ScanDetails = $scanDetails;

        return $storageReport;
    }

    hidden [LSRSubscription] SerializeServiceScanReport($scanResult)
    {
        $storageReport = [LSRSubscription]::new()
        $storageReport.SubscriptionId = $scanResult.SubscriptionId
        $storageReport.SubscriptionName = $scanResult.SubscriptionName 
        
        $resources = [LSRResources]::new()
        $resources.HashId = [Helpers]::ComputeHash($scanResult.ResourceId)
        $resources.ResourceId = $scanResult.ResourceId
        $resources.FeatureName = $scanResult.Feature
        $resources.ResourceGroupName = $scanResult.ResourceGroup
        $resources.ResourceName = $scanResult.ResourceName
        $resources.FirstScannedOn = [DateTime]::UtcNow
        $resources.LastEventOn = [DateTime]::UtcNow

        #$resources.ResourceMetadata = $scanResult.Metadata

        $scanResult.ControlResults | ForEach-Object {
                $serviceControlResult = $_
				if($scanResult.IsLatestPSModule -and $serviceControlResult.HasRequiredAccess -and $scanResult.HasAttestationReadPermissions)
				{
					$resourceScanResult = [LSRResourceScanResult]::new()
					$resourceScanResult.ScannedBy = [Helpers]::GetCurrentRMContext().Account
					$resourceScanResult.ScanSource = $scanResult.Source
					$resourceScanResult.ScannerVersion = $scanResult.ScannerVersion 
					$resourceScanResult.ControlVersion = $scanResult.ControlVersion
					$resourceScanResult.ChildResourceName = $serviceControlResult.NestedResourceName 
					$resourceScanResult.ControlId = $serviceControlResult.ControlId 
					$resourceScanResult.ControlIntId = $serviceControlResult.ControlIntId 
					$resourceScanResult.ControlSeverity = $serviceControlResult.ControlSeverity 
					$resourceScanResult.ActualVerificationResult = $serviceControlResult.ActualVerificationResult 
					$resourceScanResult.AttestedBy =  $serviceControlResult.AttestedBy 
					$resourceScanResult.AttestedDate = $serviceControlResult.AttestedDate
					$resourceScanResult.Justification = $serviceControlResult.Justification
					$resourceScanResult.AttestationStatus = $serviceControlResult.AttestationStatus
					$resourceScanResult.AttestationData = $serviceControlResult.AttestedState
					$resourceScanResult.VerificationResult = $serviceControlResult.VerificationResult
					$resourceScanResult.ScanKind = $scanResult.ScanKind
					$resourceScanResult.ScannerModuleName = [Constants]::AzSKModuleName
					$resourceScanResult.IsLatestPSModule = $scanResult.IsLatestPSModule
					$resourceScanResult.HasRequiredPermissions = $serviceControlResult.HasRequiredAccess
					$resourceScanResult.HasAttestationWritePermissions = $scanResult.HasAttestationWritePermissions
					$resourceScanResult.HasAttestationReadPermissions = $scanResult.HasAttestationReadPermissions
					$resourceScanResult.UserComments = $serviceControlResult.UserComments
					$resourceScanResult.IsBaselineControl = $serviceControlResult.IsBaselineControl
					$resourceScanResult.HasOwnerAccessTag = $serviceControlResult.HasOwnerAccessTag

					if($resourceScanResult.ActualVerificationResult -ne [VerificationResult]::Passed)
					{
						$resourceScanResult.FirstFailedOn = [DateTime]::UtcNow
					}
					if($resourceScanResult.AttestationStatus -ne [AttestationStatus]::None)
					{
						$resourceScanResult.FirstAttestedOn = [DateTime]::UtcNow
						$resourceScanResult.AttestationCounter = 1
					}

					$resourceScanResult.FirstScannedOn = [DateTime]::UtcNow
					$resourceScanResult.LastResultTransitionOn = [DateTime]::UtcNow
					$resourceScanResult.LastScannedOn = [DateTime]::UtcNow
					#$resourceScanResult.Metadata = $scanResult.Metadata

					$resources.ResourceScanResult += $resourceScanResult
				}

                
        }

        $scanDetails = [LSRScanDetails]::new()
        $scanDetails.Resources += $resources
        $storageReport.ScanDetails = $scanDetails;

        return $storageReport;
    }

    hidden [LocalSubscriptionReport] MergeScanReport([LSRSubscription] $scanReport)
    {
        $_oldScanReport = $this.GetLocalSubscriptionScanReport();

        if([Helpers]::CheckMember($_oldScanReport,"Subscriptions") -and (($_oldScanReport.Subscriptions | Where-Object { $_.SubscriptionId -eq $scanReport.SubscriptionId }) | Measure-Object).Count -gt 0)
        {
            $_oldScanRerportSubscription = $_oldScanReport.Subscriptions | Where-Object { $_.SubscriptionId -eq $scanReport.SubscriptionId }
            if([Helpers]::CheckMember($scanReport,"ScanDetails") -and [Helpers]::CheckMember($scanReport.ScanDetails,"SubscriptionScanResult") `
                    -and ($scanReport.ScanDetails.SubscriptionScanResult | Measure-Object).Count -gt 0)
            {
                if([Helpers]::CheckMember($_oldScanRerportSubscription,"ScanDetails") -and [Helpers]::CheckMember($_oldScanRerportSubscription.ScanDetails,"SubscriptionScanResult") `
                        -and ($_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult | Measure-Object).Count -gt 0)
                {
                    $scanReport.ScanDetails.SubscriptionScanResult | ForEach-Object {
                        $subcriptionScanResult = [LSRSubscriptionControlResult] $_
                        
                        if((($_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult | Where-Object { $subcriptionScanResult.ControlIntId -eq $_.ControlIntId }) | Measure-Object).Count -gt0)
                        {
                            $_ORsubcriptionScanResult = $_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult | Where-Object { $subcriptionScanResult.ControlIntId -eq $_.ControlIntId }
                            $_ORsubcriptionScanResult.ScanKind = $subcriptionScanResult.ScanKind
                            $_ORsubcriptionScanResult.ControlIntId = $subcriptionScanResult.ControlIntId
                            $_ORsubcriptionScanResult.ControlUpdatedOn = $subcriptionScanResult.ControlUpdatedOn
                            $_ORsubcriptionScanResult.ControlSeverity = $subcriptionScanResult.ControlSeverity

                            if($subcriptionScanResult.AttestationStatus -ne [AttestationStatus]::None -and ($subcriptionScanResult.AttestationStatus -ne $_ORsubcriptionScanResult.AttestationStatus -or $subcriptionScanResult.Justification -ne $_ORsubcriptionScanResult.Justification))
                            {
                                $_ORsubcriptionScanResult.AttestationCounter = $_ORsubcriptionScanResult.AttestationCounter + 1
                            }
                            if($_ORsubcriptionScanResult.VerificationResult -ne $subcriptionScanResult.VerificationResult)
                            {
                                $_ORsubcriptionScanResult.LastResultTransitionOn = [System.DateTime]::UtcNow
                            }

                            $_ORsubcriptionScanResult.PreviousVerificationResult = $_ORsubcriptionScanResult.ActualVerificationResult
                            $_ORsubcriptionScanResult.ActualVerificationResult = $subcriptionScanResult.ActualVerificationResult
                            $_ORsubcriptionScanResult.AttestationStatus = $subcriptionScanResult.AttestationStatus
                            $_ORsubcriptionScanResult.VerificationResult = $subcriptionScanResult.VerificationResult
                            $_ORsubcriptionScanResult.AttestedBy = $subcriptionScanResult.AttestedBy
                            $_ORsubcriptionScanResult.AttestedDate = $subcriptionScanResult.AttestedDate
                            $_ORsubcriptionScanResult.Justification = $subcriptionScanResult.Justification
                            $_ORsubcriptionScanResult.AttestationData = $subcriptionScanResult.AttestationData
                            $_ORsubcriptionScanResult.LastScannedOn = [System.DateTime]::UtcNow

                            if($_ORsubcriptionScanResult.FirstScannedOn -eq [Constants]::AzSKDefaultDateTime)
                            {
                                $_ORsubcriptionScanResult.FirstScannedOn = [System.DateTime]::UtcNow
                            }
                            
                            if($_ORsubcriptionScanResult.FirstFailedOn -eq [Constants]::AzSKDefaultDateTime -and $subcriptionScanResult.ActualVerificationResult -eq [VerificationResult]::Failed)
                            {
                                $_ORsubcriptionScanResult.FirstFailedOn = [System.DateTime]::UtcNow
                            }

                            if($_ORsubcriptionScanResult.FirstAttestedOn -eq [Constants]::AzSKDefaultDateTime -and $subcriptionScanResult.AttestationStatus -ne [AttestationStatus]::None)
                            {
                                $_ORsubcriptionScanResult.FirstAttestedOn = [System.DateTime]::UtcNow
                            }

                            $_ORsubcriptionScanResult.ScannedBy = $subcriptionScanResult.ScannedBy
                            $_ORsubcriptionScanResult.ScanSource = $subcriptionScanResult.ScanSource
                            $_ORsubcriptionScanResult.ScannerModuleName = $subcriptionScanResult.ScannerModuleName
                            $_ORsubcriptionScanResult.ScannerVersion = $subcriptionScanResult.ScannerVersion
                            $_ORsubcriptionScanResult.ControlVersion = $subcriptionScanResult.ControlVersion
                            $_ORsubcriptionScanResult.IsLatestPSModule = $subcriptionScanResult.IsLatestPSModule
                            $_ORsubcriptionScanResult.HasRequiredPermissions = $subcriptionScanResult.HasRequiredPermissions
                            $_ORsubcriptionScanResult.HasAttestationWritePermissions = $subcriptionScanResult.HasAttestationWritePermissions
                            $_ORsubcriptionScanResult.HasAttestationReadPermissions = $subcriptionScanResult.HasAttestationReadPermissions
                            $_ORsubcriptionScanResult.UserComments = $subcriptionScanResult.UserComments
                            $_ORsubcriptionScanResult.Metadata = $subcriptionScanResult.Metadata
							$_ORsubcriptionScanResult.IsBaselineControl = $subcriptionScanResult.IsBaselineControl
							$_ORsubcriptionScanResult.HasOwnerAccessTag = $subcriptionScanResult.HasOwnerAccessTag
                            
							$_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult = $_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult | Where-Object { $subcriptionScanResult.ControlIntId -ne $_.ControlIntId }
                            $_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult += $_ORsubcriptionScanResult
                        }
                    }
                }
                else
                {
                    $_oldScanRerportSubscription.ScanDetails.SubscriptionScanResult += $scanReport.ScanDetails.SubscriptionScanResult;
                }
            }

            if([Helpers]::CheckMember($scanReport,"ScanDetails")  -and [Helpers]::CheckMember($scanReport.ScanDetails,"Resources") `
                -and ($scanReport.ScanDetails.Resources | Measure-Object).Count -gt 0)
            {
                if([Helpers]::CheckMember($_oldScanRerportSubscription,"ScanDetails") -and [Helpers]::CheckMember($_oldScanRerportSubscription.ScanDetails,"Resources") `
                         -and ($_oldScanRerportSubscription.ScanDetails.Resources | Measure-Object).Count -gt 0)
                {
                    $scanReport.ScanDetails.Resources | Foreach-Object {
                        $resource = [LSRResources] $_

                        if([Helpers]::CheckMember($_oldScanRerportSubscription.ScanDetails,"Resources") -and (($_oldScanRerportSubscription.ScanDetails.Resources | Where-Object { $resource.HashId -contains $_.HashId }) | Measure-Object).Count -gt0)
                        {
                            $_ORresource = $_oldScanRerportSubscription.ScanDetails.Resources | Where-Object { $resource.HashId -contains $_.HashId }
                            $_ORresource.LastEventOn = [DateTime]::UtcNow

                            $resource.ResourceScanResult | ForEach-Object {

                                $newControlResult = [LSRResourceScanResult] $_
                                if([Helpers]::CheckMember($_ORresource,"ResourceScanResult") -and (($_ORresource.ResourceScanResult | Where-Object { $_.ControlIntId -eq $newControlResult.ControlIntId -and $_.ChildResourceName -eq $newControlResult.ChildResourceName }) | Measure-Object).Count -eq 0)
                                {
                                    $_ORresource.ResourceScanResult += $newControlResult
                                }
                                else
                                {
                                    $_oldControlResult = $_ORresource.ResourceScanResult | Where-Object { $_.ControlIntId -eq $newControlResult.ControlIntId -and $_.ChildResourceName -eq $newControlResult.ChildResourceName }

                                    $_oldControlResult.ScanKind = $newControlResult.ScanKind
                                    $_oldControlResult.ControlIntId = $newControlResult.ControlIntId
                                    $_oldControlResult.ControlUpdatedOn = $newControlResult.ControlUpdatedOn
                                    $_oldControlResult.ControlSeverity = $newControlResult.ControlSeverity

                                    if($newControlResult.AttestationStatus -ne [AttestationStatus]::None -and($newControlResult.AttestationStatus -ne $_oldControlResult.AttestationStatus -or $newControlResult.Justification -ne $_oldControlResult.Justification))
                                    {
                                        $_oldControlResult.AttestationCounter = $_oldControlResult.AttestationCounter + 1 
                                    }
                                    if($_oldControlResult.VerificationResult -ne $newControlResult.VerificationResult)
                                    {
                                        $_oldControlResult.LastResultTransitionOn = [System.DateTime]::UtcNow
                                    }

                                    $_oldControlResult.PreviousVerificationResult = $_oldControlResult.VerificationResult
                                    $_oldControlResult.ActualVerificationResult = $newControlResult.ActualVerificationResult
                                    $_oldControlResult.AttestationStatus = $newControlResult.AttestationStatus
                                    $_oldControlResult.VerificationResult = $newControlResult.VerificationResult
                                    $_oldControlResult.AttestedBy = $newControlResult.AttestedBy
                                    $_oldControlResult.AttestedDate = $newControlResult.AttestedDate
                                    $_oldControlResult.Justification = $newControlResult.Justification
                                    $_oldControlResult.AttestationData = $newControlResult.AttestationData
                                    $_oldControlResult.IsBaselineControl = $newControlResult.IsBaselineControl
                                    $_oldControlResult.LastScannedOn = [System.DateTime]::UtcNow

                                    if($_oldControlResult.FirstScannedOn -eq [Constants]::AzSKDefaultDateTime)
                                    {
                                        $_oldControlResult.FirstScannedOn = [System.DateTime]::UtcNow
                                    }
                                    
                                    if($_oldControlResult.FirstFailedOn -eq [Constants]::AzSKDefaultDateTime -and $newControlResult.ActualVerificationResult -eq [VerificationResult]::Failed)
                                    {
                                        $_oldControlResult.FirstFailedOn = [System.DateTime]::UtcNow
                                    }

                                    if($_oldControlResult.FirstAttestedOn -eq [Constants]::AzSKDefaultDateTime -and $newControlResult.AttestationStatus -ne [AttestationStatus]::None)
                                    {
                                        $_oldControlResult.FirstAttestedOn = [System.DateTime]::UtcNow
                                    }
                                    
                                    $_oldControlResult.ScannedBy = $newControlResult.ScannedBy
                                    
                                    $_oldControlResult.ScanSource = $newControlResult.ScanSource
                                    $_oldControlResult.ScannerModuleName = $newControlResult.ScannerModuleName
                                    $_oldControlResult.ScannerVersion = $newControlResult.ScannerVersion
                                    $_oldControlResult.ControlVersion = $newControlResult.ControlVersion
                                    $_oldControlResult.IsLatestPSModule = $newControlResult.IsLatestPSModule
                                    $_oldControlResult.HasRequiredPermissions = $newControlResult.HasRequiredPermissions
                                    $_oldControlResult.HasAttestationWritePermissions = $newControlResult.HasAttestationWritePermissions
                                    $_oldControlResult.HasAttestationReadPermissions = $newControlResult.HasAttestationReadPermissions
                                    $_oldControlResult.UserComments = $newControlResult.UserComments
                                    $_oldControlResult.Metadata = $newControlResult.Metadata
									$_oldControlResult.HasOwnerAccessTag = $newControlResult.HasOwnerAccessTag

                                    $_ORresource.ResourceScanResult = $_ORresource.ResourceScanResult | Where-Object { $_.ControlIntId -ne $_oldControlResult.ControlIntId -or  $_.ChildResourceName -ne  $_oldControlResult.ChildResourceName }
                                    $_ORresource.ResourceScanResult += $_oldControlResult
                                }
                            }
                        }
                        else
                        {
                            $_oldScanRerportSubscription.ScanDetails.Resources += $resource
                        }
                    }
                }
                else
                {
                    $_oldScanRerportSubscription.ScanDetails.Resources += $scanReport.ScanDetails.Resources;
                }
            }

            $_oldScanReport.Subscriptions = $_oldScanReport.Subscriptions | Where-Object { $_.SubscriptionId -ne $scanReport.SubscriptionId }
            $_oldScanReport.Subscriptions += $_oldScanRerportSubscription
        }
        else
        {
            if([Helpers]::CheckMember($_oldScanReport,"Subscriptions"))
            {
                $_oldScanReport.Subscriptions += $scanReport;
            }
            else
            {
                $_oldScanReport = [LocalSubscriptionReport]::new()
                $_oldScanReport.Subscriptions += $scanReport;
            }
            
        }

        return $_oldScanReport
    }

    [bool] HasStorageReportReadAccessPermissions()
	{
		if($this.HasStorageReportReadPermissions -le 0)
		{
			return $false;
		}
		else
		{
			return $true;
		}
	}

	[bool] HasStorageReportWriteAccessPermissions()
	{		
		if($this.HasStorageReportWritePermissions -le 0)
		{
			return $false;
		}
		else
		{
			return $true;
		}
	}

	hidden [LSRSubscription] SerializeResourceInventory($resourceInventory)
    {
        $storageReport = [LSRSubscription]::new()
        $storageReport.SubscriptionId = $resourceInventory.SubscriptionId
        # $storageReport.SubscriptionName = $scanResult.SubscriptionName 
		if([Helpers]::CheckMember($resourceInventory,"ResourceGroups") -and ($resourceInventory.ResourceGroups | Measure-Object ).Count -gt 0)
		{
			$scanDetails = [LSRScanDetails]::new()
			$resourceInventory.ResourceGroups | ForEach-Object 
			{
				$resourcegroups = $_
				if([Helpers]::CheckMember($resourcegroups,"Resources") -and ($resourcegroups.Resources | Measure-Object ).Count -gt 0)
				{
					$resource = $_
					$newResource = [LSRResources]::new()
					$newResource.HashId = [Helpers]::ComputeHash($resource.ResourceId)
					$newResource.ResourceId = $resource.ResourceId
					$newResource.FeatureName = $resource.Feature
					$newResource.ResourceGroupName = $resourcegroups.Name
					$newResource.ResourceName = $resource.Name

					$scanDetails.Resources += $newResource
				}
			}
			$storageReport.ScanDetails = $scanDetails;
		}
        return $storageReport;
    }
}
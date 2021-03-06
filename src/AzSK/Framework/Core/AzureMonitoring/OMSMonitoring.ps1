Set-StrictMode -Version Latest 

class OMSMonitoring: CommandBase
{
	[string] $OMSSampleViewTemplateFilepath;
	[string] $OMSSearchesTemplateFilepath;
	[string] $OMSAlertsTemplateFilepath;
	[string] $OMSGenericTemplateFilepath;
	
	[string] $OMSLocation;
	[string] $OMSResourceGroup;
	[string] $OMSWorkspaceName;
	[string] $OMSWorkspaceId;
	[string] $ApplicationSubscriptionName

	OMSMonitoring([string] $_omsSubscriptionId,[string] $_omsResourceGroup,[string] $_omsWorkspaceId, [InvocationInfo] $invocationContext): 
        Base([string] $_omsSubscriptionId, $invocationContext) 
    { 	
		
			
					$this.OMSResourceGroup = $_omsResourceGroup
					$this.OMSWorkspaceId = $_omsWorkspaceId
					$omsWorkSpaceInstance = Get-AzOperationalInsightsWorkspace | Where-Object {$_.CustomerId -eq "$_omsWorkspaceId" -and $_.ResourceGroupName -eq  "$($this.OMSResourceGroup)"}
					if($null -eq $omsWorkSpaceInstance)
					{
						throw [SuppressedException] "Invalid Log Analytics Workspace."
					}
					$this.OMSWorkspaceName = $omsWorkSpaceInstance.Name;
					$locationInstance = Get-AzLocation | Where-Object { $_.DisplayName -eq $omsWorkSpaceInstance.Location -or  $_.Location -eq $omsWorkSpaceInstance.Location } 
					$this.OMSLocation = $locationInstance.Location
				
		
	}

	[void] ConfigureOMS([string] $_viewName, [bool] $_validateOnly)	
    {		
	   Write-Host "WARNING: This command will overwrite the existing AzSK Security View that you may have installed using previous versions of AzSK if you are using the same view name as the one used earlier. In that case we recommend taking a backup using 'Edit -> Export' option available in the Log Analytics workspace.`n" -ForegroundColor Yellow
	   $input = Read-Host "Enter 'Y' to continue and 'N' to skip installation (Y/N)"
		while ($input -ne "y" -and $input -ne "n")
		{
        if (-not [string]::IsNullOrEmpty($input)) {
			$this.PublishCustomMessage(("Please select an appropriate option.`n" + [Constants]::DoubleDashLine), [MessageType]::Warning)
                  
        }
        $input = Read-Host "Enter 'Y' to continue and 'N' to skip installation (Y/N)"
        $input = $input.Trim()
				
		}
		if ($input -eq "y") 
		{
			$this.PublishCustomMessage([Constants]::DoubleDashLine + "`r`nStarted setting up AzSK Monitoring solution pack`r`n"+[Constants]::DoubleDashLine);
		
			$OptionalParameters = New-Object -TypeName Hashtable

			$OMSLogPath = [Constants]::AzSKTempFolderPath + "\OMS";
			if(-not (Test-Path -Path $OMSLogPath))
			{
				mkdir -Path $OMSLogPath -Force | Out-Null
			}
					
			$genericViewTemplateFilepath = [ConfigurationManager]::LoadServerConfigFile("AZSK.AM.OMS.GenericView.V5.omsview"); 				
			$this.OMSGenericTemplateFilepath = $OMSLogPath+"\AZSK.AM.OMS.GenericView.V5.omsview";
			$genericViewTemplateFilepath | ConvertTo-Json -Depth 100 | Out-File $this.OMSGenericTemplateFilepath
			$this.PublishCustomMessage("`r`nSetting up AzSK Log Analytics generic view.");
			$this.ConfigureGenericView($_viewName, $_validateOnly);	
			$this.PublishCustomMessage([Constants]::SingleDashLine + "`r`nCompleted setting up AzSK Monitoring solution pack.`r`n"+[Constants]::SingleDashLine );
			$this.PublishCustomMessage("`r`nNote: `r`n1) The blades of the Log Analytics view created by this command will start populating only after AzSK scan events become available in the corresponding Log Analytics workspace.`nTo understand how to send AzSK events to a Log Analytics workspace see https://aka.ms/devopskit/oms.`r`n", [MessageType]::Warning);		
			$this.PublishCustomMessage("`r`n2) The Log Analytics view installed contains a basic set of queries over DevOps Kit scan events. Please feel free to customize them once you get familiar with the queries.`r`nWe also periodically publish updated/richer queries at: https://aka.ms/devopskit/omsqueries. `r`n",[MessageType]::Warning);
		
		}
		if ($input -eq "n")
		{
			$this.PublishCustomMessage("Skipping installation of AzSK Monitoring solution pack...`n" , [MessageType]::Info)
			return;
		}
    }

	[void] ConfigureGenericView([string] $_viewName, [bool] $_validateOnly)
	{
		$OptionalParameters = New-Object -TypeName Hashtable
		$OptionalParameters = $this.GetOMSGenericViewParameters($_viewName);
		$this.PublishCustomMessage([MessageData]::new("Starting template deployment for Log Analytics generic view. Detailed logs are shown below."));
		$ErrorMessages = @()
        if ($_validateOnly) {
            $ErrorMessages =@()
                Test-AzResourceGroupDeployment -ResourceGroupName $this.OMSResourceGroup `
                                                    -TemplateFile $this.OMSGenericTemplateFilepath `
                                                    -TemplateParameterObject $OptionalParameters -Verbose
		}
        else {

            $ErrorMessages =@()
			$SubErrorMessages = @()
            New-AzResourceGroupDeployment -Name ((Get-ChildItem $this.OMSGenericTemplateFilepath).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                        -ResourceGroupName $this.OMSResourceGroup `
                                        -TemplateFile $this.OMSGenericTemplateFilepath  `
                                        -TemplateParameterObject $OptionalParameters `
                                        -Verbose -Force -ErrorVariable SubErrorMessages
            $SubErrorMessages = $SubErrorMessages | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") }
            $ErrorMessages += $SubErrorMessages
           
        }
        if ($ErrorMessages)
        {
            "", ("{0} returned the following errors:" -f ("Template deployment", "Validation")[[bool]$_validateOnly]), @($ErrorMessages) | ForEach-Object { $this.PublishCustomMessage([MessageData]::new($_));}
        }
		else
		{
			$this.PublishCustomMessage([MessageData]::new("Completed template deployment for Log Analytics generic view."));			
		}
	}

	[Hashtable] GetOMSGenericViewParameters([string] $_applicationName)
	{
		[Hashtable] $omsParams = $this.GetOMSBaseParameters();
		$omsParams.Add("viewName",$_applicationName);
		return $omsParams;
	}

	[Hashtable] GetOMSBaseParameters()
	{
		[Hashtable] $omsParams = @{};
		$omsParams.Add("location",$this.OMSLocation);
		$omsParams.Add("resourcegroup",$this.OMSResourceGroup);
		$omsParams.Add("subscriptionId",$this.SubscriptionContext.SubscriptionId);
		$omsParams.Add("workspace",$this.OMSWorkspaceName);
        $omsParams.Add("workspaceapiversion", "2017-04-26-preview")
		return $omsParams;
	}	
}

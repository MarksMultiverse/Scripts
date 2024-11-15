# This code generates a random password and stores it in an Azure KeyVault.
# There it can be picked up by newely created vitual machines.
# This is an example what a .bicep file will look like:
#
#   resource randomAdminPassword 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
#   name: 'randomAdminPassword-${uniqueString(deployment().name, location)}'
#   location: location
#   kind: 'AzurePowerShell'
#   identity: {
#     type: 'UserAssigned'
#     userAssignedIdentities: {
#       '${managedIdentity.id}': {}
#     }
#   }
#   properties: {
#     arguments: '-numberOfInstances ${numberOfInstances} -AZKVaultName ${AZKVaultName} -PadLeftInt ${padLeftInt}'-vmNamePrefix {$vmNamePrefix} -environmentName $(environmentName)-index $(vmInitialNumber)'
#     azPowerShellVersion: '12.3.0'
#     retentionInterval: 'P1D'
#     scriptContent: loadTextContent('../../../scripts/Generate-passwords-as-secrets.ps1')
#   }
# }
# 
# The following line could be added to th virtuel machine resource/ module:
#       adminPassword: keyVault.getSecret(toUpper('${vmNamePrefix}${padLeft((i+vmInitialNumber),padLeftInt,'0')}-${environmentName}-password'))


Param (
    [Parameter(Mandatory = $true)]
    [string]$keyVaultName,
    [Parameter(Mandatory = $true)]
    [string]$vmNamePrefix,
    [Parameter(Mandatory = $true)]
    [string]$environmentName,
    [Parameter(Mandatory = $true)]
    [int]$index,
    [Parameter(Mandatory = $true)]
    [int]$numberOfInstances,
    [Parameter(Mandatory = $true)]
    [int]$padLeftInt
)

function New-Password {
    <#
    .SYNOPSIS
        Generate a random password.
    .DESCRIPTION
        Generate a random password.
    .NOTES
        Change log:
            27/11/2017 - faustonascimento - Swapped Get-Random for System.Random.
            Swapped Sort-Object for Fisher-Yates shuffle.
            17/03/2017 - Chris Dent - Created.
            Borrowed from https://gist.github.com/indented-automation/2093bd088d59b362ec2a5b81a14ba84e
    #>
 
    [CmdletBinding()]
    [OutputType([String])]
    param (
        # The length of the password which should be created.
        [Parameter(ValueFromPipeline)]
        [ValidateRange(8, 255)]
        [Int32]$Length = 12,
 
        # The character sets the password may contain. A password will contain at least one of each of the characters.
        [String[]]$CharacterSet = ('abcdefghijklmnopqrstuvwxyz',
            'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
            '0123456789',
            '!$%&^.#;'),
 
        # The number of characters to select from each character set.
        [Int32[]]$CharacterSetCount = (@(1) * $CharacterSet.Count)
    )
 
    begin {
        $bytes = [Byte[]]::new(4)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
 
        $seed = [System.BitConverter]::ToInt32($bytes, 0)
        $rnd = [Random]::new($seed)
 
        if ($CharacterSet.Count -ne $CharacterSetCount.Count) {
            throw "The number of items in -CharacterSet needs to match the number of items in -CharacterSetCount"
        }
 
        $allCharacterSets = [String]::Concat($CharacterSet)
    }
 
    process {
        try {
            $requiredCharLength = 0
            foreach ($i in $CharacterSetCount) {
                $requiredCharLength += $i
            }
 
            if ($requiredCharLength -gt $Length) {
                throw "The sum of characters specified by CharacterSetCount is higher than the desired password length"
            }
 
            $password = [Char[]]::new($Length)
            $index = 0
 
            for ($i = 0; $i -lt $CharacterSet.Count; $i++) {
                for ($j = 0; $j -lt $CharacterSetCount[$i]; $j++) {
                    $password[$index++] = $CharacterSet[$i][$rnd.Next($CharacterSet[$i].Length)]
                }
            }
 
            for ($i = $index; $i -lt $Length; $i++) {
                $password[$index++] = $allCharacterSets[$rnd.Next($allCharacterSets.Length)]
            }
 
            # Fisher-Yates shuffle
            for ($i = $Length; $i -gt 0; $i--) {
                $n = $i - 1
                $m = $rnd.Next($i)
                $j = $password[$m]
                $password[$m] = $password[$n]
                $password[$n] = $j
            }
 
            [String]::new($password)
        }
        catch {
            Write-Error -ErrorRecord $_
        }
    }
}

$ListOfVM = for ($i = $index; $i -lt ($index + $numberOfInstances); $i++) {
    $VMNamePrefix + ($i).toString().PadLeft($padLeftInt, '0') + "-" + $environmentName
}

$Secrets = Get-AzKeyVaultSecret -VaultName $keyVaultName

foreach ($VMName in $ListOfVM) {
    if ($null -eq ($Secrets | Where-Object Name -EQ "$VMName-password")) {
        try {
            "Creating new password for $VMName and pushing to KeyVault $keyVaultName"
            $newPassword = ConvertTo-SecureString(New-Password) -AsPlainText -Force
            Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "$VMName-password" -SecretValue $newPassword
        }
        catch {
            $_
            Write-Error "Failed to create password for $VMName in KeyVault $keyVaultName"
        }
    }
    else {
        Write-Host "Password for $VMName already exists"
    }
}
